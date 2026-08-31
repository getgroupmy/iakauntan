-- =====================================================================
-- iAkauntan :: the payroll run, end to end
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payroll_run.sql
--
-- statutory.sql asserts the rate functions: give app.calc_statutory a
-- wage and it returns the right contribution. That leaves the half that
-- actually pays people unasserted — which wage each rate function is
-- handed. A payslip has four different wages on it, and they are four
-- different numbers:
--
--   gross          everything earned
--   epf_wage       gross less overtime and less a reimbursement
--   socso_wage     gross less a reimbursement, overtime included
--   taxable        the same, and it is not the EPF wage
--
-- Wire overtime into the EPF base by mistake and every rate assertion
-- in statutory.sql still passes, because every rate is still correct.
-- The employer simply over-contributes on every payslip, for ever. So
-- the fixture below is built so that no two of those bases share a
-- value: if the run reads the wrong one, the number it produces cannot
-- accidentally be right.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_period  uuid;
  v_run     uuid;
  v_a       uuid;   -- full month, overtime, a claim, CP38 and zakat
  v_b       uuid;   -- joined on the 17th, aged 62
  v_c       uuid;   -- an allowance and two days of unpaid leave
  v_absent  uuid;   -- hired after the period closed
  v_leave   uuid;
  v_comp    uuid;
  v_slip    uuid;
  v_pcb_a   numeric;
  v_pcb_b   numeric;
  v_pcb_c   numeric;
  r         record;
