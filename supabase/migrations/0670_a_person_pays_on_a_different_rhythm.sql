-- =====================================================================
-- iAkauntan :: 0670 a person pays on a different rhythm
--
-- `0667` built the estimate machinery and built it company-shaped:
-- twelve monthly instalments, due on the fifteenth, with a floor of
-- 85% of last year's estimate. That is CP204, under s.107C, and it is
-- right for a company.
--
-- It is WRONG for a sole proprietor, and `open_tax_estimate` did not
-- ask. A person with business income pays under s.107B -- **CP500** --
-- which is a different rhythm, a different day, and no floor at all:
--
--   * **Six instalments, not twelve**, two months apart.
--   * **Due on the 30th**, not the 15th -- of March, May, July,
--     September, November and January.
--   * **No 85% floor.** LHDN ISSUES the CP500 from the preceding
--     year's assessment; the taxpayer may apply to revise it downward
--     by 30 June. There is nothing for an estimate to be "too low
--     against", so a screen that reported one as failing a floor
--     would be inventing a rule.
--
-- The penalty is the same shape: under-estimate by more than 30% of
-- what was actually owed and 10% of the excess is added.
--
-- ---------------------------------------------------------------------
-- Why this is worse than a gap
--
-- A missing feature is visible. This was a sole proprietor opening an
-- estimate and being handed a company's schedule -- twelve dates, all
-- of them wrong, printed with the same confidence as a correct one.
-- Nothing said so, because nothing had asked what kind of taxpayer
-- was looking.
--
-- ---------------------------------------------------------------------
-- The shape of the fix
--
-- `tax_estimate_rules` gains a FORM. The primary key moves from the
-- year of assessment to the year and the form together, because the
-- two rhythms coexist in the same year and always will. Everything
-- `0667` seeded stays, as CP204.
--
-- Two of `0667`'s assumptions had to be widened rather than worked
-- around:
--
--   * `instalment_day` was checked `between 1 and 28`, which is a
--     sound way to avoid inventing a 30th of February and refuses
--     CP500 outright. It is now 1 to 31, and the schedule CLAMPS --
--     reusing `app.tax_filing_fixed_date` from `0668`, which exists
--     because `make_date(2027, 2, 30)` raises rather than clamping.
--   * The instalments were assumed to be monthly. `months_between`
--     says how far apart they are, and defaults to one.
--
-- ---------------------------------------------------------------------
-- What a basis period is for a person
--
-- Under s.21 an individual's basis year IS the calendar year, so the
-- CP500 months named above -- March, May, and so on -- are both
-- calendar months and months 3, 5, 7, 9, 11 and 13 of the basis
-- period. The schedule counts from the period, which agrees.
--
-- Where somebody has given a sole proprietorship a non-calendar
-- financial year in this product, the dates follow the PERIOD and
-- will not be LHDN's. That is stated rather than guessed at: the
-- alternative is hard-coding calendar months and being wrong for a
-- company, which is the mistake this migration exists to undo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rules gain a form
-- ---------------------------------------------------------------------
alter table public.tax_estimate_rules
  add column form text not null default 'CP204'
    check (form in ('CP204', 'CP500')),

  -- How far apart the instalments are. One for CP204, two for CP500.
  add column months_between integer not null default 1
    check (months_between between 1 and 12),

  -- CP500 has no floor against the previous year: LHDN issues the
  -- estimate rather than the taxpayer proposing one. FALSE here means
  -- the question does not arise, which is a different answer from
  -- "the previous figure is unknown" -- and the screen prints them
  -- differently.
  add column has_floor boolean not null default true;

comment on column public.tax_estimate_rules.form is
  'CP204 for a company under s.107C, CP500 for an individual under '
  's.107B. Two rhythms that coexist in every year of assessment.';

comment on column public.tax_estimate_rules.has_floor is
  'Whether an estimate can be too low to be ACCEPTED, as distinct '
  'from too low to avoid a penalty. False for CP500: LHDN issues it, '
  'so there is nothing to fall short of.';

-- The day may now be the 30th. `0667` capped it at 28 to avoid
-- inventing a 30th of February; the schedule below clamps instead,
-- which is the same protection without excluding a real rule.
alter table public.tax_estimate_rules
  drop constraint tax_estimate_rules_instalment_day_check;
alter table public.tax_estimate_rules
  add constraint tax_estimate_rules_instalment_day_check
    check (instalment_day between 1 and 31);

-- The year alone no longer identifies a rule.
alter table public.tax_estimate_rules
  drop constraint tax_estimate_rules_pkey;
alter table public.tax_estimate_rules
  add constraint tax_estimate_rules_pkey
    primary key (year_of_assessment, form);

insert into public.tax_estimate_rules
  (year_of_assessment, form, floor_percent_of_prior, has_floor,
   under_tolerance_percent, under_penalty_percent,
   instalments, months_between, first_instalment_month, instalment_day,
   filing_days_before, revision_months, source, notes)
