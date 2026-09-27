-- =====================================================================
-- CP204 and CP500: the estimate, before it becomes a penalty
--
-- `0665` and `0666` compute what is owed once the year has finished.
-- This is the other half of the year, and it runs the opposite way: a
-- company has to say what it thinks it will owe BEFORE the basis period
-- begins, pay that in monthly instalments, and is penalised if it
-- guessed too low.
--
-- The penalty is what makes this worth building rather than leaving to
-- a spreadsheet. Under-estimate by more than the tolerance and 10% of
-- the excess is added to the bill — money lost to arithmetic nobody
-- did, on a figure the system already knows how to compute. The whole
-- point of `tax_estimate_exposure` below is to say so in the sixth
-- month, when it can still be revised, rather than in the assessment.
--
-- ---------------------------------------------------------------------
-- Why the rules are rows
--
-- Every number here is a policy lever: the floor against last year's
-- estimate, the tolerance before a penalty, the penalty itself, how
-- many instalments, which months a revision is allowed in. They have
-- all moved, and some moved recently. A constant in a function is a
-- constant somebody has to find.
--
-- `is_verified` FALSE on the seed, the same as `0025`, `0664` and
-- `0665`: these are the commonly published figures, not transcribed
-- from the Act, and anybody filing checks them first.
--
-- ---------------------------------------------------------------------
-- What this does NOT do
--
-- It does not file a CP204 and it does not pay an instalment. It
-- produces the estimate, the instalment schedule with dates, and the
-- two questions somebody actually has: is this estimate high enough to
-- be allowed, and is it high enough to avoid a penalty.
--
-- It also does not model the first basis period of a new company,
-- which has its own timing and its own exemption. `first_period` is on
-- the estimate so the screen can say the rules differ rather than
-- quietly applying the wrong ones.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rules
-- ---------------------------------------------------------------------
create table public.tax_estimate_rules (
  year_of_assessment integer primary key,

  -- An estimate may not be lower than this share of the previous
  -- year's -- the revised one where there was a revision.
  floor_percent_of_prior numeric(6, 2) not null,

  -- How far under the final liability an estimate may fall before a
  -- penalty bites, and what the penalty is on the excess beyond it.
  under_tolerance_percent numeric(6, 2) not null,
  under_penalty_percent   numeric(6, 2) not null,

  instalments             integer not null check (instalments > 0),
  -- Which month of the basis period the first instalment falls in.
  first_instalment_month  integer not null check (first_instalment_month >= 1),
  -- And which day of that month, and every month after.
  instalment_day          integer not null
                            check (instalment_day between 1 and 28),

  -- How many days before the basis period begins the estimate is due.
  filing_days_before      integer not null,

  -- Months of the basis period in which a revision is allowed.
  revision_months         integer[] not null default '{}',

  source      text,
  is_verified boolean not null default false,
  notes       text
);

comment on table public.tax_estimate_rules is
  'CP204 policy by year of assessment: the floor against last year, the '
  'tolerance and penalty for under-estimating, the instalment shape and '
  'when a revision is allowed. Every one of these has moved before.';

alter table public.tax_estimate_rules enable row level security;
create policy tax_estimate_rules_read on public.tax_estimate_rules
  for select to authenticated using (true);
create policy tax_estimate_rules_write on public.tax_estimate_rules
  for all to authenticated
  using (app.is_platform_admin()) with check (app.is_platform_admin());
grant select on public.tax_estimate_rules to authenticated;
grant insert, update, delete on public.tax_estimate_rules to authenticated;

insert into public.tax_estimate_rules
  (year_of_assessment, floor_percent_of_prior, under_tolerance_percent,
   under_penalty_percent, instalments, first_instalment_month,
   instalment_day, filing_days_before, revision_months, source, notes)
select y, 85, 30, 10, 12, 2, 15, 30, array[6, 9],
       'Published guidance for YA ' || y,
       'Seeded unverified. The first basis period of a new company has '
       'its own timing and exemption, which is not modelled.'
  from generate_series(2020, 2030) as y;

