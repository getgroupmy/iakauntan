-- =====================================================================
-- iAkauntan :: the relief ceiling that was only a helper text
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/declared_reliefs.sql
--
-- `calc_pcb` subtracts every row of `employee_tax_reliefs` from the
-- projected income before working the month's PCB out, without looking
-- at the code:
--
--     select coalesce(sum(etr.amount), 0) into v_manual
--       from public.employee_tax_reliefs etr
--      where etr.employee_id = p_employee_id and etr.tax_year = v_year;
--
-- So the amount is the whole of the arithmetic, and until `0408` nothing
-- constrained it. `tax_reliefs.max_amount` carried LHDN's ceiling and
-- was read in one place: a helper line under the amount box.
--
-- PCB is money the employer withholds and remits. What is asserted here
-- is that the ceiling now refuses, that a relief `calc_pcb` already
-- applies from the record cannot be claimed a second time, and — the
-- half that matters more than any refusal — that a relief inside the
-- ceiling still goes in and still moves the tax.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Declares a relief and says whether it was refused, in the shape
-- `saveDeclaredRelief` uses.
create or replace function pg_temp.relief_refused(
  p_org uuid, p_emp uuid, p_year integer, p_code text, p_amount numeric)
returns boolean language plpgsql as $$
begin
  insert into public.employee_tax_reliefs
    (org_id, employee_id, tax_year, relief_code, amount)
  values (p_org, p_emp, p_year, p_code, p_amount)
  on conflict (employee_id, tax_year, relief_code)
    do update set amount = excluded.amount;
  return false;
exception when others then
  return true;
end $$;

do $$
declare
  v_org   uuid;
  v_emp   uuid;
  v_year  integer := extract(year from current_date)::integer;
  v_sched uuid;
  v_cap   numeric;
  v_before numeric;
  v_after  numeric;
  v_offered text[];
  v_code  text;
