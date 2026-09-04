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
-- What the PCB deduction actually turns on
--
-- Added after a mutation sweep of `app.calc_pcb` killed only 19 of 41
-- one-line mutants. The three worked examples above pin the arithmetic
-- for three people; almost every BRANCH between them was invisible. A
-- deduction that quietly ignored a disability, a working spouse, a
-- child's share, or the PCB somebody had already paid this year would
-- have passed the suite unchanged.
--
-- Every figure below is the one the engine produces today, and every
-- one of them differs from the RM108.25 baseline in a direction the
-- Rules require. A test that only asserted "it is different" would die
-- to a mutant that changed it in the wrong direction.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_e   uuid;
  r     record;
begin
  v_org := pg_temp.test_org('Branches Co');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'B1', 'Single, 5000', date '2020-01-01', 5000,
          date '1990-01-01', 'single', 'citizen')
  returning id into v_e;

  -- The baseline everything below is measured against, restated here
  -- so this block stands on its own.
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('the baseline for this block', r.pcb, 108.25);

  -- -----------------------------------------------------------------
  -- Somebody PCB does not apply to
  --
  -- `pcb_eligible` is a column an admin can clear -- for somebody
  -- taxed under a different arrangement -- and nothing asserted that
  -- clearing it did anything at all.
  -- -----------------------------------------------------------------
  update public.employees set pcb_eligible = false where id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('nobody ineligible is deducted', r.pcb, 0);
  perform pg_temp.check_true('and no schedule is claimed for it',
    r.schedule_id is null);
  perform pg_temp.check_true('nor is it reported as verified',
    not r.is_verified);
  update public.employees set pcb_eligible = true where id = v_e;

  -- -----------------------------------------------------------------
  -- A foreign worker is a non-resident
  --
  -- The flat rate applies to BOTH non-resident statuses. Only
  -- `expatriate` was ever exercised, so a foreign worker being taxed as
  -- a resident -- with a full year's reliefs they are not entitled to --
  -- was invisible.
  -- -----------------------------------------------------------------
  update public.employees set residency_status = 'foreign_worker'
   where id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 0, 0, 0, date '2026-01-31');
  perform pg_temp.check_eq('a foreign worker is deducted the flat rate',
    r.pcb, 1500.00);

  -- And a bonus is part of the month's pay at the flat rate: there is
  -- no projection to distort, so nothing is set aside for it.
  select * into r from app.calc_pcb(
    v_e, 5000, 0, 0, 0, date '2026-01-31', 2000, 0);
  perform pg_temp.check_eq(
    'a non-resident bonus is taxed at the same flat rate',
    r.pcb, 2100.00);
  update public.employees set residency_status = 'citizen' where id = v_e;

  -- -----------------------------------------------------------------
  -- The spouse
  -- -----------------------------------------------------------------
  update public.employees
     set marital_status = 'married', spouse_is_working = true
   where id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'a working spouse earns no spouse relief', r.pcb, 108.25);

  update public.employees set spouse_is_working = false where id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'a spouse who is not working earns RM4,000 of relief',
    r.pcb, 88.25);

  -- -----------------------------------------------------------------
  -- Disability
  -- -----------------------------------------------------------------
  update public.employees set is_disabled = true where id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('a disabled employee earns RM6,000 more relief',
    r.pcb, 58.25);

  update public.employees
     set is_disabled = false, spouse_is_disabled = true
   where id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('a disabled spouse earns RM5,000 more',
    r.pcb, 63.25);

  update public.employees
     set spouse_is_disabled = false, marital_status = 'single',
         spouse_is_working = false
   where id = v_e;

  -- -----------------------------------------------------------------
  -- Children
  --
  -- Four branches of one CASE, and only the RM2,000 one was ever
  -- reached. The higher-education figure is the one that moves money.
  -- -----------------------------------------------------------------
  insert into public.employee_dependants
    (org_id, employee_id, name, relationship, date_of_birth)
  values (v_org, v_e, 'Anak', 'child', date '2015-01-01');
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('a child is worth RM2,000 of relief',
    r.pcb, 98.25);

  update public.employee_dependants set in_higher_education = true
   where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'a child in higher education is worth RM8,000', r.pcb, 68.25);

  -- 0530. A disabled child is RM6,000, and a disabled child in higher
  -- education is that PLUS the RM8,000 for the education -- section 48
  -- makes the two cumulative. The engine gave RM8,000 flat, which is
  -- what a child who is NOT disabled gets: the disability was read and
  -- then thrown away for exactly the children entitled to most. Found
  -- by a mutation sweep, which is also why both arms are pinned here
  -- rather than one.
  update public.employee_dependants
     set in_higher_education = false, is_disabled = true
   where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('a disabled child is worth RM6,000',
    r.pcb, 78.25);

  update public.employee_dependants set in_higher_education = true
   where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'a disabled child in higher education is worth RM14,000, not RM8,000',
    r.pcb, 10.80);

  update public.employee_dependants
     set is_disabled = false, in_higher_education = false
   where employee_id = v_e;

  -- The share, which decides how two separated parents split one
  -- child's relief between them.
  update public.employee_dependants
     set in_higher_education = false, relief_claim_percent = 50
   where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq('half a child claimed is half the relief',
    r.pcb, 103.25);

  -- Two ways a dependant does not count, each of which the query has a
  -- clause for and neither of which was exercised.
  update public.employee_dependants
     set relief_claim_percent = 100, is_tax_dependant = false
   where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'a dependant not claimed for tax earns nothing', r.pcb, 108.25);

  update public.employee_dependants
     set is_tax_dependant = true, relationship = 'parent'
   where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'a parent is not a child, whatever else they are', r.pcb, 108.25);
  delete from public.employee_dependants where employee_id = v_e;

  -- -----------------------------------------------------------------
  -- The floors
  --
  -- Three `greatest(..., 0)` in the function, and not one of them was
  -- ever reached. Each of them is the difference between a deduction
  -- of nothing and a NEGATIVE deduction -- money paid to an employee
  -- out of LHDN's account.
  -- -----------------------------------------------------------------
  select * into r from app.calc_pcb(v_e, 1200, 132, 12, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'reliefs beyond a year of pay leave nothing to deduct, not a refund',
    r.pcb, 0);

  select * into r from app.calc_pcb(
    v_e, 5000, 550, 35, 5000, date '2026-01-31');
  perform pg_temp.check_eq(
    'zakat beyond the tax leaves nothing to deduct, not a refund',
    r.pcb, 0);

  -- -----------------------------------------------------------------
  -- What has already been deducted this year
  --
  -- PCB is a running settlement: what is taken this month is the
  -- year's tax LESS what has already gone. Both halves of that -- this
  -- employer's own deductions and a previous employer's -- could have
  -- been dropped without a test noticing.
  -- -----------------------------------------------------------------
  insert into public.payroll_ytd
    (org_id, employee_id, tax_year, taxable_income, epf_employee, pcb)
  values (v_org, v_e, 2026, 30000, 3300, 0);
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-07-31');
  perform pg_temp.check_eq('July, with nothing deducted yet', r.pcb, 217.90);

  update public.payroll_ytd set pcb = 900 where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-07-31');
  perform pg_temp.check_eq(
    'RM900 already deducted is spread over the six months left',
    r.pcb, 67.90);

  -- Over-deducted: the year is already settled and more, and the
  -- answer is nothing, not a refund through the payslip.
  update public.payroll_ytd set pcb = 100000 where employee_id = v_e;
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-07-31');
  perform pg_temp.check_eq(
    'having over-deducted, this month deducts nothing', r.pcb, 0);

  -- The same money, paid by a previous employer, has to count the same.
  update public.payroll_ytd set pcb = 0 where employee_id = v_e;
  insert into public.employee_ytd_opening
    (org_id, employee_id, tax_year, pcb_paid)
  values (v_org, v_e, 2026, 900);
  select * into r from app.calc_pcb(v_e, 5000, 550, 35, 0, date '2026-07-31');
  perform pg_temp.check_eq(
    'and PCB paid by a previous employer counts the same', r.pcb, 67.90);

  delete from public.employee_ytd_opening where employee_id = v_e;
  delete from public.payroll_ytd where employee_id = v_e;

  -- -----------------------------------------------------------------
  -- The EPF deducted from a bonus
  --
  -- It is relieved, up to the same cap as ordinary EPF. This needs a
  -- LOW earner to see: on RM5,000 a month the cap is already binding,
  -- which is why the mutant that dropped this relief altogether
  -- survived the sweep.
  -- -----------------------------------------------------------------
  select * into r from app.calc_pcb(
    v_e, 3000, 330, 25, 0, date '2026-01-31');
  perform pg_temp.check_eq('on RM3,000 a month there is nothing to deduct',
    r.pcb, 0);

  select * into r from app.calc_pcb(
    v_e, 3000, 330, 25, 0, date '2026-01-31', 40000, 0);
  perform pg_temp.check_eq('a RM40,000 bonus is taxed once, in full',
    r.pcb, 2901.40);

  select * into r from app.calc_pcb(
    v_e, 3000, 330, 25, 0, date '2026-01-31', 40000, 4400);
  perform pg_temp.check_eq(
    'and the EPF deducted from it is relieved, under the cap',
    r.pcb, 2897.00);

  -- A bonus too small to move the band still moves the deduction by
  -- its own tax and no more -- five sen, which is the rounding step.
  select * into r from app.calc_pcb(
    v_e, 5000, 550, 35, 0, date '2026-01-31', 1, 0);
  perform pg_temp.check_eq('a bonus of one ringgit adds five sen',
    r.pcb, 108.30);

  -- The third floor, and the least obvious. A bonus RAISES the year's
  -- income by its own amount and the year's relief by twelve times the
  -- EPF taken from it, so a small bonus with a large EPF deduction
  -- makes the year's tax go DOWN. Left unfloored the engine would hand
  -- the difference back through the payslip; the deduction for the
  -- bonus is nothing, and the relief is settled at assessment.
  select * into r from app.calc_pcb(
    v_e, 8000, 100, 25, 0, date '2026-01-31');
  perform pg_temp.check_eq(
    'on RM8,000 with barely any EPF, before any bonus', r.pcb, 553.75);

  select * into r from app.calc_pcb(
    v_e, 8000, 100, 25, 0, date '2026-01-31', 100, 2000);
  perform pg_temp.check_eq(
    'a bonus whose own EPF relieves more than it earns adds nothing, '
    'and takes nothing back',
    r.pcb, 553.75);
