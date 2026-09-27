-- =====================================================================
-- Capital allowances, Schedule 3 ITA 1967
--
-- `0084` gives every fixed asset accounting depreciation: straight line
-- or reducing balance, over a useful life somebody chose. None of that
-- is deductible. In a Malaysian tax computation accounting
-- depreciation is ADDED BACK in full under s.33(1) and replaced by
-- capital allowances at rates Parliament sets.
--
-- So this is not a second depreciation method and must never be made to
-- share code with the first. They are two different numbers, computed
-- from different rules, for different readers, and the entire point of
-- a tax computation is the gap between them. A company that depreciates
-- a laptop over four years still claims 20% + 20% on it.
--
-- ---------------------------------------------------------------------
-- What this does NOT do
--
-- It does not file anything and it does not compute tax. It produces
-- the Schedule 3 working -- qualifying expenditure, initial and annual
-- allowances, residual expenditure, and the balancing adjustment on
-- disposal -- which is the figure a Form C computation then subtracts
-- to get chargeable income. The computation itself is a separate piece
-- of work and this is deliberately the half that stands alone.
--
-- ---------------------------------------------------------------------
-- The apportionment question, answered explicitly
--
-- Capital allowances are NOT pro-rated for the part of a year an asset
-- was owned. An asset in use at the end of the basis period attracts
-- the full initial allowance in the year it was acquired and the full
-- annual allowance in that year and every year after, whether it
-- arrived in January or December. Apportionment in Schedule 3 is about
-- a BASIS PERIOD that is not twelve months -- a company changing its
-- accounting date -- which is a different thing and is not modelled
-- here.
--
-- This is written down because it is the single easiest rule to get
-- wrong by analogy: `0084`'s `app.months_held` pro-rates accounting
-- depreciation to the month, correctly, and reaching for it here would
-- produce a schedule that is wrong for every asset bought after
-- January. A secondary source consulted while writing this said to
-- pro-rate by months in use; it is wrong, and this comment exists so
-- nobody re-reads it and "fixes" the code to match.
--
-- `apportion_first_year` on the class is there for the rare regime that
-- genuinely does apportion. It defaults to FALSE everywhere.
--
-- ---------------------------------------------------------------------
-- Why the rates are rows and not constants
--
-- Budget speeches move them. `0025` made the same choice for EPF,
-- SOCSO and EIS, with the same `is_verified` flag meaning "derived from
-- published percentages, not transcribed from the gazette" -- and the
-- seed below is is_verified FALSE for exactly that reason. Anybody
-- filing a real return checks the figures against the Act and ticks
-- them.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rates
-- ---------------------------------------------------------------------
create table public.capital_allowance_classes (
  id             uuid primary key default gen_random_uuid(),
  code           text not null,
  label          text not null,

  -- Given once, in the year the asset is acquired.
  initial_rate   numeric(6, 4) not null default 0
                   check (initial_rate >= 0 and initial_rate <= 1),
  -- Given every year the asset is in use, including the first.
  annual_rate    numeric(6, 4) not null default 0
                   check (annual_rate >= 0 and annual_rate <= 1),

  -- The motor vehicle restriction. Qualifying expenditure is the LESSER
  -- of cost and this, so a RM300,000 car is allowed on RM100,000 (or
  -- RM200,000 if new, on the road, and within the higher limit). Null
  -- means the whole cost qualifies, which is every other class.
  cost_cap       numeric(18, 2) check (cost_cap > 0),

  -- 100% in the first year for an asset under `small_value_threshold`,
  -- subject to `aggregate_cap` across all such assets in the year.
  -- Three columns rather than a boolean because the rule is three
  -- numbers and hiding two of them in code is how a Budget change
  -- becomes a migration.
  small_value_threshold numeric(18, 2)
                   check (small_value_threshold > 0),
  aggregate_cap  numeric(18, 2) check (aggregate_cap > 0),

  -- See the header. False everywhere, and the column exists so the rare
  -- regime that apportions can say so instead of being special-cased.
  apportion_first_year boolean not null default false,

  effective_from date not null,
  effective_to   date,
  sort_order     integer not null default 0,

  -- The same provenance columns `0025` gives the payroll schedules, and
  -- for the same reason.
  source         text,
  is_verified    boolean not null default false,
  notes          text,
  created_at     timestamptz not null default now(),

  constraint ca_class_period_is_forwards
    check (effective_to is null or effective_to > effective_from),
  -- An aggregate cap with nothing to aggregate, or a threshold with no
  -- cap, is half a rule. Either both or neither.
  constraint ca_class_small_value_is_whole
    check ((small_value_threshold is null) = (aggregate_cap is null)),
  unique (code, effective_from)
);

