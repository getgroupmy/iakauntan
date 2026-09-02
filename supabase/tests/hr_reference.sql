-- =====================================================================
-- iAkauntan :: HR reference data tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/hr_reference.sql
--
-- Public holidays, leave entitlement bands and the statutory rate
-- tables: all read every month by leave, attendance and payroll, none
-- of them reachable from the app until 0091.
--
-- Two things here are statutory and so are asserted rather than
-- eyeballed: the Employment Act 1955 leave minimums (s.60E(1) annual,
-- s.60F(1) sick), and the fact that an ordinary organization owner
-- cannot publish or verify a statutory rate table. The second matters
-- more than it looks — `statutory_schedules` has no `org_id`, so a
-- write by one company is a write to every company's payroll.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- The four holidays that can be filled in without asking anyone
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Holiday Sdn Bhd');
  v_n integer;
begin
  v_n := public.add_fixed_public_holidays(v_org, 2026);
  perform pg_temp.check_eq('four fixed holidays added', v_n, 4);
  perform pg_temp.check_true('Malaysia Day is 16 September',
    (select true from public.public_holidays
      where org_id = v_org and holiday_date = date '2026-09-16'
        and name = 'Malaysia Day'));
  perform pg_temp.check_true('and none of them is a working day',
    (select bool_and(not is_working) from public.public_holidays
      where org_id = v_org));

  -- Idempotent. Somebody will press the button twice, and the unique
  -- constraint treats two NULL state codes as distinct, so nothing but
  -- this check stops a duplicate.
  v_n := public.add_fixed_public_holidays(v_org, 2026);
  perform pg_temp.check_eq('a second run adds nothing', v_n, 0);
  perform pg_temp.check_eq('and the calendar is unchanged',
    (select count(*) from public.public_holidays where org_id = v_org), 4);

  v_n := public.add_fixed_public_holidays(v_org, 2027);
  perform pg_temp.check_eq('the next year is its own four', v_n, 4);

  begin
    perform public.add_fixed_public_holidays(v_org, 1899);
    raise exception 'FAIL: accepted a year outside the range';
  exception when sqlstate '22023' then
    raise notice 'ok   a year outside the range is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Employment Act 1955 leave minimums
--
-- s.60E(1): 8 days under two years of service, 12 from two, 16 from
-- five. s.60F(1) sick leave: 14, 18, 22 on the same bands.
--
-- These would fail if somebody moved a band boundary by one year, which
-- is the whole point of asserting them.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Leave Bands Sdn Bhd');
  v_type uuid;
  v_n integer;
