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

  -- ------------------------------------------------------------------
  -- The payslip foots against its own itemisation
  -- ------------------------------------------------------------------
  -- `payslip_pdf.dart` prints the *lines* as the itemisation and the
  -- *scalars* beside them as the totals of those lines: gross pay under
  -- the earnings, total deductions under the deductions, net pay under
  -- both.
  --
  -- **These three cannot fail as the engine is written today, and that
  -- is the point of asserting them.** `calculate_payroll_run` derives
  -- all three from the lines --
  --
  --     v_base.gross     := sum(payslip_lines where kind = 'earning')
  --     v_deduct         := sum(payslip_lines where kind = 'deduction')
  --     net_pay          := v_base.gross - v_deduct
  --
  -- -- so what is pinned here is the *derivation*, not the arithmetic.
  -- The failure this would catch is a future change that sets one of
  -- the scalars from somewhere other than the lines, which is exactly
  -- what `complete_pos_sale` does to a sales document's `tax_amount`
  -- and how `0410`'s service charge came to be missing from four
  -- separate places. On a payslip that would read as an employee's
  -- earnings not adding up to their own gross.
  --
  -- Reported honestly: mutating the engine to break either identity is
  -- caught by the named-figure assertions earlier in this file before
  -- reaching these, so they killed nothing that was not already dying.
  -- They are a pin on the derivation and are worth exactly that much.
  --
  -- Asked of every payslip in the run rather than of a named one, so a
  -- future employee shape is covered by the same assertion.
  for r in select * from public.payslips where run_id = v_run loop
    perform pg_temp.check_eq(
      'the earnings lines add up to the gross pay printed beside them',
      (select coalesce(sum(amount), 0) from public.payslip_lines
        where payslip_id = r.id and kind = 'earning'),
      r.gross_pay);
    perform pg_temp.check_eq(
      'and the deduction lines to the total deductions',
      (select coalesce(sum(amount), 0) from public.payslip_lines
        where payslip_id = r.id and kind = 'deduction'),
      r.total_deductions);
    perform pg_temp.check_eq(
      'and what is left is the net pay',
      round(r.gross_pay - r.total_deductions, 2), r.net_pay);
  end loop;

  -- And there was more than one shape of payslip to ask it of, so the
  -- loop above did not pass by running once over an easy case.
  perform pg_temp.check_true('on three payslips, not one',
    (select count(*) from public.payslips where run_id = v_run) = 3);
  perform pg_temp.check_true('one of which has no deductions at all',
    exists (select 1 from public.payslips
             where run_id = v_run and total_deductions = 0));
  perform pg_temp.check_true('and one of which has several',
    exists (select 1 from public.payslips p
             where p.run_id = v_run
               and (select count(*) from public.payslip_lines l
                     where l.payslip_id = p.id and l.kind = 'deduction') >= 3));
end $$;

-- ---------------------------------------------------------------------
-- The bonus that was taxed as though it came every month (0446)
--
-- `calc_pcb` projects the month's taxable pay over the months left in
-- the year, which is right for a salary and wrong for a bonus. Measured
-- before 0446, on RM5,000 a month paid on 25 February 2026: an ordinary
-- month deducted 90.95, and the same month with a 12,000 bonus rolled
-- into it deducted **2,528.85** -- close to the whole year's tax, taken
-- in one month, because eleven months were still to come and the bonus
-- was multiplied by eleven.
--
-- The year still came out right, which is what hid it: later months
-- subtract what has already been deducted. What is wrong is every month
-- in between, and the employee who leaves before December never gets
-- the correction.
--
-- February matters here. A December bonus is unaffected -- the factor
-- is 1 -- which is why a suite that pays in a single month never saw
-- this.
--
-- The three figures are asserted rather than described, against the
-- 2026 PCB schedule this repository seeds. If a published schedule
-- moves them, this file is where that should be noticed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Bonus Bulan Dua Sdn Bhd');
  v_emp    uuid;
  v_plain  numeric;
  v_split  numeric;
  v_rolled numeric;
begin
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'B1', 'Paid a bonus in February', date '2020-01-01',
          5000, 26, 8, date '1990-01-01', 'single', 'citizen')
  returning id into v_emp;

  select c.pcb into v_plain
    from app.calc_pcb(v_emp, 5000, 550, 30, 0, date '2026-02-25') c;
  perform pg_temp.check_eq(
    'five thousand in February deducts 90.95', v_plain, 90.95);

  -- Seventeen thousand of *ordinary* pay: annualising it is correct,
  -- and this is the figure the bonus month used to produce.
  select c.pcb into v_rolled
    from app.calc_pcb(v_emp, 17000, 550, 30, 0, date '2026-02-25') c;
  perform pg_temp.check_eq(
    'seventeen thousand of salary deducts 2528.85', v_rolled, 2528.85);

  -- The same money, said to be a bonus.
  select c.pcb into v_split
    from app.calc_pcb(v_emp, 5000, 550, 30, 0, date '2026-02-25',
                      12000, 0) c;
  perform pg_temp.check_eq(
    'the same money as a bonus deducts 994.45', v_split, 994.45);

  -- The two claims that make it the right 994.45 rather than a smaller
  -- arbitrary one: the bonus is charged at all, and it is charged once
  -- rather than eleven times.
  perform pg_temp.check_true('a bonus is charged something',
    v_split > v_plain);
  perform pg_temp.check_true(
    'and not as though it came every month',
    v_split < v_plain + (v_rolled - v_plain) / 2);
