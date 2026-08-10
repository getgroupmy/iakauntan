-- =====================================================================
-- iAkauntan :: 0031 hrms permissions and calculate
-- Applied as project migration 20260810054902.
-- =====================================================================

-- Who may see and edit other people's HR records.
create or replace function app.can_manage_hr(p_org_id uuid)
returns boolean language sql stable
set search_path = public, app, pg_temp as $$
  select app.has_org_role(p_org_id,
    array['owner','admin','hr_manager']::app.member_role[]);
$$;

-- Payroll touches the ledger, so it needs a finance role as well.
create or replace function app.can_run_payroll(p_org_id uuid)
returns boolean language sql stable
set search_path = public, app, pg_temp as $$
  select app.has_org_role(p_org_id,
    array['owner','admin','hr_manager','accountant']::app.member_role[]);
$$;

-- The employee record belonging to the caller, if any. Self-service
-- policies are written against this, so a member with no employee record
-- simply sees nothing rather than everything.
create or replace function app.my_employee_id(p_org_id uuid)
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select e.id from public.employees e
   where e.org_id = p_org_id and e.user_id = auth.uid()
   limit 1;
$$;

-- True when the caller manages this employee, directly or further up the
-- reporting line. Approvals are written against this so a manager can act
-- on their own team without being given the whole company.
create or replace function app.manages_employee(p_employee_id uuid)
returns boolean language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_org uuid;
  v_me uuid;
  v_cursor uuid;
  v_depth integer := 0;
begin
  select org_id, manager_id into v_org, v_cursor
    from public.employees where id = p_employee_id;
  if v_org is null then return false; end if;

  select id into v_me from public.employees
   where org_id = v_org and user_id = auth.uid();
  if v_me is null then return false; end if;

  -- Walk up the chain, with a depth stop so a cycle in the data cannot
  -- hang the query.
  while v_cursor is not null and v_depth < 12 loop
    if v_cursor = v_me then return true; end if;
    select manager_id into v_cursor from public.employees where id = v_cursor;
    v_depth := v_depth + 1;
  end loop;
  return false;
end;
$$;

