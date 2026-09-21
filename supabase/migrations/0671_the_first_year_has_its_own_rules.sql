-- =====================================================================
-- iAkauntan :: 0671 the first year has its own rules
--
-- `0667` put `first_period` on every estimate and said, in as many
-- words, that it existed "so the screen can say the rules differ
-- rather than quietly applying the wrong ones". Nothing then read it.
-- The flag was a promise that the rules differ, kept nowhere.
--
-- They differ in two ways, and both are worth money:
--
--   * **The CP204 is due three months from commencing operations**,
--     not thirty days before the basis period begins. For a company
--     incorporated partway through a year those are not the same date
--     and the ordinary one has usually already passed.
--   * **A qualifying new SME pays NO instalments for its first two
--     years of assessment** — s.107C(4A). A schedule of twelve
--     payments for a company that owes none is twelve demands for
--     money on dates nobody has to meet.
--
-- ---------------------------------------------------------------------
-- Why nothing detects this
--
-- The obvious rule is "the company's first financial year in this
-- product". It is wrong, and quietly: a company migrating from
-- AutoCount with fifteen years of history has its first fiscal year
-- HERE long after its first basis period. Applying the new-company
-- rules to it would move a real deadline and cancel real instalments.
--
-- `corp_entities` carries incorporation dates and is a secretarial
-- firm's CLIENT list, not the organisation's own record — there is no
-- flag saying which row, if any, is the company using the software.
-- So there is no signal here that is not a guess, and `first_period`
-- stays something a person says. The screen asks; nothing infers.
--
-- ---------------------------------------------------------------------
-- Unknown is not exempt
--
-- The exemption tests paid-up ordinary share capital at the beginning
-- of the basis period and gross business income — the same two figures
-- `0665` already tests for the SME band, against the same limits in
-- `company_tax_rates`, read rather than copied so the two cannot
-- disagree about what an SME is.
--
-- Neither is a balance this system holds, so both are typed and both
-- may be null. **Null means the exemption is NOT established**, and
-- the instalments are scheduled. That is the safe direction and it is
-- worth saying which way it runs: paying instalments that turn out
-- not to have been due is recoverable, and skipping instalments that
-- were due is a penalty under s.107C(9). The screen says the test
-- could not be taken rather than pretending it failed.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The rules for a first period
-- ---------------------------------------------------------------------
alter table public.tax_estimate_rules
  -- How long a new taxpayer has from commencing operations. Three
  -- months for CP204.
  add column first_period_filing_months integer
    check (first_period_filing_months > 0),

  -- How many years of assessment a qualifying new SME is relieved of
  -- instalments for. Two for CP204. Zero -- not null -- for CP500,
  -- because "no relief" is an answer and null would read as "nobody
  -- has said".
  add column first_period_exempt_years integer not null default 0
    check (first_period_exempt_years >= 0);

comment on column public.tax_estimate_rules.first_period_filing_months is
  'Months from commencing operations to furnish the first estimate, '
  'in place of the ordinary "so many days before the period opens" — '
  'which for a company incorporated partway through a year has '
  'usually already passed.';

comment on column public.tax_estimate_rules.first_period_exempt_years is
  'Years of assessment a qualifying new SME pays no instalments for. '
  'Zero means no relief, which is not the same as nobody having said.';

update public.tax_estimate_rules
   set first_period_filing_months = 3,
       first_period_exempt_years = 2,
       notes = coalesce(notes, '') ||
         ' A new company furnishes within three months of commencing '
         'operations, and a qualifying new SME is relieved of '
         'instalments for its first two years of assessment '
         '(s.107C(4A)).'
 where form = 'CP204';

-- CP500 has no equivalent relief: LHDN issues the estimate from the
-- preceding assessment, and a person with no preceding assessment is
-- simply not issued one yet.
update public.tax_estimate_rules
   set first_period_filing_months = null,
       first_period_exempt_years = 0
 where form = 'CP500';