end $$;

-- ---------------------------------------------------------------------
-- And the flag has to reach the payslip line
--
-- The split is only as good as the run's knowledge of which earnings
-- are which, and that travels from `salary_components` onto
-- `payslip_lines` through the insert that copies a component's flags. A
-- new column the copier was never told about is the failure this
-- project has met five times, so it is asserted rather than assumed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Bonus Melalui Larian Sdn Bhd');
  v_emp    uuid;
  v_period uuid;
  v_run    uuid;
  v_comp   uuid;
  v_plain_comp uuid;
  v_slip   uuid;
begin
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-02', date '2026-02-01', date '2026-02-28',
          date '2026-02-25')
  returning id into v_period;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day,
     date_of_birth, marital_status, residency_status)
  values (v_org, 'B2', 'Gets the February bonus', date '2020-01-01',
          5000, 26, 8, date '1990-01-01', 'single', 'citizen')
  returning id into v_emp;

  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable, is_additional_remuneration)
  values (v_org, 'BONUS', 'Annual bonus', 'earning', 12000,
          true, true, false, false, false, true)
  returning id into v_comp;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (v_org, v_emp, v_comp, date '2020-01-01');

  -- An ordinary allowance, created the way every component in this
  -- schema was created before 0446: without mentioning the flag at
  -- all. It must not become additional remuneration by default, or
  -- every existing allowance silently stops being annualised and
  -- every company's PCB moves the day this migration applies.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable)
  values (v_org, 'TRAVEL', 'Travel allowance', 'earning', 200,
          true, false, false, false, false)
  returning id into v_plain_comp;

  insert into public.employee_salary_components
    (org_id, employee_id, component_id, effective_from)
  values (v_org, v_emp, v_plain_comp, date '2020-01-01');

  insert into public.payroll_runs (org_id, period_id, run_no)
  values (v_org, v_period, 'PAY-2026-02')
  returning id into v_run;

  perform public.calculate_payroll_run(v_run);

  select p.id into v_slip from public.payslips p
   where p.run_id = v_run and p.employee_id = v_emp;

  perform pg_temp.check_true('the flag reaches the payslip line',
    (select l.is_additional_remuneration from public.payslip_lines l
      where l.payslip_id = v_slip and l.code = 'BONUS'));

  perform pg_temp.check_true('and the salary line is not marked',
    (select not l.is_additional_remuneration from public.payslip_lines l
      where l.payslip_id = v_slip and l.code = 'BASIC'));

  perform pg_temp.check_true(
    'nor is an allowance that never mentioned the flag',
    (select not l.is_additional_remuneration from public.payslip_lines l
      where l.payslip_id = v_slip and l.code = 'TRAVEL'));

  -- The whole point, through the run rather than the function: 17,200
  -- of pay in February -- 5,000 salary, 200 allowance and a 12,000
  -- bonus -- and the deduction is the one the split produces, not the
  -- annualised figure the same money used to attract.
  --
  -- Neither 994.45 nor 2,528.85, and both differences are the fixture
  -- rather than the method. The allowance is 200 a month of ordinary
  -- pay, so it *is* annualised, which is correct and raises the normal
  -- half. The bonus is EPF-liable, so the month's employee EPF is
  -- computed on the larger wage and the share belonging to the bonus
  -- enters the year's relief once alongside the bonus itself.
  perform pg_temp.check_eq('the run deducts the split figure',
    (select p.pcb from public.payslips p where p.id = v_slip), 1115.30);
end $$;


