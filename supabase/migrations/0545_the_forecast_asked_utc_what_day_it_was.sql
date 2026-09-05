-- The forecast asked what day it was in UTC. Everything else asks Malaysia.
--
-- `app.today()` is `app.malaysian_day(now())` and eighty-seven functions
-- in this schema use it, because Postgres runs in UTC here and on
-- Supabase and a Malaysian business day is eight hours ahead. Between
-- 16:00 and 24:00 UTC -- midnight to eight in the morning in Kuala
-- Lumpur -- `current_date` is the day before `app.today()`.
--
-- `run_inventory_forecast` defaulted `p_as_of` to `CURRENT_DATE`, and
-- `app/lib/src/data/repository.dart` calls it with `p_org` and at most
-- `p_warehouse` -- never a date. So a buyer who presses Run forecast at
-- two in the morning got demand measured to YESTERDAY, a days-of-cover
-- counted from yesterday, and a stockout date a day early -- and then
-- `create_po_from_suggestions`, which dates its order from
-- `app.today()`, raised a purchase order dated TODAY off it. One
-- module, two different days, for a third of every day. Deciding when
-- something runs out is the whole of what this module does.
--
-- FOUND BY THE CLOCK. `forecast_order_shapes.sql` had been green all
-- day and failed at 01:25 Malaysian time with "expected 2026-10-15, got
-- 2026-10-16" -- the test anchored on `current_date`, the order on
-- `app.today()`. Fixing the test to read the product's clock is what
-- exposed that the product was not reading it either.
--
-- THE OTHER FORTY. `DEFAULT CURRENT_DATE` appears on forty-one
-- functions. This is the only one whose default is actually taken: the
-- nightly cron passes `(now() at time zone 'Asia/Kuala_Lumpur')::date`
-- explicitly, and every other Dart caller passes a date of its own.
-- They are a trap rather than a bug, and `utc_is_not_today.sql` holds
-- the list at forty so a forty-second cannot be added quietly.

CREATE OR REPLACE FUNCTION public.run_inventory_forecast(p_org uuid, p_warehouse uuid DEFAULT NULL::uuid, p_as_of date DEFAULT app.today())
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
$function$;
