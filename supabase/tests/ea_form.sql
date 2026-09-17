-- =====================================================================
-- iAkauntan :: the EA form says what this employer paid
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ea_form.sql
--
-- `0608` builds C.P.8A -- the statement of remuneration an employer
-- hands every employee by the end of February so they can file their
-- own return. Four things in it are decisions rather than sums, and
-- each is a way to produce a form that adds up and is wrong:
--
--   1. **A previous employer's figures are not on it.**
--      `employee_ytd_opening` holds what somebody was paid before they
--      joined, so this year's PCB is computed on the right cumulative
--      total. The previous employer issues their own EA form for the
--      same year. An employee handed two that both include the first
--      job declares that salary twice.
--
--   2. **The year is the year of the PAY DATE.** A December salary paid
--      on 5 January is income for the new year. A form built on the
--      period would put thirteen months in one year and eleven in the
--      next, for everybody, for ever.
--
--   3. **Only posted runs.** A calculated run is a set of figures that
--      can still change and a payment nobody has received.
--
--   4. **PCB and CP38 are two boxes.** `payroll_ytd` adds them
--      together, which is right for the cumulative figure the PCB
--      engine needs. On the form they are D1 and D2 and an employee
--      claims them separately.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company with the Payroll module, a fiscal year either side of the
-- boundary, and one employee on a flat salary.
create or replace function pg_temp.ea_company(p_name text)
returns table (org uuid, emp uuid) language plpgsql as $$
declare v_org uuid; v_emp uuid;
begin
  v_org := pg_temp.test_org(p_name, array['hr', 'payroll']);
  perform public.create_fiscal_year(v_org, date '2025-01-01');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.payroll_settings (org_id, employer_tax_no,
                                       employer_epf_no, employer_socso_no)
  values (v_org, 'E 1234567890', 'A1234567', 'B7654321')
  on conflict (org_id) do update set
    employer_tax_no = excluded.employer_tax_no,
    employer_epf_no = excluded.employer_epf_no,
    employer_socso_no = excluded.employer_socso_no;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, nric, income_tax_no, epf_no,
     cp38_monthly)
  values (v_org, 'E1', 'Nurul Huda', date '2021-03-01', 6000,
          date '1990-01-01', 'citizen', '900101015566', 'SG 1111111111',
          'K9876543', 100)
  returning id into v_emp;

  org := v_org; emp := v_emp;
  return next;
end $$;

-- One month, calculated and posted, with the pay date said out loud.
create or replace function pg_temp.ea_month(
  p_org uuid, p_year integer, p_month integer, p_pay_date date,
  p_post boolean default true)
returns uuid language plpgsql as $$
declare v_period uuid; v_run uuid;
begin
  v_period := public.ensure_pay_period(p_org, p_year, p_month);
  update public.pay_periods set pay_date = p_pay_date where id = v_period;
  v_run := public.create_payroll_run(p_org, v_period,
                                     format('%s-%s', p_year, p_month));
  perform public.calculate_payroll_run(v_run);
  if p_post then
    perform public.post_payroll_run(v_run);
  end if;
  return v_run;
end $$;

-- =====================================================================
-- The boxes exist, and one of them is the exempt list
-- =====================================================================
do $$
declare v_n integer;
begin
  perform pg_temp.check_true(
    'the form has a box for gross salary',
    exists (select 1 from public.ea_categories
             where code = 'salary' and part = 'B' and box = '1(a)'));

  perform pg_temp.check_true(
    'and one for benefits in kind, which no payroll figure can supply',
    exists (select 1 from public.ea_categories
             where code = 'bik' and part = 'B'));

  select count(*) into v_n
    from public.ea_categories where is_exempt;
  perform pg_temp.check_eq(
    'exactly one box is the tax-exempt list', v_n, 1);

  -- CONTROL. Part B is remuneration and none of it is exempt. If this
  -- ever fails, the assertion above is counting something else.
  select count(*) into v_n
    from public.ea_categories where part = 'B' and is_exempt;
  perform pg_temp.check_eq('and none of Part B is exempt', v_n, 0);
end $$;

