-- =====================================================================
-- iAkauntan :: how a statutory rate table is chosen and read
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/statutory_schedules.sql
--
-- `statutory.sql` asserts the figures the seeded tables produce.
-- `hr_reference.sql` asserts who may publish a table and that
-- publishing closes what it supersedes. Neither asserts the machinery
-- underneath, and three parts of it had nothing on them at all:
--
--   * which schedule answers when two could — the bug 0287 fixes,
--   * the banded, fixed-amount form a real PERKESO table takes, which
--     `calc_statutory` supports and nothing had ever exercised,
--   * `app.round_statutory` and `app.epf_category`, both small, both
--     read on every payslip, both unnamed by any test.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A correction republished the same day is the one that answers
--
-- Before 0287 this file's first assertion failed: two schedules shared
-- an effective_from, `order by effective_from desc limit 1` had no
-- tie-break, and the heap handed back the table the correction was
-- published to replace. Payroll went on paying the wrong figures while
-- every screen showed the right ones.
--
-- hrdf is used throughout this section because nothing else in the
-- suite publishes against it, so the seeded schedule of every other
-- body is left where `statutory.sql` expects to find it.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_typo uuid; v_fixed uuid; v_amount numeric;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_typo := public.platform_publish_statutory_schedule(
    'hrdf', 'Levy, mistyped', 'percentage', date '2030-01-01',
    jsonb_build_array(jsonb_build_object('employer_rate', 9.99)),
    null, null, null, 'nearest_cent', true);
  v_fixed := public.platform_publish_statutory_schedule(
    'hrdf', 'Levy, corrected', 'percentage', date '2030-01-01',
    jsonb_build_array(jsonb_build_object('employer_rate', 1.00)),
    null, null, null, 'nearest_cent', true);

  perform pg_temp.check_eq('one schedule starts on that day, not two',
    (select count(*) from public.statutory_schedules
      where body = 'hrdf' and effective_from = date '2030-01-01'), 1);
  perform pg_temp.check_true('and the correction is the one that survived',
    (app.statutory_schedule_on('hrdf', date '2030-06-01')).id = v_fixed);
  perform pg_temp.check_eq('the table it replaced is gone entirely',
    (select count(*) from public.statutory_schedules where id = v_typo), 0);
  perform pg_temp.check_eq('and its bands went with it',
    (select count(*) from public.statutory_rates where schedule_id = v_typo), 0);

  -- The assertion that matters: what a payroll would actually charge.
  select employer_amount into v_amount
    from app.calc_statutory('hrdf', 'default', 10000, date '2030-06-01');
  perform pg_temp.check_eq('the levy on 10,000 is the corrected 1%',
    v_amount, 100.00);

  -- Replaced, not closed. Closing a same-day schedule would have to
  -- write effective_to = effective_from - 1, which records a window
  -- that ran backwards.
  perform pg_temp.check_eq('nothing was left with a backwards window',
    (select count(*) from public.statutory_schedules
      where effective_to is not null and effective_to < effective_from), 0);
end $$;

-- ---------------------------------------------------------------------
-- Two schedules for one body may not start on the same day, whoever
-- writes them
--
-- The guard is a unique index rather than a branch inside the publish
-- function, because there are three places that pick a schedule and a
-- fourth will be written eventually. A rule the selectors can rely on
-- has to hold against every writer, not just the polite one.
-- ---------------------------------------------------------------------
do $$
declare v_admin uuid := pg_temp.test_user();
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  begin
    insert into public.statutory_schedules
      (body, name, method, effective_from, result_rounding)
    values ('hrdf', 'A second table for the same day', 'percentage',
            date '2030-01-01', 'nearest_cent');
    raise exception 'FAIL: two hrdf schedules started on the same day';
  exception when unique_violation then
    raise notice 'ok   a second schedule starting the same day is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Unless somebody has already been paid on it
