-- Two things the demo tenant showed, one of them a defect.
--
-- ## An item below the buyer's own floor is not overstocked
--
-- `item_forecast_params.min_quantity` is described in 0197 as "a hard
-- limit a buyer imposes regardless of what the model says", and
-- `app.suggested_order_qty` honours it: the order-up-to target is
-- raised to the floor and the difference is suggested. The state
-- machine in 0200 never looked at it.
--
-- So a wholesaler who holds forty of a headline part so a dealer can
-- collect the same day gets a row that says `overstocked` — earned
-- honestly, on eight hundred days of cover — next to a suggestion to
-- buy sixteen. Both numbers are right and the label is the loudest
-- thing on the line, so the line reads as a bug in the arithmetic.
--
-- The floor is now tested in the same branch as the reorder point,
-- which is before the two overstocked branches rather than after them.
-- Nothing else moves: an item with no floor is classified exactly as
-- it was.
--
-- ## And the demo had nothing to show
--
-- Sinar holds twenty-four to twenty-six of each part against demand of
-- about one a month. Every item is genuinely overstocked, every
-- suggestion is correctly zero, and the replenishment screen opens
-- empty. The module works and demonstrates nothing, which is the same
-- failure the back-dated purchase orders in 0201 were written to
-- avoid.
--
-- The fix is not invented demand. It is the availability policy a
-- wholesaler of this kind actually operates: a minimum on the shelf
-- for the parts a dealer expects to collect today, and none on the
-- parts they order in advance. That produces three suggestions and one
-- item the module correctly says nothing about — a demo where
-- everything needs ordering teaches the reader to ignore the column.
--
-- Items also get their supplier back. Every one of Sinar's parts has
-- six bills behind it and none of them had `preferred_supplier_id`
-- set, so every suggestion came out unassigned and
-- `create_po_from_suggestions` could raise nothing at all. Read from
-- the bills rather than typed in, because the answer is already in the
-- books.

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

  insert into public.forecast_runs (
    org_id, run_by, as_of_date, bucket, horizon_buckets, history_days,
    service_level, default_method, count_transfers_out, count_shrinkage)
  values (
    p_org, auth.uid(), p_as_of, v_s.bucket, v_s.horizon_buckets, v_s.history_days,
    v_s.service_level, v_s.default_method, v_s.count_transfers_out, v_s.count_shrinkage)
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
-- The demo, restated
-- ---------------------------------------------------------------------
--
-- Restated in full rather than patched, for the reason 0201 gives about
-- `demo_rebuild`: a `create or replace` that only somebody's memory
-- says matches the previous body is how a seeder quietly loses half of
-- what it used to do. Everything from 0201 is here unchanged — the
-- back-dated purchase orders that make the lead time measured, the
-- monthly buckets, the settings — and three things are added.
create or replace function app.demo_forecast_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_bill      record;
  v_line      record;
  v_po        uuid;
  v_po_line   uuid;
  v_lead      integer;
  v_seq       integer := 0;
  v_orders    integer := 0;
  v_linked    integer := 0;
  v_supplied  integer := 0;
  v_run       uuid;
  v_lines     integer;
  v_suggested integer;
  v_measured  integer;
