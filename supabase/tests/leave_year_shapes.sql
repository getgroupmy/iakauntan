-- =====================================================================
-- iAkauntan :: the leave year — entitlement, the roll, and what expires
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/leave_year_shapes.sql
--
-- `leave_requests.sql` covers filing and deciding a request, and
-- `leave_type_rules.sql` covers the rules on the type. A sweep of 77
-- one-line mutants over the seven functions behind the leave year
-- killed 46. What lived was almost the whole of two of them.
--
-- `app.roll_leave_year` IS THE ANNUAL JOB THAT DECIDES WHAT EVERY
-- EMPLOYEE HAS. Nine mutants lived on it, because nothing had ever
-- called it with a previous year worth carrying: a resigned employee
-- got next year's entitlement, a retired leave type got a fresh row,
-- and the carry-forward figure could drop any of its four terms —
-- entitlement, last year's own carry, an adjustment, and what was taken
-- — with the suite still green. Leave liability is money, and a carry
-- that quietly counts leave already taken is money the company does not
-- know it owes.
--
-- `app.leave_entitlement` READS THE ACT'S BANDS, and five lived: a type
-- that does not scale looking its days up in the bands anyway, an
-- employee hired after the year being asked about getting negative
-- service, the LOWEST matching band winning instead of the highest, and
-- one leave type reading another's bands.
--
-- The bands themselves come from `apply_statutory_leave_bands`, which
-- writes the First Schedule to the Employment Act 1955: eight days
-- under two years' service, twelve from two, sixteen from five, and
-- fourteen, eighteen and twenty-two for sick leave. The DAYS were
-- asserted. The YEARS the bands run between were not, and they are half
-- the rule.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ly_type(
  p_org uuid, p_code text, p_name text,
  p_default numeric default 0, p_scales boolean default false,
  p_carry numeric default 0, p_expiry integer default null,
  p_active boolean default true)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.leave_types
    (org_id, code, name, is_paid, default_days, scales_with_service,
     max_carry_forward, carry_forward_expiry_months, is_active)
  values (p_org, p_code, p_name, true, p_default, p_scales,
          p_carry, p_expiry, p_active)
  returning id into v;
  return v;
end $$;

create or replace function pg_temp.ly_emp(
  p_org uuid, p_no text, p_name text, p_hired date,
  p_status text default 'active', p_user uuid default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status, user_id,
     -- Somebody who has left needs a last working day: the payroll run
     -- goes by the date, not by the status. See
     -- `app.employee_departure_guard`.
     resignation_date, last_working_date)
  values (p_org, p_no, p_name, p_hired, 3000, date '1990-01-01',
          'citizen', p_status::app.employment_status, p_user,
          case when p_status in ('resigned', 'terminated')
               then p_hired + 30 end,
          case when p_status in ('resigned', 'terminated')
               then p_hired + 60 end)
  returning id into v;
  return v;
end $$;

create or replace function pg_temp.ly_entitlement(
  p_type uuid, p_hired date, p_year integer)
returns numeric language sql stable as $$
  select app.leave_entitlement(t, p_hired, p_year)
    from public.leave_types t where t.id = p_type;
$$;

-- =====================================================================
-- 1. The First Schedule, and the years its bands run between
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Cuti Tahunan Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_clerk uuid;
  v_annual uuid; v_sick uuid; v_other uuid;