-- ---------------------------------------------------------------------
-- What an estimate has to be told
-- ---------------------------------------------------------------------
alter table public.tax_estimates
  -- When the business actually began. Not the incorporation date: a
  -- company can be incorporated in March and commence operations in
  -- September, and s.107C(2) counts from the second.
  add column commenced_on date,

  -- The same two figures `0665` tests for the SME band, at the
  -- beginning of the basis period. Typed, nullable, and null means
  -- the test could not be taken.
  add column paid_up_capital numeric(18, 2)
    check (paid_up_capital >= 0),
  add column gross_business_income numeric(18, 2)
    check (gross_business_income >= 0);

comment on column public.tax_estimates.commenced_on is
  'When the business commenced operations, which is not the '
  'incorporation date — a company incorporated in March may commence '
  'in September, and the first CP204 is counted from the second.';

comment on column public.tax_estimates.paid_up_capital is
  'Paid-up ordinary share capital at the BEGINNING of the basis '
  'period. Null means the instalment exemption could not be tested, '
  'and the instalments are scheduled — the safe direction, because '
  'skipping instalments that were due is a penalty under s.107C(9).';


-- ---------------------------------------------------------------------
-- The two answers
-- ---------------------------------------------------------------------
create or replace function public.tax_estimate_first_period(
  p_estimate_id uuid)
returns table (
  is_first_period      boolean,
  form                 text,
  commenced_on         date,
  filing_due           date,
  ordinary_filing_due  date,
  filing_due_known     boolean,
  exempt_instalments   boolean,
  exemption_known      boolean,
  exempt_until_ya      integer,
  paid_up_capital      numeric,
  gross_business_income numeric,
  capital_limit        numeric,
  turnover_limit       numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  e        record;
  r        record;
  rates    record;
  v_known  boolean;
  v_exempt boolean;
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

  select * into r from public.tax_estimate_rules ru
   where ru.year_of_assessment = e.year_of_assessment
     and ru.form = e.form;
  if r is null then
    raise exception 'No % rules for year of assessment %',
      e.form, e.year_of_assessment using errcode = 'P0002';
  end if;

  -- The SME limits are READ from `0665`'s table rather than copied
  -- into this one. Two tables that both define what an SME is would
  -- agree on the day they were written.
  select * into rates from public.company_tax_rates cr
   where cr.year_of_assessment = e.year_of_assessment;

  -- Both figures, or the test was not taken. Same rule and the same
  -- reason as `0665`'s SME band: unknown says so rather than quietly
  -- coming out as "does not qualify", which is the same answer with
  -- none of the warning.
  v_known := e.first_period
             and e.paid_up_capital is not null
             and e.gross_business_income is not null
             and rates.year_of_assessment is not null;

  v_exempt := v_known
              and r.first_period_exempt_years > 0
              and e.paid_up_capital <= rates.sme_capital_limit
              and e.gross_business_income <= rates.sme_turnover_limit;

  return query select
    e.first_period,
    e.form,
    e.commenced_on,
    -- Three months from commencing operations, where the date is
    -- known. Null rather than a guess: a deadline computed from a
    -- date nobody supplied is a deadline somebody will trust.
    case when e.first_period and e.commenced_on is not null
              and r.first_period_filing_months is not null
         then (e.commenced_on
               + make_interval(months => r.first_period_filing_months)
               - interval '1 day')::date
         else null end,
    -- What it would have been under the ordinary rule, so the screen
    -- can show the two together. For a company incorporated partway
    -- through a year the ordinary one has usually already passed, and
    -- seeing that is the point.
    (e.start_date - coalesce(r.filing_days_before, 0))::date,
    (e.first_period and e.commenced_on is not null
       and r.first_period_filing_months is not null),
    v_exempt,
    v_known,
    case when v_exempt
         then e.year_of_assessment + r.first_period_exempt_years - 1
         else null end,
    e.paid_up_capital,
    e.gross_business_income,
    rates.sme_capital_limit,
    rates.sme_turnover_limit;
end; $$;

revoke all on function public.tax_estimate_first_period(uuid)
  from public, anon;
grant execute on function public.tax_estimate_first_period(uuid)
  to authenticated;

comment on function public.tax_estimate_first_period(uuid) is
  'The two ways a first basis period differs: when the estimate is '
  'due, and whether a qualifying new SME owes instalments at all. '
  'Unknown is never exempt -- the instalments are scheduled and the '
  'screen says the test could not be taken.';


-- ---------------------------------------------------------------------
-- No instalments where none are owed
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
  v_exempt boolean;
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

  -- A qualifying new SME owes none. Twelve rows of demands for money
  -- on dates nobody has to meet is worse than an empty list with a
  -- sentence under it, which is what the screen draws instead.
  select fp.exempt_instalments into v_exempt
    from public.tax_estimate_first_period(p_estimate_id) fp;
  if v_exempt then
    return;
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
      -- rather than land on the 28th.
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
  'names -- and EMPTY where a qualifying new SME owes none for its '
  'first two years of assessment. Equal amounts with the last '
  'carrying the rounding, each date clamped to the length of its '
  'month.';


-- ---------------------------------------------------------------------
-- A revision carries the first-period facts forward
-- ---------------------------------------------------------------------
-- The same class of bug `0670` fixed for the form, and it would have
-- come back in exactly the same shape: the revised row takes the
-- column defaults, so a new company's second estimate silently stops
-- being a first period, its deadline reverts to the ordinary one and
-- its exemption disappears. The first schedule would have been right,
-- which is what makes it hard to see.
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
     prior_estimate, revises_id, revision_month, first_period,
     commenced_on, paid_up_capital, gross_business_income, created_by)
  values
    (e.org_id, e.fiscal_year_id, e.year_of_assessment, e.form,
     p_estimated_tax,
     e.prior_estimate, p_estimate_id, v_month, e.first_period,
     e.commenced_on, e.paid_up_capital, e.gross_business_income,
     auth.uid())
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function public.revise_tax_estimate(uuid, numeric)
  from public, anon;