--
-- Then the old table was in force, deleting it would orphan a payslip's
-- record of what it was calculated from, and only a person can say what
-- date the correction takes effect. 55006 rather than the 23514 the
-- rest of the function raises, so a caller can tell "in use" from
-- "malformed".
-- ---------------------------------------------------------------------
do $$
declare
  v_admin  uuid := pg_temp.test_user();
  v_org    uuid := pg_temp.test_org('Payslip Sdn Bhd');
  v_sched  uuid;
  v_period uuid; v_run uuid; v_emp uuid;
  v_col    text;
  v_year   integer := 2031;
  v_caught boolean;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  insert into public.employees (org_id, employee_no, full_name, hire_date)
  values (v_org, 'E-1', 'Siti binti Rahman', date '2030-06-01') returning id into v_emp;

  -- A payslip records four schedules, one per body, and the guard has
  -- to look at all four. Checked one at a time: a guard that forgot,
  -- say, `socso_schedule_id` would still pass a test that only ever
  -- hung its payslip off `epf_schedule_id`, and would then delete a
  -- table under a payslip that used it.
  foreach v_col in array array['epf_schedule_id', 'socso_schedule_id',
                               'eis_schedule_id', 'pcb_schedule_id'] loop
    perform pg_temp.sign_in_as(v_admin);
    v_sched := public.platform_publish_statutory_schedule(
      'hrdf', 'Levy in use, ' || v_col, 'percentage',
      make_date(v_year, 1, 1),
      jsonb_build_array(jsonb_build_object('employer_rate', 1.00)),
      null, null, null, 'nearest_cent', true);

    insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
    values (v_org, v_year || '-01', make_date(v_year,1,1), make_date(v_year,1,31),
            make_date(v_year,1,31))
    returning id into v_period;
    insert into public.payroll_runs (org_id, run_no, period_id)
    values (v_org, 'PR-' || v_year, v_period) returning id into v_run;
    execute format(
      'insert into public.payslips (org_id, run_id, employee_id, %I) values ($1,$2,$3,$4)',
      v_col) using v_org, v_run, v_emp, v_sched;

    -- The flag is set inside the block and read outside it, because a
    -- `raise exception 'FAIL'` written in here would be caught by this
    -- block's own handler.
    v_caught := false;
    begin
      perform public.platform_publish_statutory_schedule(
        'hrdf', 'Levy corrected too late', 'percentage', make_date(v_year,1,1),
        jsonb_build_array(jsonb_build_object('employer_rate', 2.00)),
        null, null, null, 'nearest_cent', true);
    exception when sqlstate '55006' then
      v_caught := true;
    end;
    -- The savepoint the caught exception rolled back to took the JWT
    -- with it.
    perform pg_temp.sign_in_as(v_admin);
    perform pg_temp.check_true(
      'a schedule reached through ' || v_col || ' cannot be replaced under it',
      v_caught);
    perform pg_temp.check_true('and the payslip still names it',
      (select true from public.payslips ps
        where ps.run_id = v_run
          and v_sched in (ps.epf_schedule_id, ps.socso_schedule_id,
                          ps.eis_schedule_id, ps.pcb_schedule_id)));
    v_year := v_year + 1;
  end loop;

  -- The same correction from a later date is the supported way out, and
  -- it closes the old table rather than deleting it. v_sched is the
  -- last one published, which starts on 1 January of v_year - 1.
  perform public.platform_publish_statutory_schedule(
    'hrdf', 'Levy from February', 'percentage', make_date(v_year - 1, 2, 1),
    jsonb_build_array(jsonb_build_object('employer_rate', 2.00)),
    null, null, null, 'nearest_cent', true);
  perform pg_temp.check_eq('publishing from a later date closes the old one',
    (select effective_to from public.statutory_schedules where id = v_sched)::text,
    make_date(v_year - 1, 1, 31)::text);
end $$;

