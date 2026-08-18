-- Inventory forecasting: what will be wanted, and what to order to have
-- it.
--
-- The parts are already here and none of them are joined up. `items`
-- carries `reorder_level` and `reorder_quantity` — two numbers a human
-- typed once and nothing has recalculated since. `stock_movements` is a
-- complete demand history nobody reads. `purchase_documents` records
-- when things were ordered and `stock_movements` records when they
-- arrived, so the lead time is sitting there as a subtraction nobody
-- performs. This module does the joining.
--
-- ## A forecast is a snapshot, not a view
--
-- `forecast_lines` stores numbers rather than recomputing them. That
-- costs storage and it is the whole point: somebody has to be able to
-- answer "why did we order 400 of these in March" nine months later,
-- and a view recomputed against today's history answers a different
-- question every day. The run records its own parameters for the same
-- reason — a suggestion is only defensible if you can see the service
-- level and the horizon that produced it.
--
-- ## Which movements are demand
--
-- Not all of them, and the difference is not cosmetic.
--
--   * `sales_delivery` net of `sales_return` is demand. This is the
--     signal.
--   * `adjustment_out` and `write_off` are shrinkage. Counting them as
--     demand teaches the forecast to reorder the stock you keep losing,
--     which is a way of paying twice for a stocktake problem.
--   * `transfer_out` is demand at the warehouse it left and no demand
--     at all for the company. Which answer is right depends on whether
--     you are forecasting a branch or a business.
--
-- All three are settings rather than assumptions, defaulted to the
-- conservative reading, because an org that consumes stock internally
-- through adjustments has a genuinely different answer and no code
-- comment is going to change their mind.
--
-- ## Warehouse-level or company-level
--
-- `warehouse_id` is nullable throughout and null means "the company".
-- A business with one location forecasts at company level and never
-- thinks about it; a business with four either forecasts per location,
-- because that is where the stock has to physically be, or centrally
-- because they transfer freely. Both are legitimate, so both are
-- representable, and the nullable column is why the unique indexes
-- below are partial rather than plain.
--
-- ## What this deliberately does not do
--
-- It does not touch `items.reorder_level`. Overwriting a number a
-- person set, with a number a model produced, removes their ability to
-- disagree — and the first time the model is wrong about a slow-moving
-- part they need somewhere to say so. The computed figure lives on the
-- forecast line beside the one they typed.

-- ---------------------------------------------------------------------
-- The vocabulary
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'forecast_method') then
    -- Three, and they answer different shapes of history.
    --
    --   moving_average       flat demand, short memory. The default,
    --                        because it is the one whose output a
    --                        stock controller can check by hand.
    --   exponential_smoothing recent weeks weighted over older ones,
    --                        for demand that drifts.
    --   seasonal_naive       last season's same period, for demand
    --                        that repeats — which is most retail, and
    --                        which a moving average smooths into a lie.
    create type app.forecast_method as enum
      ('moving_average', 'exponential_smoothing', 'seasonal_naive');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'forecast_bucket') then
    create type app.forecast_bucket as enum ('day', 'week', 'month');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'replenishment_state') then
    -- What the line is telling you to do, computed once so the queue can
    -- be sorted and filtered on it rather than every client re-deriving
    -- the same comparison and disagreeing about the boundaries.
    create type app.replenishment_state as enum
      ('stocked_out', 'below_safety', 'order_now', 'order_soon', 'ok', 'overstocked');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Is the module on?