grant execute on function public.revise_tax_estimate(uuid, numeric)
  to authenticated;

comment on function public.revise_tax_estimate(uuid, numeric) is
  'Replaces an estimate with a revised one, keeping the original and '
  'carrying everything about it that is not the figure -- its form, '
  'and whether this is a first basis period with the facts that '
  'decide its deadline and its exemption. The revision is NOT refused '
  'outside the permitted months: whether it is allowed is a question '
  'the screen asks and a person answers.';


-- ---------------------------------------------------------------------
-- And the calendar follows it
-- ---------------------------------------------------------------------
-- `0668` computes the CP204 date from the basis period, which is the
-- right answer for every company that is not in its first one. Where
-- an estimate EXISTS and says otherwise, the calendar follows the
-- estimate -- otherwise the two screens would print different
-- deadlines for the same obligation, which is worse than either being
-- wrong on its own.
--
-- Before an estimate exists there is nothing to follow, and the
-- calendar shows the ordinary date. That is honest rather than
-- convenient: nothing in this schema can tell a newly incorporated
-- company from one that has been trading for fifteen years and only
-- just started keeping its books here.
--
-- The return type is unchanged, so this replaces rather than drops.
-- The estimate is now joined BEFORE the lateral that computes the
-- date, because a lateral may only reference what is to its left.
create or replace function public.tax_upcoming_filings(
  p_org_id uuid,
  p_within_days integer default 240)
