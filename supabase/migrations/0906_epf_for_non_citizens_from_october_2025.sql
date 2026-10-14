-- =====================================================================
-- iAkauntan :: 0906 EPF for non-citizens from October 2025
--
-- EPF contributions became mandatory for non-Malaysian citizen
-- employees from October 2025 wages (the November 2025 contribution
-- month): 2% from the employee and 2% from the employer, at every age
-- up to 75, a direct calculation on the wage with each share rounded up
-- to the ringgit -- Part F of the Third Schedule. KWSP's worked example:
-- RM1,751 is RM35.02 a side, so RM36 and RM36. Permanent residents stay
-- on the citizen rates. Members who joined before 1 August 1998 keep
-- their old rates, 11% and RM5. Domestic servants are outside it, and
-- that is `epf_eligible` on the employee, as before.
--
-- The schedule never followed. The only EPF table, from 1 January
-- 2024, charges every non-citizen 11% and the employer RM5 flat (0% at
-- sixty and over), on a wage rounded up to RM20: a foreign worker on
-- RM2,000 gave RM220 of their pay instead of RM40, and the employer
-- paid RM5 instead of RM40.
--
-- Production on 14 October 2026: four employees, all citizens. Nothing
-- is recalculated.
--
-- Answered "2% schedule and a pre-1998 flag":
--
--   * `statutory_rates.wage_round_up_to`: a band may carry its own wage
--     step, 0 for the wage itself; null takes the schedule's. Read by
--     `app.calc_statutory`, and published by
--     `platform_publish_statutory_schedule`.
--   * `employees.epf_pre_august_1998`, and `app.epf_category` with a
--     third argument that reads it: such a member is filed under
--     `noncitizen_pre1998_*`. `calculate_payroll_run` passes it.
--   * Every EPF table before October 2025 gains the `noncitizen_pre1998_*`
--     rows, copies of its non-citizen rows, so the flag means the same
--     thing on either side of the change. Nobody has it yet; no payslip
--     moves.
--   * The table in force on 30 September 2025 ends that day, and a new
--     one starts on 1 October 2025: the same citizen and pre-1998 rows,
--     and every other non-citizen at 2% and 2% with a wage step of 0.
--
-- The table is chosen by pay date, as every statutory table here is: a
-- September wage paid in October is read from the new table. Like the
-- table it follows, it is not marked verified.
--
-- Sources: KWSP, "Contribution For Non-Malaysian Citizen Employees" and
-- "EPF Begins Mandatory Contributions For Non-Malaysian Citizen
-- Employees Effective October 2025" (kwsp.gov.my).
--
-- Each function body is `pg_get_functiondef` of what was applied, with
-- the change marked 0906.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The two columns
-- ---------------------------------------------------------------------
alter table public.statutory_rates
  add column wage_round_up_to numeric(12, 2)
    check (wage_round_up_to is null or wage_round_up_to >= 0);

comment on column public.statutory_rates.wage_round_up_to is
  'The step this band rounds the wage up to before the rate applies, '
  'where it is not the schedule''s own: 0 for a direct calculation on '
  'the wage itself (EPF Third Schedule Part F), null to take the '
  'schedule''s. 0906.';

alter table public.employees
  add column epf_pre_august_1998 boolean not null default false;

comment on column public.employees.epf_pre_august_1998 is
  'A non-citizen who became an EPF member before 1 August 1998 keeps the '
  'old rates -- 11% from the employee and RM5 from the employer -- '
  'instead of the 2% and 2% every other non-citizen pays from October '
  '2025. Read only for a non-citizen. 0906.';

-- ---------------------------------------------------------------------
-- Which table an employee is read from
-- ---------------------------------------------------------------------
create or replace function app.epf_category(
  p_residency app.residency_status, p_age integer, p_pre_august_1998 boolean)
returns text language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case
    when p_residency in ('citizen', 'permanent_resident')
      then case when p_age >= 60 then 'citizen_60plus' else 'citizen_under60' end
    when coalesce(p_pre_august_1998, false)
      then case when p_age >= 60 then 'noncitizen_pre1998_60plus'
                else 'noncitizen_pre1998_under60' end
    else case when p_age >= 60 then 'noncitizen_60plus' else 'noncitizen_under60' end
  end;
$$;