end $$;

-- ---------------------------------------------------------------------
-- What every PCB schedule has to carry
--
-- `app.calc_pcb` reaches for four rows on the schedule and falls back
-- to a hard-coded number when each is missing: a non-resident rate, the
-- EPF relief cap, the SOCSO relief cap, the spouse relief. Every one of
-- those fallbacks is UNREACHABLE against the seeded data, which is why
-- a mutation sweep could change three of them freely without a test
-- noticing -- and it is unreachable only for as long as the seed keeps
-- its side of the bargain.
--
-- So the bargain is asserted here rather than the dead branch. A
-- schedule seeded without a non-resident rate would silently deduct
-- NOTHING from every expatriate on it, which is the failure that
-- carries a penalty rather than a refund.
-- ---------------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  select string_agg(s.name, ', ') into v_bad
    from public.statutory_schedules s
   where s.body = 'pcb'
     and not exists (select 1 from public.statutory_rates r
                      where r.schedule_id = s.id
                        and r.category = 'nonresident');
  perform pg_temp.check_true(
    'every PCB schedule carries a non-resident rate' ||
    coalesce(' -- but not ' || v_bad, ''),
    v_bad is null);

  for v_bad in
    select code from (values ('individual'), ('epf'), ('socso_eis'),
                             ('spouse')) as t(code)
  loop
    perform pg_temp.check_eq(
      format('every PCB schedule carries the %s relief', v_bad),
      (select count(*)::numeric from public.statutory_schedules s
        where s.body = 'pcb'
          and not exists (select 1 from public.tax_reliefs t
                           where t.schedule_id = s.id and t.code = v_bad)),
      0);
  end loop;

  -- And the two caps are the numbers the fallbacks assume, so a change
  -- to either has to be a deliberate one.
  perform pg_temp.check_eq('the EPF relief cap is RM4,000',
    (select max(t.max_amount) from public.tax_reliefs t
      join public.statutory_schedules s on s.id = t.schedule_id
     where s.body = 'pcb' and t.code = 'epf'), 4000);
  perform pg_temp.check_eq('the SOCSO and EIS relief cap is RM350',
    (select max(t.max_amount) from public.tax_reliefs t
      join public.statutory_schedules s on s.id = t.schedule_id
     where s.body = 'pcb' and t.code = 'socso_eis'), 350);
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

  -- Seventeen functions are deliberately open to an unauthenticated
  -- caller, and each earned its place by someone who has no account
  -- needing to
  -- do exactly one thing: a director signing one resolution, a customer
  -- reading one invoice they were sent a link to, and — since 0262 — a
  -- customer at a table reading the menu on the QR sticker in front of
  -- them and ordering from it.
  --
  -- The allowlist is the point. Deleting this check would be easier and
  -- would stop it doing its job — it caught `open_shared_document` on
  -- the commit that added it, and `open_customer_portal` on `0493`,
  -- which is what an allowlist is for. Adding a name here should feel
  -- like a decision, and anybody doing it should be able to say which
  -- stranger needs the function and why nothing else in the database is
  -- reachable through it.
  --
  -- The count in the sentence above had drifted to five behind the list
  -- by `0493` — it said ten against fifteen names. The assertion never
  -- cared, because it is written against the list rather than the
  -- number, which is why nothing caught it; but a comment that
  -- undercounts the open doors by a third is worse than no count, so
  -- it is worth correcting whenever a name goes in.
  perform pg_temp.check_true('nothing new is exposed to anon',
    not exists (
      select 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app')
         and p.prosecdef
         and has_function_privilege('anon', p.oid, 'execute')
         and p.proname not in (
           'corp_open_signing_link',
           'corp_sign_with_link',
           -- 0378, and it is the pair of the one above rather than a
           -- new door. `app.signature_status` has had `declined` since
           -- `0069` and nothing could produce it, so a director reading
           -- a resolution on a link could sign it or close the tab —
           -- and a line that stays pending for ever reads at the other
           -- end as an email nobody opened.
           --
           -- It reaches exactly what signing reaches and no more: the
           -- token resolves the one signature line, the same checks
           -- apply (a valid, unused, unexpired link on a pending line
           -- of a request that has not been withdrawn), and the link is
           -- spent either way so it cannot be used to sign after
           -- refusing. It writes a status and a reason on one row.
           -- `supabase/tests/decline_and_lodge.sql` asserts the refusal
           -- and what it does not do.
           'corp_decline_with_link',
           -- Takes a share token and returns one sales document, with
           -- internal notes and line cost deliberately left out.
           -- `supabase/tests/document_share.sql` asserts both absences.
           'open_shared_document',
           -- 0413, and the smallest thing that could be added beside
           -- the one above: the customer reading an invoice on a link
           -- has to be told how they may pay it, and they are not
           -- signed in.
           --
           -- It takes the same token, applies the same checks (a valid,
           -- unrevoked, unexpired link on a document that has not been
           -- withdrawn), and answers with acquirer codes and names for
           -- gateways this company has switched on and can actually
           -- settle through. Nothing about a gateway crosses to an
           -- unauthenticated caller except what is already printed on
           -- the button they are about to press: no key, no collection
           -- reference, no mode. It writes nothing.
           --
           -- Its siblings are deliberately *not* here.
           -- `begin_shared_payment` and `settle_shared_payment` are
           -- revoked from anon and authenticated alike, and
           -- `app.shared_payment_intent` -- which hands back an
           -- acquirer key -- from every client role. Only the service
           -- role reaches those, which is to say the edge function.
           -- `supabase/tests/shared_invoice_payment.sql` asserts all
           -- three refusals under `set local role anon`.
           'shared_payment_options',
           -- 0493, and the pair of them widen `open_shared_document`
           -- by exactly one step: from the document to the contact
           -- that owes it. A customer with three invoices held three
           -- links and had nowhere to see what they owed altogether.
           --
           -- `open_customer_portal` takes a portal token and answers
           -- with one contact's outstanding invoices: number, dates,
           -- currency, what is still owed on each, and the total.
           -- Every clause that keeps it to one account is asserted in
           -- `supabase/tests/customer_portal.sql` -- another
           -- customer's invoice, a draft, a settled one, an expired
           -- token and a revoked one all produce nothing. No lines, no
           -- costs, no internal notes: those stay behind
           -- `open_shared_document`, which the customer reaches only
           -- through the function below.
           'open_customer_portal',
           -- The one that mints a credential, and so the more
           -- dangerous of the two. It hands a portal holder a normal
           -- document share token for one of *their own* invoices, so
           -- everything from there is 0067's and 0414's code
           -- unchanged. Without the clause that checks the document
           -- belongs to this account, a portal token would be a key to
           -- every invoice in the tenant -- which is the assertion
           -- "a portal cannot open somebody else's invoice", and the
           -- reason the migration's self-check also greps for that
           -- clause by name.
           --
           -- It revokes nothing, deliberately: a customer clicking
           -- through their own account has sent nobody anything, and
           -- killing the link the tenant emailed them last week would
           -- be a bug wearing a rule's clothes.
           'portal_document_token',
           -- 0390, and the pair of them are the reader and the writer
           -- of one conversation. `ticket_comments.author_contact_id`
           -- has existed since `0192` with a check constraint demanding
           -- exactly one author, and nothing ever wrote it — so the
           -- customer who raised a ticket could not say anything on it.
           --
           -- `open_shared_ticket` takes a token and returns one ticket
           -- and the comments on it that are not internal. That filter
           -- is the reason the function exists: `is_internal` defaults
           -- to true and `0192` calls it the most dangerous boolean in
           -- a helpdesk. No assignee, no SLA deadline, no agent named,
           -- nothing about any other ticket or any other customer.
           'open_shared_ticket',
           -- The writer. It appends one comment as the ticket's own
           -- requester contact, always visible, and lifts the ticket
           -- off `pending` so the clock that was paused while the
           -- company waited runs again. It deliberately does not touch
           -- `first_response_at`: that target is a promise about how
           -- quickly the company would answer, and stopping it on the
           -- customer's own message would report a target met that
           -- nobody met. It writes nothing else and reads nothing else.
           -- `supabase/tests/ticket_share.sql` asserts the internal
           -- note never leaves, the response clock is untouched, and an
           -- expired or revoked link takes no reply.
           'reply_to_shared_ticket',
           -- 0235. Reachable before anybody has signed in, because the
           -- only moment a rejected password can be reported is before
           -- there is a session. It is built to be safe rather than
           -- trusted: nothing is recorded for an address that is not a
           -- user, no password or attempt is stored, the same void comes
           -- back either way so it cannot be used to find out which
           -- addresses exist, and at most one row a minute per account is
           -- written so it cannot bury a real event.
           -- `supabase/tests/security_audit.sql` asserts the silence and
           -- the rate limit; the rest is the signature, which takes an
           -- address and nothing else.
           'report_failed_sign_in',
           -- 0347, and the one entry on this list that makes the
           -- platform easier to enumerate rather than harder. Read it
           -- as a decision, because it is one.
           --
           -- A company's door and an address pointed at a module are
           -- both for a known set of people, and taking a password from
           -- somebody who was never going to be let in is a round trip
           -- that ends in a refusal it could have started with. So the
           -- form asks the email first and this answers whether it has
           -- any business there — which means anyone who can reach
           -- `sinar.iakauntan.com` can ask whether an address is on
           -- Sinar's team without knowing a password. Before this they
           -- had to know one.
           --
           -- What bounds it: it answers a bare yes or no and nothing
           -- else; an address that exists nowhere and one belonging to
           -- another company are the same answer; and every host that
           -- is not for somebody in particular — the bare domain, a
           -- name nobody holds, a parked name — answers true for
           -- everybody, so the oracle reaches only addresses an
           -- operator deliberately pointed at somebody.
           -- `supabase/tests/email_before_password.sql` asserts each of
           -- those, including the ones that are about what it does not
           -- say.
           'may_sign_in_here',
           -- 0262, and the three of them are one feature: a token on a
           -- sticker, the menu behind it, and an order placed from it.
           --
           -- Each takes a token and never an organization id, and every
           -- one of them resolves the shop from the link row rather
           -- than from anything the caller says. What a stranger can
           -- reach is one outlet's sellable items and their prices —
           -- which is a menu, and a menu is a thing shops print and
           -- hand out. `supabase/tests/pos_public_menu.sql` asserts the
           -- rest: an expired or retired link reaches nothing, a
           -- single-use one closes behind the order it carried, the
           -- price is the shop's rather than the browser's, and an
           -- order can only be placed into an outlet with a shift open.
           'public_pos_menu',
           'public_pos_menu_modifiers',
           'place_public_pos_order',
           -- 0290, and the only one here that is not about a token.
           --
           -- It is the corporate landing page: the thing somebody sees
           -- when they type the address on a business card, before they
           -- have any reason to make an account. It takes no argument,
           -- so there is nothing to vary and nothing to probe with, and
           -- what it returns is marketing copy a platform administrator
           -- chose to publish — no organization, no person, no
           -- identifier of either. An unpublished page comes back empty
           -- rather than as a draft.
           --
           -- The tables behind it are not merely policy-protected but
           -- ungranted to anon entirely, so this function is the whole
           -- of the public surface rather than the polite route to it.
           -- `supabase/tests/landing_page.sql` asserts both, and that
           -- only a platform administrator can change what it says.
           'landing_page',
           -- 0327, and the same shape of thing as the landing page: a
           -- question a browser has to be able to ask before anybody
           -- has signed in.
           --
           -- It takes a host and answers whose door it is — a company's
           -- name and its logo, so the sign-in page at
           -- `sinar.iakauntan.com` can say Sinar on it. No identifier,
           -- no contact, nothing about who works there, and a host
           -- nobody has reserved comes back empty rather than as an
           -- error, because "this name is free" is not a secret.
           --
           -- What it can be probed for is whether a given subdomain is
           -- taken, which is what a browser typing the address finds
           -- out anyway. `supabase/tests/workspace_address.sql` asserts
           -- the rest: that a request is not a door, that the door
           -- closes for a company that stops paying or stops trading,
           -- and that anon may call this and nothing else here.
           'workspace_by_host',
           -- 0334, and the plainest one on the list: the terms
           -- somebody is being asked to agree to, the privacy policy
           -- that describes what happens to them, and the address to
           -- write to if they want to ask about either. A policy only
           -- members can read is not a policy.
           --
           -- It takes no argument, so there is nothing to vary and
           -- nothing to probe with. What comes back is the wording on
           -- five screens: the two that always draw — sign in and sign
           -- up — and the three that are only returned once a platform
           -- administrator has published them, so a half-written
           -- privacy policy is not a published one.
           -- `supabase/tests/site_pages.sql` asserts the gate, that
           -- the table behind it is shut to anon, and that only a
           -- platform administrator can change what it says.
           'site_pages')));

  -- The other half of that allowlist, and it is not decoration.
  --
  -- `0165` added an event trigger that strips PUBLIC and anon from every
  -- new function in `public` and `app`, because Postgres grants the
  -- first and Supabase's default privileges grant the second, and
  -- sixteen functions went in relying on neither being true. The trigger
  -- fires on `create or replace` as well as on `create` — so re-issuing
  -- any of these three without re-granting anon afterwards would take
  -- the share and signing links offline. The check above cannot see
  -- that: it asks what is exposed, and losing an exposure passes it.
  --
  -- So assert the exposure. A share link that has silently stopped
  -- working is found by a customer, not by us.
  perform pg_temp.check_eq('and the fifteen that need anon still have it',
    (select count(*)
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.prosecdef
        and has_function_privilege('anon', p.oid, 'execute')
        and p.proname in ('corp_open_signing_link', 'corp_sign_with_link',
                          'open_shared_document', 'report_failed_sign_in',
                          -- 0493. A portal link that has silently
                          -- stopped working is found by a customer who
                          -- thinks they are being chased for money
                          -- they cannot see.
                          'open_customer_portal', 'portal_document_token',
                          -- A ticket link that has silently stopped
                          -- working is found by a customer who thinks
                          -- they are being ignored.
                          'open_shared_ticket', 'reply_to_shared_ticket',
                          -- A QR sticker that has silently stopped
                          -- working is found by a customer holding a
                          -- phone at a table, which is worse than being
                          -- found by us.
                          'public_pos_menu', 'public_pos_menu_modifiers',
                          'place_public_pos_order',
                          -- A landing page that has silently stopped
                          -- loading is found by somebody deciding not to
                          -- buy the product.
                          'landing_page',
                          -- And a company's own door that has stopped
                          -- opening is found by their staff, who see
                          -- our mark where theirs should be and wonder
                          -- what they have signed into.
                          'workspace_by_host',
                          -- And a terms page that has silently stopped
                          -- loading is found by somebody who was asked
                          -- to agree to it and could not read it.
                          'site_pages',
                          -- And a door that has stopped asking the
                          -- email first is found by a shift standing at
                          -- a till typing a password nobody will take.
                          'may_sign_in_here')),
    15);

  perform pg_temp.check_true('and the link tables stay shut to anon',
    not exists (
      select 1 from information_schema.role_table_grants
       where grantee = 'anon'
         and table_name in ('corp_signing_links', 'corp_signatures',
                            'corp_signature_requests', 'corp_documents',
                            -- `document_share_links` and, since `0390`,
                            -- `ticket_share_links`. Both hold a column
                            -- of token hashes, and Supabase's default
                            -- privileges grant `anon` every table
                            -- privilege — so the revoke in the
                            -- migration is the only thing between an
                            -- anonymous request and every live link in
                            -- the system.
                            'document_share_links',
                            'ticket_share_links',
                            -- 0493, and the same shape as the two
                            -- above: a column of token hashes, each
                            -- one a live door into a customer's whole
                            -- account rather than a single document.
                            'customer_portal_links')));

  -- 0498, and the reason the assertion above needed a list at all: a
  -- table carries an `anon` grant from the moment it is created, so
  -- until 0498 the only tables shut to a stranger were the ones whose
  -- migration remembered. Two hundred and sixty-seven did not.
  --
  -- Not an open door even then -- row level security is on everywhere
  -- and every guard is false for somebody not signed in -- but the
  -- grant is what makes a `using (true)` typed in a hurry reachable
  -- rather than inert, which is the whole point of a second line.
  perform pg_temp.check_true('nothing in public is readable by a stranger',
    not exists (
      select 1 from pg_class c
       where c.relnamespace = 'public'::regnamespace
         and c.relkind in ('r', 'p', 'v', 'm')
         and not (c.relname = any(app.anon_readable_tables()))
         and has_table_privilege('anon', c.oid, 'select')));

  -- The four that are meant to be: the front page's three and the
  -- statutory remittance calendar, each with an unguarded policy to
  -- match. A sweep that took these would empty the front page quietly.
  perform pg_temp.check_eq(
    'except the four the front page and the calendar need',
    (select count(*)::integer from unnest(app.anon_readable_tables()) t
      where has_table_privilege('anon', 'public.' || quote_ident(t),
                                'select')), 4);

  -- And the half that stops it coming back. Without the default
  -- privilege revoked, the next table added is exposed again and the
  -- assertion above passes until somebody adds one.
  create table if not exists public.zz_anon_probe (id integer);
  perform pg_temp.check_true('and a table made after this one is shut too',
    not has_table_privilege('anon', 'public.zz_anon_probe', 'select'));
  drop table public.zz_anon_probe;

  -- 0499, and the same shape one role along: a table privilege that no
  -- policy permits cannot do anything, and is one policy typed wrong
  -- away from being able to do everything. `payslip_access_log` is the
  -- one that made this visible -- an authenticated DELETE against the
  -- record of who read whose payslip was allowed to run and stopped by
  -- row level security matching no rows, rather than refused.
  perform pg_temp.check_true(
    'no write privilege outlives the policy that would permit it',
    not exists (
      select 1 from pg_class c
      cross join unnest(array['insert', 'update', 'delete']) cmd
       where c.relnamespace = 'public'::regnamespace
         and c.relkind in ('r', 'p')
         and has_table_privilege('authenticated', c.oid, cmd)
         and not app.policy_permits(c.relname::text, cmd)));

  -- The other half. A sweep with an off-by-one in it would take the
  -- privileges the product runs on, and the first thing anybody would
  -- notice is an invoice that cannot be saved.
  -- `corp_officers` is the one that matters most here: its writes come
  -- from a single `for all` policy rather than a policy per command, so
  -- a sweep that read only the per-command policies would take it and
  -- leave the two obvious tables standing.
  perform pg_temp.check_true('an invoice can still be raised from the API',
    has_table_privilege('authenticated', 'public.sales_documents', 'insert')
    and has_table_privilege('authenticated', 'public.contacts', 'update')
    and has_table_privilege('authenticated', 'public.corp_officers',
                            'insert'));

  -- A module gate is restrictive: it narrows what a permissive policy
  -- allows and grants nothing by itself. Counting one as permission
  -- would keep exactly the privileges that have no way to be used, so
  -- the predicate is asked about a table that has nothing but a gate.
  create table if not exists public.zz_gate_probe (org_id uuid);
  alter table public.zz_gate_probe enable row level security;
  create policy zz_gate on public.zz_gate_probe
    as restrictive for insert to authenticated with check (true);
  perform pg_temp.check_true('a module gate is not a permission',
    not app.policy_permits('zz_gate_probe', 'insert'));
  drop table public.zz_gate_probe;

  -- The whole permission layer hangs off this one predicate, and the
  -- twenty-six guards written as `if not app.can_x(...) then raise` only
  -- fire on a hard false. A null here reopens every one of them.
  perform pg_temp.check_eq('a stranger organisation is a hard false, never null',
    case when app.has_org_role(gen_random_uuid(),
           array['owner', 'admin']::app.member_role[]) is false
         then 1 else 0 end, 1);

  -- The change history carries salaries and bank numbers in its diffs,
  -- so it is admin-only and, like the read log, written by the database
  -- rather than by anybody with an API key.
  perform pg_temp.check_true('the change history cannot be written from the API',
    not exists (
      select 1 from pg_policies
       where tablename = 'audit_logs' and cmd <> 'SELECT'));

  perform pg_temp.check_true('and it is not open to everyone who reads the ledger',
    (select qual::text like '%can_admin%'
       from pg_policies
      where tablename = 'audit_logs' and policyname = 'audit_logs_select'));