begin
  -- Act as the owner before anything guarded is called. The seeder that
  -- runs immediately before this one signs out on its way out, so this
  -- function starts with no caller at all, and `app.module_access`
  -- returns 'none' the moment `auth.uid()` is null.
  perform app.demo_act_as(p_owner);

  perform app.demo_modules(p_org, array['forecasting']);

  insert into public.forecast_settings (
    org_id, bucket, horizon_buckets, history_days, default_method,
    default_window, service_level, default_lead_time_days, min_periods)
  values (p_org, 'month', 3, 365, 'moving_average', 3, 0.9500, 14, 3)
  on conflict (org_id) do update
     set bucket = excluded.bucket,
         horizon_buckets = excluded.horizon_buckets,
         default_method = excluded.default_method,
         default_window = excluded.default_window,
         min_periods = excluded.min_periods;

  -- --------------------------------------------------------------
  -- The order each bill would have come from
  -- --------------------------------------------------------------
  for v_bill in
    select d.id, d.doc_date, d.contact_id, d.currency
      from public.purchase_documents d
     where d.org_id = p_org
       and d.doc_type = 'bill'
       and exists (select 1 from public.stock_movements m
                    where m.org_id = p_org
                      and m.movement_type = 'purchase_receipt'
                      and m.source_id = d.id)
     order by d.doc_date
  loop
    v_seq := v_seq + 1;

    -- Between five and twelve days, walked deterministically rather
    -- than randomly so the demo tells the same story every rebuild and
    -- the median is a number somebody can check by hand.
    v_lead := 5 + (v_seq * 3) % 8;

    insert into public.purchase_documents
      (org_id, doc_type, doc_no, contact_id, doc_date, expected_date,
       currency, status)
    values
      (p_org, 'purchase_order', 'PO-DEMO-' || lpad(v_seq::text, 4, '0'),
       v_bill.contact_id, v_bill.doc_date - v_lead,
       v_bill.doc_date, coalesce(v_bill.currency, 'MYR'), 'completed')
    returning id into v_po;
    v_orders := v_orders + 1;

    for v_line in
      select l.id, l.line_no, l.item_id, l.description, l.quantity,
             l.uom_code, l.unit_price, l.warehouse_id
        from public.purchase_document_lines l
       where l.document_id = v_bill.id
         and l.item_id is not null
       order by l.line_no
    loop
      insert into public.purchase_document_lines
        (org_id, document_id, line_no, line_type, item_id, description,
         quantity, quantity_received, uom_code, unit_price, warehouse_id)
      values
        (p_org, v_po, v_line.line_no, 'item', v_line.item_id, v_line.description,
         v_line.quantity, v_line.quantity, v_line.uom_code, v_line.unit_price,
         v_line.warehouse_id)
      returning id into v_po_line;

      -- The link the lead time is measured along.
      update public.purchase_document_lines
         set source_line_id = v_po_line
       where id = v_line.id;
      v_linked := v_linked + 1;
    end loop;
  end loop;

  -- --------------------------------------------------------------
  -- Who actually supplies each part
  -- --------------------------------------------------------------
  --
  -- Read from the bills rather than assigned, because six bills per
  -- item already answer the question and an invented answer would
  -- disagree with the purchase history sitting next to it on screen.
  --
  -- Without this every suggestion comes out unassigned and
  -- `create_po_from_suggestions` can raise nothing at all — the demo
  -- would show the list and then refuse to act on it.
  update public.items i
     set preferred_supplier_id = (
           select d.contact_id
             from public.purchase_document_lines l
             join public.purchase_documents d on d.id = l.document_id
            where l.item_id = i.id
              and d.org_id = p_org
              and d.doc_type = 'bill'
            order by d.doc_date desc, d.created_at desc
            limit 1)
   where i.org_id = p_org
     and i.track_inventory
     and i.preferred_supplier_id is null;

  select count(*) into v_supplied
    from public.items i
   where i.org_id = p_org and i.track_inventory
     and i.preferred_supplier_id is not null;

  -- --------------------------------------------------------------
  -- The availability policy, which is what gives the module something
  -- to say
  -- --------------------------------------------------------------
  --
  -- Sinar holds two dozen of everything against demand of about one a
  -- month, so on the numbers alone there is nothing to buy and the
  -- screen opens empty. That is the correct answer and a useless
  -- demonstration.
  --
  -- What a distributor of this kind actually operates is a floor on the
  -- parts a dealer expects to collect the same day, and nothing on the
  -- parts they order in advance. So: a floor on the server and the
  -- switch, cartons on the cabling kit, and deliberately nothing at all
  -- on the UPS — because a replenishment screen where every line says
  -- "order" teaches the reader to stop looking at the column.
  insert into public.item_forecast_params
    (org_id, item_id, min_quantity, min_order_quantity, order_multiple, notes)
  select p_org, i.id,
         case i.code when 'ITM-100' then 40
                     when 'ITM-110' then 40
                     when 'ITM-130' then 30 end,
         case i.code when 'ITM-130' then 6 end,
         case i.code when 'ITM-130' then 6 end,
         case i.code
           when 'ITM-100' then
             'Forty on the shelf: a dealer collecting a server the same '
             'day is the reason they buy from us rather than direct'
           when 'ITM-110' then
             'Forty on the shelf, same promise as the servers'
           when 'ITM-130' then
             'Ships in cartons of six, minimum one carton — so a '
             'suggestion of four becomes six rather than being rounded '
             'down by whoever types the order'
         end
    from public.items i
   where i.org_id = p_org
     and i.track_inventory
     and i.code in ('ITM-100', 'ITM-110', 'ITM-130')
  on conflict do nothing;

  -- --------------------------------------------------------------
  -- And run one, so the screen has something to open on
  -- --------------------------------------------------------------
  --
  -- The suggestions are deliberately left un-actioned. Raising the
  -- draft orders here would net them off and the replenishment screen
  -- would open saying there is nothing outstanding, which is the one
  -- thing the demo is not for.
  v_run := public.run_inventory_forecast(p_org);

  select count(*),
         count(*) filter (where suggested_qty > 0),
         count(*) filter (where lead_time_source = 'measured')
    into v_lines, v_suggested, v_measured
    from public.forecast_lines where run_id = v_run;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Sinar forecasting: %s back-dated orders linked to %s bill line(s), '
    '%s item(s) with a supplier read from their bills, %s forecast, '
    '%s to order, %s on a measured lead time.',
    v_orders, v_linked, v_supplied, v_lines, v_suggested, v_measured);
end;
$$;

revoke all on function app.demo_forecast_sinar(uuid, uuid) from public, anon, authenticated;
