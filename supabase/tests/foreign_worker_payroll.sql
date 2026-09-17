-- =====================================================================
-- iAkauntan :: the foreign worker's payslip
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/foreign_worker_payroll.sql
--
-- `app.epf_category` sorts an employee into one of four EPF categories
-- and two of them are for people who are not Malaysian. Nothing tested
-- either: changing the non-citizen employee rate, the non-citizen rate
-- at sixty, or the RM 5.00 flat employer contribution left every
-- assertion in this directory passing.
--
-- That is not a small corner of a Malaysian payroll. The employer's
-- side is the part worth stating plainly: for a non-citizen it is a
-- flat RM 5.00 a month whatever the salary, not a percentage. An
-- engine that quietly applied 12% to a foreign worker on RM 3,000
-- would over-contribute by RM 355 a month per head and nothing in this
-- directory would have noticed.
--
-- The HRD Corp optional tier is here for the same reason: an employer
-- with five to nine employees may opt in at half a per cent, and only
-- the mandatory one per cent was ever asserted.
--
-- Three columns are deliberately left unasserted, because they are
-- columns nothing reads for those categories and a test for them would
-- only be asserting that unused data is unused: the employee rate on
-- both HRD Corp tiers, since a levy has no employee side, and the
-- employer rate on the non-resident tax scale, since a tax scale has no
-- employer. The fourth of that kind -- the employer rate beside the
-- non-citizen flat amount -- is asserted, because there the danger is
-- real: read alongside the amount rather than instead of it, it turns
-- RM 5.00 into RM 365.00.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.a_period(p_org uuid)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (p_org, '2026-06', date '2026-06-01', date '2026-06-30',
          date '2026-06-30')
  returning id into v_id;
  return v_id;
end;
$$;

do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_young  uuid;   -- a non-citizen under 60
  v_old    uuid;   -- a non-citizen of 60 and over
  v_local  uuid;   -- a Malaysian on the same salary, for contrast
  r_young  record;
  r_old    record;
  r_local  record;
begin
  v_org := pg_temp.test_org('Kilang Bersama Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_period := pg_temp.a_period(v_org);

  -- Three people on RM 3,000, differing only in nationality and age.
  -- Both kinds of non-citizen the enum knows about are used, because
  -- `epf_category` treats a foreign worker and an expatriate alike and
  -- a change that separated them should be caught here.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, employment_status)
  values (v_org, 'F1', 'Nguyen Van An', date '2022-01-01', 3000,
          date '1990-03-02', 'single', 'foreign_worker', 'active')
  returning id into v_young;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, employment_status)
  values (v_org, 'F2', 'Rahman Bin Ismail', date '2015-01-01', 3000,
          date '1960-01-05', 'single', 'expatriate', 'active')
  returning id into v_old;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, employment_status)
  values (v_org, 'M1', 'Siti binti Ahmad', date '2022-01-01', 3000,
          date '1990-03-02', 'single', 'citizen', 'active')
  returning id into v_local;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-06') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select * into r_young from public.payslips
   where run_id = v_run and employee_id = v_young;
  select * into r_old from public.payslips
   where run_id = v_run and employee_id = v_old;
  select * into r_local from public.payslips
   where run_id = v_run and employee_id = v_local;

  -- ------------------------------------------------------------------
  -- Under sixty
  --
  -- The employee pays what a Malaysian pays. The employer does not:
  -- RM 5.00, flat, whatever the wage.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a foreign worker contributes eleven per cent',
    r_young.epf_employee, 330.00);
  perform pg_temp.check_eq('and the employer five ringgit, not a percentage',
    r_young.epf_employer, 5.00);

  -- Said as a comparison as well, because the two numbers above could
  -- both be wrong in the same direction and still look like a payslip.
  perform pg_temp.check_eq('the employee side matches a Malaysian''s',
    r_young.epf_employee, r_local.epf_employee);
  perform pg_temp.check_true('and the employer side does not',
    r_local.epf_employer > r_young.epf_employer);
  perform pg_temp.check_eq('the Malaysian employer pays thirteen per cent',
    r_local.epf_employer, 390.00);

  -- ------------------------------------------------------------------
  -- Sixty and over
  --
  -- The employee side stops, as it does for a Malaysian. The flat
  -- employer contribution does not.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('at sixty the foreign employee stops paying',
    r_old.epf_employee, 0);
  perform pg_temp.check_eq('and the employer still pays the five ringgit',
    r_old.epf_employer, 5.00);

  -- ------------------------------------------------------------------
  -- The flat amount governs, and the rate column beside it does not
  --
  -- Both non-citizen rows carry an employer_rate of 0 and an
  -- employer_amount of 5. Nothing reads that rate, and the danger is
  -- somebody later making `calc_statutory` add the two together --
  -- which on RM 3,000 would turn RM 5.00 into RM 365.00 a month per
  -- head and look like a plausible EPF figure. So the rate is set to
  -- something visible here and the answer must not move.
  -- ------------------------------------------------------------------
  update public.statutory_rates r
     set employer_rate = 12
    from public.statutory_schedules s
   where s.id = r.schedule_id and s.body = 'epf'
     and r.category like 'noncitizen%';

  update public.payroll_runs set status = 'draft' where id = v_run;
  delete from public.payslips where run_id = v_run;
  perform public.calculate_payroll_run(v_run);
  select * into r_young from public.payslips
   where run_id = v_run and employee_id = v_young;

  perform pg_temp.check_eq(
    'the flat amount governs and the rate beside it is not added',
    r_young.epf_employer, 5.00);

  -- The categories are sorted by nationality and age, and getting
  -- either wrong puts somebody on the wrong side of all of the above.
  perform pg_temp.check_eq('a non-citizen under sixty is sorted as one',
    app.epf_category('foreign_worker'::app.residency_status, 35),
    'noncitizen_under60');
  perform pg_temp.check_eq('and at sixty into the other',
    app.epf_category('expatriate'::app.residency_status, 60),
    'noncitizen_60plus');
  -- A permanent resident is a Malaysian for EPF, which is the one
  -- classification somebody would get wrong from the column name.
  perform pg_temp.check_eq('a permanent resident is on the Malaysian rates',
    app.epf_category('permanent_resident'::app.residency_status, 35),
    'citizen_under60');
end $$;

-- ---------------------------------------------------------------------
-- The levy an employer opts into
--
-- Five to nine employees is half a per cent, and only the mandatory one
-- per cent above ten was asserted anywhere.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_period uuid;
  v_run    uuid;
  v_emp    uuid;
  r        record;
begin
  v_org := pg_temp.test_org('Kedai Kecil Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  v_period := pg_temp.a_period(v_org);

  insert into public.payroll_settings (org_id, hrdf_category)
  values (v_org, 'optional_5to9')
  on conflict (org_id) do update set hrdf_category = excluded.hrdf_category;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, employment_status)
  values (v_org, 'S1', 'Lim Wei Ming', date '2022-01-01', 4000,
          date '1990-03-02', 'single', 'citizen', 'active')
  returning id into v_emp;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-06') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  select * into r from public.payslips
   where run_id = v_run and employee_id = v_emp;

  perform pg_temp.check_eq('the optional levy is half a per cent',
    r.hrdf, 20.00);
  -- Stated as the rate as well, so a levy that came out right on
  -- RM 4,000 by arithmetic accident does not pass.
  perform pg_temp.check_eq('which is half of what the mandatory tier is',
    r.hrdf, round(r.hrdf_wage / 200, 2));
end $$;

rollback;