end $$;

-- ---------------------------------------------------------------------
-- The rule that keeps the allowlist short
--
-- The allowlist above asserts what is exposed to anon right now. What
-- keeps it short is 0165's event trigger, which strips PUBLIC and anon
-- from every function created in `public` or `app` — because Supabase
-- ships `alter default privileges ... grant all on functions to anon`,
-- so without it a new function arrives reachable by strangers and
-- somebody has to notice.
--
-- Nothing asserted the trigger itself, only its accumulated output. On
-- a from-scratch build that is nearly enough — remove the trigger and
-- the next definer function added in `public` lights the allowlist up.
-- Nearly, because it depends on a later migration happening to add one,
-- and because the allowlist reports the symptom rather than the cause:
-- "something you did not expect is exposed" is a worse morning than
-- "the thing that stops that is switched off".
--
-- The third assertion is the one this file most needed. A replace
-- strips anon too, which is not obvious and is the reason 0290 and 0294
-- both re-grant anon immediately after re-creating `landing_page()`.
-- Those lines read as redundant. They are not, and the day somebody
-- tidies them away the landing page goes dark for everybody who has not
-- signed in.
-- ---------------------------------------------------------------------
do $$
declare v_enabled "char";
begin
  select evtenabled into v_enabled
    from pg_event_trigger where evtname = 'revoke_public_execute';
  perform pg_temp.check_true('the trigger that shuts new functions is armed',
    v_enabled is not null and v_enabled <> 'D');

  -- A function made here and rolled back with the rest of the file.
  create function public.zz_trigger_probe()
  returns integer language sql security definer as 'select 1';

  perform pg_temp.check_true(
    'a new function is not born reachable by a stranger',
    not has_function_privilege('anon', 'public.zz_trigger_probe()', 'execute'));
  perform pg_temp.check_true('nor by PUBLIC',
    not has_function_privilege('public', 'public.zz_trigger_probe()', 'execute'));

  -- Grant it deliberately, then replace it. This is the behaviour every
  -- re-grant in this repository depends on.
  grant execute on function public.zz_trigger_probe() to anon;
  perform pg_temp.check_true('an anon grant can still be given on purpose',
    has_function_privilege('anon', 'public.zz_trigger_probe()', 'execute'));

  create or replace function public.zz_trigger_probe()
  returns integer language sql security definer as 'select 2';
  perform pg_temp.check_true(
    'and replacing the function takes it away again',
    not has_function_privilege('anon', 'public.zz_trigger_probe()', 'execute'));

  -- The other half, and the reason the trigger is safe to leave on: a
  -- grant to `authenticated` survives, so re-creating an ordinary
  -- function does not lock out every signed-in user on the platform.
  grant execute on function public.zz_trigger_probe() to authenticated;
  create or replace function public.zz_trigger_probe()
  returns integer language sql security definer as 'select 3';
  perform pg_temp.check_true(
    'while a signed-in user keeps theirs',
    has_function_privilege('authenticated', 'public.zz_trigger_probe()', 'execute'));

  drop function public.zz_trigger_probe();

  -- And the same in `app`, because the trigger names two schemas and an
  -- assertion that only probes one is an assertion that passes while
  -- half the rule is gone. Narrowing the trigger to `public` alone
  -- survived every check above until this was added.
  --
  -- `app` never had Supabase's default anon grant to begin with, so the
  -- interesting half here is the replace: a deliberate anon grant on an
  -- `app` function is stripped the same way, which is what keeps a
  -- SECURITY DEFINER helper from quietly becoming a public entry point
  -- the next time somebody edits it.
  create function app.zz_trigger_probe()
  returns integer language sql security definer as 'select 1';
  perform pg_temp.check_true('an app function is shut to PUBLIC too',
    not has_function_privilege('public', 'app.zz_trigger_probe()', 'execute'));

  grant execute on function app.zz_trigger_probe() to anon;
  create or replace function app.zz_trigger_probe()
  returns integer language sql security definer as 'select 2';
  perform pg_temp.check_true(
    'and replacing one in app takes anon away as well',
    not has_function_privilege('anon', 'app.zz_trigger_probe()', 'execute'));
  drop function app.zz_trigger_probe();