begin
  v_annual := pg_temp.ly_type(v_org, 'AL', 'Annual leave', 0, false);
  v_sick   := pg_temp.ly_type(v_org, 'MC', 'Sick leave', 0, false);
  v_other  := pg_temp.ly_type(v_org, 'CL', 'Compassionate leave', 3, false);

  perform pg_temp.check_refused('a leave type that is not there says so',
    format('select public.apply_statutory_leave_bands(%L, %L)',
           gen_random_uuid(), 'annual'),
    '%Leave type not found%');

  perform pg_temp.check_refused('and an unknown preset says which are known',
    format('select public.apply_statutory_leave_bands(%L, %L)',
           v_annual, 'maternity'),
    '%expected annual or sick%');

  -- Setting statutory entitlement is HR's job. A member with a real
  -- role and real access is still not HR.
  v_clerk := pg_temp.another_user('kerani@cuti.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'accounts_clerk', 'active')
  on conflict (org_id, user_id) do update
    set role = 'accounts_clerk', status = 'active';
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused(
    'setting what everybody is entitled to is not a bookkeeping decision',
    format('select public.apply_statutory_leave_bands(%L, %L)',
           v_annual, 'annual'),
    '%Only HR may set leave entitlement bands%');
  perform pg_temp.sign_in_as(v_owner);

  perform pg_temp.check_eq('three bands are written',
    public.apply_statutory_leave_bands(v_annual, 'annual'), 3);
  perform pg_temp.check_eq('and three for sick leave',
    public.apply_statutory_leave_bands(v_sick, 'sick'), 3);

  -- THE YEARS, which nothing asserted. s.60E(1) reads "less than two
  -- years", "two years or more but less than five", and "five years or
  -- more" — so the first band covers a first and a second calendar year
  -- of service and stops, and the top one has no ceiling at all. A
  -- ceiling on the top band is an employee of twenty years' service
  -- falling off the end of the schedule.
  perform pg_temp.check_eq('the first band runs to one year of service',
    (select b.service_years_to from public.leave_entitlement_bands b
      where b.leave_type_id = v_annual and b.service_years_from = 0), 1);
  perform pg_temp.check_eq('the middle band from two to four',
    (select b.service_years_to from public.leave_entitlement_bands b
      where b.leave_type_id = v_annual and b.service_years_from = 2), 4);
  perform pg_temp.check_true('and the top band has no ceiling',
    (select b.service_years_to is null from public.leave_entitlement_bands b
      where b.leave_type_id = v_annual and b.service_years_from = 5));

  -- The days, both presets, so the two `case` arms are separated.
  perform pg_temp.check_eq('eight days under two years',
    (select b.days from public.leave_entitlement_bands b
      where b.leave_type_id = v_annual and b.service_years_from = 0), 8);
  perform pg_temp.check_eq('twelve from two', (select b.days
    from public.leave_entitlement_bands b
     where b.leave_type_id = v_annual and b.service_years_from = 2), 12);
  perform pg_temp.check_eq('sixteen from five', (select b.days
    from public.leave_entitlement_bands b
     where b.leave_type_id = v_annual and b.service_years_from = 5), 16);
  perform pg_temp.check_eq('fourteen days of sick leave under two years',
    (select b.days from public.leave_entitlement_bands b
      where b.leave_type_id = v_sick and b.service_years_from = 0), 14);
  perform pg_temp.check_eq('eighteen from two', (select b.days
    from public.leave_entitlement_bands b
     where b.leave_type_id = v_sick and b.service_years_from = 2), 18);
  perform pg_temp.check_eq('twenty-two from five', (select b.days
    from public.leave_entitlement_bands b
     where b.leave_type_id = v_sick and b.service_years_from = 5), 22);

  -- Applying the schedule turns scaling ON for that type -- the bands
  -- are only consulted when it does -- and for THAT TYPE ONLY.
  perform pg_temp.check_true('the type now scales with service',
    (select t.scales_with_service from public.leave_types t
      where t.id = v_annual));
  perform pg_temp.check_true(
    'and compassionate leave, which nobody asked about, still does not',
    (select not t.scales_with_service from public.leave_types t
      where t.id = v_other));

  -- Applying it twice leaves three bands, not six.
  perform pg_temp.check_eq('applying it again replaces rather than adds',
    public.apply_statutory_leave_bands(v_annual, 'annual'), 3);
  perform pg_temp.check_eq('so there are still three',
    (select count(*) from public.leave_entitlement_bands
      where leave_type_id = v_annual), 3);
end $$;

-- =====================================================================
-- 2. Reading the bands
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Baca Band Sdn Bhd');
  v_scaling uuid; v_fixed uuid; v_bandless uuid; v_second uuid;
begin
  v_scaling  := pg_temp.ly_type(v_org, 'AL', 'Annual', 99, false);
  perform public.apply_statutory_leave_bands(v_scaling, 'annual');

  -- A type with bands on it that does NOT scale. Somebody applied the
  -- schedule and then switched scaling off, which is the switch's whole
  -- purpose: this company gives everybody the same eighteen days.
  v_fixed := pg_temp.ly_type(v_org, 'AL2', 'Flat annual', 18, false);
  perform public.apply_statutory_leave_bands(v_fixed, 'annual');
  update public.leave_types set scales_with_service = false
   where id = v_fixed;

  perform pg_temp.check_eq(
    'a type that does not scale gives its own days, whatever bands are '
    'sitting on it',
    pg_temp.ly_entitlement(v_fixed, date '2015-01-01', 2026), 18);
  perform pg_temp.check_eq('while the one that scales reads the schedule',
    pg_temp.ly_entitlement(v_scaling, date '2015-01-01', 2026), 16);

  -- Each band, at both of its ends.
  perform pg_temp.check_eq('no service at all is the first band',
    pg_temp.ly_entitlement(v_scaling, date '2026-01-01', 2026), 8);
  perform pg_temp.check_eq('and one year still is',
    pg_temp.ly_entitlement(v_scaling, date '2025-01-01', 2026), 8);
  perform pg_temp.check_eq('two years is the second',
    pg_temp.ly_entitlement(v_scaling, date '2024-01-01', 2026), 12);
  perform pg_temp.check_eq('four years still is',
    pg_temp.ly_entitlement(v_scaling, date '2022-01-01', 2026), 12);
  perform pg_temp.check_eq('five years is the third',
    pg_temp.ly_entitlement(v_scaling, date '2021-01-01', 2026), 16);
  perform pg_temp.check_eq('and thirty years is still the third -- the '
    'top band has no ceiling to fall off',
    pg_temp.ly_entitlement(v_scaling, date '1996-01-01', 2026), 16);

  -- SOMEBODY HIRED AFTER THE YEAR BEING ASKED ABOUT. A balance drawn up
  -- for last year, or a hire date typed a year out, gives negative
  -- service, and negative service matches no band at all -- so without
  -- the floor the answer is the default rather than the first band.
  perform pg_temp.check_eq(
    'service before the hire date is no service, not negative service',
    pg_temp.ly_entitlement(v_scaling, date '2027-06-01', 2026), 8);

  -- A scaling type with NO bands falls back to its own days rather than
  -- to nothing. A null entitlement is a balance row that says the
  -- employee is owed nothing at all.
  v_bandless := pg_temp.ly_type(v_org, 'AL3', 'Scaling, unbanded', 11, true);
  perform pg_temp.check_eq('a scaling type with no bands gives its own days',
    pg_temp.ly_entitlement(v_bandless, date '2015-01-01', 2026), 11);

  -- One type does not read another's bands. Both scale, both have
  -- bands, and the numbers are different.
  v_second := pg_temp.ly_type(v_org, 'MC', 'Sick', 0, false);
  perform public.apply_statutory_leave_bands(v_second, 'sick');
  perform pg_temp.check_eq('annual leave reads the annual bands',
    pg_temp.ly_entitlement(v_scaling, date '2015-01-01', 2026), 16);
  perform pg_temp.check_eq('and sick leave the sick ones',
    pg_temp.ly_entitlement(v_second, date '2015-01-01', 2026), 22);

  -- WHICH BAND WINS WHEN TWO MATCH. The Act's own schedule does not
  -- overlap, so nothing separated "the highest band that starts at or
  -- below this service" from "the lowest". A company that adds a band
  -- of its own does overlap, and the one that starts latest is the one
  -- that means this employee.
  insert into public.leave_entitlement_bands
    (leave_type_id, service_years_from, service_years_to, days)
  values (v_scaling, 0, null, 5);
  perform pg_temp.check_eq(
    'the band that starts latest wins, not the one that starts first',
    pg_temp.ly_entitlement(v_scaling, date '2015-01-01', 2026), 16);
end $$;

-- =====================================================================
-- 3. Rolling the year over
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Guling Tahun Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_other_org uuid;
  v_live uuid; v_retired uuid; v_scaling uuid;
  v_stay uuid; v_gone uuid; v_theirs uuid;
  v_n integer; v_year integer := 2026;
begin
  perform pg_temp.allow_many_companies();

  -- A cap wide enough that the four terms of the carry are separable.
  -- With a cap of five, 10 + 3 + 2 - 4 and 10 + 3 - 4 both come out at
  -- five and the arithmetic is invisible.
  v_live    := pg_temp.ly_type(v_org, 'AL', 'Annual', 14, false, 20);
  v_retired := pg_temp.ly_type(v_org, 'OLD', 'Retired type', 14, false, 20,
                               null, false);
  v_scaling := pg_temp.ly_type(v_org, 'SC', 'Scaling annual', 0, false, 0);
  perform public.apply_statutory_leave_bands(v_scaling, 'annual');

  v_stay := pg_temp.ly_emp(v_org, 'E1', 'Puan Siti', date '2021-01-01');
  v_gone := pg_temp.ly_emp(v_org, 'E2', 'Encik Zul', date '2021-01-01',
                           'resigned');

  -- The company next door, standing up BEFORE the roll runs rather
  -- than after it. Built afterwards it proves nothing: a roll that
  -- swept every employee on the platform would still not have found
  -- somebody who did not exist yet.
  v_other_org := pg_temp.test_org('Syarikat Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  v_theirs := pg_temp.ly_emp(v_other_org, 'T1', 'Their staff',
                             date '2021-01-01');

  -- Last year, with all four terms different and none of them zero.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year,
     entitled_days, carried_forward, adjustment_days, taken_days)
  values (v_org, v_stay, v_live, v_year - 1, 10, 3, 2, 4);

  v_n := app.roll_leave_year(v_org, v_year);

  -- WHO GETS A ROW.
  perform pg_temp.check_eq(
    'somebody who has left is not given next year''s leave',
    (select count(*) from public.leave_balances b
      where b.employee_id = v_gone and b.leave_year = v_year), 0);
  perform pg_temp.check_eq('and a retired leave type gets no new year',
    (select count(*) from public.leave_balances b
      where b.leave_type_id = v_retired and b.leave_year = v_year), 0);
  perform pg_temp.check_eq('while the employee still here gets one per type',
    (select count(*) from public.leave_balances b
      where b.employee_id = v_stay and b.leave_year = v_year), 2);

  -- WHAT CARRIES. Ten entitled, three brought in, two adjusted on, four
  -- taken: eleven left, and the cap is twenty, so eleven carries.
  -- Dropping any one of the four terms gives eight, nine or fifteen.
  perform pg_temp.check_eq(
    'the carry is everything that was there less everything taken',
    (select b.carried_forward from public.leave_balances b
      where b.employee_id = v_stay and b.leave_type_id = v_live
        and b.leave_year = v_year), 11);

  -- And THIS year's entitlement, not last year's. Hired January 2021,
  -- so 2026 is five years of service and 2025 is four: sixteen days
  -- against twelve, which is the band boundary the Act puts there.
  perform pg_temp.check_eq(
    'the entitlement is the year being opened, not the year closing',
    (select b.entitled_days from public.leave_balances b
      where b.employee_id = v_stay and b.leave_type_id = v_scaling
        and b.leave_year = v_year), 16);

  -- RUNNING IT TWICE. The annual job gets run again — by a scheduler
  -- that fired twice, or by somebody making sure. It must not restate
  -- an entitlement HR has since adjusted by hand.
  update public.leave_balances set entitled_days = 25
   where employee_id = v_stay and leave_type_id = v_live
     and leave_year = v_year;
  perform pg_temp.check_eq('a second run opens no further rows',
    app.roll_leave_year(v_org, v_year), 0);
  perform pg_temp.check_eq(
    'and leaves an entitlement somebody has since changed alone',
    (select b.entitled_days from public.leave_balances b
      where b.employee_id = v_stay and b.leave_type_id = v_live
        and b.leave_year = v_year), 25);

  -- AND ONLY THIS COMPANY'S PEOPLE.
  perform pg_temp.check_eq(
    'the roll opens no balance for the company next door''s employee',
    (select count(*) from public.leave_balances b
      where b.employee_id = v_theirs), 0);

  -- THE RULE THE CARRY'S `coalesce(max_carry_forward, 0)` LEANS ON.
  -- The column is NOT NULL with a default of nought, so the coalesce
  -- can never fire and swapping its fallback changes nothing. What
  -- matters is the default itself: a leave type nobody has thought
  -- about carries NOTHING forward, because silently rolling everything
  -- over is how leave liability grows unnoticed.
  perform pg_temp.check_eq('a carry limit is always a number',
    (select is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = 'leave_types'
        and column_name = 'max_carry_forward'), 'NO');
  perform pg_temp.check_eq('and a type nobody has set one on carries none',
    (select t.max_carry_forward from public.leave_types t
      where t.id = v_scaling), 0);