-- ---------------------------------------------------------------------
create or replace function app.has_forecasting_module(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select app.has_module(p_org_id, 'forecasting');
$$;

grant execute on function app.has_forecasting_module(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- How this company wants to be forecast
-- ---------------------------------------------------------------------
create table if not exists public.forecast_settings (
  org_id              uuid primary key
                        references public.organizations(id) on delete cascade,

  -- How much past to read, and at what granularity.
  --
  -- A year by default: enough for `seasonal_naive` to have a season to
  -- copy, and short enough that a product's demand three years ago does
  -- not outvote last month.
  history_days        integer not null default 365,
  bucket              app.forecast_bucket not null default 'week',

  -- How much future to produce. Eight weeks covers a typical lead time
  -- with room to see past it, which is the point of forecasting rather
  -- than just reordering.
  horizon_buckets     integer not null default 8,

  default_method      app.forecast_method not null default 'moving_average',

  -- Periods of history the average runs over, and the season length for
  -- `seasonal_naive`. One number because for a seasonal forecast the
  -- window *is* the season.
  default_window      integer not null default 4,

  -- Exponential smoothing's weight on the newest observation. 0.3 is
  -- the conventional starting point: responsive enough to follow a
  -- trend, damped enough not to chase one bad week.
  default_alpha       numeric(4,3) not null default 0.300,

  -- The probability of not stocking out during the lead time. Drives
  -- the safety stock through the normal quantile — see `app.normal_z`.
  -- 95% is the usual commercial setting; 99% roughly doubles the buffer
  -- for the last four points of it, which is a business decision and
  -- therefore a field.
  service_level       numeric(5,4) not null default 0.9500,

  -- Used only when neither the item nor the purchase history says
  -- otherwise.
  default_lead_time_days integer not null default 14,

  -- Which movements count as demand. See the header — these are the
  -- three questions worth being explicit about.
  count_transfers_out boolean not null default false,
  count_shrinkage     boolean not null default false,

  -- Below this many periods of history a forecast is arithmetic
  -- performed on noise. The run records the item as insufficient
  -- history rather than producing a confident number from three weeks.
  min_periods         integer not null default 4,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint forecast_settings_history   check (history_days between 28 and 3650),
  constraint forecast_settings_horizon   check (horizon_buckets between 1 and 52),
  constraint forecast_settings_window    check (default_window between 2 and 52),
  constraint forecast_settings_alpha     check (default_alpha > 0 and default_alpha < 1),
  constraint forecast_settings_service   check (service_level >= 0.50 and service_level <= 0.9999),
  constraint forecast_settings_lead      check (default_lead_time_days between 0 and 365),
  constraint forecast_settings_minper    check (min_periods between 2 and 52)
);

-- ---------------------------------------------------------------------
-- Per item, where it differs
-- ---------------------------------------------------------------------
--
-- Every override is nullable and null means "inherit". That is what
-- makes the settings above worth having: a company sets its policy once
-- and names the handful of items that are exceptions, rather than
-- carrying a full parameter set on all four thousand.
create table if not exists public.item_forecast_params (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id) on delete cascade,
  item_id           uuid not null references public.items(id) on delete cascade,
  warehouse_id      uuid references public.warehouses(id) on delete cascade,

  method            app.forecast_method,
  window_periods    integer,
  alpha             numeric(4,3),
  service_level     numeric(5,4),

  -- Null means: measure it from purchase history, and fall back to the
  -- company default when there is not enough of that to measure.
  lead_time_days    integer,

  -- Hard limits a buyer imposes regardless of what the model says. A
  -- max matters more than it looks: it is how somebody stops the system
  -- suggesting a year of stock for something with a shelf life.
  min_quantity      numeric(18,4),
  max_quantity      numeric(18,4),

  -- What the supplier will actually accept. A suggestion of 7 when the
  -- carton is 12 is a suggestion that gets silently rounded by whoever
  -- types the order, and then the forecast is blamed for the excess.
  min_order_quantity numeric(18,4),
  order_multiple     numeric(18,4),

  -- Overrides items.preferred_supplier_id for this location.
  supplier_id       uuid references public.contacts(id) on delete set null,

  -- Excluded items still appear in the run's count, so "we forecast 12
  -- of 400 items" is answerable. Silence about what was skipped is how
  -- a replenishment report quietly stops covering half the catalogue.
  is_excluded       boolean not null default false,
  notes             text,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint ifp_window   check (window_periods is null or window_periods between 2 and 52),
  constraint ifp_alpha    check (alpha is null or (alpha > 0 and alpha < 1)),
  constraint ifp_service  check (service_level is null
                                 or (service_level >= 0.50 and service_level <= 0.9999)),
  constraint ifp_lead     check (lead_time_days is null or lead_time_days between 0 and 365),
  constraint ifp_minmax   check (min_quantity is null or max_quantity is null
                                 or max_quantity >= min_quantity),
  constraint ifp_moq      check (min_order_quantity is null or min_order_quantity >= 0),
  constraint ifp_multiple check (order_multiple is null or order_multiple > 0)
);

-- Two partial indexes rather than one plain unique, because
-- `warehouse_id` is nullable and NULL is not equal to NULL: a plain
-- unique constraint would happily accept four company-level rows for
-- the same item. Anything inferring these in an ON CONFLICT has to
-- carry the predicate too.
create unique index if not exists item_forecast_params_wh
  on public.item_forecast_params (org_id, item_id, warehouse_id)
  where warehouse_id is not null;
create unique index if not exists item_forecast_params_org_wide
  on public.item_forecast_params (org_id, item_id)
  where warehouse_id is null;

-- ---------------------------------------------------------------------
-- A run, and what it decided
-- ---------------------------------------------------------------------
create table if not exists public.forecast_runs (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id) on delete cascade,
  run_at            timestamptz not null default now(),
  run_by            uuid references auth.users(id) on delete set null,

  -- The parameters as they stood, copied rather than referenced. The
  -- settings row will be edited; this run's numbers have to keep
  -- meaning what they meant.
  as_of_date        date not null default current_date,
  bucket            app.forecast_bucket not null,
  horizon_buckets   integer not null,
  history_days      integer not null,
  service_level     numeric(5,4) not null,
  default_method    app.forecast_method not null,
  count_transfers_out boolean not null,
  count_shrinkage   boolean not null,

  items_considered  integer not null default 0,
  items_forecast    integer not null default 0,
  items_skipped     integer not null default 0,
  items_suggested   integer not null default 0,
  notes             text,
  created_at        timestamptz not null default now()
);

