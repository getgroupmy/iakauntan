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
  v_ee numeric; v_er numeric; v_sched uuid; v_said text; v_ver boolean;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  -- `0404`. This table is three steps of a long one, so it has holes in
  -- it by construction -- which is the point of the section below, and
  -- is also exactly what `platform_publish_statutory_schedule` now
  -- refuses to publish. Asserted first, because a fixture that quietly
  -- stopped going through the front door would hide that.
  begin
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
    raise exception
      'FAIL: a SOCSO table missing most of its bands was published';
  exception when check_violation then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('the refusal names the wage nothing covers',
      v_said like '%starts at 2900.01%');
    perform pg_temp.check_true('and says what is wrong with it',
      v_said like '%nothing covers a wage below it%');
    raise notice 'ok   a table with holes in it cannot be published';
  end;

  -- The other shape, and the more likely one: a complete table from
  -- zero whose last band stops. That is how somebody transcribing a
  -- ceiling writes it if they reach for `wage_to`, so the refusal has
  -- to name the column that actually means "contributions stop
  -- counting above this".
  begin
    perform public.platform_publish_statutory_schedule(
      'eis', 'A ceiling written as a last band', 'table',
      date '2033-01-01',
      jsonb_build_array(
        jsonb_build_object('category','default','wage_from',0,'wage_to',6000,
                           'employee_rate',0.2,'employer_rate',0.2)),
      'Akta Sistem Insurans Pekerjaan 2017', null, null, 'nearest_5sen', true);
    raise exception
      'FAIL: an EIS table that stops at its ceiling was published';
  exception when check_violation then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('the refusal names where the table stops',
      v_said like '%stops at 6000%');
    perform pg_temp.check_true('and which column expresses a ceiling',
      v_said like '%wage_ceiling%');
    raise notice 'ok   a ceiling written as a last band is refused';
  end;

  -- Three more shapes, each isolated. The first refusal above happens
  -- to be caught by the "must start at zero" rule, so on its own it
  -- says nothing about the rest -- mutation testing showed the gap
  -- branch was never reached by any assertion in this file.
  begin
    perform public.platform_publish_statutory_schedule(
      'eis', 'A step missing from the middle', 'table', date '2033-02-01',
      jsonb_build_array(
        jsonb_build_object('category','default','wage_from',0,'wage_to',3000,
                           'employee_rate',0.2,'employer_rate',0.2),
        jsonb_build_object('category','default','wage_from',4000,'wage_to',null,
                           'employee_rate',0.2,'employer_rate',0.2)),
      null, null, null, 'nearest_5sen', true);
    raise exception 'FAIL: a table with a step missing was published';
  exception when check_violation then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('the refusal names both sides of the gap',
      v_said like '%jumps from 3000.00 to 4000.00%');
    raise notice 'ok   a step missing from the middle is refused';
  end;

  begin
    perform public.platform_publish_statutory_schedule(
      'eis', 'Two bands over the same wage', 'table', date '2033-03-01',
      jsonb_build_array(
        jsonb_build_object('category','default','wage_from',0,'wage_to',3000,
                           'employee_rate',0.2,'employer_rate',0.2),
        jsonb_build_object('category','default','wage_from',2500,'wage_to',null,
                           'employee_rate',0.4,'employer_rate',0.4)),
      null, null, null, 'nearest_5sen', true);
    raise exception 'FAIL: two bands covering one wage were published';
  exception when check_violation then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('the refusal says the answer would depend on row order',
      v_said like '%depend on the order%');
    raise notice 'ok   two bands over the same wage are refused';
  end;

  begin
    perform public.platform_publish_statutory_schedule(
      'eis', 'Something after the open band', 'table', date '2033-04-01',
      jsonb_build_array(
        jsonb_build_object('category','default','wage_from',0,'wage_to',null,
                           'employee_rate',0.2,'employer_rate',0.2),
        jsonb_build_object('category','default','wage_from',5000,'wage_to',null,
                           'employee_rate',0.4,'employer_rate',0.4)),
      null, null, null, 'nearest_5sen', true);
    raise exception 'FAIL: a band after the open one was published';
  exception when check_violation then
    get stacked diagnostics v_said = message_text;
    perform pg_temp.check_true('the refusal says only the last may run to the top',
      v_said like '%Only the last band%');
    raise notice 'ok   nothing may follow the band that runs to the top';
  end;

  -- So the fixture is put in directly, as the owner, which is honest
  -- about what it is: three bands of a table, kept incomplete on
  -- purpose so the rest of this section has a gap to ask about.
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, source,
     is_verified, notes)
  values ('socso', 'Third Schedule, three bands of it', 'table',
          date '2032-01-01', 'nearest_5sen',
          'Akta Keselamatan Sosial Pekerja 1969', true,
          'Deliberately partial: a fixture, not a publication.')
  returning id into v_sched;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, wage_to,
     employee_rate, employer_rate, employee_amount, employer_amount, sort_order)
  values (v_sched, 'act4', 2900.01, 3000, 0.5, 1.75, 14.75, 51.65, 1),
         (v_sched, 'act4', 4900.01, 5000, 0.5, 1.75, 24.75, 86.65, 2),
         (v_sched, 'act4', 5900.01, null, 0.5, 1.75, 29.75, 104.15, 3);
  update public.statutory_schedules
     set effective_to = date '2031-12-31'
   where body = 'socso' and effective_from < date '2032-01-01'
     and (effective_to is null or effective_to >= date '2032-01-01');

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

  -- `0404`. What it must not do is call that zero a verified figure.
  -- This schedule is marked verified and the wage is in a hole, which
  -- is the combination that used to print "the statutory figures on
  -- this payslip have been verified" over a SOCSO deduction of nothing.
  select is_verified into v_ver
    from app.calc_statutory('socso','act4', 4000, date '2032-06-01');
  perform pg_temp.check_true(
    'and a wage no table covers is not a verified figure', not v_ver);
  perform pg_temp.check_true('even though the schedule itself is verified',
    (select s.is_verified from public.statutory_schedules s
      where s.id = v_sched));
  -- The other side of it: a wage the table does cover still reports the
  -- schedule's own answer, so this did not simply turn the flag off.
  select is_verified into v_ver
    from app.calc_statutory('socso','act4', 4905, date '2032-06-01');
  perform pg_temp.check_true('a wage it does cover is still verified', v_ver);
  -- And an employee with no wage at all is not an unverified payslip.
  select is_verified into v_ver
    from app.calc_statutory('socso','act4', 0, date '2032-06-01');
  perform pg_temp.check_true(
    'nor is a month of unpaid leave on a verified table', v_ver);

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

