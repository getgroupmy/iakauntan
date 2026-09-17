-- =====================================================================
-- iAkauntan :: the day a statutory table changes
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/statutory_changeover.sql
--
-- A sweep of the statutory engine — `app.calc_statutory`, `calc_pcb`,
-- `round_statutory`, `epf_category`, `statutory_schedule_on` — killed 26
-- of 33 one-line mutants. The rates, the bands, the ceiling, the KWSP
-- rounding step and the two sides of every contribution are all pinned.
--
-- WHAT WAS NOT PINNED IS WHICH TABLE APPLIES ON WHICH DAY. Every fixture
-- holds ONE schedule per body, open-ended, so
--
--     effective_from <= date                     could become <
--     (effective_to is null or effective_to >= date)   could become >
--     order by effective_from desc                could become asc
--
-- and every payslip would still come out to the sen. That matters
-- exactly when it is hardest to notice: KWSP publishes a new table, it
-- takes effect on the first of a month, and the payroll for that month
-- is charged on last month's rates. Nobody re-checks a figure the
-- software produced.
--
-- The PCB table is worse still, because it is read for a whole YEAR
-- through `pcb_schedule_for_year` — at 31 December, deliberately, so a
-- table published mid-year is the one the year is assessed on. Read at
-- 1 January it would be the superseded one, and the difference is a
-- year of deductions.
--
-- The other three are about a table that is malformed rather than one
-- that changed: a rounding step of nothing, which would divide by zero
-- but for one guard; two bands covering the same wage, where only the
-- ordering decides which is charged; and whether a payslip records the
-- schedule it was computed from at all.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- 1. The first day of the new table, and the last day of the old one
-- ---------------------------------------------------------------------
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_old uuid; v_new uuid; v_amount numeric; v_sched uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  -- Two levy tables a year apart, and the rates chosen so that a
  -- payslip on the wrong side of the changeover reads as a different
  -- number rather than as the same one.
  v_old := public.platform_publish_statutory_schedule(
    'hrdf', 'Levy, the old table', 'percentage', date '2031-01-01',
    jsonb_build_array(jsonb_build_object('employer_rate', 1.00)),
    null, null, null, 'nearest_cent', true);
  v_new := public.platform_publish_statutory_schedule(
    'hrdf', 'Levy, from July', 'percentage', date '2031-07-01',
    jsonb_build_array(jsonb_build_object('employer_rate', 2.00)),
    null, null, null, 'nearest_cent', true);

  perform pg_temp.check_eq('publishing the new table closes the old one',
    (select effective_to::text from public.statutory_schedules
      where id = v_old), (date '2031-06-30')::text);

  -- THE DAY IT TAKES EFFECT. `effective_from <= p_date`: the first of
  -- July is charged on July's table, not on June's.
  perform pg_temp.check_true('the new table applies on the day it starts',
    (app.statutory_schedule_on('hrdf', date '2031-07-01')).id = v_new);
  select employer_amount into v_amount
    from app.calc_statutory('hrdf', 'default', 10000, date '2031-07-01');
  perform pg_temp.check_eq('and the levy that day is charged at the new rate',
    v_amount, 200.00);

  -- THE DAY BEFORE. `effective_to >= p_date`: a table closed ON the
  -- thirtieth still applies on the thirtieth.
  perform pg_temp.check_true('the old table applies on its own last day',
    (app.statutory_schedule_on('hrdf', date '2031-06-30')).id = v_old);
  select employer_amount into v_amount
    from app.calc_statutory('hrdf', 'default', 10000, date '2031-06-30');
  perform pg_temp.check_eq('and that day is still charged at the old rate',
    v_amount, 100.00);

  -- And the day the old table itself began, which is the other edge of
  -- the same comparison.
  perform pg_temp.check_true('a table applies on its own first day too',
    (app.statutory_schedule_on('hrdf', date '2031-01-01')).id = v_old);
  perform pg_temp.check_true('and on no day before it',
    (app.statutory_schedule_on('hrdf', date '2030-12-31')).id
      is distinct from v_old);

  -- WHICH SCHEDULE THE PAYSLIP IS TOLD. A payslip records the table its
  -- figures came from — it is what `payslip_pdf.dart` prints its
  -- "not verified" warning off, and what an auditor reads to know which
  -- gazette a deduction was computed against. An answer with the right
  -- money and the wrong table is not an answer.
  select schedule_id into v_sched
    from app.calc_statutory('hrdf', 'default', 10000, date '2031-07-01');
  perform pg_temp.check_eq('the figure names the table it was computed from',
    v_sched, v_new);
  select schedule_id into v_sched
    from app.calc_statutory('hrdf', 'default', 10000, date '2031-06-30');
  perform pg_temp.check_eq('and on the other side of the changeover, the other one',
    v_sched, v_old);
end $$;

-- ---------------------------------------------------------------------
-- 2. Two tables that both apply, and the one that wins
-- ---------------------------------------------------------------------
--
-- `platform_publish_statutory_schedule` closes what it supersedes, so
-- this shape should not arise through it. It arises through a migration
-- that seeds a table directly — which is how every table in this
-- product got here — and `order by effective_from desc` is the second
-- line of defence behind the publisher. With one open-ended schedule
-- per body it decides nothing and could be reversed unseen.
do $$
declare
  v_early uuid; v_late uuid; v_amount numeric;