-- ---------------------------------------------------------------------
-- A banded table with fixed amounts, which is the shape PERKESO's is
--
-- The seeded SOCSO and EIS schedules are percentages with a ceiling,
-- marked unverified, standing in until somebody types the Third
-- Schedule of the Employees' Social Security Act 1969 in. That table is
-- not a percentage: it is wage bands, each with the ringgit and sen
-- both sides pay, and `calc_statutory` already prefers a band's stated
-- amount over any rate. Nothing had ever exercised that preference, so
-- the day the real table is published it would have been the first run.
--
-- The bands below are the Act's own figures for three wage steps. The
-- method is recorded as `table` rather than `percentage`; nothing
-- branches on it, but it is what a person reading the schedule sees.
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_ee numeric; v_er numeric;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);
  perform public.platform_publish_statutory_schedule(
    'socso', 'Third Schedule, three bands of it', 'table',
    date '2032-01-01',
    jsonb_build_array(
      jsonb_build_object('category','act4','wage_from',2900.01,'wage_to',3000,
                         'employee_amount',14.75,'employer_amount',51.65,
                         'employee_rate',0.5,'employer_rate',1.75),
      jsonb_build_object('category','act4','wage_from',4900.01,'wage_to',5000,
                         'employee_amount',24.75,'employer_amount',86.65,
                         'employee_rate',0.5,'employer_rate',1.75),
      jsonb_build_object('category','act4','wage_from',5900.01,'wage_to',null,
                         'employee_amount',29.75,'employer_amount',104.15,
                         'employee_rate',0.5,'employer_rate',1.75)),
    'Akta Keselamatan Sosial Pekerja 1969', null, null, 'nearest_5sen', true);

  -- The point of the whole section. 4,905 is 1.75% = 85.84 by rate and
  -- 86.65 by the Act, because the Act charges the band, not the wage.
  -- If the amount were ignored this would come back 85.85.
  select employee_amount, employer_amount into v_ee, v_er
    from app.calc_statutory('socso','act4', 4905, date '2032-06-01');
  perform pg_temp.check_eq('the band''s stated employee figure, not 0.5% of the wage',
    v_ee, 24.75);
  perform pg_temp.check_eq('the band''s stated employer figure, not 1.75% of the wage',
    v_er, 86.65);

  -- Every wage inside a band pays the same, which is what makes it a
  -- band. Asserted at both ends because `wage_from`/`wage_to` are the
  -- comparison that decides it, and an off-by-one at either edge would
  -- charge a neighbouring band.
  select employer_amount into v_er
    from app.calc_statutory('socso','act4', 4900.01, date '2032-06-01');
  perform pg_temp.check_eq('the first sen of the band pays the band', v_er, 86.65);
  select employer_amount into v_er
    from app.calc_statutory('socso','act4', 5000, date '2032-06-01');
  perform pg_temp.check_eq('and so does its last ringgit', v_er, 86.65);

  -- One sen either side is a different band.
  select employer_amount into v_er
    from app.calc_statutory('socso','act4', 3000, date '2032-06-01');
  perform pg_temp.check_eq('a sen below the band start is the band below',
    v_er, 51.65);

  -- The open-ended top band: no wage_to, so it answers for everything
  -- above it, and the figure does not climb with the wage.
  select employer_amount into v_er
    from app.calc_statutory('socso','act4', 250000, date '2032-06-01');
  perform pg_temp.check_eq('the top band is a ceiling by being open-ended',
    v_er, 104.15);

  -- A wage in a gap between bands has no rate row. It contributes
  -- nothing rather than guessing at the nearest band, and it still
  -- names the schedule it looked in, so a payslip records what was
  -- consulted even when the answer was zero.
  select employee_amount, employer_amount into v_ee, v_er
    from app.calc_statutory('socso','act4', 4000, date '2032-06-01');
  perform pg_temp.check_eq('a wage no band covers contributes nothing', v_er, 0);
  perform pg_temp.check_true('and the schedule consulted is still named',
    (select schedule_id is not null
       from app.calc_statutory('socso','act4', 4000, date '2032-06-01')));

  -- A category the table does not carry is not the same as a wage it
  -- does not cover, and both come back nil rather than borrowing the
  -- other category's figures.
  select employer_amount into v_er
    from app.calc_statutory('socso','act800', 4905, date '2032-06-01');
  perform pg_temp.check_eq('a category this table does not carry contributes nothing',
    v_er, 0);
