-- The arithmetic. Every number a buyer will be asked to trust is
-- produced here, and every one of them is asserted in
-- `supabase/tests/inventory_forecast.sql` against a worked example.
--
-- ## Why a normal quantile has to be computed rather than looked up
--
-- Safety stock is `z · σ · √L`, and `z` is the inverse normal CDF at
-- the service level. Postgres has the normal CDF nowhere, so this is
-- Acklam's rational approximation — the standard one, accurate to
-- about 1.15e-9 across the whole range, which is nine digits more than
-- a stock buffer needs.
--
-- A lookup table of the four service levels anybody actually picks
-- would also work and was the first instinct. It is worse: the moment
-- somebody sets 0.93 because their supplier is unreliable, a table
-- either refuses them or silently rounds to 0.95, and rounding a
-- service level is exactly the kind of quiet substitution that makes a
-- number untrustworthy.
--
-- ## Why safety stock scales with the square root of lead time
--
-- Because demand over L days is the sum of L independent daily
-- demands, and the variance of a sum is the sum of the variances. The
-- standard deviation therefore grows as √L, not L. Getting this wrong
-- by using L is the single most common error in reorder point
-- arithmetic and it overstates the buffer by a factor of √L — for a
-- 16-day lead time, four times the stock actually needed.
--
-- ## Why the forecast methods return a series and not a number
--
-- A reorder point needs a rate. A purchasing decision needs a shape:
-- whether the next eight weeks are flat, climbing, or the same hump
-- that happened last year. Returning the horizon lets the caller do
-- both, and lets the screen draw the thing the buyer is actually
-- reasoning about.

-- ---------------------------------------------------------------------
-- The normal quantile
-- ---------------------------------------------------------------------
create or replace function app.normal_z(p numeric)
returns numeric
language plpgsql
immutable
as $$
declare
  -- Acklam's coefficients. Named a/b/c/d as in the published algorithm
  -- so it can be checked against the source rather than reverse
  -- engineered from here.
  a1 constant double precision := -3.969683028665376e+01;
  a2 constant double precision :=  2.209460984245205e+02;
  a3 constant double precision := -2.759285104469687e+02;
  a4 constant double precision :=  1.383577518672690e+02;
  a5 constant double precision := -3.066479806614716e+01;
  a6 constant double precision :=  2.506628277459239e+00;

  b1 constant double precision := -5.447609879822406e+01;
  b2 constant double precision :=  1.615858368580409e+02;
  b3 constant double precision := -1.556989798598866e+02;
  b4 constant double precision :=  6.680131188771972e+01;
  b5 constant double precision := -1.328068155288572e+01;

  c1 constant double precision := -7.784894002430293e-03;
  c2 constant double precision := -3.223964580411365e-01;
  c3 constant double precision := -2.400758277161838e+00;
  c4 constant double precision := -2.549732539343734e+00;
  c5 constant double precision :=  4.374664141464968e+00;
  c6 constant double precision :=  2.938163982698783e+00;

  d1 constant double precision :=  7.784695709041462e-03;
  d2 constant double precision :=  3.224671290700398e-01;
  d3 constant double precision :=  2.445134137142996e+00;
  d4 constant double precision :=  3.754408661907416e+00;

  p_low  constant double precision := 0.02425;
  v_p    double precision := p::double precision;
  q      double precision;
  r      double precision;
  v_x    double precision;