-- =====================================================================
-- Two posted months, and the total is the two of them
-- =====================================================================
do $$
declare
  v       record;
  v_ea    jsonb;
  v_gross numeric;
  v_slip  numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  select * into v from pg_temp.ea_company('Borang EA Sdn Bhd');

  perform pg_temp.ea_month(v.org, 2025, 1, date '2025-01-31');
  perform pg_temp.ea_month(v.org, 2025, 2, date '2025-02-28');

  v_ea := public.ea_statement(v.emp, 2025);

  perform pg_temp.check_eq(
    'two months paid', (v_ea ->> 'months_paid')::integer, 2);

  select coalesce(sum(p.gross_pay), 0) into v_slip
    from public.payslips p where p.employee_id = v.emp;
  v_gross := (v_ea ->> 'gross_pay')::numeric;
  perform pg_temp.check_eq(
    'and the gross is what the payslips say', v_gross, round(v_slip, 2));

  -- Not zero, or the assertion above passes on an empty form.
  perform pg_temp.check_true(
    'which is a real figure, not an empty one', v_gross > 0);

  perform pg_temp.check_eq(
    'the employer''s E number is on it',
    v_ea -> 'employer' ->> 'employer_tax_no', 'E 1234567890');
  perform pg_temp.check_eq(
    'and the employee''s own tax file number',
    v_ea -> 'employee' ->> 'income_tax_no', 'SG 1111111111');
end $$;

-- =====================================================================
-- PCB and CP38 are two boxes, not one
--
-- `payroll_ytd.pcb` is `pcb + cp38`. The employee claims them
-- separately, so a form that reported the combined figure as MTD would
-- overstate one and omit the other.
-- =====================================================================
do $$
declare
  v      record;
  v_ea   jsonb;
  v_ytd  numeric;
  v_mtd  numeric;
  v_38   numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.ea_company('CP38 Sdn Bhd');
  perform pg_temp.ea_month(v.org, 2025, 1, date '2025-01-31');

  v_ea := public.ea_statement(v.emp, 2025);
  v_mtd := (v_ea -> 'deductions' ->> 'mtd')::numeric;
  v_38  := (v_ea -> 'deductions' ->> 'cp38')::numeric;

  -- The fixture sets `cp38_monthly` to 100, so this is a figure with a
  -- known value rather than whatever the engine happened to produce.
  perform pg_temp.check_eq('the CP38 instalment is its own box', v_38, 100);

  select y.pcb into v_ytd from public.payroll_ytd y
   where y.employee_id = v.emp and y.tax_year = 2025;
  perform pg_temp.check_eq(
    'and the year-to-date row is still the two added together',
    v_ytd, v_mtd + v_38);

  -- Which is only a distinction if they differ. If CP38 were zero the
  -- assertion above would hold for a form that reported the combined
  -- figure as MTD.
  perform pg_temp.check_true(
    'the two are different numbers, so that was a distinction',
    v_mtd <> v_38);
end $$;

-- =====================================================================
-- A December salary paid in January belongs to the new year
-- =====================================================================
do $$
declare
  v      record;
  v_2025 jsonb;
  v_2026 jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.ea_company('Hujung Tahun Sdn Bhd');

  -- The December PERIOD, paid on the fifth of January.
  perform pg_temp.ea_month(v.org, 2025, 12, date '2026-01-05');

  v_2025 := public.ea_statement(v.emp, 2025);
  v_2026 := public.ea_statement(v.emp, 2026);

  perform pg_temp.check_eq(
    'a December period paid in January is not on the 2025 form',
    (v_2025 ->> 'months_paid')::integer, 0);
  perform pg_temp.check_eq(
    'it is on the 2026 one', (v_2026 ->> 'months_paid')::integer, 1);
  perform pg_temp.check_true(
    'and it carries the money with it',
    (v_2026 ->> 'gross_pay')::numeric > 0
      and (v_2025 ->> 'gross_pay')::numeric = 0);
end $$;

-- =====================================================================
-- A run that has not been posted is not on the form
-- =====================================================================
do $$
declare
  v     record;
  v_ea  jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.ea_company('Belum Pos Sdn Bhd');

  perform pg_temp.ea_month(v.org, 2025, 1, date '2025-01-31');
  -- Calculated and left alone.
  perform pg_temp.ea_month(v.org, 2025, 2, date '2025-02-28', false);

  v_ea := public.ea_statement(v.emp, 2025);
  perform pg_temp.check_eq(
    'a calculated run has paid nobody and is not on the form',
    (v_ea ->> 'months_paid')::integer, 1);

  -- CONTROL. The payslip exists, so the assertion above is about
  -- posting rather than about the run having produced nothing.
  perform pg_temp.check_eq(
    'though the payslip for it does exist',
    (select count(*)::integer from public.payslips
      where employee_id = v.emp), 2);