begin
  v_org := pg_temp.test_org('Payroll Wiring Co');

  -- 1.0% of the levy's own wage, which is the point of asserting it at
  -- all: it is charged neither on gross pay nor on the EPF wage.
  insert into public.payroll_settings (org_id, hrdf_category)
  values (v_org, 'mandatory_10plus')
  on conflict (org_id) do update set hrdf_category = excluded.hrdf_category;

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-01', date '2026-01-01', date '2026-01-31',
          date '2026-01-31')
  returning id into v_period;

  -- ------------------------------------------------------------------
  -- A: 25 working days of 8 hours, so the hourly rate is exactly
  -- RM25.00 and the overtime is a number a person can check.
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status,
     cp38_monthly, zakat_monthly)
  values (v_org, 'W1', 'Full month, overtime and a claim',
          date '2020-01-01', 5000, 25, 8,
          date '1992-04-15', 'single', 'citizen', 50, 25)
  returning id into v_a;

  -- Ten hours of ordinary overtime, spread over two days because the
  -- table is one row per employee per date.
  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_normal_minutes)
  values (v_org, v_a, date '2026-01-12', 360),
         (v_org, v_a, date '2026-01-13', 240);

  -- A reimbursement, not wages: it is paid through payroll and it is
  -- liable for nothing at all.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, status,
     total_amount, approved_amount, pay_with_payroll)
  values (v_org, 'EC-W1-1', v_a, date '2026-01-15', 'approved',
          300, 300, true);

  -- ------------------------------------------------------------------
  -- B: hired on the 17th of a 31 day month, and 62 years old. 15/31 of
  -- RM6,200 is exactly RM3,000.
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'W2', 'Joined on the seventeenth, aged sixty-two',
          date '2026-01-17', 6200, 25, 8,
          date '1963-06-10', 'married', 'citizen')
  returning id into v_b;

  -- ------------------------------------------------------------------
  -- C: an allowance that is taxable but not EPF wages, and two days of
  -- unpaid leave, which is an earning line with a minus in front of it.
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'W3', 'An allowance and two days unpaid',
          date '2019-05-01', 3120, 26, 8,
          date '1988-11-02', 'single', 'citizen')
  returning id into v_c;

  -- Travelling allowance: taxable, and outside all four contributions.
  -- The levy flag is stated rather than left to its default, because
  -- `0370` made it a decision and the PSMB Act 2001 excludes a
  -- travelling allowance by name.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable)
  values (v_org, 'TRAVEL', 'Travel allowance', 'earning', 200,
          true, false, false, false, false)
  returning id into v_comp;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (v_org, v_c, v_comp, date '2019-05-01');

  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'UNPAID', 'Unpaid leave', false)
  returning id into v_leave;

  insert into public.leave_requests
    (org_id, request_no, employee_id, leave_type_id,
     start_date, end_date, total_days, status)
  values (v_org, 'LV-W3-1', v_c, v_leave,
          date '2026-01-20', date '2026-01-21', 2, 'approved');

  -- ------------------------------------------------------------------
  -- And somebody who does not work here yet.
  -- ------------------------------------------------------------------
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'W4', 'Starts next month', date '2026-02-01', 9000,
          date '1995-03-03', 'citizen')
  returning id into v_absent;

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-01')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  -- ==================================================================
  -- A: the four wages, which are four different numbers
  -- ==================================================================
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_a;

  perform pg_temp.check_eq('A basic salary', r.basic_salary, 5000.00);
  perform pg_temp.check_eq('A overtime hours', r.ot_hours, 10.00);
  -- 5000 / 25 days / 8 hours = RM25.00 an hour, at time and a half.
  perform pg_temp.check_eq('A overtime pay', r.ot_amount, 375.00);
  perform pg_temp.check_eq('A claims carried onto the payslip',
    r.claims_amount, 300.00);

  perform pg_temp.check_eq('A gross is basic, overtime and the claim',
    r.gross_pay, 5675.00);
  -- The assertion this whole file exists for.
  perform pg_temp.check_eq('A EPF wage excludes overtime and the claim',
    r.epf_wage, 5000.00);
  perform pg_temp.check_eq('A SOCSO wage includes overtime, not the claim',
    r.socso_wage, 5375.00);
  perform pg_temp.check_eq('A EIS wage likewise', r.eis_wage, 5375.00);
  perform pg_temp.check_eq('A taxable income excludes only the claim',
    r.taxable_income, 5375.00);

  -- 11% and 13% of RM5,000, rounded up to the ringgit.
  perform pg_temp.check_eq('A EPF employee', r.epf_employee, 550);
  perform pg_temp.check_eq('A EPF employer', r.epf_employer, 650);
  -- Charged on 5,375: the rate function agrees, which is the proof the
  -- run handed it the overtime-inclusive wage.
  perform pg_temp.check_eq('A SOCSO employee', r.socso_employee, 26.90);
  perform pg_temp.check_eq('A SOCSO employer', r.socso_employer, 94.05);
  perform pg_temp.check_eq('A EIS employee', r.eis_employee, 10.75);
  perform pg_temp.check_eq('A EIS employer', r.eis_employer, 10.75);
  -- 1% of the basic salary. On gross it would have been 56.75, and on
  -- the EPF wage it agrees here only because EPF happens to exclude
  -- overtime too — `hrdf_levy.sql` is where the two come apart.
  perform pg_temp.check_eq('A levy wage is the basic salary',
    r.hrdf_wage, 5000.00);
  perform pg_temp.check_eq('A HRDF levy is charged on it', r.hrdf, 50.00);

  perform pg_temp.check_eq('A CP38 is carried across', r.cp38, 50.00);
  perform pg_temp.check_eq('A zakat is carried across', r.zakat, 25.00);

  v_pcb_a := r.pcb;
  perform pg_temp.check_eq('A PCB is computed on the taxable wage',
    v_pcb_a,
    (select c.pcb from app.calc_pcb(v_a, 5375, 550, 26.90 + 10.75, 25,
                                    date '2026-01-31') c));
  perform pg_temp.check_true('A PCB is a real deduction, not zero',
    v_pcb_a > 0);

  perform pg_temp.check_eq('A deductions are the six employee items',
    r.total_deductions, 550 + 26.90 + 10.75 + v_pcb_a + 50 + 25);
  -- The employer's contributions are the employer's, so they leave net
  -- pay alone, and the RM300 reimbursement reaches the bank untouched.
  perform pg_temp.check_eq('A net pay is gross less those deductions',
    r.net_pay, 5675.00 - (550 + 26.90 + 10.75 + v_pcb_a + 50 + 25));

  v_slip := r.id;

  perform pg_temp.check_eq('A has one line per earning',
    (select count(*) from public.payslip_lines
      where payslip_id = v_slip and kind = 'earning'), 3);

  -- Overtime is wages for tax, for SOCSO and for EIS, and is not EPF
  -- wages. Four booleans, and the third one is the one that moves.
  select * into r from public.payslip_lines
   where payslip_id = v_slip and code = 'OT';
  perform pg_temp.check_eq('A overtime line amount', r.amount, 375.00);
  perform pg_temp.check_eq('A overtime line rate', r.rate, 25.0000);
  perform pg_temp.check_true('A overtime is taxable', r.is_taxable);
  perform pg_temp.check_true('A overtime is not EPF wages',
    not r.is_epf_liable);
  perform pg_temp.check_true('A overtime is SOCSO wages',
    r.is_socso_liable);
  perform pg_temp.check_true('A overtime is EIS wages', r.is_eis_liable);

  -- A reimbursement is liable for nothing whatsoever.
  select * into r from public.payslip_lines
   where payslip_id = v_slip and code = 'CLAIMS';
  perform pg_temp.check_eq('A claim line amount', r.amount, 300.00);
  perform pg_temp.check_true('A claim is not taxable', not r.is_taxable);
  perform pg_temp.check_true('A claim is not EPF wages',
    not r.is_epf_liable);
  perform pg_temp.check_true('A claim is not SOCSO wages',
    not r.is_socso_liable);
  perform pg_temp.check_true('A claim is not EIS wages',
    not r.is_eis_liable);

  perform pg_temp.check_eq('A owes six deductions',
    (select count(*) from public.payslip_lines
      where payslip_id = v_slip and kind = 'deduction'), 6);
  perform pg_temp.check_eq('A employer contributions are EPF, SOCSO, EIS and HRDF',
    (select count(*) from public.payslip_lines
      where payslip_id = v_slip and kind = 'employer_contribution'), 4);

  -- ==================================================================
  -- B: fifteen days of a thirty-one day month, and past sixty
  -- ==================================================================
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_b;

  perform pg_temp.check_eq('B is paid 15/31 of the month',
    r.basic_salary, 3000.00);
  perform pg_temp.check_eq('B gross', r.gross_pay, 3000.00);

  -- The employee side of EPF stops at 60; the employer side falls to 4%.
  perform pg_temp.check_eq('B EPF employee stops at sixty',
    r.epf_employee, 0);
  perform pg_temp.check_eq('B EPF employer is 4% at sixty',
    r.epf_employer, 120);

  -- Act 800 is employment injury only, so there is no employee side.
  perform pg_temp.check_eq('B SOCSO employee under Act 800 is nil',
    r.socso_employee, 0);
  perform pg_temp.check_eq('B SOCSO employer under Act 800',
    r.socso_employer, 37.50);

  -- EIS is not charged at all past sixty, eligibility flag or no.
  perform pg_temp.check_true('B is still flagged EIS eligible',
    (select eis_eligible from public.employees where id = v_b));
  perform pg_temp.check_eq('B EIS employee is nil past sixty',
    r.eis_employee, 0);
  perform pg_temp.check_eq('B EIS employer is nil past sixty',
    r.eis_employer, 0);
  perform pg_temp.check_eq('B HRDF on the pro-rated wage', r.hrdf, 30.00);

  v_pcb_b := r.pcb;
  v_slip := r.id;

  -- The pro-ration is on the line as well as in the total, because the
  -- payslip has to say why it is short.
  perform pg_temp.check_eq('B basic line says which days were worked',
    (select description from public.payslip_lines
      where payslip_id = v_slip and code = 'BASIC'),
    'Basic salary (15 of 31 days)');

  -- ==================================================================
  -- C: an allowance, and unpaid leave as a negative earning
  -- ==================================================================
  select * into r from public.payslips
   where run_id = v_run and employee_id = v_c;

  perform pg_temp.check_eq('C unpaid days', r.unpaid_leave_days, 2.00);
  -- 3120 / 26 working days = RM120 a day.
  perform pg_temp.check_eq('C unpaid leave amount',
    r.unpaid_leave_amount, 240.00);

  -- 3120 basic + 200 allowance - 240 unpaid.
  perform pg_temp.check_eq('C gross', r.gross_pay, 3080.00);
  -- The allowance is not EPF wages; the unpaid leave is, and it is
  -- negative, so it comes off the base as well as off the pay.
  perform pg_temp.check_eq('C EPF wage is basic less the unpaid days',
    r.epf_wage, 2880.00);
  perform pg_temp.check_eq('C SOCSO wage likewise', r.socso_wage, 2880.00);
  perform pg_temp.check_eq('C taxable income includes the allowance',
    r.taxable_income, 3080.00);

  -- 11% and 13% of 2,880, each rounded up to the next ringgit.
  perform pg_temp.check_eq('C EPF employee rounds up', r.epf_employee, 317);
  perform pg_temp.check_eq('C EPF employer rounds up', r.epf_employer, 375);
  perform pg_temp.check_eq('C SOCSO employee', r.socso_employee, 14.40);
  perform pg_temp.check_eq('C SOCSO employer', r.socso_employer, 50.40);
  perform pg_temp.check_eq('C EIS employee', r.eis_employee, 5.75);
  -- 2,880 again, and for a different reason than EPF's: the travelling
  -- allowance is out under the PSMB Act, not because EPF ignores it.
  perform pg_temp.check_eq('C levy wage excludes the travel allowance',
    r.hrdf_wage, 2880.00);
  perform pg_temp.check_eq('C HRDF', r.hrdf, 28.80);

  v_pcb_c := r.pcb;
  v_slip := r.id;

  select * into r from public.payslip_lines
   where payslip_id = v_slip and code = 'UNPAID';
  perform pg_temp.check_eq('C unpaid leave is a negative earning',
    r.amount, -240.00);
  perform pg_temp.check_eq('C and it is an earning, not a deduction',
    r.kind::text, 'earning');
  perform pg_temp.check_true('C unpaid leave is EPF liable, so it reduces the base',
    r.is_epf_liable);

  select * into r from public.payslip_lines
   where payslip_id = v_slip and code = 'TRAVEL';
  perform pg_temp.check_eq('C allowance takes the component default',
    r.amount, 200.00);
  perform pg_temp.check_true('C allowance is taxable', r.is_taxable);
  perform pg_temp.check_true('C allowance is not EPF wages',
    not r.is_epf_liable);
  perform pg_temp.check_true('C allowance keeps its component id',
    r.component_id = v_comp);

  -- ==================================================================
  -- The run, and who is not on it
  -- ==================================================================
  perform pg_temp.check_eq('somebody hired next month has no payslip',
    (select count(*) from public.payslips
      where run_id = v_run and employee_id = v_absent), 0);

  select * into r from public.payroll_runs where id = v_run;
  perform pg_temp.check_eq('the run is calculated', r.status::text,
    'calculated');
  perform pg_temp.check_eq('three employees were paid', r.employee_count, 3);
  perform pg_temp.check_eq('total gross', r.total_gross,
    5675.00 + 3000.00 + 3080.00);
  perform pg_temp.check_eq('total EPF employee', r.total_epf_employee,
    550 + 0 + 317);
  perform pg_temp.check_eq('total EPF employer', r.total_epf_employer,
    650 + 120 + 375);
  perform pg_temp.check_eq('total SOCSO employer', r.total_socso_employer,
    94.05 + 37.50 + 50.40);
  perform pg_temp.check_eq('total EIS employee', r.total_eis_employee,
    10.75 + 0 + 5.75);
  perform pg_temp.check_eq('total HRDF', r.total_hrdf,
    50.00 + 30.00 + 28.80);
  -- CP38 is remitted with PCB, so the run's tax line carries both.
  perform pg_temp.check_eq('total PCB carries CP38 with it',
    r.total_pcb, v_pcb_a + v_pcb_b + v_pcb_c + 50);
  perform pg_temp.check_eq('total zakat', r.total_zakat, 25.00);

  perform pg_temp.check_eq('total net is the sum of the payslips',
    r.total_net,
    (select sum(net_pay) from public.payslips where run_id = v_run));
  -- What the company parts with: the gross, plus its own contributions.
  perform pg_temp.check_eq('total employer cost',
    r.total_employer_cost,
    r.total_gross + r.total_epf_employer + r.total_socso_employer
                  + r.total_eis_employer + r.total_hrdf);

  -- ==================================================================
  -- Running it again replaces the payslips rather than adding to them
  -- ==================================================================
  perform public.calculate_payroll_run(v_run);
  perform pg_temp.check_eq('a second calculation leaves three payslips',
    (select count(*) from public.payslips where run_id = v_run), 3);
  perform pg_temp.check_eq('and the same total',
    (select total_gross from public.payroll_runs where id = v_run),
    5675.00 + 3000.00 + 3080.00);

  -- Once it is posted the figures are history.
  update public.payroll_runs set status = 'posted' where id = v_run;
  begin
    perform public.calculate_payroll_run(v_run);
    raise exception 'FAIL: a posted run was recalculated';
  exception when sqlstate '22023' then
    raise notice 'ok   a posted run cannot be recalculated';
  end;

  update public.payroll_runs set status = 'draft' where id = v_run;

  begin
    perform public.calculate_payroll_run(gen_random_uuid());
    raise exception 'FAIL: an unknown run was calculated';
  exception when sqlstate 'P0002' then
    raise notice 'ok   an unknown run is rejected';
  end;

  perform pg_temp.sign_in_as(pg_temp.another_user('outsider@example.test'));
  begin
    perform public.calculate_payroll_run(v_run);
    raise exception 'FAIL: a non-member calculated a payroll run';
  exception when sqlstate '42501' then
    raise notice 'ok   a non-member cannot calculate a payroll run';
  end;

  perform pg_temp.sign_out();
end $$;

rollback;