create index if not exists forecast_runs_org_at
  on public.forecast_runs (org_id, run_at desc);

create table if not exists public.forecast_lines (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id) on delete cascade,
  run_id            uuid not null references public.forecast_runs(id) on delete cascade,
  item_id           uuid not null references public.items(id) on delete cascade,
  warehouse_id      uuid references public.warehouses(id) on delete cascade,

  -- What was actually used, which is not always what was asked for: an
  -- item with one season of history cannot be forecast seasonally, and
  -- the line says so rather than quietly falling back.
  method_used       app.forecast_method not null,
  periods_used      integer not null,
  skipped_reason    text,

  -- The demand signal, per day, so every downstream number is in the
  -- same unit regardless of the bucket the history was read in.
  mean_daily_demand numeric(18,6) not null default 0,
  stddev_daily_demand numeric(18,6) not null default 0,

  -- The horizon, one element per bucket. An array rather than a child
  -- table because it is read and written whole and never queried
  -- across — a table would be four hundred rows per run to express
  -- what a chart draws in one pass.
  forecast_buckets  numeric(18,4)[] not null default '{}',
  forecast_total    numeric(18,4) not null default 0,

  lead_time_days    numeric(8,2) not null,
  -- 'measured' | 'item' | 'settings' — a number is worth much less
  -- without knowing whether it came from this supplier's actual
  -- deliveries or from a default nobody revisited.
  lead_time_source  text not null,

  safety_stock      numeric(18,4) not null default 0,
  reorder_point     numeric(18,4) not null default 0,

  -- Position at the moment of the run.
  on_hand           numeric(18,4) not null default 0,
  reserved          numeric(18,4) not null default 0,
  on_order          numeric(18,4) not null default 0,
  available         numeric(18,4) not null default 0,

  days_cover        numeric(10,2),
  stockout_on       date,

  state             app.replenishment_state not null,
  suggested_qty     numeric(18,4) not null default 0,
  supplier_id       uuid references public.contacts(id) on delete set null,

  -- What the human had set, carried alongside rather than overwritten,
  -- so the two can be compared and argued about.
  manual_reorder_level    numeric(18,4),
  manual_reorder_quantity numeric(18,4),

  created_at        timestamptz not null default now(),

  constraint forecast_lines_periods check (periods_used >= 0),
  constraint forecast_lines_lead    check (lead_time_days >= 0),
  constraint forecast_lines_source  check (lead_time_source in ('measured','item','settings'))
);