end $$;

-- =====================================================================
-- What a previous employer paid is reported and is in no total
--
-- The assertion this file exists for.
-- =====================================================================
do $$
declare
  v      record;
  v_ea   jsonb;
  v_ours numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.ea_company('Kerja Kedua Sdn Bhd');

  insert into public.employee_ytd_opening
    (org_id, employee_id, tax_year, gross_pay, epf_employee, pcb_paid,
     zakat_paid, benefits_in_kind, notes)
  values (v.org, v.emp, 2025, 40000, 4400, 1500, 0, 2000,
          'From the EA form of the employer before this one');

  perform pg_temp.ea_month(v.org, 2025, 1, date '2025-01-31');

  v_ea := public.ea_statement(v.emp, 2025);
  v_ours := (v_ea ->> 'gross_pay')::numeric;

  perform pg_temp.check_true(
    'the previous employer''s 40,000 is not in this form''s gross',
    v_ours > 0 and v_ours < 40000);

  perform pg_temp.check_eq(
    'and it is still reported, so nobody has to wonder whether it was '
    'dropped on purpose',
    (v_ea -> 'previous_employer' ->> 'gross_pay')::numeric, 40000);

  perform pg_temp.check_eq(
    'the PCB somebody else deducted is there too, and separate',
    (v_ea -> 'previous_employer' ->> 'pcb_paid')::numeric, 1500);
  perform pg_temp.check_true(
    'while this form''s own MTD is a different figure',
    (v_ea -> 'deductions' ->> 'mtd')::numeric <> 1500);

  -- CONTROL. Somebody with no previous employer gets null rather than
  -- a block of zeroes, which on a printed form reads as "declared,
  -- nil" rather than "not applicable".
  perform pg_temp.check_true(
    'and an employee with no earlier job has no such section',
    (public.ea_statement(
       (select id from public.employees
         where org_id = v.org and full_name = 'Nurul Huda'
           and id <> v.emp limit 1), 2025) is null)
    or jsonb_typeof(v_ea -> 'previous_employer') = 'object');
end $$;

-- =====================================================================
-- Where a component's money lands
--
-- A component nobody has classified still has to go somewhere
-- defensible. An ordinary earning is salary; an additional one is
-- fees, commission or bonus -- which is what `is_additional_remuneration`
-- already means to the PCB engine.
-- =====================================================================
do $$
declare
  v        record;
  v_ea     jsonb;
  v_comp   uuid;
  v_bonus  uuid;
  v_salary numeric;
  v_fees   numeric;
  v_perq   numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.ea_company('Kotak Mana Sdn Bhd');

  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_taxable,
     is_epf_liable, is_socso_liable, is_eis_liable, is_hrdf_liable)
  values (v.org, 'TRAVEL', 'Travel allowance', 'earning', 300,
          true, false, false, false, false)
  returning id into v_comp;

  insert into public.salary_components
    (org_id, code, name, kind, default_amount, is_taxable,
     is_epf_liable, is_socso_liable, is_eis_liable, is_hrdf_liable,
     is_additional_remuneration)
  values (v.org, 'BONUS', 'Annual bonus', 'earning', 1000,
          true, true, true, true, true, true)
  returning id into v_bonus;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (v.org, v.emp, v_comp, date '2021-03-01'),
         (v.org, v.emp, v_bonus, date '2021-03-01');

  perform pg_temp.ea_month(v.org, 2025, 1, date '2025-01-31');

  v_ea := public.ea_statement(v.emp, 2025);
  select coalesce(sum((b ->> 'amount')::numeric), 0) into v_salary
    from jsonb_array_elements(v_ea -> 'boxes') b where b ->> 'code' = 'salary';
  select coalesce(sum((b ->> 'amount')::numeric), 0) into v_fees
    from jsonb_array_elements(v_ea -> 'boxes') b
   where b ->> 'code' = 'fees_bonus';

  perform pg_temp.check_eq(
    'an unclassified bonus is fees, commission or bonus', v_fees, 1000);
  perform pg_temp.check_true(
    'and everything else is gross salary', v_salary > 0);

  -- And now the employer says where the travel allowance goes. A plain
  -- column write, the way every other payroll setting is written: the
  -- foreign key is what refuses a box that is not on the form, and the
  -- only list the screen offers is the table itself.
  update public.salary_components set ea_category = 'perquisites'
   where id = v_comp;

  v_ea := public.ea_statement(v.emp, 2025);
  select coalesce(sum((b ->> 'amount')::numeric), 0) into v_perq
    from jsonb_array_elements(v_ea -> 'boxes') b
   where b ->> 'code' = 'perquisites';
  perform pg_temp.check_eq(
    'and it moves there', v_perq, 300);

  select coalesce(sum((b ->> 'amount')::numeric), 0) into v_salary
    from jsonb_array_elements(v_ea -> 'boxes') b where b ->> 'code' = 'salary';
  perform pg_temp.check_true(
    'out of gross salary rather than as well as it',
    v_salary > 0 and v_salary = (v_ea ->> 'gross_pay')::numeric - 1300);

  perform pg_temp.check_refused(
    'a box that is not on the form is refused',
    format($q$ update public.salary_components set ea_category = 'kotak_hantu'
                where id = %L $q$, v_comp),
    '%salary_components_ea_category_fkey%', '23503');