comment on table public.capital_allowance_classes is
  'Schedule 3 ITA 1967 rates by asset class, effective-dated. Platform '
  'data, not tenant data: the rates are the same for every company in '
  'Malaysia. is_verified false means derived from published '
  'percentages rather than transcribed from the Act.';

comment on column public.capital_allowance_classes.apportion_first_year is
  'Capital allowances are NOT apportioned for part-year ownership -- an '
  'asset in use at the end of the basis period gets the full year. '
  'False everywhere. See the migration header.';

alter table public.capital_allowance_classes enable row level security;

-- Readable by anybody signed in, like any other rate table: these are
-- published figures, and a company cannot compute its own schedule
-- without them.
create policy ca_classes_read on public.capital_allowance_classes
  for select to authenticated using (true);

-- Written by platform staff only. No tenant sets its own capital
-- allowance rates.
create policy ca_classes_write on public.capital_allowance_classes
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());

-- A policy is not a grant. `0662` and `0663` both learned this.
grant select on public.capital_allowance_classes to authenticated;
grant insert, update, delete on public.capital_allowance_classes
  to authenticated;

-- ---------------------------------------------------------------------
-- Which class an asset falls in
-- ---------------------------------------------------------------------

-- On the asset rather than in a side table: the register has to show
-- whether a row attracts allowances at all, and a left join for one
-- text column is a join every screen has to remember.
--
-- NULLABLE, and that is a real answer rather than "not filled in yet".
-- Land attracts no capital allowance. So does goodwill. An asset with
-- no class is out of the schedule, not missing from it.
alter table public.fixed_assets
  add column ca_class_code text;

comment on column public.fixed_assets.ca_class_code is
  'Schedule 3 class, or null for an asset that attracts no capital '
  'allowance at all -- land, for instance. Not a to-do.';

-- Whether the vehicle was new and on the road, which is what decides
-- between the two motor caps. Only read for a class that HAS a cap.
alter table public.fixed_assets
  add column ca_notes text;

comment on column public.fixed_assets.ca_notes is
  'Why this asset is in the class it is in -- the reasoning a reviewer '
  'would otherwise have to reconstruct from the cost and the label.';

-- ---------------------------------------------------------------------
-- The class in force for a date
-- ---------------------------------------------------------------------
create or replace function app.ca_class_at(p_code text, p_on date)
returns public.capital_allowance_classes
language sql stable
set search_path = public, pg_temp
as $$
  select c.*
    from public.capital_allowance_classes c
   where c.code = p_code
     and c.effective_from <= p_on
     and (c.effective_to is null or c.effective_to > p_on)
   -- Latest wins where two overlap, which the unique constraint does
   -- not prevent: (code, effective_from) is unique, so two rows can
   -- still claim the same day if somebody forgets an effective_to.
   order by c.effective_from desc
   limit 1;
$$;

