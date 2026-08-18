-- Running a forecast, and turning what it says into an order.
--
-- ## Converting a bucket to a day, twice, and differently
--
-- The history is read in weeks or months; every downstream formula
-- wants days. The mean divides:
--
--     mean_daily = mean_bucket / days_in_bucket
--
-- The standard deviation does not. Bucket demand is the sum of the
-- daily demands inside it, variances of independent sums add, so
--
--     sigma_bucket = sigma_daily * sqrt(days_in_bucket)
--     sigma_daily  = sigma_bucket / sqrt(days_in_bucket)
--
-- Dividing sigma by the days instead of its root is the same error as
-- multiplying safety stock by lead time instead of its root, and it
-- understates the buffer by that factor — for weekly buckets, two and a
-- half times too little.
--
-- ## Available is not on hand
--
-- `on_hand - reserved + on_order`. Leaving `on_order` out is how a
-- replenishment report tells you to buy the same stock every day until
-- the first order lands. Leaving `reserved` out is how it tells you
-- there is stock for a customer whose order has already claimed it.
--
-- ## Order up to, not order to the reorder point
--
-- The target covers the lead time *and* the review period — the
-- horizon this run was asked for — because ordering exactly up to the
-- reorder point means reordering again tomorrow. That is what makes
-- the horizon a purchasing decision rather than a chart setting.

-- ---------------------------------------------------------------------
-- Days in a bucket
-- ---------------------------------------------------------------------
create or replace function app.bucket_days(p_bucket app.forecast_bucket)
returns numeric
language sql
immutable
as $$
  -- 30.44 rather than 30: the average Gregorian month. A month bucket
  -- treated as 30 days drifts a forecast by five days a year, which is
  -- a third of a typical lead time.
  select case p_bucket
           when 'day'   then 1::numeric
           when 'week'  then 7::numeric
           when 'month' then 30.44::numeric
         end;
$$;

grant execute on function app.bucket_days(app.forecast_bucket) to authenticated;

-- ---------------------------------------------------------------------
-- What is already coming
-- ---------------------------------------------------------------------
create or replace function app.quantity_on_order(
  p_org uuid, p_item uuid, p_warehouse uuid default null)
returns numeric
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  -- Ordered and not yet received, on orders that are still live. Draft
  -- is excluded because nobody has committed to it; void and rejected
  -- because nobody will; completed because it has all arrived.
  select coalesce(sum(greatest(l.quantity - coalesce(l.quantity_received, 0), 0)), 0)
    from public.purchase_document_lines l
    join public.purchase_documents d on d.id = l.document_id
   where l.org_id = p_org
     and l.item_id = p_item
     and d.doc_type = 'purchase_order'
     and d.status in ('pending', 'approved', 'posted', 'partial')
     and (p_warehouse is null or l.warehouse_id = p_warehouse);
$$;

grant execute on function app.quantity_on_order(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------
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
    elsif v_avail <= v_rop then
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
-- What the latest run says to order
-- ---------------------------------------------------------------------
create or replace function public.forecast_suggestions(p_org uuid)
returns setof public.forecast_lines
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.*
    from public.forecast_lines l
   where l.org_id = p_org
     and app.can_read_module(p_org, 'forecasting')
     and l.run_id = (select r.id from public.forecast_runs r
                      where r.org_id = p_org
                      order by r.run_at desc limit 1)
     and l.suggested_qty > 0
   order by array_position(
     array['stocked_out','below_safety','order_now','order_soon','ok','overstocked']
       ::text[], l.state::text),
     l.days_cover nulls last;
$$;

grant execute on function public.forecast_suggestions(uuid) to authenticated;

comment on function public.run_inventory_forecast(uuid, uuid, date) is
  'Forecasts every stocked item and records what it decided. Items with '
  'too little history get a line saying so rather than no line at all — '
  'an item silently absent from a replenishment report is one nobody '
  'notices they stopped ordering.';