end $$;

-- =====================================================================
-- 4. What expires, and whose
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Luput Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_them uuid;
  v_type uuid; v_retired uuid; v_emp uuid; v_their_emp uuid;
  v_year integer := extract(year from current_date)::integer;
  v_on date := make_date(extract(year from current_date)::integer, 1, 1)
               + interval '4 months';
  v_n integer;
begin
  perform pg_temp.allow_many_companies();

  -- Carry expires three months into the year. The sweep is run in the
  -- fourth month, which is after that.
  v_type    := pg_temp.ly_type(v_org, 'AL', 'Annual', 14, false, 20, 3);
  v_retired := pg_temp.ly_type(v_org, 'OLD', 'Retired', 14, false, 20, 3,
                               false);
  v_emp := pg_temp.ly_emp(v_org, 'E1', 'Puan Siti', date '2020-01-01');

  -- Six carried in and two of them used: four expire.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year,
     entitled_days, carried_forward, taken_days)
  values (v_org, v_emp, v_type, v_year, 14, 6, 2);
  -- The same figures on the retired type, and on a year already gone.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year,
     entitled_days, carried_forward, taken_days)
  values (v_org, v_emp, v_retired, v_year, 14, 6, 2),
         (v_org, v_emp, v_type, v_year - 1, 14, 6, 2);

  -- And the company next door, with the identical position.
  v_them := pg_temp.test_org('Jiran Luput Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  v_their_emp := pg_temp.ly_emp(v_them, 'T1', 'Their staff',
                                date '2020-01-01');
  insert into public.leave_types
    (org_id, code, name, is_paid, default_days, max_carry_forward,
     carry_forward_expiry_months)
  values (v_them, 'AL', 'Annual', true, 14, 20, 3);
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year,
     entitled_days, carried_forward, taken_days)
  select v_them, v_their_emp, t.id, v_year, 14, 6, 2
    from public.leave_types t where t.org_id = v_them;

  v_n := app.expire_carried_leave(v_org, v_on::date);

  perform pg_temp.check_eq(
    'what was carried in and never used expires: six brought in, two '
    'used, and two is what is left',
    (select b.carried_forward from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year), 2);

  perform pg_temp.check_eq('a retired leave type is not swept',
    (select b.carried_forward from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_retired
        and b.leave_year = v_year), 6);

  perform pg_temp.check_eq(
    'nor a year already closed -- what is done with a closed year is a '
    'correction somebody makes on purpose, not a sweep',
    (select b.carried_forward from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year - 1), 6);

  perform pg_temp.check_eq('and not one sen of the company next door',
    (select b.carried_forward from public.leave_balances b
      where b.employee_id = v_their_emp), 6);

  perform pg_temp.check_eq('one balance was swept, and only one', v_n, 1);

  -- THE RULE `least(taken, carried)` LEANS ON, which is why swapping it
  -- for `taken` alone changes no answer: a row is only selected when
  -- what was carried EXCEEDS what has been taken, and on those rows the
  -- two expressions are the same number. Here is a row on the other
  -- side of that line -- more taken than was carried -- and it is left
  -- alone rather than having its carry raised to what was taken.
  update public.leave_balances set carried_forward = 3, taken_days = 9
   where employee_id = v_emp and leave_type_id = v_type
     and leave_year = v_year;
  perform pg_temp.check_eq('a balance with more taken than carried is '
    'not swept at all', app.expire_carried_leave(v_org, v_on::date), 0);
  perform pg_temp.check_eq('and its carry is untouched',
    (select b.carried_forward from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year), 3);