create index if not exists forecast_lines_run   on public.forecast_lines (run_id);
create index if not exists forecast_lines_item  on public.forecast_lines (org_id, item_id);
create index if not exists forecast_lines_state on public.forecast_lines (run_id, state);

create unique index if not exists forecast_lines_unique_wh
  on public.forecast_lines (run_id, item_id, warehouse_id)
  where warehouse_id is not null;
create unique index if not exists forecast_lines_unique_org_wide
  on public.forecast_lines (run_id, item_id)
  where warehouse_id is null;

-- ---------------------------------------------------------------------
-- Keeping updated_at honest
-- ---------------------------------------------------------------------
drop trigger if exists forecast_settings_touch on public.forecast_settings;
create trigger forecast_settings_touch
  before update on public.forecast_settings
  for each row execute function app.set_updated_at();

drop trigger if exists item_forecast_params_touch on public.item_forecast_params;
create trigger item_forecast_params_touch
  before update on public.item_forecast_params
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.forecast_settings     enable row level security;
alter table public.item_forecast_params  enable row level security;
alter table public.forecast_runs         enable row level security;
alter table public.forecast_lines        enable row level security;

drop policy if exists forecast_settings_select on public.forecast_settings;
create policy forecast_settings_select on public.forecast_settings for select
  using (app.can_read_module(org_id, 'forecasting'));
drop policy if exists forecast_settings_write on public.forecast_settings;
create policy forecast_settings_write on public.forecast_settings for all
  using (app.can_admin(org_id) and app.has_forecasting_module(org_id))
  with check (app.can_admin(org_id) and app.has_forecasting_module(org_id));

drop policy if exists item_forecast_params_select on public.item_forecast_params;
create policy item_forecast_params_select on public.item_forecast_params for select
  using (app.can_read_module(org_id, 'forecasting'));
drop policy if exists item_forecast_params_write on public.item_forecast_params;
create policy item_forecast_params_write on public.item_forecast_params for all
  using (app.can_write_module(org_id, 'forecasting'))
  with check (app.can_write_module(org_id, 'forecasting'));

-- Runs and lines are written by the SECURITY DEFINER function that
-- produces them and by nothing else. A forecast somebody could hand-edit
-- is a forecast that cannot be cited, so the API gets read only.
drop policy if exists forecast_runs_select on public.forecast_runs;
create policy forecast_runs_select on public.forecast_runs for select
  using (app.can_read_module(org_id, 'forecasting'));

drop policy if exists forecast_lines_select on public.forecast_lines;
create policy forecast_lines_select on public.forecast_lines for select
  using (app.can_read_module(org_id, 'forecasting'));

grant select, insert, update, delete on public.forecast_settings    to authenticated;
grant select, insert, update, delete on public.item_forecast_params to authenticated;
grant select                         on public.forecast_runs        to authenticated;
grant select                         on public.forecast_lines       to authenticated;

-- ---------------------------------------------------------------------
-- The module itself
-- ---------------------------------------------------------------------
insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order) values
  ('forecasting', 'Inventory Forecasting',
   'Demand read from the stock ledger rather than typed in: forecasts '
   'per item and location, safety stock at a chosen service level, '
   'reorder points that move when demand does, lead times measured '
   'from what suppliers actually did, and a replenishment queue that '
   'raises the purchase order',
   false, 49, 19)
on conflict (code) do nothing;

comment on table public.forecast_lines is
  'One item''s forecast as at a particular run. Stored rather than '
  'recomputed, because "why did we order 400 in March" has to be '
  'answerable in December, and a view gives a different answer daily.';

comment on column public.forecast_lines.lead_time_source is
  'Where the lead time came from: measured from this supplier''s own '
  'deliveries, set on the item, or the company default. A reorder point '
  'is only as good as this, so it is reported rather than buried.';

comment on table public.forecast_settings is
  'Which movements count as demand, how far back to read and how much '
  'risk of stocking out to accept. Settings rather than assumptions '
  'because an org that issues stock internally through adjustments has '
  'a genuinely different answer.';