end $$;

-- ---------------------------------------------------------------------
-- app.round_statutory, which decides the last sen of every contribution
--
-- Three modes, one per body: EPF rounds the contribution up to the next
-- ringgit, SOCSO and EIS to the nearest five sen, PCB to the cent. The
-- halfway cases are the ones worth writing down, because they are where
-- a plausible reimplementation differs.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('up_ringgit takes a sen over to the next ringgit',
    app.round_statutory(550.01, 'up_ringgit'), 551);
  perform pg_temp.check_eq('and leaves an exact ringgit alone',
    app.round_statutory(550.00, 'up_ringgit'), 550);
  perform pg_temp.check_eq('it rounds up, never to nearest',
    app.round_statutory(550.99, 'up_ringgit'), 551);

  perform pg_temp.check_eq('nearest_5sen goes down below the halfway point',
    app.round_statutory(87.52, 'nearest_5sen'), 87.50);
  perform pg_temp.check_eq('and up at it',
    app.round_statutory(87.525, 'nearest_5sen'), 87.55);
  perform pg_temp.check_eq('an exact five sen is already there',
    app.round_statutory(87.55, 'nearest_5sen'), 87.55);

  perform pg_temp.check_eq('nearest_cent is half up',
    app.round_statutory(108.245, 'nearest_cent'), 108.25);

  -- Anything unrecognised falls to the cent rather than to no rounding
  -- at all. The table's check constraint keeps the three modes honest,
  -- so this is the behaviour if that constraint is ever widened without
  -- this function being taught the new mode.
  perform pg_temp.check_eq('an unknown mode falls back to the cent',
    app.round_statutory(108.245, 'to the nearest kopeck'), 108.25);
end $$;

-- ---------------------------------------------------------------------
-- app.epf_category, which picks which of the four EPF rate rows applies
--
-- Read on every payslip and named by nothing. Two axes — residency and
-- whether the employee has reached 60 — and the four answers are the
-- category strings the seeded EPF table is keyed on, so a typo here
-- finds no rate row and contributes nothing rather than failing.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_eq('a citizen under 60',
    app.epf_category('citizen', 35), 'citizen_under60');
  perform pg_temp.check_eq('a permanent resident counts as a citizen',
    app.epf_category('permanent_resident', 35), 'citizen_under60');
  perform pg_temp.check_eq('sixty is the day the rate changes, not sixty-one',
    app.epf_category('citizen', 60), 'citizen_60plus');
  perform pg_temp.check_eq('fifty-nine is not',
    app.epf_category('citizen', 59), 'citizen_under60');
  perform pg_temp.check_eq('a foreign worker under 60',
    app.epf_category('foreign_worker', 35), 'noncitizen_under60');
  perform pg_temp.check_eq('and over',
    app.epf_category('foreign_worker', 60), 'noncitizen_60plus');
  -- `residency_status` has four values and the category has two sides,
  -- so expatriate has to land somewhere; it lands with the foreign
  -- worker, which is the EPF's own division.
  perform pg_temp.check_eq('an expatriate is a non-citizen for EPF',
    app.epf_category('expatriate', 35), 'noncitizen_under60');

  -- The strings are only useful if the seeded table is keyed on them.
  -- Asserted against the table rather than restated, so renaming a
  -- category on one side and not the other is caught here.
  perform pg_temp.check_eq('all four name a row in the EPF table',
    (select count(distinct r.category)
       from public.statutory_rates r
       join public.statutory_schedules s on s.id = r.schedule_id
      where s.body = 'epf'
        and r.category in (app.epf_category('citizen', 35),
                           app.epf_category('citizen', 60),
                           app.epf_category('foreign_worker', 35),
                           app.epf_category('foreign_worker', 60))), 4);
end $$;

rollback;