-- ---------------------------------------------------------------------
-- What `app.calc_statutory` does at its edges
--
-- Added after a mutation sweep killed 19 of 24 one-line mutants. Four
-- survived, and every one of them was a branch the suite reached and
-- never looked at the answer of.
--
-- These run against the SEEDED tables rather than a fixture, because
-- what is being pinned is the arithmetic a real payslip gets.
-- ---------------------------------------------------------------------
do $$
declare
  r     record;
  v_ver boolean;
begin
  -- -----------------------------------------------------------------
  -- The RM20 step, and which way it goes
  --
  -- KWSP rounds the wage UP to the next RM20 before applying the rate.
  -- Every wage the suite used was already a multiple of twenty, so
  -- rounding to the NEAREST step gave the same answer everywhere and a
  -- mutant that did so survived. RM5,001 is where the two part company:
  -- up lands on 5,020, nearest lands back on 5,000 — and 5,000 is in a
  -- different employer band, so the difference is not a rounding
  -- difference, it is forty-seven ringgit of somebody's contribution.
  -- -----------------------------------------------------------------
  select * into r
    from app.calc_statutory('epf', 'citizen_under60', 5000,
                            date '2026-01-31');
  perform pg_temp.check_eq('EPF on RM5,000: the employee pays 11%',
    r.employee_amount, 550);
  perform pg_temp.check_eq('and the employer 13%, being at the boundary',
    r.employer_amount, 650);

  select * into r
    from app.calc_statutory('epf', 'citizen_under60', 5001,
                            date '2026-01-31');
  perform pg_temp.check_eq(
    'one ringgit more rounds the wage UP to RM5,020', r.employee_amount, 553);
  perform pg_temp.check_eq(
    'and past the boundary the employer pays 12%', r.employer_amount, 603);

  -- The whole step lands on one figure, which is what "up to the next
  -- twenty" means and what a floor or a nearest would break.
  select * into r
    from app.calc_statutory('epf', 'citizen_under60', 5019,
                            date '2026-01-31');
  perform pg_temp.check_eq('RM5,019 rounds to the same RM5,020',
    r.employee_amount, 553);
  select * into r
    from app.calc_statutory('epf', 'citizen_under60', 5020,
                            date '2026-01-31');
  perform pg_temp.check_eq('and RM5,020 is already there',
    r.employee_amount, 553);

  -- -----------------------------------------------------------------
  -- A date no table covers
  --
  -- Not a hole inside a table -- that is asserted above -- but a date
  -- before any schedule exists at all. Nothing to compute AND nothing
  -- to trust, and the second half is the one that had no assertion: a
  -- mutant returning `true` here put "these figures have been verified"
  -- on a payslip computed from no table whatsoever.
  -- -----------------------------------------------------------------
  select * into r
    from app.calc_statutory('epf', 'citizen_under60', 5000,
                            date '1990-01-31');
  perform pg_temp.check_eq('before any EPF table there is nothing to pay',
    r.employee_amount, 0);
  perform pg_temp.check_eq('on either side', r.employer_amount, 0);
  perform pg_temp.check_true('and no schedule to name', r.schedule_id is null);
  perform pg_temp.check_true(
    'and nothing about it has been verified', not r.is_verified);

  -- -----------------------------------------------------------------
  -- An unverified schedule says so
  --
  -- The seeded tables in this repository are NOT checked against the
  -- gazette -- `is_verified` is false on every one of them, and
  -- `payslip_pdf.dart` prints its warning off that flag. Nothing
  -- asserted that the flag survived the journey out of
  -- `calc_statutory`, so a mutant hard-coding `true` took the warning
  -- off every payslip in the product and passed.
  -- -----------------------------------------------------------------
  perform pg_temp.check_true('the seeded EPF table is not verified',
    not (select s.is_verified from public.statutory_schedules s
          where s.id = (app.statutory_schedule_on('epf',
                                                  date '2026-01-31')).id));
  select is_verified into v_ver
    from app.calc_statutory('epf', 'citizen_under60', 5000,
                            date '2026-01-31');
  perform pg_temp.check_true('and the figure it produces says so', not v_ver);

  -- Bands that do not overlap are what makes `calc_statutory` taking
  -- the HIGHEST matching band equivalent to taking the lowest. That is
  -- checked over the shipped schedules in `statutory_bands.sql`, which
  -- has no fixtures of its own to trip over -- this file deliberately
  -- builds a schedule WITH a hole in it, a few hundred lines up.
end $$;

rollback;
