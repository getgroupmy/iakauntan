-- ---------------------------------------------------------------------
-- 0409  The one figure on the payslip that skips calc_statutory
-- ---------------------------------------------------------------------
--
-- `payslips.schedules_verified` is what the banner on the payslip screen
-- and the line on the PDF are drawn from: whether every statutory table
-- this payslip's figures came from has been checked against what the
-- body actually published. `calculate_payroll_run` builds it by AND-ing
-- the flag each calculation hands back:
--
--     v_verified := coalesce(v_epf_ver, true) and coalesce(v_soc_ver, true)
--               and coalesce(v_eis_ver, true) and coalesce(v_pcb_ver, true);
--
-- Four bodies. There are five. The HRD Corp levy is worked out from a
-- rate read straight off `statutory_rates`:
--
--     select r.employer_rate into v_hrdf_rate
--       from public.statutory_rates r
--       join public.statutory_schedules s on s.id = r.schedule_id
--      where s.body = 'hrdf' and r.category = v_set.hrdf_category
--        ...
--
-- The join reaches the schedule and does not read `s.is_verified`. It is
-- the one statutory figure that does not come through
-- `app.calc_statutory`, and so the one whose verification had no way
-- into the flag.
--
-- ## What that costs, and when
--
-- Two things, and both are latent today rather than live. Every seeded
-- schedule on this project is `is_verified = false` -- epf, socso, eis,
-- pcb and hrdf alike -- so every payslip that touches any of the four
-- is already stamped unverified for those, and the levy's silence
-- changes nothing. Said plainly rather than dressed up as a live defect.
--
-- What it costs is the moment somebody does the right thing. The four
-- are verified against the KWSP and PERKESO schedules and the LHDN
-- tables; HRD Corp publishes its own rates separately and is the
-- obvious one to be verified last. In that window a payslip says its
-- figures came from verified tables while the levy on it came from one
-- nobody has checked. The flag is only worth carrying if it is true.
--
-- The second is the shape `0404` named. If a company has set
-- `payroll_settings.hrdf_category` and no HRDF schedule is in force for
-- the pay date, `select ... into` finds nothing, `v_hrdf_rate` is null,
-- `coalesce(v_hrdf_rate, 0) > 0` is false and the levy is **zero** --
-- silently, on a company that has told the system it is liable. The
-- zero is not changed here: an absent schedule means there is no
-- arithmetic to be wrong about, which is the answer `0404` settled for
-- `app.calc_statutory` and `0408` followed. What changes is that the
-- payslip stops calling it verified, which is exactly what `0404` did
-- with a wage that fell between two bands.
--
-- ## Scope
--
-- The levy's verification counts only where the levy was consulted --
-- the employee is `hrdf_eligible` and the company has set a category --
-- on the same terms as the other four, each of which leaves its own
-- flag at `true` when its calculation does not run.
--
-- The function is restated whole because plpgsql bodies are replaced
-- whole; `0370` is the version being restated and everything else in it
-- is unchanged.
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
  v_epf_ee    numeric := 0;
  v_epf_er    numeric := 0;
  v_epf_sched uuid;
  v_epf_ver   boolean := true;
  v_soc_ee    numeric := 0;
  v_soc_er    numeric := 0;
  v_soc_sched uuid;
  v_soc_ver   boolean := true;
  v_soc_cat   text;
  v_eis_ee    numeric := 0;
  v_eis_er    numeric := 0;
  v_eis_sched uuid;
  v_eis_ver   boolean := true;
  v_pcb_amt   numeric := 0;
  v_pcb_sched uuid;
  v_pcb_ver   boolean := true;
  v_hrdf      numeric := 0;
  v_hrdf_rate numeric := 0;
  v_hrdf_ver  boolean := true;
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
    select r.employer_rate, s.is_verified into v_hrdf_rate, v_hrdf_ver
      from public.statutory_rates r
      join public.statutory_schedules s on s.id = r.schedule_id
     where s.body = 'hrdf' and r.category = v_set.hrdf_category
       and s.effective_from <= v_period.pay_date
       and (s.effective_to is null or s.effective_to >= v_period.pay_date)
     order by s.effective_from desc limit 1;
    -- A category is set and nothing answers it for this pay date:
    -- `select into` leaves both targets null, the levy comes out zero
    -- as it did before, and the null is what makes the payslip stop
    -- calling that zero verified further down. Written first as an
    -- explicit `if not found then v_hrdf_ver := false`, which a mutant
    -- showed to be dead -- the `coalesce(v_hrdf_ver, false)` below
    -- already says it, and a branch no mutation can kill is a branch
    -- that is not doing anything.
  end if;

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
    v_soc_cat := case when v_age >= 60 then 'act800' else 'act4' end;

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

    select coalesce(sum(a.ot_normal_minutes), 0) as normal,
           coalesce(sum(a.ot_restday_minutes), 0) as restday,
           coalesce(sum(a.ot_holiday_minutes), 0) as holiday
      into v_ot
      from public.attendance_records a
     where a.employee_id = v_emp.id
       and a.work_date between v_period.period_start and v_period.period_end;

    v_ot_hours := round((v_ot.normal + v_ot.restday + v_ot.holiday) / 60.0, 2);
    v_ot_amt := round(v_hourly * (
        v_ot.normal  / 60.0 * coalesce(v_set.ot_normal_multiplier, 1.5)
      + v_ot.restday / 60.0 * coalesce(v_set.ot_restday_multiplier, 2.0)
      + v_ot.holiday / 60.0 * coalesce(v_set.ot_holiday_multiplier, 3.0)), 2);

    select coalesce(sum(
             lr.total_days
             * ((least(lr.end_date, v_period.period_end)
                 - greatest(lr.start_date, v_period.period_start) + 1)::numeric
                / greatest((lr.end_date - lr.start_date) + 1, 1))), 0)
      into v_unpaid
      from public.leave_requests lr
      join public.leave_types lt on lt.id = lr.leave_type_id
     where lr.employee_id = v_emp.id and lr.status = 'approved'
       and not lt.is_paid
       and lr.start_date <= v_period.period_end
       and lr.end_date >= v_period.period_start;

    v_unpaid_amt := case when coalesce(v_emp.working_days_per_month, 0) > 0
      then round(v_unpaid * v_emp.basic_salary / v_emp.working_days_per_month, 2)
      else 0 end;

    select coalesce(sum(c.approved_amount), 0) into v_claims
      from public.expense_claims c
     where c.employee_id = v_emp.id and c.status = 'approved'
       and c.pay_with_payroll and c.paid_at is null
       and c.claim_date <= v_period.period_end;

    insert into public.payslips (
      org_id, run_id, employee_id, employee_no, employee_name,
      department_name, position_title, nric, epf_no, socso_no,
      income_tax_no, bank_name, bank_account_no, basic_salary,
      unpaid_leave_days, unpaid_leave_amount, ot_hours, ot_amount, claims_amount)
    values (
      v_run.org_id, p_run_id, v_emp.id, v_emp.employee_no, v_emp.full_name,
      v_emp.dept_name, v_emp.pos_title, v_emp.nric, v_emp.epf_no,
      v_emp.socso_no, v_emp.income_tax_no, v_emp.bank_name,
      v_emp.bank_account_no, v_basic, round(v_unpaid, 2), v_unpaid_amt,
      v_ot_hours, v_ot_amt, v_claims)
    returning id into v_slip;

    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount,
       is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
       is_hrdf_liable)
    values (v_run.org_id, v_slip, 1, 'earning', 'BASIC',
            case when v_worked >= v_days then 'Basic salary'
                 else format('Basic salary (%s of %s days)', v_worked, v_days) end,
            v_basic, true, true, true, true, true);

    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount,
       is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
       is_hrdf_liable, account_id, component_id)
    select v_run.org_id, v_slip,
           10 + row_number() over (order by sc.sort_order, sc.code),
           sc.kind, sc.code, sc.name,
           round(coalesce(esc.amount, nullif(sc.default_amount, 0),
                 v_emp.basic_salary * coalesce(sc.percent_of_basic, 0) / 100), 2),
           sc.is_taxable, sc.is_epf_liable, sc.is_socso_liable, sc.is_eis_liable,
           sc.is_hrdf_liable, sc.account_id, sc.id
      from public.employee_salary_components esc
      join public.salary_components sc on sc.id = esc.component_id
     where esc.employee_id = v_emp.id and sc.is_active
       and esc.effective_from <= v_period.period_end
       and (esc.effective_to is null or esc.effective_to >= v_period.period_start);

    if v_ot_amt > 0 then
      insert into public.payslip_lines
        (org_id, payslip_id, line_no, kind, code, description, quantity,
         rate, amount, is_taxable, is_epf_liable, is_socso_liable,
         is_eis_liable, is_hrdf_liable)
      -- Overtime: taxable, outside EPF, inside SOCSO and EIS, and named
      -- in the PSMB Act's exclusions, so outside the levy as well.
      values (v_run.org_id, v_slip, 40, 'earning', 'OT', 'Overtime',
              v_ot_hours, round(v_hourly, 4), v_ot_amt, true, false, true,
              true, false);
    end if;

    if v_unpaid_amt > 0 then
      insert into public.payslip_lines
        (org_id, payslip_id, line_no, kind, code, description, quantity,
         amount, is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
         is_hrdf_liable)
      -- A negative earning against basic pay, so it comes off every wage
      -- the basic went into, the levy's included: the levy is on wages
      -- paid, not on the contract.
      values (v_run.org_id, v_slip, 45, 'earning', 'UNPAID', 'Unpaid leave',
              round(v_unpaid, 2), -v_unpaid_amt, true, true, true, true, true);
    end if;

    if v_claims > 0 then
      insert into public.payslip_lines
        (org_id, payslip_id, line_no, kind, code, description, amount,
         is_taxable, is_epf_liable, is_socso_liable, is_eis_liable,
         is_hrdf_liable)
      -- Money the employee spent, handed back. Not wages under any of
      -- the five heads.
      values (v_run.org_id, v_slip, 50, 'earning', 'CLAIMS',
              'Expense claims reimbursement', v_claims, false, false, false,
              false, false);
    end if;

    select coalesce(sum(l.amount), 0) as gross,
           coalesce(sum(l.amount) filter (where l.is_epf_liable), 0) as epf_wage,
           coalesce(sum(l.amount) filter (where l.is_socso_liable), 0) as socso_wage,
           coalesce(sum(l.amount) filter (where l.is_eis_liable), 0) as eis_wage,
           coalesce(sum(l.amount) filter (where l.is_hrdf_liable), 0) as hrdf_wage,
           coalesce(sum(l.amount) filter (where l.is_taxable), 0) as taxable
      into v_base
      from public.payslip_lines l
     where l.payslip_id = v_slip and l.kind = 'earning';

    v_epf_ee := 0; v_epf_er := 0; v_epf_sched := null; v_epf_ver := true;
    v_soc_ee := 0; v_soc_er := 0; v_soc_sched := null; v_soc_ver := true;
    v_eis_ee := 0; v_eis_er := 0; v_eis_sched := null; v_eis_ver := true;
    v_pcb_amt := 0; v_pcb_sched := null; v_pcb_ver := true;

    if v_emp.epf_eligible and v_base.epf_wage > 0 then
      select c.employee_amount, c.employer_amount, c.schedule_id, c.is_verified
        into v_epf_ee, v_epf_er, v_epf_sched, v_epf_ver
        from app.calc_statutory('epf',
               app.epf_category(v_emp.residency_status, v_age),
               v_base.epf_wage, v_period.pay_date) c;
    end if;
    v_epf_ee := coalesce(v_epf_ee, 0)
      + ceil(v_base.epf_wage * coalesce(v_emp.epf_voluntary_employee_rate, 0) / 100);
    v_epf_er := coalesce(v_epf_er, 0)
      + ceil(v_base.epf_wage * coalesce(v_emp.epf_voluntary_employer_rate, 0) / 100);

    if v_emp.socso_eligible and v_base.socso_wage > 0 then
      select c.employee_amount, c.employer_amount, c.schedule_id, c.is_verified
        into v_soc_ee, v_soc_er, v_soc_sched, v_soc_ver
        from app.calc_statutory('socso', v_soc_cat,
               v_base.socso_wage, v_period.pay_date) c;
    end if;

    if v_emp.eis_eligible and v_age < 60 and v_base.eis_wage > 0 then
      select c.employee_amount, c.employer_amount, c.schedule_id, c.is_verified
        into v_eis_ee, v_eis_er, v_eis_sched, v_eis_ver
        from app.calc_statutory('eis', 'default',
               v_base.eis_wage, v_period.pay_date) c;
    end if;

    v_zakat := coalesce(v_emp.zakat_monthly, 0);

    select c.pcb, c.schedule_id, c.is_verified
      into v_pcb_amt, v_pcb_sched, v_pcb_ver
      from app.calc_pcb(v_emp.id, v_base.taxable, v_epf_ee,
             coalesce(v_soc_ee, 0) + coalesce(v_eis_ee, 0),
             v_zakat, v_period.pay_date) c;

    if coalesce(v_hrdf_rate, 0) > 0 and v_emp.hrdf_eligible then
      -- On the levy's own wage, not on EPF's. The two differ by exactly
      -- the bonus.
      v_hrdf := round(v_base.hrdf_wage * v_hrdf_rate / 100, 2);
    else
      v_hrdf := 0;
    end if;

    v_verified := coalesce(v_epf_ver, true) and coalesce(v_soc_ver, true)
              and coalesce(v_eis_ver, true) and coalesce(v_pcb_ver, true);

    -- The levy is the one statutory figure on this payslip that does not
    -- come through `app.calc_statutory`, so its schedule's verification
    -- had no way in. Named on the same terms as the other four: it
    -- counts only where it was actually consulted.
    if coalesce(v_emp.hrdf_eligible, false)
       and v_set.hrdf_category is not null then
      v_verified := v_verified and coalesce(v_hrdf_ver, false);
    end if;

    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount, is_taxable)
    select v_run.org_id, v_slip, v.no, 'deduction', v.code, v.label, v.amt, false
      from (values
        (60, 'EPF',   'EPF employee',    coalesce(v_epf_ee, 0)),
        (61, 'SOCSO', 'SOCSO employee',  coalesce(v_soc_ee, 0)),
        (62, 'EIS',   'EIS employee',    coalesce(v_eis_ee, 0)),
        (63, 'PCB',   'PCB / MTD',       coalesce(v_pcb_amt, 0)),
        (64, 'CP38',  'CP38 instalment', coalesce(v_emp.cp38_monthly, 0)),
        (65, 'ZAKAT', 'Zakat',           v_zakat)
      ) as v(no, code, label, amt)
     where v.amt > 0;

    insert into public.payslip_lines
      (org_id, payslip_id, line_no, kind, code, description, amount, is_taxable)
    select v_run.org_id, v_slip, v.no, 'employer_contribution', v.code, v.label,
           v.amt, false
      from (values
        (70, 'EPF_ER',   'EPF employer',   coalesce(v_epf_er, 0)),
        (71, 'SOCSO_ER', 'SOCSO employer', coalesce(v_soc_er, 0)),
        (72, 'EIS_ER',   'EIS employer',   coalesce(v_eis_er, 0)),
        (73, 'HRDF',     'HRD Corp levy',  v_hrdf)
      ) as v(no, code, label, amt)
     where v.amt > 0;

    select coalesce(sum(l.amount), 0) into v_deduct
      from public.payslip_lines l
     where l.payslip_id = v_slip and l.kind = 'deduction';

    update public.payslips set
      gross_pay = v_base.gross,
      epf_wage = v_base.epf_wage,
      -- The insured wage, which is what the contribution was charged on.
      socso_wage = app.insured_wage('socso', v_soc_cat, v_base.socso_wage,
                                    v_period.pay_date),
      eis_wage = app.insured_wage('eis', 'default', v_base.eis_wage,
                                  v_period.pay_date),
      hrdf_wage = v_base.hrdf_wage,
      taxable_income = v_base.taxable,
      epf_employee = coalesce(v_epf_ee, 0),
      epf_employer = coalesce(v_epf_er, 0),
      socso_employee = coalesce(v_soc_ee, 0),
      socso_employer = coalesce(v_soc_er, 0),
      eis_employee = coalesce(v_eis_ee, 0),
      eis_employer = coalesce(v_eis_er, 0),
      pcb = coalesce(v_pcb_amt, 0),
      cp38 = coalesce(v_emp.cp38_monthly, 0),
      zakat = v_zakat,
      hrdf = v_hrdf,
      total_deductions = v_deduct,
      net_pay = v_base.gross - v_deduct,
      epf_schedule_id = v_epf_sched,
      socso_schedule_id = v_soc_sched,
      eis_schedule_id = v_eis_sched,
      pcb_schedule_id = v_pcb_sched,
      schedules_verified = v_verified
    where id = v_slip;

    v_n := v_n + 1;
  end loop;

  update public.payroll_runs r set
    status = 'calculated', calculated_at = now(), employee_count = v_n,
    total_gross = t.gross, total_deductions = t.deductions, total_net = t.net,
    total_epf_employee = t.epf_ee, total_epf_employer = t.epf_er,
    total_socso_employee = t.socso_ee, total_socso_employer = t.socso_er,
    total_eis_employee = t.eis_ee, total_eis_employer = t.eis_er,
    total_pcb = t.pcb, total_zakat = t.zakat, total_hrdf = t.hrdf,
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

  return (select to_jsonb(r) from public.payroll_runs r where r.id = p_run_id);
end;
$$;
-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'calculate_payroll_run';

  -- The rate lookup reads the flag. Asserted on the source rather than
  -- behaviourally because the behaviour needs a verified HRDF schedule
  -- and an unverified one in the same fixture, which is what
  -- `hrdf_levy.sql` does; this is here so a later restatement of the
  -- function that drops the line cannot pass by having no HRDF data.
  if v_src !~ 'v_hrdf_rate, v_hrdf_ver' then
    raise exception
      'FAIL 0409: the levy''s rate is read without its schedule''s '
      'is_verified -- the payslip would call it verified either way';
  end if;

  if v_src !~ 'v_verified and coalesce\(v_hrdf_ver' then
    raise exception
      'FAIL 0409: the levy''s verification does not reach '
      'schedules_verified';
  end if;

  -- And the other four still do. A restatement that lost one of them
  -- would satisfy the two above.
  if v_src !~ 'v_epf_ver' or v_src !~ 'v_soc_ver'
     or v_src !~ 'v_eis_ver' or v_src !~ 'v_pcb_ver' then
    raise exception
      'FAIL 0409: one of the four bodies that already reached the flag '
      'has been lost in restating the function';
  end if;

  raise notice '0409: all five statutory bodies reach schedules_verified';
end
$do$;