returns table (
  filing_type text,
  filing_name text,
  form_label text,
  statute_ref text,
  fiscal_year_id uuid,
  period_from date,
  period_to date,
  year_of_assessment integer,
  due_date date,
  efiling_due_date date,
  days_left integer,
  is_overdue boolean,
  needs_employees boolean,
  description text,
  computation_id uuid,
  estimate_id uuid,
  status text,
  filing_id uuid)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  v_today date := app.today();
  v_entity text;
  v_has_staff boolean;
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  select o.entity_type into v_entity
    from public.organizations o where o.id = p_org_id;

  -- An employer for this purpose is anybody who has ever had somebody
  -- on the payroll: a company that let its last employee go in March
  -- still files a Form E for that year.
  select exists (
    select 1 from public.employees e where e.org_id = p_org_id
  ) into v_has_staff;

  return query
  select t.code,
         t.name,
         t.form_label,
         t.statute_ref,
         fy.id,
         -- Form E and Form EA cover a calendar year whatever the
         -- company's year end is, so they are labelled with one. The
         -- date below is the same either way; this is not.
         case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 1, 1)
              else fy.start_date end,
         case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 12, 31)
              else fy.end_date end,
         extract(year from fy.end_date)::integer,
         d.due,
         case when t.efiling_grace_months is null
                   and t.efiling_grace_days is null then null
              else (d.due
                    + make_interval(months => coalesce(t.efiling_grace_months, 0))
                    + make_interval(days => coalesce(t.efiling_grace_days, 0)))::date
         end,
         (d.due - v_today)::integer,
         d.due < v_today,
         t.needs_employees,
         t.description,
         tc.id,
         te.id,
         -- Nothing recorded reads as nothing recorded rather than as
         -- null, so a screen can switch on one value.
         coalesce(tf.status, 'not_started'),
         tf.id
    from public.fiscal_years fy
    join public.tax_filing_types t
      on coalesce(v_entity, 'other') = any (t.applies_to)
     and (not t.needs_employees or v_has_staff)
    left join public.tax_computations tc
      on tc.fiscal_year_id = fy.id and tc.org_id = fy.org_id
    -- The estimate still in force: a revision is a NEW row in `0667`
    -- that names the one it replaces, so the current one is whichever
    -- nothing has revised.
    left join public.tax_estimates te
      on te.fiscal_year_id = fy.id and te.org_id = fy.org_id
     and not exists (select 1 from public.tax_estimates r
                      where r.revises_id = te.id)
    cross join lateral (
      select coalesce(
        -- A first basis period's CP204 is due three months from
        -- commencing operations. Only for the CP204 rows: a Form C is
        -- seven months after the period's close whether the company
        -- is new or not.
        case when t.code = 'cp204'
                  and te.first_period
                  and te.commenced_on is not null
             then (select (te.commenced_on
                           + make_interval(
                               months => ru.first_period_filing_months)
                           - interval '1 day')::date
                     from public.tax_estimate_rules ru
                    where ru.year_of_assessment =
                            extract(year from fy.end_date)::integer
                      and ru.form = te.form
                      and ru.first_period_filing_months is not null)
             else null end,
        app.tax_filing_due(
          t.basis, t.days_before, t.months_after, t.period_month,
          t.due_month, t.due_day, fy.start_date, fy.end_date)) as due
    ) d
    -- Keyed on the obligation rather than the year -- see `0669`'s
    -- header. Joined on the period this row is FOR, which for Form E
    -- is the calendar year computed above, so the expression is
    -- repeated rather than referenced: a select-list alias is not in
    -- scope in the from clause.
    left join public.tax_filings tf
      on tf.org_id = fy.org_id and tf.filing_type = t.code
     and tf.period_to = case when t.basis = 'month_day_after_year'
              then make_date(extract(year from fy.end_date)::integer, 12, 31)
              else fy.end_date end
   where fy.org_id = p_org_id
     and d.due is not null
     -- Dealt with, one way or the other. An obligation still in
     -- preparation STAYS: somebody opening a Form C has not filed it,
     -- and a list that cleared on the intention to do something would
     -- be worse than one that never cleared at all.
     and coalesce(tf.status, 'not_started') not in
           ('filed', 'not_applicable')
     -- A year either side of the window: an obligation that is already
     -- late is the one somebody most needs to see, and dropping it the
     -- day after it was due is exactly backwards.
     and d.due between v_today - 365
                   and v_today + greatest(coalesce(p_within_days, 240), 1)
   order by d.due, t.sort_order;
end;
$$;

revoke all on function public.tax_upcoming_filings(uuid, integer)
  from public, anon;
grant execute on function public.tax_upcoming_filings(uuid, integer)
  to authenticated;

comment on function public.tax_upcoming_filings(uuid, integer) is
  'Every income tax obligation this company still has against its own '
  'basis periods, computed rather than stored, with what is already '
  'late kept in the list and what has been filed or dismissed taken '
  'out of it. A CP204 whose estimate says this is a first basis '
  'period follows the estimate''s three-month deadline rather than '
  'the ordinary one, so the two screens cannot disagree.';