select r.year_of_assessment, 'CP500',
       0, false,
       30, 10,
       6, 2, 3, 30,
       0, array[6],
       'ITA 1967 s.107B',
       'Six bimonthly instalments due on the 30th of March, May, '
       'July, September, November and January. No floor: LHDN issues '
       'the CP500 from the preceding year''s assessment and the '
       'taxpayer applies to revise it, by 30 June, on a CP502.'
  from public.tax_estimate_rules r
 where r.form = 'CP204'
on conflict (year_of_assessment, form) do nothing;


-- ---------------------------------------------------------------------
-- An estimate knows which one it is
-- ---------------------------------------------------------------------
alter table public.tax_estimates
  add column form text not null default 'CP204'
    check (form in ('CP204', 'CP500'));

comment on column public.tax_estimates.form is
  'Decided from the entity type when the estimate is opened, not '
  'typed. A sole proprietor handed a company''s twelve monthly '
  'instalments is being given twelve wrong dates with no sign that '
  'anything is wrong.';

-- Which form an entity type files. A company and an LLP file CP204;
-- everybody else with business income files CP500. An entity type
-- nobody recognises gets CP204, which is what this product mostly
-- holds -- and `open_tax_estimate` says which it chose.
create or replace function app.tax_estimate_form(p_entity_type text)
returns text
language sql immutable
set search_path = pg_catalog, public, pg_temp as $$
  select case p_entity_type
    when 'sole_proprietor' then 'CP500'
    when 'enterprise'      then 'CP500'
    when 'individual'      then 'CP500'
    when 'partnership'     then 'CP500'
    else 'CP204'
  end;
$$;

comment on function app.tax_estimate_form(text) is
  'Which estimate an entity type pays: CP204 under s.107C for a '
  'company or LLP, CP500 under s.107B for a person with business '
  'income. A partnership allocates, so its PARTNERS pay CP500 -- the '
  'firm''s own estimate is a working for them, on their rhythm.';


-- ---------------------------------------------------------------------
-- The schedule, on whichever rhythm applies
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
  v_first date;
  v_month date;
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

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;
  if r is null then
    raise exception 'No % rules for year of assessment %',
      e.form, e.year_of_assessment using errcode = 'P0002';
  end if;

  v_each := round(e.estimated_tax / r.instalments, 2);

  -- The month the first instalment falls in, counted from the start of
  -- the basis period.
  v_first := date_trunc('month',
               e.start_date
               + make_interval(months => r.first_instalment_month - 1))::date;

  for i in 1..r.instalments loop
    v_month := (v_first
                + make_interval(
                    months => (i - 1) * r.months_between))::date;
    return query select
      i,
      -- Clamped to the length of the month. CP500 falls on the 30th,
      -- and a schedule that reached February would otherwise raise
      -- rather than land on the 28th. `0668` wrote this because
      -- `make_date(2027, 2, 30)` raises before anything can catch it.
      app.tax_filing_fixed_date(
        extract(year from v_month)::integer,
        extract(month from v_month)::integer,
        r.instalment_day),
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
  'The instalments an estimate is paid in, on the rhythm its FORM '
  'names -- twelve monthly for CP204, six bimonthly for CP500. Equal '
  'amounts with the last carrying the rounding, and each date clamped '
  'to the length of its month.';


-- ---------------------------------------------------------------------
-- The exposure, without inventing a floor that does not exist
-- ---------------------------------------------------------------------
-- `floor_applies` is new and is NOT the same as `floor_known`. There
-- are three states and `0667` could only express two:
--
--   * the floor applies and last year's figure is known -- answerable;
--   * the floor applies and it is not -- a question mark;
--   * the floor does not apply at all, which is CP500, and where
--     `0667` would have printed "the floor cannot be checked" about a
--     rule that does not exist.
drop function if exists public.tax_estimate_exposure(uuid, uuid);

create or replace function public.tax_estimate_exposure(
  p_estimate_id uuid,
  p_computation_id uuid default null)