end $$;


-- ---------------------------------------------------------------------
-- The change history
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_emp uuid;
  v_n   integer;
  v_changes jsonb;
begin
  v_org := pg_temp.test_org('Audited Co');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary, residency_status)
  values (v_org, 'A1', 'Audited Person', date '2026-01-01', 5000, 'citizen')
  returning id into v_emp;

  update public.employees set basic_salary = 6500 where id = v_emp;
  -- A write that changes nothing is not an event.
  update public.employees set basic_salary = 6500 where id = v_emp;

  select count(*) into v_n from public.audit_logs
   where org_id = v_org and table_name = 'employees' and record_id = v_emp;
  perform pg_temp.check_eq(
    'an insert and a real update are recorded, a no-op update is not', v_n, 2);

  select jsonb_build_object('from', old_data, 'to', new_data) into v_changes
    from public.audit_logs
   where org_id = v_org and record_id = v_emp and action = 'update';
  perform pg_temp.check_true('and only the field that moved is kept',
    v_changes = jsonb_build_object(
      'from', jsonb_build_object('basic_salary', 5000.00),
      'to',   jsonb_build_object('basic_salary', 6500.00)));

  -- Nobody without admin gets to read it.
  perform pg_temp.sign_out();
  begin
    perform * from public.audit_trail(v_org);
    raise exception 'FAIL: a non-admin read the change history';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-admin cannot read the change history';
  end;
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