comment on function app.epf_category(app.residency_status, integer, boolean) is
  'The EPF category an employee''s contribution is read from: citizen or '
  'permanent resident, a non-citizen member from before 1 August 1998, '
  'or any other non-citizen; each under or from sixty. The schedule in '
  'force decides what each pays. 0906.';

-- ---------------------------------------------------------------------
-- The arithmetic, the publisher and the payroll run
-- ---------------------------------------------------------------------
-- app.calc_statutory
CREATE OR REPLACE FUNCTION app.calc_statutory(p_body app.statutory_body, p_category text, p_wage numeric, p_date date)
 RETURNS TABLE(employee_amount numeric, employer_amount numeric, schedule_id uuid, is_verified boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sched public.statutory_schedules;
  v_rate  public.statutory_rates;
  v_wage  numeric;
  v_ee    numeric := 0;
  v_er    numeric := 0;
  v_step  numeric;
begin
  v_sched := app.statutory_schedule_on(p_body, p_date);

  -- No table for this date. Nothing to compute and nothing to trust,
  -- which is the one case where `false` is the honest answer.
  if v_sched.id is null then
    return query select 0::numeric, 0::numeric, null::uuid, false;
    return;
  end if;

  -- A month of unpaid leave. There is nothing to contribute on, but the
  -- schedule is whatever it is -- reporting `false` here printed "the
  -- statutory figures on this payslip have not been verified" on a
  -- payslip whose schedules were fine.
  if p_wage <= 0 then
    return query select 0::numeric, 0::numeric, v_sched.id, v_sched.is_verified;
    return;
  end if;

  select * into v_rate
    from public.statutory_rates r
   where r.schedule_id = v_sched.id
     and r.category = p_category
     and p_wage >= r.wage_from
     and (r.wage_to is null or p_wage <= r.wage_to)
   order by r.wage_from desc
   limit 1;

  -- The hole, and the one thing that changes about it.
  --
  -- The amount stays zero. `statutory_schedules.sql` decided that
  -- deliberately -- "it contributes nothing rather than guessing at the
  -- nearest band" -- and guessing at a statutory figure is worse than
  -- not producing one. The schedule it consulted is still named, for
  -- the reason that file gives: a payslip should record what was looked
  -- in even when the answer was nothing.
  --
  -- What was wrong was the third value. It handed back the schedule's
  -- own `is_verified`, so a table checked against the gazette but
  -- missing a band reported a zero contribution as a verified figure --
  -- and `payslip_pdf.dart` prints its warning off that flag, so the one
  -- payslip that most needed a warning was the one that got none.
  -- Nothing about a wage no table covers has been verified.
  if v_rate.id is null then
    return query select 0::numeric, 0::numeric, v_sched.id, false;
    return;
  end if;

  -- Contributions stop counting wages above the insured ceiling.
  v_wage := least(p_wage, coalesce(v_rate.wage_ceiling, p_wage));

  -- KWSP rounds the wage up to the next RM20 before applying the rate.
  -- 0906. A band can carry its own step: Part F of the Third Schedule
  -- is a direct 2% on the wage itself, not on the next RM20, so a
  -- non-citizen's band says 0 and a citizen's says nothing and keeps
  -- the schedule's.
  v_step := coalesce(v_rate.wage_round_up_to, v_sched.wage_round_up_to);
  if v_step is not null and v_step > 0 then
    v_wage := ceil(v_wage / v_step) * v_step;
  end if;

  v_ee := coalesce(v_rate.employee_amount,
                   app.round_statutory(v_wage * v_rate.employee_rate / 100,
                                       v_sched.result_rounding));
  v_er := coalesce(v_rate.employer_amount,
                   app.round_statutory(v_wage * v_rate.employer_rate / 100,
                                       v_sched.result_rounding));

  return query select v_ee, v_er, v_sched.id, v_sched.is_verified;
end;
$function$;

-- public.platform_publish_statutory_schedule
CREATE OR REPLACE FUNCTION public.platform_publish_statutory_schedule(p_body text, p_name text, p_method text, p_effective_from date, p_rates jsonb, p_source text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_wage_round_up_to numeric DEFAULT NULL::numeric, p_result_rounding text DEFAULT 'nearest_cent'::text, p_is_verified boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_id    uuid;
  v_prior uuid;
  v_rate  jsonb;
  v_n     integer := 0;
begin
  if not app.is_platform_admin() then
    raise exception 'Statutory rates are shared by every organization and '
                    'may only be changed by a platform administrator'
      using errcode = '42501';
  end if;

  if jsonb_typeof(p_rates) <> 'array' or jsonb_array_length(p_rates) = 0 then
    raise exception 'A schedule with no rates would calculate nothing'
      using errcode = '23514';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A schedule needs a name' using errcode = '23514';
  end if;
  if p_result_rounding not in ('nearest_cent', 'nearest_5sen', 'up_ringgit') then
    raise exception 'Unknown rounding mode %', p_result_rounding
      using errcode = '22023';
  end if;

  -- Close whatever this supersedes, but only schedules that started
  -- earlier: republishing a correction to the current table must not
  -- give it an effective_to before its own effective_from.
  update public.statutory_schedules
     set effective_to = p_effective_from - 1
   where body = p_body::app.statutory_body
     and effective_from < p_effective_from
     and (effective_to is null or effective_to >= p_effective_from);

  -- A schedule already starting on this day is the one being corrected.
  select id into v_prior
    from public.statutory_schedules
   where body = p_body::app.statutory_body
     and effective_from = p_effective_from;

  if v_prior is not null then
    if exists (select 1 from public.payslips ps
                where ps.epf_schedule_id   = v_prior
                   or ps.socso_schedule_id = v_prior
                   or ps.eis_schedule_id   = v_prior
                   or ps.pcb_schedule_id   = v_prior) then
      raise exception
        'Payslips were already calculated on the % table starting %. '
        'Publish the correction from the date it takes effect.',
        p_body, p_effective_from using errcode = '55006';
    end if;
    delete from public.statutory_schedules where id = v_prior;
  end if;

  insert into public.statutory_schedules
    (body, name, method, effective_from, wage_round_up_to,
     result_rounding, source, is_verified, notes)
  values (p_body::app.statutory_body, btrim(p_name),
          p_method::app.statutory_method, p_effective_from,
          p_wage_round_up_to, p_result_rounding,
          nullif(btrim(p_source), ''), coalesce(p_is_verified, false),
          nullif(btrim(p_notes), ''))
  returning id into v_id;

  for v_rate in select * from jsonb_array_elements(p_rates) loop
    v_n := v_n + 1;
    insert into public.statutory_rates
      (schedule_id, category, wage_from, wage_to,
       employee_rate, employer_rate, employee_amount, employer_amount,
       wage_ceiling, wage_round_up_to, sort_order)
    values (
      v_id,
      coalesce(nullif(v_rate ->> 'category', ''), 'default'),
      coalesce((v_rate ->> 'wage_from')::numeric, 0),
      (v_rate ->> 'wage_to')::numeric,
      coalesce((v_rate ->> 'employee_rate')::numeric, 0),
      coalesce((v_rate ->> 'employer_rate')::numeric, 0),
      (v_rate ->> 'employee_amount')::numeric,
      (v_rate ->> 'employer_amount')::numeric,
      (v_rate ->> 'wage_ceiling')::numeric,
      -- 0906. A band's own wage step, where it has one.
      (v_rate ->> 'wage_round_up_to')::numeric,
      coalesce((v_rate ->> 'sort_order')::integer, v_n));
  end loop;

  -- `0404`. In the same transaction that inserted them, so a schedule
  -- with a hole in it is never published rather than published and
  -- then found.
  perform app.assert_statutory_bands(v_id);

  return v_id;
end;
$function$;

-- public.calculate_payroll_run
CREATE OR REPLACE FUNCTION public.calculate_payroll_run(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
       -- 0895: overtime on the days this payslip pays for, as 0894 did
       -- for unpaid leave -- not on a day before the hire date or after
       -- the last working day that a clock let somebody record.
       and a.work_date between v_from and v_to;

    v_ot_hours := round((v_ot.normal + v_ot.restday + v_ot.holiday) / 60.0, 2);
    v_ot_amt := round(v_hourly * (
        v_ot.normal  / 60.0 * coalesce(v_set.ot_normal_multiplier, 1.5)
      + v_ot.restday / 60.0 * coalesce(v_set.ot_restday_multiplier, 2.0)
      + v_ot.holiday / 60.0 * coalesce(v_set.ot_holiday_multiplier, 3.0)), 2);

    -- 0894: unpaid leave counts only on the days this payslip pays for,
    -- `v_from` to `v_to` -- the period cut to the hire date and the last
    -- working day. Basic is already prorated to those days; leave on a
    -- day outside them was deducted a second time.
    select coalesce(sum(
             lr.total_days
             * ((least(lr.end_date, v_to)
                 - greatest(lr.start_date, v_from) + 1)::numeric
                / greatest((lr.end_date - lr.start_date) + 1, 1))), 0)
      into v_unpaid
      from public.leave_requests lr
      join public.leave_types lt on lt.id = lr.leave_type_id
     where lr.employee_id = v_emp.id and lr.status = 'approved'
       and not lt.is_paid
       and lr.start_date <= v_to
       and lr.end_date >= v_from;

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
       is_hrdf_liable, account_id, component_id, is_additional_remuneration)
    select v_run.org_id, v_slip,
           10 + row_number() over (order by sc.sort_order, sc.code),
           sc.kind, sc.code, sc.name,
           round(coalesce(esc.amount, nullif(sc.default_amount, 0),
                 v_emp.basic_salary * coalesce(sc.percent_of_basic, 0) / 100), 2),
           sc.is_taxable, sc.is_epf_liable, sc.is_socso_liable, sc.is_eis_liable,
           sc.is_hrdf_liable, sc.account_id, sc.id,
           sc.is_additional_remuneration
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
           coalesce(sum(l.amount) filter (where l.is_taxable), 0) as taxable,
           coalesce(sum(l.amount) filter (
             where l.is_taxable and l.is_additional_remuneration), 0)
             as additional,
           coalesce(sum(l.amount) filter (
             where l.is_epf_liable and l.is_additional_remuneration), 0)
             as additional_epf_wage
      into v_base
      from public.payslip_lines l
     where l.payslip_id = v_slip and l.kind = 'earning';

    v_epf_ee := 0; v_epf_er := 0; v_epf_sched := null; v_epf_ver := true;
    v_soc_ee := 0; v_soc_er := 0; v_soc_sched := null; v_soc_ver := true;
    v_eis_ee := 0; v_eis_er := 0; v_eis_sched := null; v_eis_ver := true;
    v_pcb_amt := 0; v_pcb_sched := null; v_pcb_ver := true;

    if v_emp.epf_eligible then
      select c.employee_amount, c.employer_amount, c.schedule_id, c.is_verified
        into v_epf_ee, v_epf_er, v_epf_sched, v_epf_ver
        from app.calc_statutory('epf',
               app.epf_category(v_emp.residency_status, v_age,
                                v_emp.epf_pre_august_1998),  -- 0906
               v_base.epf_wage, v_period.pay_date) c;
    end if;
    v_epf_ee := coalesce(v_epf_ee, 0)
      + ceil(v_base.epf_wage * coalesce(v_emp.epf_voluntary_employee_rate, 0) / 100);
    v_epf_er := coalesce(v_epf_er, 0)
      + ceil(v_base.epf_wage * coalesce(v_emp.epf_voluntary_employer_rate, 0) / 100);

    if v_emp.socso_eligible then
      select c.employee_amount, c.employer_amount, c.schedule_id, c.is_verified
        into v_soc_ee, v_soc_er, v_soc_sched, v_soc_ver
        from app.calc_statutory('socso', v_soc_cat,
               v_base.socso_wage, v_period.pay_date) c;
    end if;

    if v_emp.eis_eligible and v_age < 60 then
      select c.employee_amount, c.employer_amount, c.schedule_id, c.is_verified
        into v_eis_ee, v_eis_er, v_eis_sched, v_eis_ver
        from app.calc_statutory('eis', 'default',
               v_base.eis_wage, v_period.pay_date) c;
    end if;

    v_zakat := coalesce(v_emp.zakat_monthly, 0);

    select c.pcb, c.schedule_id, c.is_verified
      into v_pcb_amt, v_pcb_sched, v_pcb_ver
      -- The month's taxable pay, split. Everything on the left is
      -- annualised by `calc_pcb`; the additional remuneration is added
      -- to the year once, which is the whole difference. The employee's
      -- EPF on the additional part is its share of the month's EPF,
      -- because EPF is a stepped function of the total wage and there
      -- is no separate figure to read for one line of it -- a
      -- proportional split keeps the year's relief equal to the year's
      -- actual contribution, which is the property that matters.
      from app.calc_pcb(v_emp.id,
             v_base.taxable - v_base.additional, v_epf_ee,
             coalesce(v_soc_ee, 0) + coalesce(v_eis_ee, 0),
             v_zakat, v_period.pay_date,
             v_base.additional,
             case when v_base.epf_wage > 0
                  then round(v_epf_ee * v_base.additional_epf_wage
                             / v_base.epf_wage, 2)
                  else 0 end) c;

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
$function$;

-- ---------------------------------------------------------------------
-- The tables
-- ---------------------------------------------------------------------
do $do$
declare
  v_prior uuid;
  v_new   uuid;
  v_s     record;
begin
  if exists (select 1 from public.statutory_schedules
              where body = 'epf' and effective_from > date '2025-10-01') then
    raise exception
      'An EPF table already starts after 1 October 2025. 0906 would put '
      'the 2%% rows under it rather than in it; publish the change into '
      'that table instead.' using errcode = '55000';
  end if;

  -- The pre-1998 member was always on the old rates, so every table
  -- before October 2025 carries them under their own name too. Nobody
  -- has the flag yet, so no payslip moves.
  for v_s in
    select s.id from public.statutory_schedules s
     where s.body = 'epf' and s.effective_from < date '2025-10-01'
  loop
    insert into public.statutory_rates
      (schedule_id, category, wage_from, wage_to, employee_rate,
       employer_rate, employee_amount, employer_amount, wage_ceiling,
       wage_round_up_to, sort_order)
    select r.schedule_id, replace(r.category, 'noncitizen_', 'noncitizen_pre1998_'),
           r.wage_from, r.wage_to, r.employee_rate, r.employer_rate,
           r.employee_amount, r.employer_amount, r.wage_ceiling,
           r.wage_round_up_to, r.sort_order + 100
      from public.statutory_rates r
     where r.schedule_id = v_s.id
       and r.category in ('noncitizen_under60', 'noncitizen_60plus');
    perform app.assert_statutory_bands(v_s.id);
  end loop;

  v_prior := (app.statutory_schedule_on('epf', date '2025-09-30')).id;
  if v_prior is null then
    raise exception 'No EPF table is in force on 30 September 2025.'
      using errcode = '55000';
  end if;

  update public.statutory_schedules
     set effective_to = date '2025-09-30'
   where body = 'epf'
     and effective_from < date '2025-10-01'
     and (effective_to is null or effective_to >= date '2025-10-01');

  insert into public.statutory_schedules
    (body, name, method, effective_from, wage_round_up_to,
     result_rounding, source, is_verified, notes)
  select 'epf', 'EPF statutory rates, non-citizens at 2% from October 2025',
         s.method, date '2025-10-01', s.wage_round_up_to, s.result_rounding,
         'KWSP Third Schedule; Part F for non-Malaysian citizen employees '
         'from October 2025 wages', false,
         'Citizens and permanent residents as before. Non-citizens (other '
         'than members from before 1 August 1998) pay 2% and the employer '
         '2% at every age, directly on the wage, each share rounded up to '
         'the ringgit. Load the gazetted table for exact band amounts.'
    from public.statutory_schedules s where s.id = v_prior
  returning id into v_new;

  -- Citizens and the pre-1998 member: as they were.
  insert into public.statutory_rates
    (schedule_id, category, wage_from, wage_to, employee_rate,
     employer_rate, employee_amount, employer_amount, wage_ceiling,
     wage_round_up_to, sort_order)
  select v_new, r.category, r.wage_from, r.wage_to, r.employee_rate,
         r.employer_rate, r.employee_amount, r.employer_amount,
         r.wage_ceiling, r.wage_round_up_to, r.sort_order
    from public.statutory_rates r
   where r.schedule_id = v_prior
     and (r.category like 'citizen%' or r.category like 'noncitizen_pre1998%');

  -- Everyone else who is not a citizen: 2% and 2%, on the wage itself.
  insert into public.statutory_rates
    (schedule_id, category, wage_from, wage_to, employee_rate,
     employer_rate, employee_amount, employer_amount, wage_ceiling,
     wage_round_up_to, sort_order)
  values (v_new, 'noncitizen_under60', 0, null, 2, 2, null, null, null, 0, 50),
         (v_new, 'noncitizen_60plus',  0, null, 2, 2, null, null, null, 0, 51);

  perform app.assert_statutory_bands(v_new);
end
$do$;