-- ---------------------------------------------------------------------
-- The ten a mutation sweep found
-- ---------------------------------------------------------------------
-- Thirty-five one-line mutants of `calculate_payroll_run` against
-- twenty-seven test files. Twenty-five die, which is what CLAUDE.md's
-- rule about statutory arithmetic is supposed to buy: the EPF category,
-- the SOCSO age split, the PCB annualisation, the additional
-- remuneration, the relief for zakat and for SOCSO and EIS, the
-- overtime multipliers, the proration for a joiner -- all held.
--
-- The ten that survived are not rates. They are the things AROUND the
-- rates, and they fall into three groups.
--
--   * THE ELIGIBILITY FLAGS. Every employee row carries epf_eligible,
--     socso_eligible and hrdf_eligible, and all three could be ignored
--     with nothing noticing. Contributing for somebody who is not
--     liable is not a rounding error: it is money deducted from a
--     person's pay and remitted to a board that will not credit it.
--
--   * THE CEILINGS. SOCSO and EIS are charged on an INSURED wage, which
--     stops at a ceiling; the payslip records that insured figure and
--     not the whole wage. Replace app.insured_wage with the raw wage
--     and every contribution stays right while the wage printed beside
--     it, and reported on the Borang, is wrong for everybody paid above
--     the ceiling.
--
--   * WHETHER ANYBODY CHECKED. schedules_verified is what tells a
--     payroll officer these figures came from a gazetted schedule
--     somebody has confirmed. It could be set to true unconditionally.
--     That is worse than a wrong number, because it is a wrong number
--     wearing a badge.
--
-- Two more are arithmetic after all: voluntary EPF rounds UP to the
-- ringgit and could round down, and the public holiday overtime
-- multiplier could quietly become the rest day one.
do $$
declare
  v_org     uuid;
  v_period  uuid;
  v_run     uuid;
  v_optout  uuid;   -- liable for nothing
  v_high    uuid;   -- paid above every ceiling
  v_vol     uuid;   -- voluntary EPF at a rate that exposes the rounding
  v_hol     uuid;   -- overtime on a public holiday only
  v_sched   uuid;
  v_comp    uuid;
  v_slip    uuid;
  v_ins_soc numeric;
  v_ins_eis numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Payroll Sapu Sdn Bhd');
  insert into public.payroll_settings (org_id, hrdf_category)
  values (v_org, 'mandatory_10plus')
  on conflict (org_id) do update set hrdf_category = excluded.hrdf_category;

  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-03', date '2026-03-01', date '2026-03-31',
          date '2026-03-31')
  returning id into v_period;

  -- ==================================================================
  -- 1. Somebody liable for none of it
  --
  -- All three flags off. The rates are right and would be charged
  -- anyway: what is asserted here is that the question was asked.
  -- ==================================================================
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day, date_of_birth,
     marital_status, residency_status,
     epf_eligible, socso_eligible, eis_eligible, hrdf_eligible)
  values (v_org, 'X1', 'Liable for nothing', date '2020-01-01', 4000,
          25, 8, date '1990-01-01', 'single', 'citizen',
          false, false, false, false)
  returning id into v_optout;

  -- ==================================================================
  -- 2. Somebody paid above every ceiling
  --
  -- RM20,000 is above the SOCSO and EIS insured maxima, so the wage
  -- recorded on the payslip must be the CEILING and not the pay.
  -- ==================================================================
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day, date_of_birth,
     marital_status, residency_status)
  values (v_org, 'X2', 'Paid above the ceilings', date '2020-01-01', 20000,
          25, 8, date '1985-01-01', 'married', 'citizen')
  returning id into v_high;

  -- ==================================================================
  -- 3. Voluntary EPF, at a rate whose exact answer is not a ringgit
  --
  -- RM3,333 at 1% is 33.33, which EPF rounds UP to 34. Rounding down
  -- gives 33 -- one ringgit a month, on every member with a voluntary
  -- rate, in the wrong direction for the member.
  -- ==================================================================
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day, date_of_birth,
     marital_status, residency_status, epf_voluntary_employee_rate)
  values (v_org, 'X3', 'Voluntary EPF at one per cent', date '2020-01-01',
          3333, 25, 8, date '1990-01-01', 'single', 'citizen', 1)
  returning id into v_vol;

  -- ==================================================================
  -- 4. Overtime on a public holiday and on nothing else
  --
  -- Eight hours at RM25 an hour. At the holiday multiplier of three
  -- that is RM600; at the rest day multiplier of two it is RM400. Only
  -- holiday minutes, so the two answers cannot be confused with the
  -- ordinary rate.
  -- ==================================================================
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     working_days_per_month, working_hours_per_day, date_of_birth,
     marital_status, residency_status)
  values (v_org, 'X4', 'Worked the holiday', date '2020-01-01', 5000,
          25, 8, date '1990-01-01', 'single', 'citizen')
  returning id into v_hol;
  insert into public.attendance_records
    (org_id, employee_id, work_date, ot_holiday_minutes)
  values (v_org, v_hol, date '2026-03-09', 480);

  -- And a bonus for the same person, because it is the one thing that
  -- makes the EPF wage and the levy's wage differ. A bonus is EPF
  -- wages and is named in the PSMB Act's exclusions, so it is not levy
  -- wages -- without it both bases are the basic salary and "charged on
  -- the wrong wage" is a mutation no fixture can see.
  insert into public.salary_components
    (org_id, code, name, kind, default_amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
     is_hrdf_liable, is_additional_remuneration)
  values (v_org, 'BONUS-S', 'Bonus', 'earning', 3000,
          true, true, false, false, false, true)
  returning id into v_comp;
  insert into public.employee_salary_components
    (org_id, employee_id, component_id, amount, effective_from)
  values (v_org, v_hol, v_comp, 3000, date '2020-01-01');

  insert into public.payroll_runs (org_id, period_id, run_no, status)
  values (v_org, v_period, 'PR-SAPU-1', 'draft') returning id into v_run;
  perform public.calculate_payroll_run(v_run);

  -- ------------------------------------------------------------------
  -- What the flags did
  -- ------------------------------------------------------------------
  select id into v_slip from public.payslips
   where run_id = v_run and employee_id = v_optout;

  perform pg_temp.check_eq('somebody not in EPF has no EPF deducted',
    (select epf_employee from public.payslips where id = v_slip), 0::numeric);
  perform pg_temp.check_eq('nor contributed for',
    (select epf_employer from public.payslips where id = v_slip), 0::numeric);
  perform pg_temp.check_eq('somebody not covered by SOCSO has none deducted',
    (select socso_employee from public.payslips where id = v_slip), 0::numeric);
  perform pg_temp.check_eq('nor contributed for',
    (select socso_employer from public.payslips where id = v_slip), 0::numeric);
  perform pg_temp.check_eq('and no levy is paid for them',
    (select hrdf from public.payslips where id = v_slip), 0::numeric);

  -- And they were paid, or the five zeroes above are satisfied by an
  -- employee the run skipped entirely.
  perform pg_temp.check_eq('and they are on the payroll all the same',
    (select gross_pay from public.payslips where id = v_slip), 4000::numeric);

  -- ------------------------------------------------------------------
  -- The insured wage, which is not the wage
  -- ------------------------------------------------------------------
  select id into v_slip from public.payslips
   where run_id = v_run and employee_id = v_high;

  v_ins_soc := app.insured_wage('socso', 'act4', 20000, date '2026-03-31');
  v_ins_eis := app.insured_wage('eis', 'default', 20000, date '2026-03-31');

  perform pg_temp.check_true(
    'the ceiling is below the pay, or this asserts nothing',
    v_ins_soc < 20000 and v_ins_eis < 20000);
  perform pg_temp.check_eq(
    'the payslip records the SOCSO wage the contribution was charged on',
    (select socso_wage from public.payslips where id = v_slip), v_ins_soc);
  perform pg_temp.check_eq('and the EIS one',
    (select eis_wage from public.payslips where id = v_slip), v_ins_eis);
  -- The EPF wage has no ceiling, so it is the pay -- which is what
  -- makes the two above a statement about ceilings rather than about
  -- wages being recorded at all.
  perform pg_temp.check_eq('while the EPF wage is the whole pay',
    (select epf_wage from public.payslips where id = v_slip), 20000::numeric);

  -- ------------------------------------------------------------------
  -- Voluntary EPF rounds up
  -- ------------------------------------------------------------------
  select id into v_slip from public.payslips
   where run_id = v_run and employee_id = v_vol;
  perform pg_temp.check_eq(
    'one per cent of RM3,333 is RM34 of voluntary EPF, not RM33',
    (select epf_employee from public.payslips where id = v_slip)
      - (select c.employee_amount from app.calc_statutory('epf',
           app.epf_category('citizen', 36), 3333, date '2026-03-31') c),
    34::numeric);

  -- ------------------------------------------------------------------
  -- The holiday multiplier is the holiday one
  -- ------------------------------------------------------------------
  select id into v_slip from public.payslips
   where run_id = v_run and employee_id = v_hol;
  perform pg_temp.check_eq(
    'eight hours on a public holiday is three times the hourly rate',
    (select ot_amount from public.payslips where id = v_slip), 600::numeric);

  -- ------------------------------------------------------------------
  -- Whether anybody checked the schedules
  --
  -- `schedules_verified` is what tells a payroll officer these figures
  -- came from a gazetted schedule somebody has confirmed. Unasserted,
  -- it could be set true unconditionally -- a wrong number wearing a
  -- badge.
  --
  -- The seeded schedules are all `is_verified = false`, which is the
  -- honest default: nobody at this company has checked them against the
  -- gazette. So the flag reads false here, and that is asserted FIRST,
  -- because it is the direction that catches a function claiming
  -- verification it does not have.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'unchecked schedules are not reported as verified',
    (select count(*)::integer from public.payslips
      where run_id = v_run and schedules_verified), 0);

  -- Verified, and it says so -- or the assertion above holds for a
  -- function that never sets the flag at all.
  update public.statutory_schedules set is_verified = true
   where body in ('epf', 'socso', 'eis', 'pcb', 'hrdf');
  update public.payroll_runs set status = 'draft' where id = v_run;
  perform public.calculate_payroll_run(v_run);
  perform pg_temp.check_eq('and once checked, they are',
    (select count(*)::integer from public.payslips
      where run_id = v_run and not schedules_verified), 0);

  -- Now the levy alone. It reaches the payslip by a different road from
  -- the other four -- read once before the loop rather than through
  -- app.calc_statutory -- so its verification had to be added by hand
  -- and can be dropped by hand.
  select s.id into v_sched
    from public.statutory_rates r
    join public.statutory_schedules s on s.id = r.schedule_id
   where s.body = 'hrdf' and r.category = 'mandatory_10plus'
     and s.effective_from <= date '2026-03-31'
     and (s.effective_to is null or s.effective_to >= date '2026-03-31')
   order by s.effective_from desc limit 1;
  perform pg_temp.check_true('the levy has a schedule of its own',
    v_sched is not null);
  update public.statutory_schedules set is_verified = false where id = v_sched;

  update public.payroll_runs set status = 'draft' where id = v_run;
  perform public.calculate_payroll_run(v_run);
  perform pg_temp.check_true(
    'an unchecked levy schedule is not reported as verified either',
    (select not schedules_verified from public.payslips
      where run_id = v_run and employee_id = v_high));
  -- And somebody the levy is not due for is unaffected by it, which is
  -- what "it counts only where it was actually consulted" means.
  perform pg_temp.check_true(
    'while somebody the levy is not due for is still verified',
    (select schedules_verified from public.payslips
      where run_id = v_run and employee_id = v_optout));
  update public.statutory_schedules set is_verified = true where id = v_sched;

  -- ------------------------------------------------------------------
  -- The levy is charged on its own wage, and only where it is due
  -- ------------------------------------------------------------------
  update public.payroll_runs set status = 'draft' where id = v_run;
  perform public.calculate_payroll_run(v_run);
  select id into v_slip from public.payslips
   where run_id = v_run and employee_id = v_hol;
  perform pg_temp.check_true(
    'overtime and the bonus are in the pay but not in the levy''s wage',
    (select hrdf_wage < gross_pay from public.payslips where id = v_slip));
  perform pg_temp.check_true(
    'and the levy''s wage is not the EPF wage either -- the bonus is in '
    'one and not the other',
    (select hrdf_wage <> epf_wage from public.payslips where id = v_slip));
  perform pg_temp.check_eq('so the levy is charged on the levy''s wage',
    (select hrdf from public.payslips where id = v_slip),
    (select round(hrdf_wage * 1.0 / 100, 2) from public.payslips
      where id = v_slip));

  raise notice 'ok   payroll: the ten a sweep found';
