-- =====================================================================
-- iAkauntan :: statutory engine tests
--
-- The worked examples in the README, made executable. Run against a
-- database with the migrations applied:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/statutory.sql
--
-- Every check raises on failure, so a non-zero exit means a rate table,
-- a rounding rule or a relief has moved. Nothing is written: the whole
-- file runs inside a transaction that is rolled back at the end.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- EPF
--
-- Employer drops from 13% to 12% above RM5,000, and stops for the
-- employee at 60 while the employer side falls to 4%.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from app.calc_statutory(
    'epf', 'citizen_under60', 5000, date '2026-01-31');
  perform pg_temp.check_eq('EPF 5000 employee', r.employee_amount, 550);
  perform pg_temp.check_eq('EPF 5000 employer (13%)', r.employer_amount, 650);

  select * into r from app.calc_statutory(
    'epf', 'citizen_under60', 12000, date '2026-01-31');
  perform pg_temp.check_eq('EPF 12000 employee', r.employee_amount, 1320);
  perform pg_temp.check_eq('EPF 12000 employer (12%)', r.employer_amount, 1440);

  select * into r from app.calc_statutory(
    'epf', 'citizen_60plus', 4500, date '2026-01-31');
  perform pg_temp.check_eq('EPF 60+ employee stops', r.employee_amount, 0);
  perform pg_temp.check_eq('EPF 60+ employer (4%)', r.employer_amount, 180);

  -- The wage is rounded up to the next RM20 before the rate is applied,
  -- and the contribution up to the next ringgit.
  select * into r from app.calc_statutory(
    'epf', 'citizen_under60', 3010, date '2026-01-31');
  perform pg_temp.check_eq('EPF rounds the wage up to RM3,020',
    r.employee_amount, ceil(3020 * 0.11));
end $$;

-- ---------------------------------------------------------------------
-- SOCSO and EIS
--
-- Both cap at the RM6,000 insured wage. Act 800 covers employment
-- injury only, so the employee side is nil.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  select * into r from app.calc_statutory('socso', 'act4', 5000, date '2026-01-31');
  perform pg_temp.check_eq('SOCSO 5000 employee', r.employee_amount, 25.00);
  perform pg_temp.check_eq('SOCSO 5000 employer', r.employer_amount, 87.50);

  select * into r from app.calc_statutory('socso', 'act4', 12000, date '2026-01-31');
  perform pg_temp.check_eq('SOCSO caps at 6000, employee', r.employee_amount, 30.00);
  perform pg_temp.check_eq('SOCSO caps at 6000, employer', r.employer_amount, 105.00);

  select * into r from app.calc_statutory('socso', 'act800', 4500, date '2026-01-31');
  perform pg_temp.check_eq('SOCSO Act 800 employee is nil', r.employee_amount, 0);
  perform pg_temp.check_eq('SOCSO Act 800 employer', r.employer_amount, 56.25);

  select * into r from app.calc_statutory('eis', 'default', 12000, date '2026-01-31');
  perform pg_temp.check_eq('EIS caps at 6000, employee', r.employee_amount, 12.00);
  perform pg_temp.check_eq('EIS caps at 6000, employer', r.employer_amount, 12.00);

  perform pg_temp.check_eq('SOCSO insured wage shown on a payslip',
    app.insured_wage('socso', 'act4', 12000, date '2026-01-31'), 6000);
end $$;

-- ---------------------------------------------------------------------
-- The annual tax scale
-- ---------------------------------------------------------------------
do $$
declare v_sched uuid;
begin
  select id into v_sched from app.statutory_schedule_on('pcb', date '2026-01-31');

  -- Below the threshold, and inside the rebate.
  perform pg_temp.check_eq('tax on 5,000', app.annual_tax(5000, v_sched), 0);
  perform pg_temp.check_eq('tax on 30,000 after the RM400 rebate',
    app.annual_tax(30000, v_sched), 150 + (30000 - 20000) * 0.03 - 400);
  -- Above the rebate ceiling the full amount stands.
  perform pg_temp.check_eq('tax on 46,650',
    app.annual_tax(46650, v_sched), 600 + (46650 - 35000) * 0.06);
  perform pg_temp.check_eq('tax on 122,650',
    app.annual_tax(122650, v_sched), 9400 + (122650 - 100000) * 0.25);
end $$;

-- ---------------------------------------------------------------------
-- PCB, the three worked examples from the README
--
-- Computed against a throwaway organization so the figures do not depend
-- on whatever the demo tenant has accumulated.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_single uuid;
  v_family uuid;
  v_senior uuid;
  r record;