begin
  insert into public.statutory_schedules
    (body, name, method, effective_from, effective_to, result_rounding,
     is_verified)
  values ('hrdf', 'Seeded and never closed', 'percentage',
          date '2032-01-01', null, 'nearest_cent', true)
  returning id into v_early;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, employer_rate)
  values (v_early, 'default', 0, 1.00);

  insert into public.statutory_schedules
    (body, name, method, effective_from, effective_to, result_rounding,
     is_verified)
  values ('hrdf', 'Seeded beside it', 'percentage',
          date '2032-07-01', null, 'nearest_cent', true)
  returning id into v_late;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, employer_rate)
  values (v_late, 'default', 0, 3.00);

  perform pg_temp.check_true('two tables can both apply on one day',
    (select count(*) from public.statutory_schedules
      where body = 'hrdf' and effective_from <= date '2032-08-01'
        and (effective_to is null or effective_to >= date '2032-08-01')) >= 2);
  perform pg_temp.check_true('and the later of them is the one in force',
    (app.statutory_schedule_on('hrdf', date '2032-08-01')).id = v_late);
  select employer_amount into v_amount
    from app.calc_statutory('hrdf', 'default', 10000, date '2032-08-01');
  perform pg_temp.check_eq('so the levy is charged at the later table''s rate',
    v_amount, 300.00);

  -- Before the later one begins, the earlier one is still the answer.
  perform pg_temp.check_true('and before it begins, the earlier one stands',
    (app.statutory_schedule_on('hrdf', date '2032-03-01')).id = v_early);
end $$;

-- ---------------------------------------------------------------------
-- 3. The PCB table is read for the year, at the end of it
-- ---------------------------------------------------------------------
--
-- `pcb_schedule_for_year` asks for the table in force on 31 December
-- and not on 1 January, because a table published mid-year is the one
-- the whole year is assessed on. Read at the start of the year it would
-- find the superseded one, and every PCB deduction from then on would
-- be computed against a gazette that had been replaced.
do $$
declare
  v_admin uuid := pg_temp.test_user();
  v_jan uuid; v_jun uuid;
begin
  insert into public.platform_admins (user_id) values (v_admin)
    on conflict do nothing;
  perform pg_temp.sign_in_as(v_admin);

  v_jan := public.platform_publish_statutory_schedule(
    'pcb', 'PCB, as the year opened', 'table', date '2033-01-01',
    jsonb_build_array(jsonb_build_object('category', 'nonresident',
                                         'employee_rate', 30.00)),
    null, null, null, 'nearest_5sen', true);
  v_jun := public.platform_publish_statutory_schedule(
    'pcb', 'PCB, as amended in June', 'table', date '2033-06-01',
    jsonb_build_array(jsonb_build_object('category', 'nonresident',
                                         'employee_rate', 25.00)),
    null, null, null, 'nearest_5sen', true);

  perform pg_temp.check_true('the year is assessed on the table in force at its end',
    (app.pcb_schedule_for_year(2033)).id = v_jun);
  perform pg_temp.check_true('which is not the one it opened on',
    (app.pcb_schedule_for_year(2033)).id is distinct from v_jan);
  -- And a year that ended before the amendment still reads its own.
  perform pg_temp.check_true('a closed year keeps the table it was assessed on',
    (app.pcb_schedule_for_year(2032)).id is distinct from v_jun);
end $$;

-- ---------------------------------------------------------------------
-- 4. A table that is malformed rather than superseded
-- ---------------------------------------------------------------------
do $$
declare
  v_zero uuid; v_over uuid; v_amount numeric;
begin
  -- A ROUNDING STEP OF NOTHING. `wage_round_up_to` has no check
  -- constraint, so nought is storable, and `ceil(wage / 0)` is a
  -- division by zero in the middle of somebody's payroll. The guard
  -- reads `is not null AND > 0`; without the second half this raises.
  insert into public.statutory_schedules
    (body, name, method, effective_from, wage_round_up_to, result_rounding,
     is_verified)
  values ('epf', 'A step of nothing', 'percentage', date '2034-01-01',
          0, 'nearest_cent', true)
  returning id into v_zero;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, employee_rate, employer_rate)
  values (v_zero, 'citizen_under60', 0, 11.00, 13.00);

  select employee_amount into v_amount
    from app.calc_statutory('epf', 'citizen_under60', 3050, date '2034-01-01');
  perform pg_temp.check_eq('a step of nothing rounds the wage to nothing at all',
    v_amount, 335.50);
  perform pg_temp.check_eq('and the employer''s share on the same unrounded wage',
    (select employer_amount from app.calc_statutory(
       'epf', 'citizen_under60', 3050, date '2034-01-01')), 396.50);

  -- TWO BANDS OVER ONE WAGE. `statutory_rates` has no constraint that
  -- bands may not overlap, and with the bands this product ships they
  -- never do — so `order by wage_from desc` decides nothing and could
  -- be reversed without a figure moving. It decides here: a wage of
  -- 5,000 sits inside both, and the narrower band starting higher is
  -- the one a rate table means.
  insert into public.statutory_schedules
    (body, name, method, effective_from, result_rounding, is_verified)
  values ('socso', 'Bands that overlap', 'percentage', date '2034-01-01',
          'nearest_cent', true)
  returning id into v_over;
  insert into public.statutory_rates
    (schedule_id, category, wage_from, wage_to, employee_rate, employer_rate)
  values (v_over, 'default', 0, 9999, 1.00, 2.00),
         (v_over, 'default', 4000, 9999, 5.00, 6.00);

  select employee_amount into v_amount
    from app.calc_statutory('socso', 'default', 5000, date '2034-01-01');
  perform pg_temp.check_eq('the band starting higher is the one charged',
    v_amount, 250.00);
  perform pg_temp.check_eq('and below it, the band beneath',
    (select employee_amount from app.calc_statutory(
       'socso', 'default', 1000, date '2034-01-01')), 10.00);
end $$;

rollback;
