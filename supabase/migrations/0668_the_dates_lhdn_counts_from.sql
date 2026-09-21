-- =====================================================================
-- iAkauntan :: 0668 the dates LHDN counts from
--
-- Measured before building. SSM's deadlines are computed (`0063`),
-- SST's are (`0455`), service tax on payment is (`0456`), the
-- fifteenth of the month after is (`0457`), quit rent and assessment
-- are (`0387`). Searched this schema for an income tax filing
-- deadline -- a due date for a Form C, a Form B, a Form E, a CP204 --
-- and there is not one. `0664` through `0667` built the whole tax
-- stack and gave it no dates at all.
--
-- That is the wrong way round. The computation is work somebody
-- chooses to do; the deadline is the thing that costs money whether
-- they did it or not. A late Form C is a penalty under s.112, a
-- CP204 that was never furnished means LHDN raises its own estimate,
-- and a Form E nobody remembered is an offence under s.120 with a
-- fine attached -- and the reason all three happen is that they are
-- each measured from a DIFFERENT clock.
--
-- ---------------------------------------------------------------------
-- Three clocks, which is the whole reason this is arithmetic
--
--   * **The basis period.** Form C is due seven months after the
--     close of the accounting period, so a company with a 30 June
--     year end files on 31 January. CP204 is due thirty days BEFORE
--     that period begins, which for the same company is 1 June of the
--     year before -- a date more than a year and a half away from the
--     Form C for the period it estimates.
--   * **The year of assessment.** Form B and Form P are due on
--     30 June in the year following, whatever the accounts do.
--   * **The calendar year of remuneration.** Form E and Form EA cover
--     1 January to 31 December, no matter what the company's own year
--     end is.
--
-- The third clock is worth being precise about, because it is easy to
-- overstate. Its DUE DATE lands on the same arithmetic as the second --
-- a fixed day in the year after the year the period ends in -- so for
-- a June year end the Form E date comes out right either way. What is
-- NOT the same is the PERIOD: Form E for a company with a June year
-- end covers a calendar year, and a row that showed
-- `1 Jul 2025 - 30 Jun 2026` beside it would be naming a period no
-- Form E has ever covered. Somebody reconciling the EA forms to the
-- payroll would then reconcile the wrong twelve months, find it did
-- not add up, and have nothing to tell them why.
--
-- So the period is a separate decision from the date, and both are
-- asserted in `supabase/tests/tax_filing_calendar.sql` against a
-- company with a June year end -- because a December year end makes
-- all three clocks agree and would let every one of these be wrong
-- without a test noticing.
--
-- ---------------------------------------------------------------------
-- The e-filing grace is not a deadline
--
-- LHDN publishes a Return Form Filing Programme each year which
-- grants extra time for a return filed through e-Filing -- commonly a
-- month for Form C, a fortnight for Form B and Form P. It is a
-- concession, it is republished annually, and it has been changed.
--
-- So it is a SEPARATE column from the statutory date, and the
-- statutory date is the due date. A screen that showed only the grace
-- date would be telling somebody their deadline is later than the Act
-- says it is, on the strength of a document that can be withdrawn --
-- and the day it is withdrawn, every date in the product is wrong in
-- the expensive direction. The grace is shown as what it is: extra
-- time somebody may have, beside the date they definitely have.
--
-- ---------------------------------------------------------------------
-- Nothing is stored
--
-- Same argument as `0063`: the obligations are computed from the
-- company's own periods every time they are asked for, so correcting
-- a rule corrects every company at once rather than every company
-- that opens a filing after today. `is_verified` FALSE on the seed,
-- like `0025`, `0664`, `0665` and `0667` before it.
--
-- What this does NOT do: it does not file anything, it does not pay
-- anything, and it does not know whether a particular company is
-- exempt. A dormant company still gets a Form C row, because a
-- dormant company still files one.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The obligations
-- ---------------------------------------------------------------------
create table public.tax_filing_types (
  code text primary key,
  name text not null,
  -- What somebody looks for on LHDN's site: 'C', 'B', 'E', 'CP204'.
  form_label text not null,
  statute_ref text,

  -- Which clock. Each of the four measures from a different thing and
  -- reads a different pair of the columns below.
  basis text not null check (basis in (
    'before_period_start',    -- days_before, from the period's start
    'after_period_end',       -- months_after, from the period's end
    'month_of_period',        -- period_month, the end of that month
    'month_day_after_ya',     -- due_month/due_day, year after the YA
    'month_day_after_year')), -- the same date arithmetic, over the
                              -- CALENDAR year rather than the basis
                              -- period. See the header: it is the
                              -- period that differs, not the date.

  days_before  integer check (days_before >= 0),
  months_after integer check (months_after > 0),
  period_month integer check (period_month between 1 and 12),
  due_month    integer check (due_month between 1 and 12),
  -- NULL means the last day of `due_month`, which is how "the last day
  -- of February" is written without a leap-year branch anywhere.
  due_day      integer check (due_day between 1 and 31),

  applies_to text[] not null,

  -- Form E, Form EA and CP58 are obligations of an EMPLOYER. A company
  -- with no payroll has none of them, and listing them anyway trains
  -- somebody to ignore the list.
  needs_employees boolean not null default false,

  -- The concession, held apart from the date. See the header.
  --
  -- In months AND in days, because the Programme grants them in
  -- different units and converting one to the other loses days: a
  -- month from 31 January is 28 February, and thirty days from it is
  -- 2 March. Two days on the wrong side of a deadline is the whole
  -- value of the column.
  efiling_grace_months integer check (efiling_grace_months >= 0),
  efiling_grace_days   integer check (efiling_grace_days >= 0),

  description text,
  sort_order integer not null default 100,
  is_verified boolean not null default false,
  source text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.tax_filing_types is
  'What LHDN requires and when, per entity type. Computed against a '
  'company''s own periods by tax_upcoming_filings -- nothing is stored '
  'per company, so a corrected rule corrects everybody. Seeded '
  'is_verified FALSE: check against the Act and the current Return '
  'Form Filing Programme before anybody files on it.';

comment on column public.tax_filing_types.efiling_grace_months is
  'Extra time LHDN''s annually published Filing Programme grants an '
  'e-filed return. A concession, not a statutory date, which is why it '
  'is not folded into the due date.';

alter table public.tax_filing_types enable row level security;

-- Platform reference, the same shape as tax_treatments and
-- capital_allowance_classes: every tenant reads the same rows, and
-- nobody writes them from the app.
create policy tax_filing_types_read on public.tax_filing_types
  for select to authenticated using (true);

grant select on public.tax_filing_types to authenticated;

insert into public.tax_filing_types
  (code, name, form_label, statute_ref, basis, days_before, months_after,
   period_month, due_month, due_day, applies_to, needs_employees,
   efiling_grace_months, efiling_grace_days, description, sort_order, source)
values
  ('cp204', 'Estimate of tax payable', 'CP204', 'ITA 1967 s.107C(2)',
   'before_period_start', 30, null, null, null, null,
   array['sdn_bhd', 'bhd', 'llp'], false, null, null,
   'Furnished not later than thirty days before the basis period '
   'begins — which is before the year it estimates has started, and is '
   'the single most missed date here. A company in its first basis '
   'period furnishes within three months of commencing operations '
   'instead, and a qualifying new SME is relieved of instalments for '
   'its first two years of assessment; neither is computed here.',
   10, 'ITA 1967 s.107C'),

  ('cp204a_6', 'Revision of the estimate, sixth month', 'CP204A',
   'ITA 1967 s.107C(7)', 'month_of_period', null, null, 6, null, null,
   array['sdn_bhd', 'bhd', 'llp'], false, null, null,
   'The first of the two months a revision is allowed in. This is the '
   'one that is worth money: by the ninth month most of the '
   'instalments have already been paid at the old figure.',
   20, 'ITA 1967 s.107C(7)'),

  ('cp204a_9', 'Revision of the estimate, ninth month', 'CP204A',
   'ITA 1967 s.107C(7)', 'month_of_period', null, null, 9, null, null,
   array['sdn_bhd', 'bhd', 'llp'], false, null, null,
   'The last chance to revise. After this the estimate stands and the '
   'shortfall is priced at assessment.',
   30, 'ITA 1967 s.107C(7)'),

  ('form_c', 'Return of a company', 'C', 'ITA 1967 s.77A(1)',
   'after_period_end', null, 7, null, null, null,
   array['sdn_bhd', 'bhd'], false, 1, null,
   'Seven months from the day following the close of the accounting '
   'period — so it moves with the year end rather than sitting on a '
   'fixed date. Filed with the tax computation, and a dormant company '
   'files one too.',
   40, 'ITA 1967 s.77A'),

  ('form_pt', 'Return of a limited liability partnership', 'PT',
   'ITA 1967 s.77A(1)', 'after_period_end', null, 7, null, null, null,
   array['llp'], false, 1, null,
   'An LLP is taxed as a company and files its own return on the same '
   'seven months — which is what separates it from a conventional '
   'partnership, whose Form P allocates and taxes nobody.',
   50, 'ITA 1967 s.77A'),

  ('form_b', 'Return of an individual carrying on a business', 'B',
   'ITA 1967 s.77(1)', 'month_day_after_ya', null, null, null, 6, 30,
   array['sole_proprietor', 'enterprise', 'individual'], false, null, 15,
   'Thirtieth of June in the year following the year of assessment. A '
   'person with no business income files Form BE by 30 April instead, '
   'which is two months earlier and is not this row.',
   60, 'ITA 1967 s.77'),

  ('form_p', 'Return of a partnership', 'P', 'ITA 1967 s.86',
   'month_day_after_ya', null, null, null, 6, 30,
   array['partnership'], false, null, 15,
   'The partnership allocates and pays nothing. Each partner then has '
   'their own Form B on the same date, carrying the share this return '
   'gave them — so a late Form P makes every partner late.',
   70, 'ITA 1967 s.86'),

  ('form_e', 'Employer''s return of remuneration', 'E',
   'ITA 1967 s.83(1)', 'month_day_after_year', null, null, null, 3, 31,
   array['sdn_bhd', 'bhd', 'llp', 'partnership', 'sole_proprietor',
         'enterprise', 'individual', 'association', 'government',
         'other'], true, 1, null,
   'Measured from the CALENDAR year the remuneration was paid in, not '
   'from the company''s own year end. Due whether or not any tax was '
   'deducted, and due from an employer with a single employee.',
   80, 'ITA 1967 s.83(1)'),

  ('form_ea', 'Statement of remuneration to each employee', 'EA',
   'ITA 1967 s.83(1A)', 'month_day_after_year', null, null, null, 2, null,
   array['sdn_bhd', 'bhd', 'llp', 'partnership', 'sole_proprietor',
         'enterprise', 'individual', 'association', 'government',
         'other'], true, null, null,
   'The last day of February. Not lodged with LHDN — it is given to '
   'the employee, who cannot file their own return without it, which '
   'is why it is here: nothing else in a company''s year reminds '
   'anybody of a deadline that produces no submission.',
   90, 'ITA 1967 s.83(1A)'),

  ('cp58', 'Statement of monetary and non-monetary incentives', 'CP58',
   'ITA 1967 s.83A', 'month_day_after_year', null, null, null, 3, 31,
   array['sdn_bhd', 'bhd', 'llp', 'partnership', 'sole_proprietor',
         'enterprise'], false, null, null,
   'Only where incentives above the threshold were paid to an agent, '
   'dealer or distributor in the calendar year — a condition this '
   'schema cannot test, so the row appears and says so rather than '
   'being silently dropped for a company that owes one.',
   100, 'ITA 1967 s.83A');


-- ---------------------------------------------------------------------
-- The date itself
-- ---------------------------------------------------------------------

-- A day in a month, where NULL means the last one -- so "the last day
-- of February" is a null rather than a leap-year branch, and a 31st
-- asked of a thirty-day month is the 30th rather than an error.
create or replace function app.tax_filing_fixed_date(
  p_year integer, p_month integer, p_day integer)
returns date
language sql immutable
set search_path = pg_catalog, public, pg_temp as $$
  -- Counted forward from the first of the month rather than handed to
  -- `make_date`, which raises on 31 February before anything has a
  -- chance to clamp it -- so the obvious spelling of this function
  -- fails on exactly the case it exists to handle.
  select case
    when p_month is null then null
    else least(
      (date_trunc('month', make_date(p_year, p_month, 1))
         + make_interval(days => greatest(coalesce(p_day, 31), 1) - 1))::date,
      (date_trunc('month', make_date(p_year, p_month, 1))
         + interval '1 month - 1 day')::date)
  end;
$$;

comment on function app.tax_filing_fixed_date(integer, integer, integer) is
  'A day in a month, clamped to the month''s length. NULL day means '
  'the last day, which is how the Form EA deadline is written.';


-- Pure, so it can be asserted directly rather than through a company.
-- Every clock in the header is one branch, and every branch is a line
-- of arithmetic rather than a stored date.
create or replace function app.tax_filing_due(
  p_basis text,
  p_days_before integer,
  p_months_after integer,
  p_period_month integer,
  p_due_month integer,
  p_due_day integer,
  p_period_start date,
  p_period_end date)
returns date
language sql immutable
set search_path = pg_catalog, public, pg_temp as $$
  select case p_basis
    -- Thirty days before the period opens.
    when 'before_period_start' then
      p_period_start - coalesce(p_days_before, 0)

    -- Seven months from the day FOLLOWING the close of the period,
    -- which is not seven months from the close. A period ending
    -- 30 June runs from 1 July, and seven months of it ends on
    -- 31 January -- a day later than adding seven months to the 30th
    -- gives, and a day that matters: 30 January is late.
    --
    -- The same one day is the difference between 30 September and
    -- 29 September for a February year end, and it is the reason this
    -- is written as "forward a day, forward the months, back a day"
    -- rather than the shorter thing that is wrong.
    when 'after_period_end' then
      ((p_period_end + 1)
         + make_interval(months => coalesce(p_months_after, 0))
         - interval '1 day')::date

    -- The end of the nth month of the basis period. Month one is the
    -- month the period starts in, so the sixth month of a period
    -- opening 1 January closes on 30 June.
    when 'month_of_period' then
      (date_trunc('month', p_period_start)
         + make_interval(months => coalesce(p_period_month, 1))
         - interval '1 day')::date

    -- A fixed date in the year after the year of assessment, which is
    -- taken from the period's end the same way `0665` takes it.
    --
    -- The calendar-year obligations share this line deliberately
    -- rather than by accident: Form E for the calendar year a period
    -- ends in falls due on the same day of the following year. What
    -- they do not share is the period, which
    -- `tax_upcoming_filings` decides separately.
    when 'month_day_after_ya' then
      app.tax_filing_fixed_date(
        extract(year from p_period_end)::integer + 1,
        p_due_month, p_due_day)
    when 'month_day_after_year' then
      app.tax_filing_fixed_date(
        extract(year from p_period_end)::integer + 1,
        p_due_month, p_due_day)
  end;
$$;

comment on function app.tax_filing_due(
  text, integer, integer, integer, integer, integer, date, date) is
  'The statutory due date for one obligation against one basis period. '
  'Pure, so supabase/tests/tax_filing_calendar.sql asserts it against '
  'a June year end, where the clocks disagree.';


-- ---------------------------------------------------------------------
-- What this company owes, and when
-- ---------------------------------------------------------------------
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
  estimate_id uuid)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
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
         -- date above is the same either way; this is not.
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
         te.id
    from public.fiscal_years fy
    join public.tax_filing_types t
      on coalesce(v_entity, 'other') = any (t.applies_to)
     and (not t.needs_employees or v_has_staff)
    cross join lateral (
      select app.tax_filing_due(
               t.basis, t.days_before, t.months_after, t.period_month,
               t.due_month, t.due_day, fy.start_date, fy.end_date) as due
    ) d
    left join public.tax_computations tc
      on tc.fiscal_year_id = fy.id and tc.org_id = fy.org_id
    -- The estimate still in force: a revision is a NEW row in `0667`
    -- that names the one it replaces, so the current one is whichever
    -- nothing has revised.
    left join public.tax_estimates te
      on te.fiscal_year_id = fy.id and te.org_id = fy.org_id
     and not exists (select 1 from public.tax_estimates r
                      where r.revises_id = te.id)
   where fy.org_id = p_org_id
     and d.due is not null
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
  'Every income tax obligation this company has against its own basis '
  'periods, computed rather than stored, with what is already late '
  'kept in the list. The e-filing date is shown beside the statutory '
  'one, never instead of it.';