begin
  if p is null then
    return null;
  end if;

  -- The open interval, because the quantile at 0 and 1 is infinite and
  -- an infinite safety stock is not a number anybody can order.
  if v_p <= 0 or v_p >= 1 then
    raise exception 'normal_z is defined on (0,1), not %', p
      using errcode = '22003';
  end if;

  if v_p < p_low then
    q := sqrt(-2 * ln(v_p));
    v_x := (((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6)
           / ((((d1*q + d2)*q + d3)*q + d4)*q + 1);
  elsif v_p <= 1 - p_low then
    q := v_p - 0.5;
    r := q * q;
    v_x := (((((a1*r + a2)*r + a3)*r + a4)*r + a5)*r + a6) * q
           / (((((b1*r + b2)*r + b3)*r + b4)*r + b5)*r + 1);
  else
    q := sqrt(-2 * ln(1 - v_p));
    v_x := -(((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6)
           / ((((d1*q + d2)*q + d3)*q + d4)*q + 1);
  end if;

  return round(v_x::numeric, 6);
end;
$$;

grant execute on function app.normal_z(numeric) to authenticated;

-- ---------------------------------------------------------------------
-- Safety stock and the reorder point
-- ---------------------------------------------------------------------
--
-- Both take demand already expressed per day, so the caller has done
-- the bucket conversion once rather than every formula doing it again
-- and one of them doing it differently.
create or replace function app.safety_stock(
  p_service_level     numeric,
  p_stddev_daily      numeric,
  p_lead_time_days    numeric)
returns numeric
language sql
immutable
as $$
  -- z · σ · √L. The square root is the whole point: demand over L days
  -- is a sum of L daily demands, variances add, so the standard
  -- deviation grows as √L. Using L instead would order √L times too
  -- much — four times over, on a sixteen-day lead time.
  select round(
    greatest(
      app.normal_z(p_service_level)
        * greatest(coalesce(p_stddev_daily, 0), 0)
        * sqrt(greatest(coalesce(p_lead_time_days, 0), 0)),
      0),
    4);
$$;

create or replace function app.reorder_point(
  p_mean_daily      numeric,
  p_lead_time_days  numeric,
  p_safety_stock    numeric)
returns numeric
language sql
immutable
as $$
  -- Expected demand across the lead time, plus the buffer for the days
  -- it runs hot. Nothing more: a reorder point is not an order
  -- quantity and conflating the two is how businesses end up holding a
  -- quarter of stock.
  select round(
    greatest(coalesce(p_mean_daily, 0), 0)
      * greatest(coalesce(p_lead_time_days, 0), 0)
    + greatest(coalesce(p_safety_stock, 0), 0),
    4);
$$;

grant execute on function app.safety_stock(numeric, numeric, numeric) to authenticated;
grant execute on function app.reorder_point(numeric, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- The three methods
-- ---------------------------------------------------------------------
--
-- Each takes the demand history oldest first and returns the horizon.
-- None of them looks at the database, which is what makes them
-- testable against a worked example rather than against whatever the
-- demo data happens to contain today.
create or replace function app.forecast_moving_average(
  p_history numeric[],
  p_window  integer,
  p_horizon integer)
returns numeric[]
language plpgsql
immutable
as $$
declare
  v_n     integer := coalesce(array_length(p_history, 1), 0);
  v_take  integer;
  v_mean  numeric;
begin
  if v_n = 0 or p_horizon < 1 then
    return '{}'::numeric[];
  end if;

  -- A window longer than the history is not an error; it is somebody
  -- asking for a four-period average of three periods. Averaging what
  -- there is answers that honestly, and `periods_used` on the line
  -- records how much there was.
  v_take := least(greatest(p_window, 1), v_n);

  select avg(x) into v_mean
    from unnest(p_history[v_n - v_take + 1 : v_n]) as x;

  -- Flat by construction. A moving average has no opinion about trend,
  -- and pretending otherwise by extrapolating the last two points is
  -- how a quiet fortnight becomes a forecast of zero.
  return array(select round(v_mean, 4) from generate_series(1, p_horizon));
end;
$$;

create or replace function app.forecast_exponential_smoothing(
  p_history numeric[],
  p_alpha   numeric,
  p_horizon integer)
returns numeric[]
language plpgsql
immutable
as $$
declare
  v_n     integer := coalesce(array_length(p_history, 1), 0);
  v_level numeric;
  i       integer;
begin
  if v_n = 0 or p_horizon < 1 then
    return '{}'::numeric[];
  end if;

  -- Seeded with the first observation rather than with zero. Seeding at
  -- zero makes the level climb out of a hole for the first several
  -- periods, which on short histories is most of them.
  v_level := p_history[1];

  for i in 2 .. v_n loop
    v_level := p_alpha * p_history[i] + (1 - p_alpha) * v_level;
  end loop;

  -- Simple exponential smoothing, so the forecast is the level and the
  -- level is flat going forward. Holt's trend term is deliberately not
  -- here: with the dozen periods of history a small business has, a
  -- fitted trend extrapolates noise confidently, and confident nonsense
  -- is worse than a flat line.
  return array(select round(v_level, 4) from generate_series(1, p_horizon));
end;
$$;

create or replace function app.forecast_seasonal_naive(
  p_history numeric[],
  p_season  integer,
  p_horizon integer)
returns numeric[]
language plpgsql
immutable
as $$
declare
  v_n   integer := coalesce(array_length(p_history, 1), 0);
  v_s   integer := greatest(coalesce(p_season, 1), 1);
  v_out numeric[] := '{}'::numeric[];
  i     integer;
  v_idx integer;
begin
  if v_n = 0 or p_horizon < 1 then
    return '{}'::numeric[];
  end if;

  -- Needs a whole season to copy. Without one it would repeat a
  -- fragment and call it seasonality, so it says it cannot instead and
  -- the caller falls back to a method that can — recording which, on
  -- the line.
  if v_n < v_s then
    return null;
  end if;

  for i in 1 .. p_horizon loop
    -- The same period one season ago, wrapping for horizons longer than
    -- the season.
    v_idx := v_n - v_s + 1 + ((i - 1) % v_s);
    v_out := v_out || round(p_history[v_idx], 4);
  end loop;

  return v_out;
end;
$$;

grant execute on function app.forecast_moving_average(numeric[], integer, integer) to authenticated;
grant execute on function app.forecast_exponential_smoothing(numeric[], numeric, integer) to authenticated;
grant execute on function app.forecast_seasonal_naive(numeric[], integer, integer) to authenticated;

-- ---------------------------------------------------------------------
-- When it runs out
-- ---------------------------------------------------------------------
--
-- Null when demand is zero or negative — an item nothing is consuming
-- does not have a stockout date, and returning a date far in the future
-- would sort it into the queue as though it did.
create or replace function app.days_of_cover(
  p_available   numeric,
  p_mean_daily  numeric)
returns numeric
language sql
immutable
as $$
  select case
           when coalesce(p_mean_daily, 0) <= 0 then null
           when coalesce(p_available, 0) <= 0 then 0
           else round(p_available / p_mean_daily, 2)
         end;
$$;

grant execute on function app.days_of_cover(numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- What to actually order
-- ---------------------------------------------------------------------
--
-- The order-up-to level is demand across the lead time *and* the review
-- period, plus safety stock: ordering only up to the reorder point
-- leaves you reordering again the following day. The review period is
-- the horizon the run was asked for, which is what makes the horizon a
-- purchasing decision rather than a chart setting.
create or replace function app.suggested_order_qty(
  p_available        numeric,
  p_mean_daily       numeric,
  p_lead_time_days   numeric,
  p_review_days      numeric,
  p_safety_stock     numeric,
  p_min_quantity     numeric default null,
  p_max_quantity     numeric default null,
  p_min_order_qty    numeric default null,
  p_order_multiple   numeric default null)
returns numeric
language plpgsql
immutable
as $$
declare
  v_target numeric;
  v_qty    numeric;
begin
  v_target := greatest(coalesce(p_mean_daily, 0), 0)
                * (greatest(coalesce(p_lead_time_days, 0), 0)
                   + greatest(coalesce(p_review_days, 0), 0))
              + greatest(coalesce(p_safety_stock, 0), 0);

  -- A floor the buyer set wins over the model, both ways round: it is
  -- their shelf and their shelf life.
  if p_min_quantity is not null then
    v_target := greatest(v_target, p_min_quantity);
  end if;
  if p_max_quantity is not null then
    v_target := least(v_target, p_max_quantity);
  end if;

  v_qty := v_target - coalesce(p_available, 0);

  if v_qty <= 0 then
    return 0;
  end if;

  -- Rounding up, not to nearest. A carton of 12 rounded down is an
  -- order that arrives short, and the whole point of the multiple is
  -- that the supplier will not ship the remainder.
  if coalesce(p_order_multiple, 0) > 0 then
    v_qty := ceil(v_qty / p_order_multiple) * p_order_multiple;
  end if;

  if coalesce(p_min_order_qty, 0) > 0 then
    v_qty := greatest(v_qty, p_min_order_qty);
    -- Raising to the minimum can break the multiple, so the multiple is
    -- reapplied. Order of operations matters and this is the order that
    -- satisfies both constraints rather than the last one applied.
    if coalesce(p_order_multiple, 0) > 0 then
      v_qty := ceil(v_qty / p_order_multiple) * p_order_multiple;
    end if;
  end if;

  return round(v_qty, 4);
end;
$$;

grant execute on function app.suggested_order_qty(
  numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric)
  to authenticated;

comment on function app.normal_z(numeric) is
  'Inverse normal CDF by Acklam''s rational approximation, accurate to '
  'about 1.15e-9. Computed rather than looked up so a service level of '
  '0.93 is honoured instead of silently rounded to 0.95.';

comment on function app.safety_stock(numeric, numeric, numeric) is
  'z * sigma * sqrt(lead time). The square root is load bearing: '
  'variances of independent daily demands add, so the standard '
  'deviation grows as the root. Using lead time undiluted overstates '
  'the buffer by that root — four times over at sixteen days.';
