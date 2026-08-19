-- Forecasting one location, which the schema has allowed all along and
-- nothing could ask for.
--
-- `warehouse_id` is nullable throughout the module and null means "the
-- company". `run_inventory_forecast` has taken a `p_warehouse` argument
-- since 0200, `app.demand_series` filters movements by it,
-- `item_forecast_params` is keyed on it, and every forecast line records
-- it. A business with four locations could not reach any of it, because
-- nothing ever passed anything but null.
--
-- ## The run did not know where it was
--
-- The reason this is a migration and not a dropdown. `forecast_runs`
-- recorded every parameter it used — the bucket, the horizon, the
-- service level, all copied so a suggestion stays defensible months
-- later — and not the one that says *which stock it was about*. The
-- warehouse reached the lines and never the run.
--
-- That is fine while there is only ever one run, and wrong the moment
-- there are two. `forecast_suggestions` asks for "the latest run for
-- this organization"; forecast the main store, then forecast the branch,
-- then open the main store and you are shown the branch's answers under
-- the main store's heading. Nothing errors. The numbers are real
-- numbers. They are about somewhere else.
--
-- So the column goes on the run, and every read is keyed on
-- (organization, warehouse) rather than organization. Existing rows keep
-- null, which is not a backfill dodge: every run made so far was made
-- with no warehouse, and null already means exactly that.
--
-- ## `is not distinct from`, not `=`
--
-- The company-level run has a null warehouse, and `warehouse_id = null`
-- is null rather than true — so a plain equality finds no run at all and
-- the replenishment screen goes empty for every company that has not
-- named a location. The one comparison in this file that has to be
-- written the long way.
--
-- ## What picking a location changes
--
-- More than the filter. `count_transfers_out` is described in 0197 as
-- meaningful only when forecasting a single warehouse — at company level
-- a transfer out is matched by a transfer in and nets to nothing, which
-- is the right answer rather than a coincidence. Until now that setting
-- could be switched on and never mean anything. This is the screen that
-- gives it a purpose.

-- ---------------------------------------------------------------------
-- Where the run was
-- ---------------------------------------------------------------------
alter table public.forecast_runs
  add column if not exists warehouse_id uuid
    references public.warehouses (id) on delete cascade;

comment on column public.forecast_runs.warehouse_id is
  'The location this run was about, or null for the company as a whole. '
  'On the run rather than only on its lines, because "the latest run" '
  'is a question about a place as well as a company — without it a '
  'branch''s figures are shown under the main store''s heading and '
  'nothing says so.';

-- The lookup every read below performs.
create index if not exists forecast_runs_latest_idx
  on public.forecast_runs (org_id, warehouse_id, run_at desc);