end $$;

-- =====================================================================
-- 5. Filing and deciding, on the year the leave is in
-- =====================================================================
do $$
declare
  v_org uuid := pg_temp.test_org('Mohon Cuti Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_type uuid; v_emp uuid; v_req uuid; v_fresh uuid;
  v_year integer := extract(year from current_date)::integer;
  v_next date := make_date(extract(year from current_date)::integer + 1, 3, 2);
begin
  v_type  := pg_temp.ly_type(v_org, 'AL', 'Annual', 14, false, 20);
  -- A paid leave type nobody has drawn a balance for.
  v_fresh := pg_temp.ly_type(v_org, 'CL', 'Compassionate', 3, false, 0);
  v_emp   := pg_temp.ly_emp(v_org, 'E1', 'Puan Siti', date '2020-01-01',
                            'active', v_owner);

  -- Ten entitled, three brought in, two adjusted on, four taken:
  -- eleven days available. Every term is a different number, so
  -- dropping any one of them changes the answer.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year,
     entitled_days, carried_forward, adjustment_days, taken_days)
  values (v_org, v_emp, v_type, v_year, 10, 3, 2, 4);

  perform pg_temp.check_refused(
    'a request for more than is left is refused, and says how much is '
    'left',
    format('select public.submit_leave_request(%L, %L, %L, %L, 12)',
           v_org, v_type, make_date(v_year, 6, 1), make_date(v_year, 6, 12)),
    '%Only 11.00 day(s)%');

  -- And exactly what is left is allowed. Without this the assertion
  -- above is also satisfied by a function that refuses everything.
  v_req := public.submit_leave_request(
    v_org, v_type, make_date(v_year, 6, 1), make_date(v_year, 6, 11), 11);
  perform pg_temp.check_eq('while a request for exactly what is left goes in',
    (select r.total_days from public.leave_requests r where r.id = v_req), 11);
  perform pg_temp.check_eq('held against the balance while it waits',
    (select b.pending_days from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year), 11);

  -- THE HOLD CANNOT GO NEGATIVE. A balance corrected by hand between
  -- the filing and the decision leaves less on hold than the request
  -- claimed, and a negative hold reads as extra leave the employee
  -- does not have.
  update public.leave_balances set pending_days = 2
   where employee_id = v_emp and leave_year = v_year;
  perform public.decide_leave_request(v_req, false);
  perform pg_temp.check_eq('a hold that is short comes off at nought, '
    'not below it',
    (select b.pending_days from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year), 0);
  perform pg_temp.check_eq('and a refusal spends nothing',
    (select b.taken_days from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year), 4);

  perform pg_temp.check_refused('a request that is not there says so',
    format('select public.decide_leave_request(%L, true)', gen_random_uuid()),
    '%Leave request not found%');

  -- THE RULE THE `is not null` LEANS ON, and the reason dropping it
  -- changes no answer: `12 > null` is NULL, and plpgsql treats a null
  -- condition as false, so the comparison alone already lets the
  -- request through. What is worth asserting is the BEHAVIOUR that
  -- depends on it -- a company that has not set an entitlement for a
  -- leave type and a year can still use the module on the day it
  -- starts, rather than having every request refused until somebody
  -- fills in a table.
  perform pg_temp.check_eq('nobody has set an entitlement for this type',
    (select count(*) from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_fresh), 0);
  perform pg_temp.check_true('and leave can still be filed against it',
    public.submit_leave_request(
      v_org, v_fresh, make_date(v_year, 8, 1), make_date(v_year, 8, 3), 3)
    is not null);

  -- ------------------------------------------------------------------
  -- Leave taken next year
  -- ------------------------------------------------------------------
  -- The balance a request touches is the one for the year the LEAVE is
  -- in, not the year it was filed in. Booking next March in December is
  -- the ordinary case, and it must not come out of this year.
  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days)
  values (v_org, v_emp, v_type, v_year + 1, 16);

  v_req := public.submit_leave_request(
    v_org, v_type, v_next, v_next + 4, 5);
  perform pg_temp.check_eq('the hold lands on next year''s balance',
    (select b.pending_days from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year + 1), 5);
  perform pg_temp.check_eq('and this year''s is untouched',
    (select b.pending_days from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year), 0);

  perform public.decide_leave_request(v_req, true);
  perform pg_temp.check_eq('approving it spends next year''s days',
    (select b.taken_days from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year + 1), 5);
  perform pg_temp.check_eq('and leaves this year''s alone',
    (select b.taken_days from public.leave_balances b
      where b.employee_id = v_emp and b.leave_type_id = v_type
        and b.leave_year = v_year), 4);
end $$;

rollback;