begin
  v_org := pg_temp.test_org('Pelepasan Cukai Sdn Bhd');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, employment_status,
     residency_status, date_of_birth)
  values (v_org, 'E-1', 'Aminah', date '2019-01-01', 'active',
          'citizen', date '1990-06-01')
  returning id into v_emp;

  v_sched := (app.pcb_schedule_for_year(v_year)).id;
  perform pg_temp.check_true(
    'there is a PCB schedule for this year to be judged by', v_sched is not null);

  -- ------------------------------------------------------------------
  -- The list the screen offers
  -- ------------------------------------------------------------------
  -- The defect this closes was that the list was empty — for the whole
  -- life of the feature — because the client asked for a column called
  -- `schedule_type` that this schema has never had. So the first thing
  -- to assert is that something is offered at all.
  select array_agg(code order by code) into v_offered
    from public.declarable_reliefs(v_year);

  perform pg_temp.check_true('the screen has reliefs to offer',
    coalesce(array_length(v_offered, 1), 0) > 0);

  perform pg_temp.check_eq(
    'and offers exactly the ones the schedule marks as the employee''s '
    'to declare',
    (select count(*) from public.declarable_reliefs(v_year)),
    (select count(*) from public.tax_reliefs r
      where r.schedule_id = v_sched
        and r.applies_to = 'manual' and not r.is_automatic));

  perform pg_temp.check_eq('and offers no automatic relief',
    (select count(*) from public.declarable_reliefs(v_year) d
      join public.tax_reliefs r
        on r.schedule_id = v_sched and r.code = d.code
     where r.is_automatic), 0);

  -- ------------------------------------------------------------------
  -- The list offered is the list allowed
  -- ------------------------------------------------------------------
  -- These two came apart once already, in the other direction: the
  -- screen offered nothing while the table accepted anything. Asserting
  -- them against each other is what stops that recurring.
  foreach v_code in array v_offered loop
    perform pg_temp.check_true(
      format('%s is offered, so %s may be declared', v_code, v_code),
      not pg_temp.relief_refused(v_org, v_emp, v_year, v_code, 1.00));
  end loop;

  -- ------------------------------------------------------------------
  -- The ceiling
  -- ------------------------------------------------------------------
  select r.code, r.max_amount into v_code, v_cap
    from public.declarable_reliefs(v_year) r
   where r.max_amount is not null
   order by r.max_amount limit 1;
  perform pg_temp.check_true('a capped relief exists to test the cap with',
    v_cap is not null);

  perform pg_temp.check_true(
    format('%s is allowed at its ceiling of RM%s', v_code, v_cap),
    not pg_temp.relief_refused(v_org, v_emp, v_year, v_code, v_cap));

  perform pg_temp.check_true(
    format('and %s is refused one sen above it', v_code),
    pg_temp.relief_refused(v_org, v_emp, v_year, v_code, v_cap + 0.01));

  perform pg_temp.check_eq(
    'so the row still holds the amount that was allowed',
    (select amount from public.employee_tax_reliefs
      where employee_id = v_emp and tax_year = v_year
        and relief_code = v_code), v_cap);

  -- A round number rather than an edge one, because the arithmetic that
  -- goes wrong in production is rarely a sen out.
  perform pg_temp.check_true(
    'and a figure ten times the ceiling is refused as well',
    pg_temp.relief_refused(v_org, v_emp, v_year, v_code, v_cap * 10));

  -- ------------------------------------------------------------------
  -- What is not the employee's to declare
  -- ------------------------------------------------------------------
  -- `calc_pcb` works the individual allowance out of the schedule and
  -- the children out of `employee_dependants`, then adds this table on
  -- top. A declared copy is claimed twice and neither half can see the
  -- other.
  perform pg_temp.check_true(
    'the individual allowance cannot be declared -- it is already given',
    pg_temp.relief_refused(v_org, v_emp, v_year, 'individual', 9000));

  perform pg_temp.check_true(
    'nor EPF, which calc_pcb takes from the month it is calculating',
    pg_temp.relief_refused(v_org, v_emp, v_year, 'epf', 4000));

  perform pg_temp.check_true(
    'nor a code the schedule has never heard of',
    pg_temp.relief_refused(v_org, v_emp, v_year, 'holiday_in_langkawi', 5000));

  perform pg_temp.check_true(
    'nor a negative amount, which would raise the tax rather than lower it',
    pg_temp.relief_refused(v_org, v_emp, v_year, v_code, -100));

  -- ------------------------------------------------------------------
  -- A year with no published table
  -- ------------------------------------------------------------------
  -- `0404` settled this direction for `app.calc_statutory`: an absent
  -- schedule means there is no arithmetic to be wrong about. Refusing
  -- the declaration would take a working HR screen down because the
  -- platform has not published a table, so the trigger stands aside —
  -- deliberately, and asserted here so it stays a decision.
  perform pg_temp.check_eq('and 2019 has no PCB schedule to judge it by',
    (select count(*) from public.statutory_schedules
      where body = 'pcb' and effective_from <= date '2019-12-31'
        and (effective_to is null or effective_to >= date '2019-12-31')), 0);

  perform pg_temp.check_true(
    'so a declaration for a year with no schedule is let through',
    not pg_temp.relief_refused(v_org, v_emp, 2019, 'life_insurance', 99999));

  -- ------------------------------------------------------------------
  -- The positive control: it still moves the tax
  -- ------------------------------------------------------------------
  -- A trigger that refused everything would satisfy every assertion
  -- above. What has to survive is the thing the feature is for.
  delete from public.employee_tax_reliefs where employee_id = v_emp;

  select pcb into v_before from app.calc_pcb(
    v_emp, 20000, 0, 0, 0, make_date(v_year, 1, 31));
  perform pg_temp.check_true(
    'an employee on RM20,000 a month owes PCB to begin with', v_before > 0);

  perform pg_temp.check_true('and may declare a relief inside the ceiling',
    not pg_temp.relief_refused(v_org, v_emp, v_year, v_code, v_cap));

  select pcb into v_after from app.calc_pcb(
    v_emp, 20000, 0, 0, 0, make_date(v_year, 1, 31));
  perform pg_temp.check_true(
    format('and the month''s PCB falls: RM%s to RM%s', v_before, v_after),
    v_after < v_before);
end $$;

rollback;