-- ---------------------------------------------------------------------
-- The estimate
-- ---------------------------------------------------------------------
create table public.tax_estimates (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null
                   references public.organizations (id) on delete cascade,
  fiscal_year_id uuid not null
                   references public.fiscal_years (id) on delete cascade,
  constraint tax_estimates_year_same_org
    foreign key (org_id, fiscal_year_id)
    references public.fiscal_years (org_id, id) on delete cascade,

  year_of_assessment integer not null,

  -- Declared HERE and not in a later ALTER. `revises_id` below points
  -- at this same table with a composite key, and a self-reference
  -- needs the key it points at to exist already -- otherwise the
  -- CREATE fails with "there is no unique constraint matching given
  -- keys for referenced table".
  unique (org_id, id),

  -- What the company says it will owe.
  estimated_tax   numeric(18, 2) not null default 0
                    check (estimated_tax >= 0),

  -- Last year's, which sets the floor. Typed rather than read from an
  -- earlier row: the first year this product is used there IS no
  -- earlier row, and a floor of nothing would silently allow any
  -- estimate at all.
  prior_estimate  numeric(18, 2),

  -- A revision replaces an earlier estimate rather than editing it.
  -- CP204A is its own form with its own date, and overwriting the
  -- original would lose the figure the floor is measured against.
  -- The company as well as the row, even though the parent is this
  -- same table. `tenant_foreign_keys.sql` refuses a single-column link
  -- to anything tenant-scoped: without the pair, a revision could
  -- point at ANOTHER company's estimate and take its prior-year figure
  -- as the floor.
  --
  -- And no `on delete` clause, which means NO ACTION: deleting an
  -- estimate a revision points at is REFUSED rather than quietly
  -- unlinking it. `set null` would try to null `org_id` as well --
  -- the same gate refuses that too -- and the right answer is the
  -- refusal anyway. The original is the figure the floor was measured
  -- against; a revision with nothing behind it is a number with no
  -- provenance.
  revises_id      uuid,
  constraint tax_estimates_revises_same_org
    foreign key (org_id, revises_id)
    references public.tax_estimates (org_id, id),
  revision_month  integer check (revision_month between 1 and 12),

  -- A new company's first basis period has different timing and an
  -- exemption. Not modelled -- this flag exists so the screen can say
  -- the rules differ rather than applying the wrong ones quietly.
  first_period    boolean not null default false,

  status     text not null default 'draft'
               check (status in ('draft', 'submitted', 'superseded')),
  notes      text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.tax_estimates is
  'A CP204 estimate for a basis period, and its revisions. A revision '
  'is a new row pointing at the one it replaces -- CP204A is its own '
  'form, and overwriting the original would lose the figure the 85% '
  'floor is measured against.';

create index tax_estimates_org_idx
  on public.tax_estimates (org_id, year_of_assessment desc);
create index tax_estimates_year_idx
  on public.tax_estimates (fiscal_year_id, created_at desc);

alter table public.tax_estimates enable row level security;
create policy tax_estimates_select on public.tax_estimates
  for select to authenticated using (app.is_org_member(org_id));
create policy tax_estimates_insert on public.tax_estimates
  for insert to authenticated with check (app.can_post(org_id));
create policy tax_estimates_update on public.tax_estimates
  for update to authenticated
  using (app.can_post(org_id)) with check (app.can_post(org_id));
create policy tax_estimates_delete on public.tax_estimates
  for delete to authenticated using (app.can_admin(org_id));
grant select, insert, update, delete on public.tax_estimates
  to authenticated;

create trigger live_change_insert after insert on public.tax_estimates
  referencing new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_update after update on public.tax_estimates
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.note_live_change();
create trigger live_change_delete after delete on public.tax_estimates
  referencing old table as old_rows
  for each statement execute function app.note_live_change();

-- ---------------------------------------------------------------------
-- The instalments
--
-- Equal monthly amounts, and the LAST one carries the rounding. Twelve
-- instalments of a figure that does not divide by twelve otherwise
-- come to a few sen more or less than the estimate, and an instalment
-- schedule that does not add up to the thing it is paying is the first
-- thing anybody notices.
-- ---------------------------------------------------------------------
create or replace function public.tax_estimate_schedule(p_estimate_id uuid)
returns table (
  instalment_no integer,
  due_on        date,
  amount        numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  e       record;
  r       record;
  v_each  numeric;
  v_start date;
  i       integer;
begin
  select te.*, fy.start_date into e
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if e is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into r from public.tax_estimate_rules
   where year_of_assessment = e.year_of_assessment;
  if r is null then
    raise exception 'No estimate rules for year of assessment %',
      e.year_of_assessment using errcode = 'P0002';
  end if;

  v_each := round(e.estimated_tax / r.instalments, 2);

  -- The first instalment's month, counted from the start of the basis
  -- period, on the day the rules name.
  v_start := date_trunc('month',
               e.start_date
               + make_interval(months => r.first_instalment_month - 1))::date
             + (r.instalment_day - 1);

  for i in 1..r.instalments loop
    return query select
      i,
      (date_trunc('month', v_start + make_interval(months => i - 1))::date
        + (r.instalment_day - 1)),
      case
        -- The last one absorbs whatever the division left over, so the
        -- schedule adds up to the estimate exactly.
        when i = r.instalments
          then round(e.estimated_tax - v_each * (r.instalments - 1), 2)
        else v_each
      end;
  end loop;
end; $$;

revoke all on function public.tax_estimate_schedule(uuid) from public, anon;
grant execute on function public.tax_estimate_schedule(uuid)
  to authenticated;

comment on function public.tax_estimate_schedule(uuid) is
  'The instalments an estimate is paid in, with their dates. Equal '
  'amounts with the last one carrying the rounding, so the schedule '
  'adds up to the estimate exactly.';

-- ---------------------------------------------------------------------
-- Is this estimate allowed, and is it high enough?
--
-- Two different questions with two different answers, and conflating
-- them is the mistake this function exists to prevent:
--
--   * **The FLOOR** is about last year. An estimate below 85% of the
--     previous year's is not a low estimate, it is an invalid one --
--     LHDN substitutes its own figure.
--   * **The EXPOSURE** is about this year. An estimate can clear the
--     floor comfortably and still be penalised, because the penalty is
--     measured against what the company ACTUALLY owed, which nobody
--     knows until the year has finished.
--
-- The second is the one worth having in the sixth month. By then the
-- ledger knows most of the answer, `0665` can compute it, and a
-- revision is still allowed.
-- ---------------------------------------------------------------------
create or replace function public.tax_estimate_exposure(
  p_estimate_id uuid,
  -- The computation to measure against, where there is one. Null asks
  -- only the floor question, which is all that can be asked before the
  -- year has run.
  p_computation_id uuid default null)
returns table (
  estimated_tax     numeric,
  prior_estimate    numeric,
  floor_required    numeric,
  meets_floor       boolean,
  floor_known       boolean,
  actual_tax        numeric,
  actual_known      boolean,
  shortfall         numeric,
  tolerance_amount  numeric,
  excess_over_tolerance numeric,
  penalty           numeric,
  revision_open     boolean,
  revision_months   integer[])
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  e        record;
  r        record;
  v_actual numeric;
  v_known  boolean := false;
  v_floor  numeric;
  v_short  numeric := 0;
  v_tol    numeric := 0;
  v_excess numeric := 0;
  v_month  integer;
begin
  select te.*, fy.start_date, fy.end_date into e
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if e is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.is_org_member(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select * into r from public.tax_estimate_rules
   where year_of_assessment = e.year_of_assessment;
  if r is null then
    raise exception 'No estimate rules for year of assessment %',
      e.year_of_assessment using errcode = 'P0002';
  end if;

  -- The floor, where last year's figure is known. Null prior estimate
  -- means unknown rather than nothing: a floor of zero would pass any
  -- estimate at all and say so confidently, which is worse than
  -- admitting the question cannot be answered.
  v_floor := round(coalesce(e.prior_estimate, 0)
                   * r.floor_percent_of_prior / 100, 2);

  if p_computation_id is not null then
    select tc.tax_charged - tc.zakat_rebate into v_actual
      from public.tax_computation(p_computation_id) tc;
    v_known := v_actual is not null;
  end if;

  if v_known then
    v_actual := greatest(v_actual, 0);
    v_short := greatest(v_actual - e.estimated_tax, 0);
    -- The tolerance is a share of what was ACTUALLY owed, not of the
    -- estimate. Measuring it against the estimate would let a company
    -- that estimated nothing be penalised on nothing.
    v_tol := round(v_actual * r.under_tolerance_percent / 100, 2);
    v_excess := greatest(v_short - v_tol, 0);
  end if;

  -- Which month of the basis period today falls in, and whether a
  -- revision is still allowed in it.
  -- `app.today()` rather than the server's idea of today. Malaysia is
  -- eight hours ahead of UTC, so for a third of every day the server
  -- is a day behind it -- and the month a revision falls in decides
  -- whether the revision is allowed at all. `malaysian_clock.sql`
  -- refuses the server's day inside a function and refused both of
  -- these.
  v_month := 1 + (extract(year from app.today())::integer
                    - extract(year from e.start_date)::integer) * 12
               + (extract(month from app.today())::integer
                    - extract(month from e.start_date)::integer);

  return query select
    round(e.estimated_tax, 2),
    case when e.prior_estimate is null then null
         else round(e.prior_estimate, 2) end,
    case when e.prior_estimate is null then null else v_floor end,
    -- Unknown reads as NOT meeting the floor. The generous answer
    -- would be a tick beside a figure nobody has checked.
    (e.prior_estimate is not null and e.estimated_tax >= v_floor),
    (e.prior_estimate is not null),
    case when v_known then round(v_actual, 2) else null end,
    v_known,
    case when v_known then round(v_short, 2) else null end,
    case when v_known then round(v_tol, 2) else null end,
    case when v_known then round(v_excess, 2) else null end,
    case when v_known
         then round(v_excess * r.under_penalty_percent / 100, 2)
         else null end,
    (v_month = any (r.revision_months)),
    r.revision_months;
end; $$;

revoke all on function public.tax_estimate_exposure(uuid, uuid)
  from public, anon;
grant execute on function public.tax_estimate_exposure(uuid, uuid)
  to authenticated;

comment on function public.tax_estimate_exposure(uuid, uuid) is
  'Whether an estimate clears the floor against last year, and -- where '
  'a computation exists to measure against -- how far under the real '
  'liability it fell and what that costs. Two different questions: an '
  'estimate can clear the floor and still be penalised.';

-- ---------------------------------------------------------------------
-- Opening one, and revising it
-- ---------------------------------------------------------------------
create or replace function public.open_tax_estimate(
  p_org_id uuid,
  p_fiscal_year_id uuid,
  p_estimated_tax numeric default 0,
  p_prior_estimate numeric default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid; v_starts date; v_ends date;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  select fy.start_date, fy.end_date into v_starts, v_ends
    from public.fiscal_years fy
   where fy.id = p_fiscal_year_id and fy.org_id = p_org_id;

  if v_starts is null then
    raise exception 'No such financial year' using errcode = 'P0002';
  end if;

  -- The live one for this period, if there is one. Pressing the button
  -- again means "show me it" rather than "make a second".
  select te.id into v_id
    from public.tax_estimates te
   where te.org_id = p_org_id
     and te.fiscal_year_id = p_fiscal_year_id
     and te.status <> 'superseded'
   order by te.created_at desc
   limit 1;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.tax_estimates
    (org_id, fiscal_year_id, year_of_assessment, estimated_tax,
     prior_estimate, created_by)
  values
    (p_org_id, p_fiscal_year_id, extract(year from v_ends)::integer,
     coalesce(p_estimated_tax, 0), p_prior_estimate, auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function
  public.open_tax_estimate(uuid, uuid, numeric, numeric)
  from public, anon;
grant execute on function
  public.open_tax_estimate(uuid, uuid, numeric, numeric)
  to authenticated;

comment on function
  public.open_tax_estimate(uuid, uuid, numeric, numeric) is
  'Starts, or reopens, the CP204 estimate for a basis period. The year '
  'of assessment comes from the period''s end date. Pressing it again '
  'hands back the live estimate rather than making a second -- but a '
  'SUPERSEDED one is passed over, so a revised year opens its '
  'revision.';

-- A revision is a NEW row that supersedes the old one, because CP204A
-- is its own form with its own date -- and because the floor for next
-- year is measured against the REVISED figure, which an overwrite
-- would lose.
create or replace function public.revise_tax_estimate(
  p_estimate_id uuid,
  p_estimated_tax numeric)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare e record; v_id uuid; v_month integer;
begin
  select te.*, fy.start_date into e
    from public.tax_estimates te
    join public.fiscal_years fy on fy.id = te.fiscal_year_id
   where te.id = p_estimate_id;

  if e is null then
    raise exception 'No such estimate' using errcode = 'P0002';
  end if;
  if not app.can_post(e.org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  if p_estimated_tax is null or p_estimated_tax < 0 then
    raise exception 'A revised estimate cannot be negative'
      using errcode = '22023';
  end if;

  -- `app.today()` rather than the server's idea of today. Malaysia is
  -- eight hours ahead of UTC, so for a third of every day the server
  -- is a day behind it -- and the month a revision falls in decides
  -- whether the revision is allowed at all. `malaysian_clock.sql`
  -- refuses the server's day inside a function and refused both of
  -- these.
  v_month := 1 + (extract(year from app.today())::integer
                    - extract(year from e.start_date)::integer) * 12
               + (extract(month from app.today())::integer
                    - extract(month from e.start_date)::integer);

  update public.tax_estimates set status = 'superseded', updated_at = now()
   where id = p_estimate_id;

  insert into public.tax_estimates
    (org_id, fiscal_year_id, year_of_assessment, estimated_tax,
     -- The floor is still measured against the ORIGINAL prior year's
     -- figure, not against the estimate being replaced.
     prior_estimate, revises_id, revision_month, first_period, created_by)
  values
    (e.org_id, e.fiscal_year_id, e.year_of_assessment, p_estimated_tax,
     e.prior_estimate, p_estimate_id, v_month, e.first_period, auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.revise_tax_estimate(uuid, numeric)
  from public, anon;
grant execute on function public.revise_tax_estimate(uuid, numeric)
  to authenticated;

comment on function public.revise_tax_estimate(uuid, numeric) is
  'Replaces an estimate with a revised one, keeping the original. The '
  'revision is NOT refused outside the permitted months -- whether it '
  'is allowed is a question the screen asks with tax_estimate_exposure '
  'and a person answers, because a late revision is sometimes the '
  'right thing to record even when it will not be accepted.';