create or replace function public.run_inventory_forecast(
  p_org       uuid,
  p_warehouse uuid default null,
  p_as_of     date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_s            public.forecast_settings%rowtype;
  v_run          uuid;
  v_item         record;
  v_hist         numeric[];
  v_mean_bucket  numeric;
  v_sd_bucket    numeric;
  v_mean_daily   numeric;
  v_sd_daily     numeric;
  v_bdays        numeric;
  v_method       app.forecast_method;
  v_window       integer;
  v_alpha        numeric;
  v_service      numeric;
  v_fc           numeric[];
  v_lead         numeric;
  v_lead_src     text;
  v_ss           numeric;
  v_rop          numeric;
  v_onhand       numeric;
  v_reserved     numeric;
  v_onorder      numeric;
  v_avail        numeric;
  v_cover        numeric;
  v_state        app.replenishment_state;
  v_qty          numeric;
  v_review       numeric;
  v_periods      integer;
  v_considered   integer := 0;
  v_forecast     integer := 0;
  v_skipped      integer := 0;
  v_suggested    integer := 0;
  v_supplier     uuid;
  v_from         date;
begin
  if not app.can_write_module(p_org, 'forecasting') then
    raise exception 'not permitted to run a forecast for this organization'
      using errcode = '42501';
  end if;

  select * into v_s from public.forecast_settings where org_id = p_org;
  if not found then
    -- Running before anybody has visited the settings screen is the
    -- normal first experience, not an error. The defaults are written
    -- down rather than assumed so the run records what it used.
    insert into public.forecast_settings (org_id) values (p_org)
    returning * into v_s;
  end if;

  v_bdays  := app.bucket_days(v_s.bucket);
  v_review := v_s.horizon_buckets * v_bdays;
  v_from   := p_as_of - v_s.history_days;

  -- The warehouse the run was for, recorded on the run itself rather
  -- than inferred from its lines. Without it "the latest run for this
  -- company" is the wrong question the moment a second location is
  -- forecast, and the answer it gives is another warehouse's.
  insert into public.forecast_runs (
    org_id, warehouse_id, run_by, as_of_date, bucket, horizon_buckets,
    history_days, service_level, default_method, count_transfers_out,
    count_shrinkage)
  values (
    p_org, p_warehouse, auth.uid(), p_as_of, v_s.bucket, v_s.horizon_buckets,
    v_s.history_days, v_s.service_level, v_s.default_method,
    v_s.count_transfers_out, v_s.count_shrinkage)
  returning id into v_run;

  for v_item in
    select i.id, i.reorder_level, i.reorder_quantity, i.preferred_supplier_id,
           p.method, p.window_periods, p.alpha, p.service_level as p_service,
           p.lead_time_days as p_lead, p.min_quantity, p.max_quantity,
           p.min_order_quantity, p.order_multiple, p.supplier_id, p.is_excluded
      from public.items i
      left join public.item_forecast_params p
        on p.org_id = i.org_id and p.item_id = i.id
       and p.warehouse_id is not distinct from p_warehouse
     where i.org_id = p_org
       and i.track_inventory
       and i.is_active
       and i.deleted_at is null
     order by i.code
  loop
    v_considered := v_considered + 1;

    if coalesce(v_item.is_excluded, false) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- Every parameter: the item's own answer, or the company's.
    v_method  := coalesce(v_item.method, v_s.default_method);
    v_window  := coalesce(v_item.window_periods, v_s.default_window);
    v_alpha   := coalesce(v_item.alpha, v_s.default_alpha);
    v_service := coalesce(v_item.p_service, v_s.service_level);

    select array_agg(d.qty order by d.period_start)
      into v_hist
      from app.demand_series(p_org, v_item.id, p_warehouse, v_s.bucket,
                             v_from, p_as_of,
                             v_s.count_transfers_out, v_s.count_shrinkage) d;

    v_periods := coalesce(array_length(v_hist, 1), 0);

    if v_periods < v_s.min_periods then
      -- Recorded rather than dropped. An item silently absent from a
      -- replenishment report is an item nobody notices they stopped
      -- ordering.
      insert into public.forecast_lines (
        org_id, run_id, item_id, warehouse_id, method_used, periods_used,
        skipped_reason, lead_time_days, lead_time_source, state,
        manual_reorder_level, manual_reorder_quantity)
      values (
        p_org, v_run, v_item.id, p_warehouse, v_method, v_periods,
        format('only %s period(s) of history, %s required',
               v_periods, v_s.min_periods),
        coalesce(v_item.p_lead, v_s.default_lead_time_days), 'settings', 'ok',
        v_item.reorder_level, v_item.reorder_quantity);
      v_skipped := v_skipped + 1;
      continue;
    end if;

    select avg(x), coalesce(stddev_samp(x), 0) into v_mean_bucket, v_sd_bucket
      from unnest(v_hist) as x;

    -- The two conversions that are not the same conversion. See header.
    v_mean_daily := v_mean_bucket / v_bdays;
    v_sd_daily   := v_sd_bucket / sqrt(v_bdays);

    if v_method = 'seasonal_naive' then
      v_fc := app.forecast_seasonal_naive(v_hist, v_window, v_s.horizon_buckets);
      if v_fc is null then
        -- Not enough history for a season. Falls back and says so, so
        -- the line is not read as a seasonal forecast that it is not.
        v_method := 'moving_average';
        v_fc := app.forecast_moving_average(v_hist, v_window, v_s.horizon_buckets);
      end if;
    elsif v_method = 'exponential_smoothing' then
      v_fc := app.forecast_exponential_smoothing(v_hist, v_alpha, v_s.horizon_buckets);
    else
      v_fc := app.forecast_moving_average(v_hist, v_window, v_s.horizon_buckets);
    end if;

    v_supplier := coalesce(v_item.supplier_id, v_item.preferred_supplier_id);

    -- Lead time, best evidence first.
    if v_item.p_lead is not null then
      v_lead := v_item.p_lead; v_lead_src := 'item';
    else
      v_lead := app.measured_lead_time(p_org, v_item.id, v_supplier);
      if v_lead is not null then
        v_lead_src := 'measured';
      else
        v_lead := v_s.default_lead_time_days; v_lead_src := 'settings';
      end if;
    end if;

    v_ss  := app.safety_stock(v_service, v_sd_daily, v_lead);
    v_rop := app.reorder_point(v_mean_daily, v_lead, v_ss);

    select coalesce(sum(sl.quantity), 0), coalesce(sum(sl.reserved_quantity), 0)
      into v_onhand, v_reserved
      from public.stock_levels sl
     where sl.org_id = p_org and sl.item_id = v_item.id
       and (p_warehouse is null or sl.warehouse_id = p_warehouse);

    v_onorder := app.quantity_on_order(p_org, v_item.id, p_warehouse);
    v_avail   := v_onhand - v_reserved + v_onorder;
    v_cover   := app.days_of_cover(v_avail, v_mean_daily);

    v_qty := app.suggested_order_qty(
      v_avail, v_mean_daily, v_lead, v_review, v_ss,
      v_item.min_quantity, v_item.max_quantity,
      v_item.min_order_quantity, v_item.order_multiple);

    -- Ordered most urgent first, so the first branch that matches is
    -- the worst true thing about this item.
    if v_onhand <= 0 and v_mean_daily > 0 then
      v_state := 'stocked_out';
    elsif v_avail < v_ss then
      v_state := 'below_safety';
    -- The buyer's own floor counts as a reason to order, and it has to
    -- be tested before the overstocked branches below. Without this an
    -- item held under a same-day availability promise reads
    -- "overstocked" on the strength of its days of cover while the
    -- suggestion beside it says to buy sixteen — both true, and the
    -- label is the loudest thing on the row.
    elsif v_avail <= v_rop
       or (v_item.min_quantity is not null and v_avail < v_item.min_quantity) then
      v_state := 'order_now';
    elsif v_avail <= v_rop + v_mean_daily * v_review then
      v_state := 'order_soon';
    elsif v_item.max_quantity is not null and v_avail > v_item.max_quantity then
      v_state := 'overstocked';
    elsif v_cover is not null and v_cover > (v_lead + v_review) * 3 then
      -- Three times what the pipeline needs. Not a fault, but it is
      -- cash on a shelf and worth being able to sort by.
      v_state := 'overstocked';
    else
      v_state := 'ok';
    end if;

    insert into public.forecast_lines (
      org_id, run_id, item_id, warehouse_id, method_used, periods_used,
      mean_daily_demand, stddev_daily_demand, forecast_buckets, forecast_total,
      lead_time_days, lead_time_source, safety_stock, reorder_point,
      on_hand, reserved, on_order, available, days_cover, stockout_on,
      state, suggested_qty, supplier_id,
      manual_reorder_level, manual_reorder_quantity)
    values (
      p_org, v_run, v_item.id, p_warehouse, v_method, v_periods,
      round(v_mean_daily, 6), round(v_sd_daily, 6),
      coalesce(v_fc, '{}'::numeric[]),
      coalesce((select sum(x) from unnest(coalesce(v_fc, '{}'::numeric[])) x), 0),
      v_lead, v_lead_src, v_ss, v_rop,
      v_onhand, v_reserved, v_onorder, v_avail, v_cover,
      case when v_cover is null then null
           else p_as_of + (floor(v_cover))::integer end,
      v_state, v_qty, v_supplier,
      v_item.reorder_level, v_item.reorder_quantity);

    v_forecast := v_forecast + 1;
    if v_qty > 0 then
      v_suggested := v_suggested + 1;
    end if;
  end loop;

  update public.forecast_runs
     set items_considered = v_considered,
         items_forecast   = v_forecast,
         items_skipped    = v_skipped,
         items_suggested  = v_suggested
   where id = v_run;

  return v_run;
end;
$$;

grant execute on function public.run_inventory_forecast(uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- What the latest run for this place says to order
-- ---------------------------------------------------------------------
--
-- Dropped and recreated rather than replaced, because the argument list
-- changes. Leaving the one-argument version standing beside this would
-- make `{"p_org": ...}` ambiguous to PostgREST, which resolves an RPC by
-- the names it was given — and the failure would be a 300 on a screen
-- that worked yesterday.
drop function if exists public.forecast_suggestions(uuid);

create function public.forecast_suggestions(
  p_org       uuid,
  p_warehouse uuid default null)
returns table (
  line_id           uuid,
  item_id           uuid,
  item_code         text,
  item_name         text,
  uom_code          text,
  warehouse_id      uuid,
  state             app.replenishment_state,
  on_hand           numeric,
  reserved          numeric,
  on_order          numeric,
  available         numeric,
  mean_daily_demand numeric,
  lead_time_days    numeric,
  lead_time_source  text,
  safety_stock      numeric,
  reorder_point     numeric,
  days_cover        numeric,
  stockout_on       date,
  suggested_qty     numeric,
  already_drafted   numeric,
  outstanding       numeric,
  supplier_id       uuid,
  supplier_name     text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, l.item_id, i.code, i.name, i.uom_code, l.warehouse_id, l.state,
         l.on_hand, l.reserved, l.on_order, l.available,
         l.mean_daily_demand, l.lead_time_days, l.lead_time_source,
         l.safety_stock, l.reorder_point, l.days_cover, l.stockout_on,
         l.suggested_qty,
         app.quantity_on_draft_order(l.org_id, l.item_id, l.warehouse_id),
         greatest(l.suggested_qty
                  - app.quantity_on_draft_order(l.org_id, l.item_id, l.warehouse_id), 0),
         l.supplier_id, c.name
    from public.forecast_lines l
    join public.items i on i.id = l.item_id
    left join public.contacts c on c.id = l.supplier_id
   where l.org_id = p_org
     and app.can_read_module(p_org, 'forecasting')
     and l.run_id = (select r.id from public.forecast_runs r
                      where r.org_id = p_org
                        -- Not `=`. See the header.
                        and r.warehouse_id is not distinct from p_warehouse
                      order by r.run_at desc limit 1)
     and l.suggested_qty > 0
   order by array_position(
     array['stocked_out','below_safety','order_now','order_soon','ok','overstocked']
       ::text[], l.state::text),
     l.days_cover nulls last,
     i.code;
$$;

grant execute on function public.forecast_suggestions(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- And the orders it raises
-- ---------------------------------------------------------------------
--
-- Same reason for the drop: a fourth argument with a default sitting
-- beside a three-argument original is two candidates for one call.
--
-- The lines it writes carry the run's warehouse, so stock is ordered
-- into the place that is short of it rather than into whichever location
-- the receiving clerk picks.
drop function if exists public.create_po_from_suggestions(uuid, jsonb, date);

create function public.create_po_from_suggestions(
  p_org           uuid,
  p_lines         jsonb default null,
  p_expected_date date default null,
  p_warehouse     uuid default null)
returns table (
  document_id    uuid,
  doc_no         text,
  supplier_id    uuid,
  supplier_name  text,
  line_count     integer,
  total_quantity numeric,
  note           text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run       uuid;
  v_sup       record;
  v_row       record;
  v_doc       uuid;
  v_no        text;
  v_line_no   integer;
  v_price     numeric;
  v_tax_code  uuid;
  v_tax_rate  numeric;
  v_currency  char(3);
  v_rate      numeric;
  v_qty       numeric;
  v_expected  date;
  v_orphans   text[];
  v_orphan_q  numeric;
begin
  if not app.can_read_module(p_org, 'forecasting') then
    raise exception 'not permitted to read forecasting for this organization'
      using errcode = '42501';
  end if;

  -- Raising a purchase order is a purchasing act, whoever asked for it.
  -- A forecasting licence is not a licence to commit the company to
  -- buying something.
  if not app.can_write_module(p_org, 'purchases') then
    raise exception 'not permitted to raise purchase orders for this organization'
      using errcode = '42501';
  end if;

  select r.id into v_run
    from public.forecast_runs r
   where r.org_id = p_org
     and r.warehouse_id is not distinct from p_warehouse
   order by r.run_at desc
   limit 1;

  if v_run is null then
    raise exception
      'No forecast has been run for this organization and location yet.'
      using errcode = 'P0002';
  end if;

  for v_sup in
    select w.supplier_id as sup, c.name as sup_name,
           coalesce(c.currency, 'MYR')::char(3) as sup_currency,
           c.payment_term_id as sup_term, max(w.lead_time_days) as max_lead
      from app.forecast_wanted(p_org, v_run, p_lines) w
      join public.contacts c on c.id = w.supplier_id
     group by w.supplier_id, c.name, c.currency, c.payment_term_id
     order by c.name
  loop
    v_currency := v_sup.sup_currency;

    -- A foreign supplier with no rate on file is that supplier's
    -- problem, not the whole replenishment's. Their order is left out
    -- with a reason rather than aborting the orders that can be raised.
    begin
      v_rate := app.exchange_rate_for(p_org, v_currency, current_date);
    exception
      when sqlstate 'P0002' or sqlstate '23514' then
        v_rate := null;
    end;

    if v_rate is null then
      select count(*), coalesce(sum(w.want), 0)
        into line_count, total_quantity
        from app.forecast_wanted(p_org, v_run, p_lines) w
       where w.supplier_id = v_sup.sup;
      document_id := null;
      doc_no := null;
      supplier_id := v_sup.sup;
      supplier_name := v_sup.sup_name;
      note := format('No exchange rate for %s on or before today, so no '
                     'order was raised. Enter one and try again.', v_currency);
      return next;
      continue;
    end if;

    -- Far enough out to be there when it is needed: the longest lead
    -- time on the order, because the document carries one date and the
    -- slowest line sets it.
    v_expected := coalesce(p_expected_date,
                           current_date + ceil(v_sup.max_lead)::integer);

    v_no := app.next_document_number_internal(p_org, 'purchase_order');

    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, expected_date, contact_id,
      payment_term_id, currency, exchange_rate, status, created_by,
      internal_notes)
    values (
      p_org, 'purchase_order', v_no, current_date, v_expected, v_sup.sup,
      v_sup.sup_term, v_currency, v_rate, 'draft', auth.uid(),
      'Raised from the inventory forecast of ' || current_date::text)
    returning id into v_doc;

    v_line_no := 0;
    v_qty     := 0;

    for v_row in
      select w.*
        from app.forecast_wanted(p_org, v_run, p_lines) w
       where w.supplier_id = v_sup.sup
       order by w.item_code
    loop
      -- What this was last bought for: from this supplier by preference,
      -- and in this order's currency, because a price in another
      -- currency is not a price. Falls back to the item's cost.
      select l.unit_price into v_price
        from public.purchase_document_lines l
        join public.purchase_documents d on d.id = l.document_id
       where l.org_id = p_org
         and l.item_id = v_row.item_id
         and d.doc_type in ('bill', 'purchase_order')
         and d.status <> 'void'
         and d.deleted_at is null
         and d.currency = v_currency
       order by (d.contact_id = v_sup.sup) desc,
                d.doc_date desc, d.created_at desc
       limit 1;

      v_price := coalesce(v_price, v_row.cost_price, 0);

      v_tax_code := v_row.purchase_tax_code_id;
      v_tax_rate := 0;
      if v_tax_code is not null then
        select t.rate into v_tax_rate
          from public.tax_codes t
         where t.id = v_tax_code and t.is_active;
        if v_tax_rate is null then
          -- Deactivated since the item was set up. Ordering with no tax
          -- is better than ordering at a rate nobody can charge.
          v_tax_code := null;
          v_tax_rate := 0;
        end if;
      end if;

      v_line_no := v_line_no + 1;
      insert into public.purchase_document_lines (
        org_id, document_id, line_no, line_type, item_id, description,
        classification_code, quantity, uom_code, unit_price,
        tax_code_id, tax_rate, warehouse_id, forecast_line_id)
      values (
        p_org, v_doc, v_line_no, 'item', v_row.item_id, v_row.item_name,
        v_row.classification_code, v_row.want, v_row.uom_code, v_price,
        v_tax_code, v_tax_rate, v_row.warehouse_id, v_row.line_id);

      v_qty := v_qty + v_row.want;
    end loop;

    document_id := v_doc;
    doc_no := v_no;
    supplier_id := v_sup.sup;
    supplier_name := v_sup.sup_name;
    line_count := v_line_no;
    total_quantity := v_qty;
    note := null;
    return next;
  end loop;

  -- And the ones nobody can be asked to supply.
  select array_agg(w.item_code order by w.item_code), coalesce(sum(w.want), 0)
    into v_orphans, v_orphan_q
    from app.forecast_wanted(p_org, v_run, p_lines) w
   where w.supplier_id is null;

  if coalesce(array_length(v_orphans, 1), 0) > 0 then
    document_id := null;
    doc_no := null;
    supplier_id := null;
    supplier_name := null;
    line_count := array_length(v_orphans, 1);
    total_quantity := v_orphan_q;
    note := format(
      '%s item(s) have no supplier and were not ordered: %s. Set a '
      'preferred supplier on the item, or a supplier in its forecast '
      'parameters.',
      array_length(v_orphans, 1), array_to_string(v_orphans, ', '));
    return next;
  end if;

  return;
end;
$$;

revoke all on function public.create_po_from_suggestions(uuid, jsonb, date, uuid)
  from public, anon;
grant execute on function public.create_po_from_suggestions(uuid, jsonb, date, uuid)
  to authenticated;

comment on function public.forecast_suggestions(uuid, uuid) is
  'What the latest run for this organization and location says to order, '
  'with the item and supplier named and any draft orders already raised '
  'netted off. Null warehouse means the company as a whole, and is '
  'matched with `is not distinct from` — a plain equality finds no run '
  'and empties the screen.';

comment on function public.create_po_from_suggestions(uuid, jsonb, date, uuid) is
  'Turns the latest run for this location into one draft purchase order '
  'per supplier, ordering the stock into the place that is short of it. '
  'Items with no supplier come back as a final row with a null document '
  'rather than being dropped.';