end $$;

-- ---------------------------------------------------------------------
-- The thirty-eight a mutation sweep found
--
-- Fifty-two one-line mutants of `post_payroll_run` against twenty-one
-- test files. THIRTEEN died -- the worst ratio of this programme -- and
-- every one of the thirteen is a statutory remittance: EPF, SOCSO and
-- EIS each owed as the employee's half PLUS the employer's, PCB owed to
-- LHDN, the three employer contributions charged as a cost, and net pay
-- owed to the staff. statutory_remittances.sql asserts those completely.
--
-- Nothing else was asserted at all. Not the front door, not zakat, not
-- the HRD levy, not the journal's date or source, not the accounts a
-- company names for itself, not the expense claims paid through the
-- run, and NOT THE YEAR TO DATE.
--
-- THE YEAR TO DATE IS THE ONE THAT COMPOUNDS. payroll_ytd is what next
-- month's PCB is computed against. A field that replaces instead of
-- adding, or a month that is not counted, does not produce a wrong
-- figure this month -- it produces a wrong figure for every remaining
-- month of the year, for every employee, and the payslips all look
-- right. It needs two months to see at all, which is why nothing saw
-- it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid; v_stranger uuid;
  v_emp uuid; v_other uuid;
  v_p1 uuid; v_p2 uuid; v_r1 uuid; v_r2 uuid;
  v_entry uuid; v_msg text;
  v_ct uuid; v_claim uuid; v_stale uuid; v_late uuid; v_theirs uuid;
  v_acct uuid; v_sal uuid; v_epfp uuid; v_netp uuid;
  v_ytd record; v_slip record;