revoke all on function app.ca_class_at(text, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Qualifying expenditure
-- ---------------------------------------------------------------------

-- What the allowance is computed ON, which is not always the cost. A
-- RM300,000 car in a class capped at RM100,000 qualifies on RM100,000,
-- and every allowance and the residual follow from this one number.
create or replace function app.ca_qualifying_expenditure(
  p_cost numeric, p_cap numeric)
returns numeric
language sql immutable
-- Pinned although this function touches nothing: `search_path.sql`
-- requires it of every function without exception, and an exception
-- for "this one is pure" is an exception somebody widens later.
set search_path = pg_temp
as $$
  select case
           when p_cap is null then p_cost
           else least(p_cost, p_cap)
         end;
$$;

revoke all on function app.ca_qualifying_expenditure(numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The schedule
-- ---------------------------------------------------------------------

-- Computed from first principles every time rather than stored per year.
--
-- The alternative -- freezing each year's claim into a table the way
-- `depreciation_runs` freezes a posting -- would be right if a company
-- could choose to claim less than the maximum. It cannot: capital
-- allowances are given, not elected, and what is not absorbed is
-- carried forward rather than deferred. So the whole schedule is a
-- function of the asset register and the rates, and computing it is
-- both idempotent and correct after somebody fixes a cost that was
-- typed wrong three years ago.
--
-- `p_year` is the YEAR OF ASSESSMENT, which for a company with a
-- December year end is the calendar year. A company with another year
-- end has a basis period, and mapping basis period to YA is a
-- different piece of work -- so this takes the year and says so, rather
-- than pretending to know.
create or replace function public.capital_allowance_schedule(
  p_org_id uuid,
  p_year   integer)
returns table (
  asset_id       uuid,
  asset_no       text,
  name           text,
  class_code     text,
  class_label    text,
  acquired       date,
  cost           numeric,
  qualifying     numeric,
  initial        numeric,
  annual         numeric,
  prior_claimed  numeric,
  balancing_allowance numeric,
  balancing_charge    numeric,
  claimed        numeric,
  residual       numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  return query
  -- The class is joined LATERALLY and its columns are named one by one.
  -- `(app.ca_class_at(...)).*` would expand the whole composite, which
  -- carries its own `id`, `label`, `notes` and `source` -- and
  -- `fixed_assets` has an `id` too, so every later reference to `id`
  -- would be ambiguous and the function would not compile.
  with asset as (
    select a.id            as asset_id,
           a.asset_no,
           a.name,
           a.acquisition_date,
           a.cost,
           a.ca_class_code,
           a.disposal_date,
           a.disposal_proceeds,
           c.label         as class_label,
           c.initial_rate,
           c.annual_rate,
           c.cost_cap,
           c.small_value_threshold,
           c.aggregate_cap
      from public.fixed_assets a
      join lateral app.ca_class_at(a.ca_class_code, a.acquisition_date) c
        on true
     where a.org_id = p_org_id
       and a.deleted_at is null
       and a.ca_class_code is not null
       -- Not yet bought as at the end of this year of assessment.
       and extract(year from a.acquisition_date) <= p_year
       -- Sold in an EARLIER year: out of the schedule entirely. The year
       -- it was sold in still appears, carrying the balancing
       -- adjustment, which is the row a reviewer looks for.
       and (a.disposal_date is null
            or extract(year from a.disposal_date) >= p_year)
  ),
  base as (
    select s.*,
           app.ca_qualifying_expenditure(s.cost, s.cost_cap) as qe,
           (extract(year from s.acquisition_date))::integer   as first_ya,
           (s.disposal_date is not null
            and extract(year from s.disposal_date) = p_year)  as sold_now,
           (s.small_value_threshold is not null)             as in_small_class,
           (s.small_value_threshold is not null
            and app.ca_qualifying_expenditure(s.cost, s.cost_cap)
                  < s.small_value_threshold)                  as is_small
      from asset s
  ),
  flagged as (
    select b.*,
           (b.first_ya = p_year) as is_first
      from base b
  ),
  -- The aggregate cap on small value assets, which cannot be decided
  -- one row at a time: para 19A writes each asset off in full, but only
  -- up to RM20,000 across all of them in a year.
  --
  -- Allocated in acquisition order, and an asset that does not fit gets
  -- what is left of the cap and no more. What the law then allows is
  -- for the remainder to be claimed at ORDINARY rates instead; that is
  -- not modelled, so this UNDER-claims rather than over-claims for a
  -- company buying more than RM20,000 of small items in a year. The
  -- direction is deliberate and the screen says so. Note also that the
  -- cap does not apply to a resident SME at all.
  allocated as (
    select f.*,
           case
             when not (f.is_small and f.is_first) then null
             else greatest(
                    least(
                      f.qe,
                      f.aggregate_cap
                        - (sum(f.qe) filter (where f.is_small and f.is_first)
                             over (order by f.acquisition_date, f.asset_no
                                   rows between unbounded preceding
                                            and current row)
                           - f.qe)),
                    0)
           end as small_allowed
      from flagged f
  ),
  amounts as (
    select a.*,
           case
             -- Filed under a small value class and NOT under the
             -- threshold, which is not a small value asset at all. It
             -- gets nothing rather than the class's 100%: an asset of
             -- exactly RM2,000 is not under RM2,000, and writing it off
             -- in full because somebody picked the wrong class is the
             -- one direction this must never fail in.
             --
             -- The residual then sits at the whole cost, which is loud
             -- on the schedule and is how somebody notices to reclassify
             -- it. `<` rather than `<=` is one asset's entire treatment.
             when a.in_small_class and not a.is_small then 0
             when a.is_small and a.is_first then a.small_allowed
             when a.is_small then 0
             when a.is_first then round(a.qe * a.initial_rate, 2)
             else 0
           end as ia_raw,
           -- No annual allowance in the year of disposal: the balancing
           -- adjustment replaces it. None at all on a small value asset,
           -- whose whole rate is the initial one.
           case
             when a.in_small_class or a.sold_now then 0
             else round(a.qe * a.annual_rate, 2)
           end as aa_raw,
           -- What the earlier years already gave: the initial allowance
           -- once, and an annual allowance for each year elapsed.
           case
             when a.is_first then 0
             when a.in_small_class and not a.is_small then 0
             when a.is_small then a.qe
             else round(a.qe * a.initial_rate, 2)
                  + round(a.qe * a.annual_rate, 2) * (p_year - a.first_ya)
           end as prior_raw
      from allocated a
  ),
  capped as (
    select m.*,
           -- Nothing may be claimed beyond the qualifying expenditure.
           -- Without this an asset past the end of its life keeps
           -- claiming a full annual allowance every year and the
           -- residual goes negative.
           least(m.prior_raw, m.qe) as prior_capped
      from amounts m
  ),
  final as (
    select c.*,
           least(c.ia_raw, greatest(c.qe - c.prior_capped, 0)) as ia
      from capped c
  ),
  final2 as (
    select f.*,
           least(f.aa_raw, greatest(f.qe - f.prior_capped - f.ia, 0)) as aa
      from final f
  ),
  balancing as (
    select f.*,
           -- Proceeds are restricted in the same proportion the cost
           -- was. Selling the RM300,000 car for RM150,000 is a disposal
           -- of a RM100,000 asset for RM50,000, or the restriction would
           -- be given with one hand and taken back with the other.
           case
             when not f.sold_now then null
             when f.cost > 0 then
               round(coalesce(f.disposal_proceeds, 0) * f.qe / f.cost, 2)
             else 0
           end as restricted_proceeds,
           greatest(f.qe - f.prior_capped - f.ia - f.aa, 0) as residual_before
      from final2 f
  )
  select b.asset_id, b.asset_no, b.name, b.ca_class_code, b.class_label,
         b.acquisition_date, b.cost, b.qe,
         b.ia, b.aa, b.prior_capped,
         case when b.sold_now
              then greatest(b.residual_before - b.restricted_proceeds, 0)
              else 0 end,
         case when b.sold_now
              -- A balancing charge claws back allowances already given
              -- and can never exceed them. Selling a fully written down
              -- lorry for more than it cost is a capital gain, which is
              -- not taxed here.
              then least(
                     greatest(b.restricted_proceeds - b.residual_before, 0),
                     b.prior_capped + b.ia + b.aa)
              else 0 end,
         b.ia + b.aa,
         case when b.sold_now then 0 else b.residual_before end
    from balancing b
   order by b.acquisition_date, b.asset_no;
end; $$;

revoke all on function public.capital_allowance_schedule(uuid, integer)
  from public, anon;
grant execute on function public.capital_allowance_schedule(uuid, integer)
  to authenticated;

comment on function public.capital_allowance_schedule(uuid, integer) is
  'The Schedule 3 working for a year of assessment: qualifying '
  'expenditure, initial and annual allowances, the balancing '
  'adjustment on disposal, and residual expenditure carried forward. '
  'Not a tax computation -- this is the figure one subtracts.';

-- ---------------------------------------------------------------------
-- The rates as they stand
--
-- Seeded is_verified FALSE. These are the commonly published Schedule 3
-- rates and the person filing a return is the one who checks them
-- against the Act and ticks the box.
-- ---------------------------------------------------------------------
insert into public.capital_allowance_classes
  (code, label, initial_rate, annual_rate, cost_cap,
   small_value_threshold, aggregate_cap, effective_from, sort_order,
   source, notes)
values
  ('plant', 'Plant and machinery (general)', 0.20, 0.14, null,
   null, null, date '2000-01-01', 10,
   'Schedule 3 ITA 1967', null),
  ('heavy', 'Heavy machinery', 0.20, 0.20, null,
   null, null, date '2000-01-01', 20,
   'Schedule 3 ITA 1967', null),
  ('motor_restricted',
   'Motor vehicle (restricted to RM100,000)', 0.20, 0.20, 100000,
   null, null, date '2000-01-01', 30,
   'Schedule 3 ITA 1967, para 2',
   'A vehicle not new, or not licensed for commercial transport. '
   'Qualifying expenditure is capped at RM100,000 however much it cost.'),
  ('motor_200k',
   'Motor vehicle, new and on the road (restricted to RM200,000)',
   0.20, 0.20, 200000, null, null, date '2000-01-01', 40,
   'Schedule 3 ITA 1967, para 2',
   'The higher cap, for a new vehicle costing no more than RM150,000 '
   'when bought -- check the condition before choosing this class.'),
  ('computer', 'Computer and IT equipment', 0.20, 0.20, null,
   null, null, date '2000-01-01', 50,
   'Schedule 3 ITA 1967', null),
  ('office', 'Office equipment and furniture', 0.20, 0.10, null,
   null, null, date '2000-01-01', 60,
   'Schedule 3 ITA 1967', null),
  ('small_value', 'Small value asset', 1.00, 0, null,
   2000, 20000, date '2000-01-01', 70,
   'Schedule 3 ITA 1967, para 19A',
   'Written off in full in the year of purchase. Each asset under '
   'RM2,000, and the total claimed this way is capped at RM20,000 a '
   'year -- a cap that does not apply to a resident SME.'),
  ('industrial_building', 'Industrial building', 0.10, 0.03, null,
   null, null, date '2000-01-01', 80,
   'Schedule 3 ITA 1967, para 63', null);