returns table (
  form              text,
  estimated_tax     numeric,
  prior_estimate    numeric,
  floor_required    numeric,
  meets_floor       boolean,
  floor_known       boolean,
  floor_applies     boolean,
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
  v_has_floor boolean;
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

  -- Aliased, because this function now has an OUT parameter called
  -- `form` and an unqualified `form` in the where clause is ambiguous
  -- between it and the column. Postgres refuses it rather than
  -- guessing, which is the good outcome: the guess would have
  -- compared the rules to an uninitialised output.
  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;
  if r is null then
    raise exception 'No % rules for year of assessment %',
      e.form, e.year_of_assessment using errcode = 'P0002';
  end if;

  v_has_floor := r.has_floor;

  -- The floor, where there is one and last year's figure is known.
  -- Null prior estimate means unknown rather than nothing: a floor of
  -- zero would pass any estimate at all and say so confidently, which
  -- is worse than admitting the question cannot be answered.
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
    -- estimate. Measuring it against the estimate would let a taxpayer
    -- who estimated nothing be penalised on nothing.
    v_tol := round(v_actual * r.under_tolerance_percent / 100, 2);
    v_excess := greatest(v_short - v_tol, 0);
  end if;

  -- Which month of the basis period today falls in, and whether a
  -- revision is still allowed in it.
  -- `app.today()` rather than the server's idea of today. Malaysia is
  -- eight hours ahead of UTC, so for a third of every day the server
  -- is a day behind it -- and the month a revision falls in decides
  -- whether the revision is allowed at all.
  v_month := 1 + (extract(year from app.today())::integer
                    - extract(year from e.start_date)::integer) * 12
               + (extract(month from app.today())::integer
                    - extract(month from e.start_date)::integer);

  return query select
    e.form,
    round(e.estimated_tax, 2),
    case when not v_has_floor or e.prior_estimate is null then null
         else round(e.prior_estimate, 2) end,
    case when not v_has_floor or e.prior_estimate is null then null
         else v_floor end,
    -- Unknown reads as NOT meeting the floor. The generous answer
    -- would be a tick beside a figure nobody has checked.
    --
    -- Where there is NO floor, this is FALSE as well -- and
    -- `floor_applies` below is what keeps the screen from reporting
    -- that as a failure. A CP500 does not pass a floor; it has none.
    (v_has_floor and e.prior_estimate is not null
       and e.estimated_tax >= v_floor),
    (v_has_floor and e.prior_estimate is not null),
    v_has_floor,
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
  'Whether an estimate clears the floor against last year -- where '
  'its form HAS a floor, which CP500 does not -- and, where a '
  'computation exists to measure against, how far under the real '
  'liability it fell and what that costs. Three separate questions, '
  'and floor_applies is what stops the third being reported as a '
  'failure of the first.';


-- ---------------------------------------------------------------------
-- Opening one, on the right form
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
declare
  v_id uuid; v_starts date; v_ends date; v_form text; v_entity text;
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

  -- Which form, from the entity type rather than from whoever pressed
  -- the button. This is the whole of `0670`: a sole proprietor handed
  -- CP204's twelve monthly dates gets twelve wrong dates, printed
  -- with the confidence of right ones.
  select o.entity_type into v_entity
    from public.organizations o where o.id = p_org_id;
  v_form := app.tax_estimate_form(v_entity);

  insert into public.tax_estimates
    (org_id, fiscal_year_id, year_of_assessment, form, estimated_tax,
     prior_estimate, created_by)
  values
    (p_org_id, p_fiscal_year_id, extract(year from v_ends)::integer,
     v_form, coalesce(p_estimated_tax, 0), p_prior_estimate, auth.uid())
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
  'Starts, or reopens, the estimate for a basis period -- CP204 or '
  'CP500, decided from the entity type rather than typed. The year of '
  'assessment comes from the period''s end date. Pressing it again '
  'hands back the live estimate rather than making a second, but a '
  'SUPERSEDED one is passed over so a revised year opens its revision.';


-- A revision carries the form forward. Without this the revised row
-- takes the column default -- CP204 -- so a sole proprietor revising a
-- CP500 would silently become a company from the second estimate on,
-- which is the original bug reappearing one step later.
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
  -- is a day behind it.
  v_month := 1 + (extract(year from app.today())::integer
                    - extract(year from e.start_date)::integer) * 12
               + (extract(month from app.today())::integer
                    - extract(month from e.start_date)::integer);

  update public.tax_estimates set status = 'superseded', updated_at = now()
   where id = p_estimate_id;

  insert into public.tax_estimates
    (org_id, fiscal_year_id, year_of_assessment, form, estimated_tax,
     -- The floor is still measured against the ORIGINAL prior year's
     -- figure, not against the estimate being replaced.
     prior_estimate, revises_id, revision_month, first_period, created_by)
  values
    (e.org_id, e.fiscal_year_id, e.year_of_assessment, e.form,
     p_estimated_tax,
     e.prior_estimate, p_estimate_id, v_month, e.first_period, auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.revise_tax_estimate(uuid, numeric)
  from public, anon;
grant execute on function public.revise_tax_estimate(uuid, numeric)
  to authenticated;

comment on function public.revise_tax_estimate(uuid, numeric) is
  'Replaces an estimate with a revised one, keeping the original and '
  'carrying its form. The revision is NOT refused outside the '
  'permitted months -- whether it is allowed is a question the screen '
  'asks with tax_estimate_exposure and a person answers, because a '
  'late revision is sometimes the right thing to record even when it '
  'will not be accepted.';