begin
  v_org := pg_temp.test_org('Gaji Sapu Sdn Bhd', array['hr', 'payroll']);
  v_owner := (select user_id from public.org_members
               where org_id = v_org and role = 'owner' limit 1);
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- Accounts the company names for itself, so the coalesce fallbacks
  -- are reached rather than the chart's defaults.
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '6105', 'Wages — our own', 'expense', 'operating_expense')
  returning id into v_sal;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '2151', 'EPF — our own', 'liability', 'other_liability')
  returning id into v_epfp;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '2146', 'Net pay — our own', 'liability', 'other_liability')
  returning id into v_netp;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '6910', 'Travel — claims', 'expense', 'operating_expense')
  returning id into v_acct;

  insert into public.payroll_settings
    (org_id, hrdf_category, salary_expense_account_id,
     epf_payable_account_id, salary_payable_account_id)
  values (v_org, 'mandatory_10plus', v_sal, v_epfp, v_netp)
  on conflict (org_id) do update
    set hrdf_category = excluded.hrdf_category,
        salary_expense_account_id = excluded.salary_expense_account_id,
        epf_payable_account_id = excluded.epf_payable_account_id,
        salary_payable_account_id = excluded.salary_payable_account_id;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, zakat_monthly, cp38_monthly)
  values (v_org, 'S1', 'Sapu Satu', date '2020-01-01', 6000,
          date '1990-01-01', 'citizen', 30, 40) returning id into v_emp;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'S2', 'Sapu Dua', date '2020-01-01', 4000,
          date '1991-01-01', 'citizen') returning id into v_other;

  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (v_org, 'TRV', 'Travel', v_acct) returning id into v_ct;

  -- Four claims: one that should be paid, and three that should not.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, status,
     total_amount, approved_amount, pay_with_payroll)
  values (v_org, 'EC-1', v_emp, date '2026-01-10', 'approved', 200, 200, true)
  returning id into v_claim;
  insert into public.expense_claim_lines
    (org_id, claim_id, claim_type_id, expense_date, description, amount)
  values (v_org, v_claim, v_ct, date '2026-01-10', 'Perjalanan', 200);

  -- Not approved.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, status,
     total_amount, approved_amount, pay_with_payroll)
  values (v_org, 'EC-2', v_emp, date '2026-01-11', 'submitted', 500, 500, true)
  returning id into v_stale;
  insert into public.expense_claim_lines
    (org_id, claim_id, claim_type_id, expense_date, description, amount)
  values (v_org, v_stale, v_ct, date '2026-01-11', 'Perjalanan', 500);

  -- Approved, but not to be paid through payroll.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, status,
     total_amount, approved_amount, pay_with_payroll)
  values (v_org, 'EC-3', v_emp, date '2026-01-12', 'approved', 700, 700, false)
  returning id into v_late;
  insert into public.expense_claim_lines
    (org_id, claim_id, claim_type_id, expense_date, description, amount)
  values (v_org, v_late, v_ct, date '2026-01-12', 'Perjalanan', 700);

  -- Approved and payable, but dated after the period ends.
  insert into public.expense_claims
    (org_id, claim_no, employee_id, claim_date, status,
     total_amount, approved_amount, pay_with_payroll)
  values (v_org, 'EC-4', v_emp, date '2026-02-20', 'approved', 900, 900, true)
  returning id into v_theirs;
  insert into public.expense_claim_lines
    (org_id, claim_id, claim_type_id, expense_date, description, amount)
  values (v_org, v_theirs, v_ct, date '2026-02-20', 'Perjalanan', 900);

  v_p1 := public.ensure_pay_period(v_org, 2026, 1);
  v_r1 := public.create_payroll_run(v_org, v_p1, 'January');

  -- ==================================================================
  -- 1. The front door
  -- ==================================================================
  begin
    perform public.post_payroll_run(gen_random_uuid());
    raise exception 'a run that does not exist was posted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a run that does not exist',
      v_msg, 'Payroll run not found');
  end;

  begin
    perform public.post_payroll_run(v_r1);
    raise exception 'a run that was never calculated was posted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a run nobody has calculated cannot be posted',
      v_msg like 'Only a calculated run can be posted; this one is draft');
  end;

  perform public.calculate_payroll_run(v_r1);

  v_stranger := pg_temp.another_user('stranger@gaji.test');
  perform pg_temp.sign_in_as(v_stranger);
  begin
    perform public.post_payroll_run(v_r1);
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('somebody who may not run payroll may not post it',
    v_msg, 'Not permitted to post payroll');

  -- An APPROVED run posts too. Narrow the guard to 'calculated' alone
  -- and a company that requires approval can never pay anybody.
  update public.payroll_runs set status = 'approved' where id = v_r1;
  v_entry := public.post_payroll_run(v_r1);
  perform pg_temp.check_true('an approved run posts', v_entry is not null);

  begin
    perform public.post_payroll_run(v_r1);
    raise exception 'a posted run was posted again';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a posted one is not posted twice',
      v_msg like 'Only a calculated run can be posted; this one is posted');
  end;

  -- ==================================================================
  -- 2. The journal
  -- ==================================================================
  perform pg_temp.check_true('the journal is dated the day of the pay run',
    (select e.entry_date = (select pay_date from public.pay_periods where id = v_p1)
       from public.gl_entries e where e.id = v_entry));
  perform pg_temp.check_eq('and is filed as payroll',
    (select e.source::text from public.gl_entries e where e.id = v_entry),
    'payroll');
  perform pg_temp.check_eq('and points back at the run',
    (select e.source_table from public.gl_entries e where e.id = v_entry),
    'payroll_runs');
  perform pg_temp.check_eq('while the run points at the journal',
    (select gl_entry_id from public.payroll_runs where id = v_r1), v_entry);
  perform pg_temp.check_eq('and reads as posted',
    (select status::text from public.payroll_runs where id = v_r1), 'posted');

  -- The accounts the company named for itself, not the chart's
  -- defaults. THE COALESCE FALLBACK: every payroll test in this suite
  -- leaves payroll_settings empty, so the fallback codes are what all
  -- of them exercise.
  perform pg_temp.check_true('wages go to the account the company names',
    (select sum(l.debit) > 0 from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_sal));
  perform pg_temp.check_true('EPF is owed on the account the company names',
    (select sum(l.credit) > 0 from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_epfp));
  perform pg_temp.check_true('and net pay on the one it names for that',
    (select sum(l.credit) > 0 from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_netp));

  -- Zakat and the HRD levy, the two statutory figures
  -- statutory_remittances.sql does not reach.
  perform pg_temp.check_eq('zakat withheld is owed',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2185'),
    (select total_zakat from public.payroll_runs where id = v_r1));
  perform pg_temp.check_true('and there is zakat to owe',
    (select total_zakat > 0 from public.payroll_runs where id = v_r1));
  perform pg_temp.check_eq('the HRD levy is charged as a cost',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6150'),
    (select total_hrdf from public.payroll_runs where id = v_r1));
  perform pg_temp.check_eq('and owed to HRD Corp',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2195'),
    (select total_hrdf from public.payroll_runs where id = v_r1));
  perform pg_temp.check_true('and there is a levy to charge',
    (select total_hrdf > 0 from public.payroll_runs where id = v_r1));

  -- ==================================================================
  -- 3. The claims that ride along with the pay
  --
  -- A claim is a reimbursement, not wages: it is in the net the staff
  -- are paid and it is NOT in the salary expense, because it is already
  -- somebody's expense on its own account.
  -- ==================================================================
  perform pg_temp.check_eq('the run records what it reimbursed',
    (select total_claims from public.payroll_runs where id = v_r1),
    200::numeric);
  perform pg_temp.check_eq('the claim is charged to the account its type names',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_acct), 200::numeric);
  perform pg_temp.check_eq('and is not in the salary expense',
    (select sum(l.debit) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_sal),
    (select total_gross - 200 from public.payroll_runs where id = v_r1));

  perform pg_temp.check_true('the claim is marked paid',
    (select paid_at is not null from public.expense_claims where id = v_claim));
  perform pg_temp.check_eq('and carries the payroll journal',
    (select gl_entry_id from public.expense_claims where id = v_claim), v_entry);

  perform pg_temp.check_true('one nobody approved is not paid',
    (select paid_at is null from public.expense_claims where id = v_stale));
  perform pg_temp.check_true('nor one not marked for payroll',
    (select paid_at is null from public.expense_claims where id = v_late));
  perform pg_temp.check_true('nor one dated after the period',
    (select paid_at is null from public.expense_claims where id = v_theirs));
  perform pg_temp.check_eq('so only the one is charged at all',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_acct), 200::numeric);

  -- ==================================================================
  -- 4. The year to date
  --
  -- Two months, because one cannot show accumulation. The second run's
  -- figures have to be ADDED to the first's, the month counted, and the
  -- whole thing filed under the year the money was paid.
  -- ==================================================================
  select * into v_slip from public.payslips
   where run_id = v_r1 and employee_id = v_emp;
  select * into v_ytd from public.payroll_ytd
   where employee_id = v_emp and tax_year = 2026;

  perform pg_temp.check_eq('after one month the year to date is that month',
    v_ytd.gross_pay, v_slip.gross_pay);
  perform pg_temp.check_eq('with one month counted', v_ytd.months_paid, 1);
  perform pg_temp.check_eq('and the tax paid so far includes CP38',
    v_ytd.pcb, v_slip.pcb + v_slip.cp38);
  perform pg_temp.check_true('and there is a CP38 for it to include',
    v_slip.cp38 > 0);

  v_p2 := public.ensure_pay_period(v_org, 2026, 2);
  v_r2 := public.create_payroll_run(v_org, v_p2, 'February');
  perform public.calculate_payroll_run(v_r2);
  perform public.post_payroll_run(v_r2);

  declare v_slip2 record; v_ytd2 record;
  begin
    select * into v_slip2 from public.payslips
     where run_id = v_r2 and employee_id = v_emp;
    select * into v_ytd2 from public.payroll_ytd
     where employee_id = v_emp and tax_year = 2026;

    perform pg_temp.check_eq('after two, it is the two added together',
      v_ytd2.gross_pay, v_slip.gross_pay + v_slip2.gross_pay);
    perform pg_temp.check_eq('the taxable income too',
      v_ytd2.taxable_income, v_slip.taxable_income + v_slip2.taxable_income);
    perform pg_temp.check_eq('the employee''s EPF too',
      v_ytd2.epf_employee, v_slip.epf_employee + v_slip2.epf_employee);
    perform pg_temp.check_eq('and the tax paid, which next month is read from',
      v_ytd2.pcb, v_slip.pcb + v_slip.cp38 + v_slip2.pcb + v_slip2.cp38);
    perform pg_temp.check_eq('with two months counted', v_ytd2.months_paid, 2);
    perform pg_temp.check_eq('and nothing filed under any other year',
      (select count(*) from public.payroll_ytd
        where employee_id = v_emp and tax_year <> 2026), 0);
    perform pg_temp.check_true('and the second month was not nothing',
      v_slip2.gross_pay > 0);
  end;

  -- ==================================================================
  -- 5. A run with nobody in it
  --
  -- An empty run posts an empty journal and marks itself done. The
  -- month then reads as paid with nothing paid, and nobody looks again.
  -- ==================================================================
  declare v_empty_org uuid; v_ep uuid; v_er uuid;
  begin
    v_empty_org := pg_temp.test_org('Kosong Sdn Bhd', array['hr', 'payroll']);
    perform public.create_fiscal_year(v_empty_org, date '2026-01-01');
    v_ep := public.ensure_pay_period(v_empty_org, 2026, 1);
    v_er := public.create_payroll_run(v_empty_org, v_ep, 'Nobody');
    perform public.calculate_payroll_run(v_er);
    perform pg_temp.check_eq('the run really is empty',
      (select employee_count from public.payroll_runs where id = v_er), 0);
    begin
      perform public.post_payroll_run(v_er);
      raise exception 'a run with nobody in it was posted';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('and a run with nobody in it is refused',
        v_msg, 'This run has no payslips to post');
    end;
  end;

  -- ==================================================================
  -- 6. The tax year is the year the money was PAID
  --
  -- Read off app.today() instead, a run posted in one calendar year for
  -- a pay date in another files the whole month under the wrong year:
  -- the EA form for that year is short, and the next year's PCB is
  -- computed from a year-to-date that has a month in it that does not
  -- belong. Reached only by a pay date in a year other than this one,
  -- which is why nothing reached it.
  -- ==================================================================
  declare v_p3 uuid; v_r3 uuid;
  begin
    perform public.create_fiscal_year(v_org, date '2027-01-01');
    v_p3 := public.ensure_pay_period(v_org, 2027, 1);
    v_r3 := public.create_payroll_run(v_org, v_p3, 'January next year');
    perform public.calculate_payroll_run(v_r3);
    perform public.post_payroll_run(v_r3);
    perform pg_temp.check_eq(
      'a run paid next year is filed under next year',
      (select months_paid from public.payroll_ytd
        where employee_id = v_emp and tax_year = 2027), 1);
    perform pg_temp.check_eq('and this year still has its own two',
      (select months_paid from public.payroll_ytd
        where employee_id = v_emp and tax_year = 2026), 2);
  end;

  -- ==================================================================
  -- 7. A claim that already has a journal keeps it
  --
  -- `coalesce(c.gl_entry_id, v_entry)`: a claim posted to the ledger on
  -- its own and then reimbursed through payroll must keep the entry
  -- that recorded the expense. Overwritten with the payroll journal,
  -- the expense's own posting is orphaned and "what happened to this
  -- claim" points at the wrong document.
  -- ==================================================================
  declare v_own uuid; v_owner_entry uuid; v_p4 uuid; v_r4 uuid;
  begin
    insert into public.expense_claims
      (org_id, claim_no, employee_id, claim_date, status,
       total_amount, approved_amount, pay_with_payroll, gl_entry_id)
    values (v_org, 'EC-5', v_other, date '2026-03-05', 'approved',
            150, 150, true, v_entry)
    returning id into v_own;
    insert into public.expense_claim_lines
      (org_id, claim_id, claim_type_id, expense_date, description, amount)
    values (v_org, v_own, v_ct, date '2026-03-05', 'Perjalanan', 150);
    v_owner_entry := v_entry;

    v_p4 := public.ensure_pay_period(v_org, 2026, 3);
    v_r4 := public.create_payroll_run(v_org, v_p4, 'March');
    perform public.calculate_payroll_run(v_r4);
    perform public.post_payroll_run(v_r4);

    perform pg_temp.check_true('the claim is paid through the run',
      (select paid_at is not null from public.expense_claims where id = v_own));
    perform pg_temp.check_eq('but keeps the journal that recorded it',
      (select gl_entry_id from public.expense_claims where id = v_own),
      v_owner_entry);
    perform pg_temp.check_true('which is not the payroll journal',
      v_owner_entry <> (select gl_entry_id from public.payroll_runs
                         where id = v_r4));
  end;

  perform pg_temp.sign_out();
  raise notice 'ok   payroll posting: the thirty-eight a sweep found';
end $$;


rollback;