-- ---------------------------------------------------------------------
-- Calculate a payroll run
-- ---------------------------------------------------------------------
create or replace function public.calculate_payroll_run(p_run_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run       public.payroll_runs;
  v_period    public.pay_periods;
  v_set       public.payroll_settings;
  v_emp       record;
  v_slip      uuid;
  v_age       integer;
  v_days      integer;
  v_from      date;
  v_to        date;
  v_worked    integer;
  v_basic     numeric;
  v_hourly    numeric;
  v_ot        record;
  v_ot_amt    numeric;
  v_ot_hours  numeric;
  v_unpaid    numeric;
  v_unpaid_amt numeric;
  v_claims    numeric;
  v_base      record;
  v_epf       record;
  v_socso     record;
  v_eis       record;
  v_pcb       record;
  v_epf_ee    numeric;
  v_epf_er    numeric;
  v_hrdf      numeric := 0;
  v_hrdf_rate numeric := 0;
  v_zakat     numeric;
  v_deduct    numeric;
  v_verified  boolean;
  v_n         integer := 0;
begin
  select * into v_run from public.payroll_runs where id = p_run_id;
  if v_run.id is null then
    raise exception 'Payroll run not found' using errcode = 'P0002';
  end if;
  if not app.can_run_payroll(v_run.org_id) then
    raise exception 'Not permitted to run payroll' using errcode = '42501';
  end if;
  if v_run.status not in ('draft', 'calculated') then
    raise exception 'This run is % and can no longer be recalculated', v_run.status
      using errcode = '22023';
  end if;

  select * into v_period from public.pay_periods where id = v_run.period_id;
  select * into v_set from public.payroll_settings where org_id = v_run.org_id;

  if v_set.hrdf_category is not null then
    select r.employer_rate into v_hrdf_rate
      from public.statutory_rates r
      join public.statutory_schedules s on s.id = r.schedule_id
     where s.body = 'hrdf' and r.category = v_set.hrdf_category
       and s.effective_from <= v_period.pay_date
       and (s.effective_to is null or s.effective_to >= v_period.pay_date)
     order by s.effective_from desc limit 1;
  end if;

  -- Recalculating replaces the previous attempt outright.
  delete from public.payslips where run_id = p_run_id;

  v_days := (v_period.period_end - v_period.period_start) + 1;

  for v_emp in
    select e.*, d.name as dept_name, p.title as pos_title
      from public.employees e
      left join public.departments d on d.id = e.department_id
      left join public.positions p on p.id = e.position_id
     where e.org_id = v_run.org_id
       and e.hire_date <= v_period.period_end
       and (e.last_working_date is null
            or e.last_working_date >= v_period.period_start)
     order by e.employee_no
  loop
    v_age := app.age_at(v_emp.date_of_birth, v_period.pay_date);

    -- An incomplete month is paid by calendar days, following the
    -- Employment Act's ordinary-rate treatment of a partial month.
    v_from := greatest(v_emp.hire_date, v_period.period_start);
    v_to := least(coalesce(v_emp.last_working_date, v_period.period_end),
                  v_period.period_end);
    v_worked := (v_to - v_from) + 1;
    v_basic := case when v_worked >= v_days then v_emp.basic_salary
                    else round(v_emp.basic_salary * v_worked / v_days, 2) end;

    v_hourly := case
      when coalesce(v_emp.working_days_per_month, 0) > 0
       and coalesce(v_emp.working_hours_per_day, 0) > 0
      then v_emp.basic_salary / v_emp.working_days_per_month
                              / v_emp.working_hours_per_day
      else 0 end;

    select coalesce(sum(ot_normal_minutes), 0) as normal,
           coalesce(sum(ot_restday_minutes), 0) as restday,
           coalesce(sum(ot_holiday_minutes), 0) as holiday
      into v_ot
      from public.attendance_records
     where employee_id = v_emp.id
       and work_date between v_period.period_start and v_period.period_end;

    v_ot_hours := round((v_ot.normal + v_ot.restday + v_ot.holiday) / 60.0, 2);
    v_ot_amt := round(v_hourly * (
        v_ot.normal  / 60.0 * coalesce(v_set.ot_normal_multiplier, 1.5)
      + v_ot.restday / 60.0 * coalesce(v_set.ot_restday_multiplier, 2.0)
      + v_ot.holiday / 60.0 * coalesce(v_set.ot_holiday_multiplier, 3.0)), 2);

    -- Unpaid leave, counting only the days that fall inside this period.
    select coalesce(sum(
             lr.total_days
             * ((least(lr.end_date, v_period.period_end)
                 - greatest(lr.start_date, v_period.period_start) + 1)::numeric
                / greatest((lr.end_date - lr.start_date) + 1, 1))), 0)
      into v_unpaid
      from public.leave_requests lr
      join public.leave_types lt on lt.id = lr.leave_type_id
     where lr.employee_id = v_emp.id
       and lr.status = 'approved'
       and not lt.is_paid
       and lr.start_date <= v_period.period_end
       and lr.end_date >= v_period.period_start;

    v_unpaid_amt := case when coalesce(v_emp.working_days_per_month, 0) > 0
      then round(v_unpaid * v_emp.basic_salary / v_emp.working_days_per_month, 2)
      else 0 end;

    select coalesce(sum(approved_amount), 0) into v_claims
      from public.expense_claims
     where employee_id = v_emp.id
       and status = 'approved'
       and pay_with_payroll
       and paid_at is null
       and claim_date <= v_period.period_end;

    insert into public.payslips (
      org_id, run_id, employee_id, employee_no, employee_name,
      department_name, position_title, nric, epf_no, socso_no,
      income_tax_no, bank_name, bank_account_no, basic_salary,
      unpaid_leave_days, unpaid_leave_amount, ot_hours, ot_amount,
      claims_amount)
    values (
      v_run.org_id, p_run_id, v_emp.id, v_emp.employee_no, v_emp.full_name,
      v_emp.dept_name, v_emp.pos_title, v_emp.nric, v_emp.epf_no,
      v_emp.socso_no, v_emp.income_tax_no, v_emp.bank_name,
      v_emp.bank_account_no, v_basic, round(v_unpaid, 2), v_unpaid_amt,
      v_ot_hours, v_ot_amt, v_claims)
    returning id into v_slip;

    -- Earnings ------------------------------------------------------
    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount,
       is_taxable, is_epf_liable, is_socso_liable, is_eis_liable)
    values (v_run.org_id, v_slip, 1, 'earning', 'BASIC',
            case when v_worked >= v_days then 'Basic salary'
                 else format('Basic salary (%s of %s days)', v_worked, v_days) end,
            v_basic, true, true, true, true);

    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount,
       is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
       account_id, component_id)
    select v_run.org_id, v_slip, 10 + row_number() over (order by sc.sort_order, sc.code),
           sc.kind, sc.code, sc.name,
           round(coalesce(esc.amount, sc.default_amount,
                 v_emp.basic_salary * coalesce(sc.percent_of_basic, 0) / 100), 2),
           sc.is_taxable, sc.is_epf_liable, sc.is_socso_liable, sc.is_eis_liable,
           sc.account_id, sc.id
      from public.employee_salary_components esc
      join public.salary_components sc on sc.id = esc.component_id
     where esc.employee_id = v_emp.id
       and sc.is_active
       and esc.effective_from <= v_period.period_end
       and (esc.effective_to is null or esc.effective_to >= v_period.period_start);

    -- Overtime is chargeable to SOCSO and EIS but not to EPF.
    if v_ot_amt > 0 then
      insert into public.payslip_lines
        (org_id, payslip_id, line_no, kind, code, description, quantity,
         rate, amount, is_taxable, is_epf_liable, is_socso_liable, is_eis_liable)
      values (v_run.org_id, v_slip, 40, 'earning', 'OT', 'Overtime',
              v_ot_hours, round(v_hourly, 4), v_ot_amt, true, false, true, true);
    end if;

    -- Unpaid leave reduces the wage itself, so it carries the same
    -- liability flags as basic pay and lowers every statutory base.
    if v_unpaid_amt > 0 then
      insert into public.payslip_lines
        (org_id, payslip_id, line_no, kind, code, description, quantity,
         amount, is_taxable, is_epf_liable, is_socso_liable, is_eis_liable)
      values (v_run.org_id, v_slip, 45, 'earning', 'UNPAID', 'Unpaid leave',
              round(v_unpaid, 2), -v_unpaid_amt, true, true, true, true);
    end if;

    -- A reimbursement is not pay: it is neither taxed nor contributed on.
    if v_claims > 0 then
      insert into public.payslip_lines
        (org_id, payslip_id, line_no, kind, code, description, amount,
         is_taxable, is_epf_liable, is_socso_liable, is_eis_liable)
      values (v_run.org_id, v_slip, 50, 'earning', 'CLAIMS',
              'Expense claims reimbursement', v_claims,
              false, false, false, false);
    end if;

    select coalesce(sum(amount), 0) as gross,
           coalesce(sum(amount) filter (where is_epf_liable), 0) as epf_wage,
           coalesce(sum(amount) filter (where is_socso_liable), 0) as socso_wage,
           coalesce(sum(amount) filter (where is_eis_liable), 0) as eis_wage,
           coalesce(sum(amount) filter (where is_taxable), 0) as taxable
      into v_base
      from public.payslip_lines
     where payslip_id = v_slip and kind = 'earning';

    -- Statutory -----------------------------------------------------
    v_verified := true;

    if v_emp.epf_eligible and v_base.epf_wage > 0 then
      select * into v_epf from app.calc_statutory(
        'epf', app.epf_category(v_emp.residency_status, v_age),
        v_base.epf_wage, v_period.pay_date);
    else
      v_epf := row(0::numeric, 0::numeric, null::uuid, true);
    end if;

    v_epf_ee := coalesce(v_epf.employee_amount, 0)
      + ceil(v_base.epf_wage * coalesce(v_emp.epf_voluntary_employee_rate, 0) / 100);
    v_epf_er := coalesce(v_epf.employer_amount, 0)
      + ceil(v_base.epf_wage * coalesce(v_emp.epf_voluntary_employer_rate, 0) / 100);

    if v_emp.socso_eligible and v_base.socso_wage > 0 then
      select * into v_socso from app.calc_statutory(
        'socso', case when v_age >= 60 then 'act800' else 'act4' end,
        v_base.socso_wage, v_period.pay_date);
    else
      v_socso := row(0::numeric, 0::numeric, null::uuid, true);
    end if;

    -- EIS stops at 60.
    if v_emp.eis_eligible and v_age < 60 and v_base.eis_wage > 0 then
      select * into v_eis from app.calc_statutory(
        'eis', 'default', v_base.eis_wage, v_period.pay_date);
    else
      v_eis := row(0::numeric, 0::numeric, null::uuid, true);
    end if;

    v_zakat := coalesce(v_emp.zakat_monthly, 0);

    select * into v_pcb from app.calc_pcb(
      v_emp.id, v_base.taxable, v_epf_ee,
      coalesce(v_socso.employee_amount, 0) + coalesce(v_eis.employee_amount, 0),
      v_zakat, v_period.pay_date);

    if coalesce(v_hrdf_rate, 0) > 0 and v_emp.hrdf_eligible then
      v_hrdf := round(v_base.epf_wage * v_hrdf_rate / 100, 2);
    else
      v_hrdf := 0;
    end if;

    v_verified := coalesce(v_epf.is_verified, true)
              and coalesce(v_socso.is_verified, true)
              and coalesce(v_eis.is_verified, true)
              and coalesce(v_pcb.is_verified, true);

    -- Deduction lines ------------------------------------------------
    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount, is_taxable)
    select v_run.org_id, v_slip, v.no, 'deduction', v.code, v.label, v.amt, false
      from (values
        (60, 'EPF',   'EPF employee',    v_epf_ee),
        (61, 'SOCSO', 'SOCSO employee',  coalesce(v_socso.employee_amount, 0)),
        (62, 'EIS',   'EIS employee',    coalesce(v_eis.employee_amount, 0)),
        (63, 'PCB',   'PCB / MTD',       coalesce(v_pcb.pcb, 0)),
        (64, 'CP38',  'CP38 instalment', coalesce(v_emp.cp38_monthly, 0)),
        (65, 'ZAKAT', 'Zakat',           v_zakat)
      ) as v(no, code, label, amt)
     where v.amt > 0;

    -- Employer costs, shown on the payslip but never netted off pay.
    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount, is_taxable)
    select v_run.org_id, v_slip, v.no, 'employer_contribution', v.code, v.label, v.amt, false
      from (values
        (70, 'EPF_ER',   'EPF employer',   v_epf_er),
        (71, 'SOCSO_ER', 'SOCSO employer', coalesce(v_socso.employer_amount, 0)),
        (72, 'EIS_ER',   'EIS employer',   coalesce(v_eis.employer_amount, 0)),
        (73, 'HRDF',     'HRD Corp levy',  v_hrdf)
      ) as v(no, code, label, amt)
     where v.amt > 0;

    select coalesce(sum(amount), 0) into v_deduct
      from public.payslip_lines
     where payslip_id = v_slip and kind = 'deduction';

    update public.payslips set
      gross_pay = v_base.gross,
      epf_wage = v_base.epf_wage,
      socso_wage = v_base.socso_wage,
      eis_wage = v_base.eis_wage,
      taxable_income = v_base.taxable,
      epf_employee = v_epf_ee,
      epf_employer = v_epf_er,
      socso_employee = coalesce(v_socso.employee_amount, 0),
      socso_employer = coalesce(v_socso.employer_amount, 0),
      eis_employee = coalesce(v_eis.employee_amount, 0),
      eis_employer = coalesce(v_eis.employer_amount, 0),
      pcb = coalesce(v_pcb.pcb, 0),
      cp38 = coalesce(v_emp.cp38_monthly, 0),
      zakat = v_zakat,
      hrdf = v_hrdf,
      total_deductions = v_deduct,
      net_pay = v_base.gross - v_deduct,
      epf_schedule_id = v_epf.schedule_id,
      socso_schedule_id = v_socso.schedule_id,
      eis_schedule_id = v_eis.schedule_id,
      pcb_schedule_id = v_pcb.schedule_id,
      schedules_verified = v_verified
    where id = v_slip;

    v_n := v_n + 1;
  end loop;

  update public.payroll_runs r set
    status = 'calculated',
    calculated_at = now(),
    employee_count = v_n,
    total_gross = t.gross,
    total_deductions = t.deductions,
    total_net = t.net,
    total_epf_employee = t.epf_ee,
    total_epf_employer = t.epf_er,
    total_socso_employee = t.socso_ee,
    total_socso_employer = t.socso_er,
    total_eis_employee = t.eis_ee,
    total_eis_employer = t.eis_er,
    total_pcb = t.pcb,
    total_zakat = t.zakat,
    total_hrdf = t.hrdf,
    total_employer_cost = t.gross + t.epf_er + t.socso_er + t.eis_er + t.hrdf
  from (
    select coalesce(sum(gross_pay), 0) gross,
           coalesce(sum(total_deductions), 0) deductions,
           coalesce(sum(net_pay), 0) net,
           coalesce(sum(epf_employee), 0) epf_ee,
           coalesce(sum(epf_employer), 0) epf_er,
           coalesce(sum(socso_employee), 0) socso_ee,
           coalesce(sum(socso_employer), 0) socso_er,
           coalesce(sum(eis_employee), 0) eis_ee,
           coalesce(sum(eis_employer), 0) eis_er,
           coalesce(sum(pcb) + sum(cp38), 0) pcb,
           coalesce(sum(zakat), 0) zakat,
           coalesce(sum(hrdf), 0) hrdf
      from public.payslips where run_id = p_run_id
  ) t
  where r.id = p_run_id;

  select to_jsonb(r) into v_run from public.payroll_runs r where r.id = p_run_id;
  return to_jsonb(v_run);
end;
$$;

comment on function public.calculate_payroll_run is
  'Builds a payslip per employee whose employment overlaps the period, deriving every statutory figure from the schedules in force on the pay date.';