begin
  insert into public.leave_types
    (org_id, code, name, default_days, scales_with_service)
  values (v_org, 'AL', 'Annual leave', 8, false)
  returning id into v_type;

  v_n := public.apply_statutory_leave_bands(v_type, 'annual');
  perform pg_temp.check_eq('three annual bands', v_n, 3);

  -- The bands are only consulted when the type says it scales, so
  -- writing them without turning that on would change nothing at all.
  perform pg_temp.check_true('and the leave type now scales with service',
    (select scales_with_service from public.leave_types where id = v_type));

  perform pg_temp.check_eq('hired this year: 8 days',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2026-03-01', 2026), 8);
  perform pg_temp.check_eq('one year in: still 8',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2025-03-01', 2026), 8);
  perform pg_temp.check_eq('two years in: 12',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2024-03-01', 2026), 12);
  perform pg_temp.check_eq('four years in: still 12',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2022-03-01', 2026), 12);
  perform pg_temp.check_eq('five years in: 16',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2021-03-01', 2026), 16);
  perform pg_temp.check_eq('and it does not keep climbing',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2010-03-01', 2026), 16);

  -- ------------------------------------------------------------------
  -- Which day of the year somebody was hired on
  --
  -- Every assertion above hires on 1 March. That is one position in the
  -- year, and a function whose answer depends on where in the year you
  -- stand cannot be tested from one position -- which is the lesson
  -- 0446 paid for in the payroll engine, where a bonus was annualised
  -- and every fixture paid in a single month.
  --
  -- `app.leave_entitlement` measures service as `p_year - year(hire)`.
  -- That counts **New Year's Eves crossed**, not months served, so the
  -- day of the year matters and these two employees are treated alike
  -- while their service differs by almost a year:
  --
  --   * hired 1 January 2024 -- 24 months of service on 1 January 2026;
  --   * hired 31 December 2024 -- 12 months and a day on the same date.
  --
  -- Both are given 12 days for 2026. Under s.60E(1) the twelve-day band
  -- is for somebody "employed for a period of two years or more", and
  -- the second employee is not, at the start of that leave year. They
  -- are by the end of it, which is the reading under which the present
  -- answer is right.
  --
  -- **This file does not decide which reading is correct**, because the
  -- Act measures entitlement against twelve months of continuous
  -- service rather than a calendar year, and choosing between the
  -- start-of-year and end-of-year conventions is a decision about
  -- somebody's leave, not an arithmetic slip to be quietly corrected.
  -- What it does is pin the convention in force so it cannot drift
  -- without a person seeing it, and name the question in the place
  -- somebody looking at leave will find it. docs/unreachable.md carries
  -- the measurement.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'hired on the last day of a year counts that year as served',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2024-12-31', 2026), 12);

  perform pg_temp.check_eq(
    'and the first day of the same year gives the same answer',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2024-01-01', 2026), 12);

  -- The boundary the difference actually reaches: one of these has
  -- served five years and a day at the start of 2030 and the other four
  -- years and a day, and both are given sixteen.
  perform pg_temp.check_eq('five New Years crossed reads as five years',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2025-12-31', 2030), 16);
  perform pg_temp.check_eq('however early in that year the hire was',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2025-01-01', 2030), 16);

  -- Applying the other preset replaces the bands rather than adding to
  -- them: a table with one row from the Act and two from somewhere else
  -- is worse than either.
  perform public.apply_statutory_leave_bands(v_type, 'sick');
  perform pg_temp.check_eq('three bands, not six',
    (select count(*) from public.leave_entitlement_bands
      where leave_type_id = v_type), 3);
  perform pg_temp.check_eq('sick leave, first year: 14',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2026-03-01', 2026), 14);
  perform pg_temp.check_eq('sick leave, two years: 18',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2024-03-01', 2026), 18);
  perform pg_temp.check_eq('sick leave, five years: 22',
    app.leave_entitlement(
      (select lt from public.leave_types lt where lt.id = v_type),
      date '2021-03-01', 2026), 22);

  begin
    perform public.apply_statutory_leave_bands(v_type, 'maternity');
    raise exception 'FAIL: accepted a preset that does not exist';
  exception when sqlstate '22023' then
    raise notice 'ok   an unknown preset is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Statutory rates belong to the platform, not to a tenant
--
-- `statutory_schedules` and `statutory_rates` have no `org_id`. Their
-- RLS is `select true` with no write policy, so nothing an ordinary
-- user does can reach them — and the two functions that can must check
-- who is calling, because an EPF rate edited by one company is every
-- company's payroll.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Not The Platform Sdn Bhd');
  v_sched uuid;
begin
  select id into v_sched from public.statutory_schedules
   where body = 'epf' order by effective_from desc limit 1;

  begin
    perform public.platform_publish_statutory_schedule(
      'epf', 'Rates I made up', 'percentage', date '2027-01-01',
      jsonb_build_array(jsonb_build_object(
        'employee_rate', 0, 'employer_rate', 0)));
    raise exception 'FAIL: an organization owner published a statutory schedule';
  exception when sqlstate '42501' then
    raise notice 'ok   publishing needs a platform administrator';
  end;

  begin
    perform public.platform_set_schedule_verified(v_sched, true);
    raise exception 'FAIL: an organization owner verified a schedule';
  exception when sqlstate '42501' then
    raise notice 'ok   verifying needs a platform administrator';
  end;

  -- Reading them is fine and has to be: the payroll engine and the
  -- screen that shows which figures are in force both depend on it.
  perform pg_temp.check_true('but anybody may read them',
    (select count(*) > 0 from public.statutory_schedules));
end $$;

-- ---------------------------------------------------------------------
-- Publishing, as the platform
-- ---------------------------------------------------------------------
do $$
declare
  v_user uuid := pg_temp.test_user();
  v_new uuid; v_old uuid;
begin
  insert into public.platform_admins (user_id) values (v_user)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_user);

  select id into v_old from public.statutory_schedules
   where body = 'eis' and effective_to is null
   order by effective_from desc limit 1;

  v_new := public.platform_publish_statutory_schedule(
    'eis', 'EIS rates from 2027', 'percentage', date '2027-01-01',
    jsonb_build_array(jsonb_build_object(
      'employee_rate', 0.2, 'employer_rate', 0.2, 'wage_ceiling', 6000)),
    'PERKESO', 'Typed from the gazette', null, 'nearest_cent', true);

  perform pg_temp.check_true('the new schedule is marked verified',
    (select is_verified from public.statutory_schedules where id = v_new));
  perform pg_temp.check_eq('and carries its band',
    (select count(*) from public.statutory_rates where schedule_id = v_new), 1);

  -- Publishing closes what it supersedes. Without this the table says
  -- two rate sets are in force at once; the calculation would still
  -- pick the right one, and anybody reading the table would not.
  perform pg_temp.check_true('the schedule it supersedes is closed',
    (select effective_to = date '2026-12-31'
       from public.statutory_schedules where id = v_old));
  perform pg_temp.check_true('the new one answers for its own period',
    (app.statutory_schedule_on('eis', date '2027-06-01')).id = v_new);
  perform pg_temp.check_true('and the old one still answers for its',
    (app.statutory_schedule_on('eis', date '2026-06-01')).id = v_old);

  begin
    perform public.platform_publish_statutory_schedule(
      'eis', 'Nothing in it', 'percentage', date '2028-01-01', '[]'::jsonb);
    raise exception 'FAIL: published a schedule with no rates';
  exception when sqlstate '23514' then
    raise notice 'ok   a schedule with no rates is refused';
  end;

  -- The rounding mode is a check constraint on the table. Catching it
  -- in the function turns 23514 from the constraint into a message that
  -- names the argument.
  begin
    perform public.platform_publish_statutory_schedule(
      'eis', 'Bad rounding', 'percentage', date '2028-01-01',
      jsonb_build_array(jsonb_build_object('employee_rate', 1)),
      null, null, null, 'nearest_ringgit');
    raise exception 'FAIL: accepted a rounding mode the table forbids';
  exception when sqlstate '22023' then
    raise notice 'ok   an unknown rounding mode is refused by name';
  end;
end $$;

-- ---------------------------------------------------------------------
-- How many days' leave a person gets (0443)
--
-- `leave_types` and `leave_entitlement_bands` decide the annual and
-- sick leave entitlement of every employee of a company, are edited
-- from the app by anybody who passes `app.can_manage_hr`, and were
-- audited by nothing. Measured before 0443: inserting a band wrote 0
-- rows to `audit_logs`, and editing it from 8 days to 99 wrote 0 more.
--
-- The band has no `org_id` -- it names its tenant through
-- `leave_type_id` -- and since 0442 a null `org_id` means the
-- platform's own trail, which every platform administrator reads. So
-- the second assertion here is about where the row is filed, not just
-- that it exists.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Cuti Tahunan Sdn Bhd');
  v_lt   uuid;
  v_band uuid;
  v_n    integer;
  v_seen uuid;
  v_to   jsonb;
begin
  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'AL', 'Annual leave', true) returning id into v_lt;

  select count(*) into v_n from public.audit_logs
   where org_id = v_org and table_name = 'leave_types';
  perform pg_temp.check_eq('creating a leave type is recorded', v_n, 1);

  insert into public.leave_entitlement_bands
    (leave_type_id, service_years_from, service_years_to, days)
  values (v_lt, 0, 2, 8) returning id into v_band;

  select count(*) into v_n from public.audit_logs
   where org_id = v_org and table_name = 'leave_entitlement_bands';
  perform pg_temp.check_eq('so is the band under it', v_n, 1);

  select org_id into v_seen from public.audit_logs
   where table_name = 'leave_entitlement_bands' and record_id = v_band;
  perform pg_temp.check_eq(
    'the band''s trail is filed under its own company', v_seen, v_org);

  -- The edit that matters: eight days becomes five.
  update public.leave_entitlement_bands set days = 5 where id = v_band;

  select new_data into v_to from public.audit_logs
   where table_name = 'leave_entitlement_bands' and action = 'update'
     and record_id = v_band;
  perform pg_temp.check_eq(
    'and the day count it was moved to is in the row',
    v_to ->> 'days', '5.00');

  -- Deleting the type cascades to its bands. The type's own deletion is
  -- audited against the company; the orphaned band must not appear in
  -- the platform's trail, where it could be read by a platform
  -- administrator and by nobody in the company it belonged to.
  delete from public.leave_types where id = v_lt;

  -- Null is the platform's own trail, and this file publishes statutory
  -- schedules of its own above, so the claim is about everything else.
  select count(*) into v_n from public.audit_logs
   where org_id is null
     and table_name not in ('statutory_schedules', 'statutory_rates');
  perform pg_temp.check_eq(
    'and a cascade leaves nothing in the platform''s trail', v_n, 0);

  select count(*) into v_n from public.audit_logs
   where org_id = v_org and table_name = 'leave_types' and action = 'delete';
  perform pg_temp.check_eq('while the deletion itself is recorded', v_n, 1);
end $$;

-- ---------------------------------------------------------------------
-- The same shape, one table older
--
-- `access_type_modules` has named its tenant through `access_types`
-- since 0236 and hit the same cascade. Measured before 0443: deleting
-- an access type left one audit row with a null `org_id` -- a company's
-- deleted permission set, filed under the platform.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Kebenaran Sdn Bhd');
  v_at  uuid;
  v_n   integer;
begin
  insert into public.access_types (org_id, name)
  values (v_org, 'Front desk') returning id into v_at;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_at, 'accounting', 'write');

  delete from public.access_types where id = v_at;

  select count(*) into v_n from public.audit_logs
   where org_id is null
     and table_name not in ('statutory_schedules', 'statutory_rates');
  perform pg_temp.check_eq(
    'no orphaned module row reaches the platform trail', v_n, 0);
end $$;

rollback;