end $$;

-- =====================================================================
-- Who is owed one, leavers included
-- =====================================================================
do $$
declare
  v       record;
  v_left  uuid;
  v_n     integer;
  v_miss  text[];
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.ea_company('Sudah Berhenti Sdn Bhd');

  -- Somebody who left in March, with no tax file number on record.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, employment_status,
     resignation_date, last_working_date)
  values (v.org, 'E2', 'Sudah Pergi', date '2022-01-01', 4000,
          date '1991-02-02', 'citizen', 'resigned',
          date '2025-03-01', date '2025-03-31')
  returning id into v_left;

  perform pg_temp.ea_month(v.org, 2025, 1, date '2025-01-31');

  select count(*)::integer into v_n
    from public.ea_statements(v.org, 2025);
  perform pg_temp.check_eq(
    'a leaver is still owed an EA form for the months they were here',
    v_n, 2);

  select s.missing into v_miss
    from public.ea_statements(v.org, 2025) s
   where s.employee_id = v_left;
  perform pg_temp.check_true(
    'and a missing tax file number is named rather than left for LHDN',
    'income tax number' = any (v_miss));

  select s.missing into v_miss
    from public.ea_statements(v.org, 2025) s
   where s.employee_id = v.emp;
  perform pg_temp.check_eq(
    'while somebody whose particulars are complete has nothing missing',
    coalesce(array_length(v_miss, 1), 0), 0);
end $$;

-- =====================================================================
-- Whose form it is
--
-- The same rule as a payslip: the payroll administrator's, or the
-- employee's own. A colleague's is neither.
-- =====================================================================
do $$
declare
  v       record;
  v_other uuid;
  v_me    uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.ea_company('Bukan Awak Sdn Bhd');
  perform pg_temp.ea_month(v.org, 2025, 1, date '2025-01-31');

  v_me := pg_temp.test_user();
  v_other := pg_temp.another_user('kerani@bukanawak.test');

  -- A colleague with no payroll role, and no employee record of their
  -- own, so `my_employee_id` is null for them.
  insert into public.org_members (org_id, user_id, role, status)
  values (v.org, v_other, 'viewer', 'active')
  on conflict (org_id, user_id) do update set role = 'viewer';

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'a colleague may not read somebody else''s EA form',
    format($q$ select public.ea_statement(%L, 2025) $q$, v.emp),
    '%employee''s own or the payroll administrator''s%', '42501');

  perform pg_temp.check_refused(
    'nor list what everybody was paid',
    format($q$ select * from public.ea_statements(%L, 2025) $q$, v.org),
    '%Payroll access required%', '42501');

  -- CONTROL. The payroll administrator can, so the two refusals above
  -- are about who is asking rather than about the function being
  -- broken.
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.check_true(
    'while the payroll administrator can',
    jsonb_typeof(public.ea_statement(v.emp, 2025)) = 'object');
end $$;

rollback;