begin
  -- A trigger enrols the creator as owner, and that row needs a real
  -- user. The whole transaction rolls back.
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Test Co', 'test-co-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          pg_temp.test_user())
  returning id into v_org;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'T1', 'Single, 5000', date '2020-01-01', 5000,
          date '1992-04-15', 'single', 'citizen')
  returning id into v_single;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, spouse_is_working, residency_status)
  values (v_org, 'T2', 'Married, 12000, two children', date '2020-01-01',
          12000, date '1985-09-22', 'married', false, 'citizen')
  returning id into v_family;

  insert into public.employee_dependants
    (org_id, employee_id, name, relationship, date_of_birth)
  values (v_org, v_family, 'Child one', 'child', date '2015-02-11'),
         (v_org, v_family, 'Child two', 'child', date '2018-08-03');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'T3', 'Aged 62, 4500', date '2010-01-04', 4500,
          date '1964-03-18', 'married', 'citizen')
  returning id into v_senior;

  -- January, so the year is projected over twelve months.
  select * into r from app.calc_pcb(v_single, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('PCB, single on 5,000', r.pcb, 108.25);

  select * into r from app.calc_pcb(v_family, 12000, 1320, 42, 0, date '2026-01-31');
  perform pg_temp.check_eq('PCB, married on 12,000 with two children',
    r.pcb, 1255.20);

  select * into r from app.calc_pcb(v_senior, 4500, 0, 0, 0, date '2026-01-31');
  perform pg_temp.check_eq('PCB, aged 62 on 4,500', r.pcb, 80.00);

  -- A non-resident is deducted flat, with no reliefs at all.
  update public.employees set residency_status = 'expatriate'
   where id = v_single;
  select * into r from app.calc_pcb(v_single, 5000, 0, 0, 0, date '2026-01-31');
  perform pg_temp.check_eq('PCB, non-resident flat rate', r.pcb, 1500.00);

  -- Zakat is a rebate against tax, not a relief against income, so a
  -- month of zakat reduces the deduction ringgit for ringgit.
  update public.employees set residency_status = 'citizen' where id = v_single;
  select * into r from app.calc_pcb(v_single, 5000, 550, 35, 5, date '2026-01-31');
  perform pg_temp.check_eq('PCB falls by the zakat paid', r.pcb, 108.25 - 5);
end $$;

-- ---------------------------------------------------------------------
-- The tax year an employee brings with them
--
-- PCB projects the year from the month in hand, so a mid-year joiner
-- with nothing recorded has a part year projected as the whole. This is
-- the difference that makes, and it is large.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_emp uuid;
  r record;
  v_bare numeric;
  v_open numeric;
  v_relief numeric;
  v_bik numeric;
begin
  v_org := pg_temp.test_org('Mid Year Co');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'M1', 'Joined in July', date '2026-07-01', 8000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_emp;

  -- July: six months left, and as far as payroll knows, six months of pay.
  select * into r from app.calc_pcb(v_emp, 8000, 880, 44, 0, date '2026-07-31');
  v_bare := r.pcb;

  insert into public.employee_ytd_opening
    (org_id, employee_id, tax_year, gross_pay, epf_employee, pcb_paid, zakat_paid)
  values (v_org, v_emp, 2026, 48000, 5280, 1500, 0);
  select * into r from app.calc_pcb(v_emp, 8000, 880, 44, 0, date '2026-07-31');
  v_open := r.pcb;

  perform pg_temp.check_true(
    'without the opening figures the deduction is a small fraction of the truth',
    v_bare * 10 < v_open);

  -- A declared relief comes off the projection.
  insert into public.employee_tax_reliefs
    (org_id, employee_id, tax_year, relief_code, amount)
  values (v_org, v_emp, 2026, 'lifestyle', 2500);
  select * into r from app.calc_pcb(v_emp, 8000, 880, 44, 0, date '2026-07-31');
  v_relief := r.pcb;
  perform pg_temp.check_true('a declared relief reduces the deduction',
    v_relief < v_open);

  -- Benefits in kind are income, and used to be stored and ignored.
  update public.employee_ytd_opening set benefits_in_kind = 12000
   where employee_id = v_emp;
  select * into r from app.calc_pcb(v_emp, 8000, 880, 44, 0, date '2026-07-31');
  v_bik := r.pcb;
  perform pg_temp.check_true('benefits in kind raise it again', v_bik > v_relief);
end $$;

-- ---------------------------------------------------------------------
-- Every seeded schedule declares its provenance
-- ---------------------------------------------------------------------
do $$
declare v_unverified integer;
begin
  select count(*) into v_unverified
    from public.statutory_schedules where not is_verified;
  perform pg_temp.check_true(
    'seeded schedules are flagged unverified until the gazetted tables are loaded',
    v_unverified > 0);
end $$;

-- ---------------------------------------------------------------------
-- Access boundaries that must not quietly loosen
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('payslips carry row level security',
    (select relrowsecurity from pg_class where relname = 'payslips'));

  perform pg_temp.check_true('the read log cannot be written from the API',
    not exists (
      select 1 from pg_policies
       where tablename = 'payslip_access_log' and cmd <> 'SELECT'));

  perform pg_temp.check_true('a grant no longer opens the payslip table',
    (select qual::text not ilike '%payslip_access_granted%'
       from pg_policies
      where tablename = 'payslips' and policyname = 'payslips_select'));

  perform pg_temp.check_true('access requests are readable but not writable',
    not exists (
      select 1 from pg_policies
       where tablename = 'payslip_access_requests' and cmd <> 'SELECT'));

  perform pg_temp.check_true('no SECURITY DEFINER function is left to anon',
    not exists (
      select 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app')
         and p.prosecdef
         and has_function_privilege('anon', p.oid, 'execute')));

  -- The whole permission layer hangs off this one predicate, and the
  -- twenty-six guards written as `if not app.can_x(...) then raise` only
  -- fire on a hard false. A null here reopens every one of them.
  perform pg_temp.check_eq('a stranger organisation is a hard false, never null',
    case when app.has_org_role(gen_random_uuid(),
           array['owner', 'admin']::app.member_role[]) is false
         then 1 else 0 end, 1);
end $$;

-- ---------------------------------------------------------------------
-- Paying a run
--
-- Posting books the liability; the payment instruction is what moves the
-- money, so the transitions around it are worth pinning down.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner  uuid := pg_temp.test_user();
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values ('Pay Co', 'pay-co-' || gen_random_uuid(), 'sdn_bhd', 'MYR', v_owner)
  returning id into v_org;

  insert into public.pay_periods (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-01', date '2026-01-01', date '2026-01-31', date '2026-01-31')
  returning id into v_period;

  insert into public.payroll_runs (org_id, period_id, run_no, status)
  values (v_org, v_period, 'PAY-TEST-1', 'draft')
  returning id into v_run;

  -- Nobody at all is refused. This is the regression test for a guard
  -- that used to pass a non-member straight through: app.org_role gives
  -- null for someone outside the organization, `null = any (...)` is
  -- null, and `if not null then raise` never fires.
  perform pg_temp.sign_out();
  begin
    perform * from public.payroll_payment_instruction(v_run);
    raise exception 'FAIL: a non-member read a payment instruction';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot read a payment instruction';
  end;

  begin
    perform public.mark_payroll_paid(v_run);
    raise exception 'FAIL: a non-member marked a run paid';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot mark a run paid';
  end;

  -- From here on, the owner of the organization.
  perform pg_temp.sign_in_as(v_owner);

  -- A run that has not been posted has no instruction to give.
  begin
    perform * from public.payroll_payment_instruction(v_run);
    raise exception 'FAIL: a draft run produced a payment file';
  exception when sqlstate '22023' then
    raise notice 'ok   a draft run refuses to produce a payment file';
  end;

  begin
    perform public.mark_payroll_paid(v_run);
    raise exception 'FAIL: a draft run was marked paid';
  exception when sqlstate '22023' then
    raise notice 'ok   a draft run cannot be marked paid';
  end;

  update public.payroll_runs set status = 'posted' where id = v_run;
  perform public.mark_payroll_paid(v_run);
  perform pg_temp.check_true('a posted run can be marked paid',
    (select status = 'paid' from public.payroll_runs where id = v_run));

  -- Paying twice is how an employee gets paid twice.
  begin
    perform public.mark_payroll_paid(v_run);
    raise exception 'FAIL: a paid run was marked paid a second time';
  exception when sqlstate '22023' then
    raise notice 'ok   a paid run cannot be marked paid again';
  end;

  -- But it can still be re-read, so the file can be produced again.
  perform * from public.payroll_payment_instruction(v_run);
  raise notice 'ok   a paid run can still produce its file';

  begin
    perform public.mark_payroll_paid(gen_random_uuid());
    raise exception 'FAIL: an unknown run was accepted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   an unknown run is rejected';
  end;

  perform pg_temp.sign_out();
end $$;

rollback;
