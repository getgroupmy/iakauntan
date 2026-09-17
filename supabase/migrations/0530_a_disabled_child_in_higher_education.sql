-- ---------------------------------------------------------------------
-- A disabled child in higher education is relieved twice, not once
--
-- Found by a mutation sweep of `app.calc_pcb`. Only 19 of 41 one-line
-- mutants died against the suite, and among the survivors was one that
-- changed the relief for a DISABLED CHILD IN HIGHER EDUCATION from
-- RM8,000 to RM2,000 without a single assertion noticing. Reaching for
-- a figure to pin it with is what showed the figure was wrong.
--
-- Section 48 of the Income Tax Act 1967 gives an unmarried disabled
-- child RM6,000, and an ADDITIONAL RM8,000 where that child is
-- receiving full-time higher education -- diploma and above in
-- Malaysia, degree and above abroad. The two are cumulative: RM14,000.
--
-- The CASE gave RM8,000, which is what a child in higher education who
-- is NOT disabled gets. The disability was being read and then thrown
-- away for exactly the children entitled to most: the arm was
-- indistinguishable from the arm below it.
--
-- WHICH WAY IT IS WRONG matters for who is out of pocket.
-- Under-relieving OVER-deducts, so the employee has had too much taken
-- from every payslip and gets it back a year later at assessment. It is
-- their money, held by LHDN, for a year, because of a line in a CASE.
--
-- The function is re-emitted whole because 0161 has long since reached
-- the hosted project and migrations are append-only. One line differs.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.calc_pcb(p_employee_id uuid, p_taxable_this_month numeric, p_epf_this_month numeric, p_socso_eis_this_month numeric, p_zakat_this_month numeric, p_pay_date date, p_additional_this_month numeric DEFAULT 0, p_additional_epf_this_month numeric DEFAULT 0)
 RETURNS TABLE(pcb numeric, schedule_id uuid, is_verified boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_emp        public.employees;
  v_sched      public.statutory_schedules;
  v_year       integer := extract(year from p_pay_date)::integer;
  v_month      integer := extract(month from p_pay_date)::integer;
  v_n          integer;
  v_ytd_taxable numeric := 0;
  v_ytd_epf     numeric := 0;
  v_ytd_socso   numeric := 0;
  v_ytd_pcb     numeric := 0;
  v_ytd_zakat   numeric := 0;
  v_open       public.employee_ytd_opening;
  v_flat_rate  numeric;
  v_projected  numeric;
  v_relief     numeric := 0;
  v_epf_used   numeric := 0;
  v_epf_cap    numeric;
  v_soc_cap    numeric;
  v_children   numeric := 0;
  v_manual     numeric := 0;
  v_chargeable numeric;
  v_tax        numeric;
  v_zakat_year numeric;
  v_remaining  numeric;
  v_extra      numeric := 0;
  v_add        numeric := greatest(coalesce(p_additional_this_month, 0), 0);
  v_add_epf    numeric := greatest(coalesce(p_additional_epf_this_month, 0), 0);
begin
  select * into v_emp from public.employees e where e.id = p_employee_id;
  if v_emp.id is null or not v_emp.pcb_eligible then
    return query select 0::numeric, null::uuid, false;
    return;
  end if;

  v_sched := app.statutory_schedule_on('pcb', p_pay_date);
  if v_sched.id is null then
    return query select 0::numeric, null::uuid, false;
    return;
  end if;

  -- A flat rate is a flat rate: there is no projection to distort, so
  -- the additional part is simply part of the month's pay.
  if v_emp.residency_status in ('expatriate', 'foreign_worker') then
    select r.employee_rate into v_flat_rate
      from public.statutory_rates r
     where r.schedule_id = v_sched.id and r.category = 'nonresident'
     limit 1;
    return query select
      app.round_statutory(
        (p_taxable_this_month + v_add) * coalesce(v_flat_rate, 0) / 100,
        'nearest_5sen'),
      v_sched.id, v_sched.is_verified;
    return;
  end if;

  v_n := greatest(12 - v_month + 1, 1);

  select coalesce(y.taxable_income, 0),
         coalesce(y.epf_employee, 0),
         coalesce(y.socso_employee, 0) + coalesce(y.eis_employee, 0),
         coalesce(y.pcb, 0),
         coalesce(y.zakat, 0)
    into v_ytd_taxable, v_ytd_epf, v_ytd_socso, v_ytd_pcb, v_ytd_zakat
    from public.payroll_ytd y
   where y.employee_id = p_employee_id and y.tax_year = v_year;

  v_ytd_taxable := coalesce(v_ytd_taxable, 0);
  v_ytd_epf     := coalesce(v_ytd_epf, 0);
  v_ytd_socso   := coalesce(v_ytd_socso, 0);
  v_ytd_pcb     := coalesce(v_ytd_pcb, 0);
  v_ytd_zakat   := coalesce(v_ytd_zakat, 0);

  select * into v_open from public.employee_ytd_opening o
   where o.employee_id = p_employee_id and o.tax_year = v_year;

  -- The year on normal pay alone. `p_taxable_this_month` no longer
  -- carries the bonus, so this is the projection the Rules describe.
  v_projected := v_ytd_taxable
               + coalesce(v_open.gross_pay, 0)
               + coalesce(v_open.benefits_in_kind, 0)
               + p_taxable_this_month * v_n;

  select coalesce(sum(tr.default_amount), 0) into v_relief
    from public.tax_reliefs tr
   where tr.schedule_id = v_sched.id and tr.is_automatic
     and tr.code = 'individual';

  select coalesce(max(tr.max_amount), 4000) into v_epf_cap
    from public.tax_reliefs tr
   where tr.schedule_id = v_sched.id and tr.code = 'epf';
  v_epf_used := v_ytd_epf + coalesce(v_open.epf_employee, 0)
              + p_epf_this_month * v_n;
  v_relief := v_relief + least(v_epf_used, v_epf_cap);

  select coalesce(max(tr.max_amount), 350) into v_soc_cap
    from public.tax_reliefs tr
   where tr.schedule_id = v_sched.id and tr.code = 'socso_eis';
  v_relief := v_relief + least(
    v_ytd_socso + p_socso_eis_this_month * v_n, v_soc_cap);

  if v_emp.marital_status = 'married' and not v_emp.spouse_is_working then
    v_relief := v_relief + coalesce(
      (select tr.default_amount from public.tax_reliefs tr
        where tr.schedule_id = v_sched.id and tr.code = 'spouse'), 4000);
  end if;
  if v_emp.is_disabled then
    v_relief := v_relief + coalesce(
      (select tr.default_amount from public.tax_reliefs tr
        where tr.schedule_id = v_sched.id and tr.code = 'disabled_self'), 6000);
  end if;
  if v_emp.spouse_is_disabled then
    v_relief := v_relief + coalesce(
      (select tr.default_amount from public.tax_reliefs tr
        where tr.schedule_id = v_sched.id and tr.code = 'disabled_spouse'), 5000);
  end if;

  select coalesce(sum(
      case
        when d.is_disabled and d.in_higher_education then 14000
        when d.is_disabled then 6000
        when d.in_higher_education then 8000
        else 2000
      end * d.relief_claim_percent / 100), 0)
    into v_children
    from public.employee_dependants d
   where d.employee_id = p_employee_id
     and d.is_tax_dependant
     and lower(d.relationship) = 'child';
  v_relief := v_relief + v_children;

  select coalesce(sum(etr.amount), 0) into v_manual
    from public.employee_tax_reliefs etr
   where etr.employee_id = p_employee_id and etr.tax_year = v_year;
  v_relief := v_relief + v_manual;

  v_chargeable := greatest(v_projected - v_relief, 0);
  v_tax := app.annual_tax(v_chargeable, v_sched.id);

  v_zakat_year := v_ytd_zakat + coalesce(v_open.zakat_paid, 0)
                + p_zakat_this_month * v_n;
  v_tax := greatest(v_tax - v_zakat_year, 0);

  v_remaining := v_tax - v_ytd_pcb - coalesce(v_open.pcb_paid, 0);

  -- The additional remuneration, once. The deduction on it is the
  -- difference the year's tax makes for having received it -- not a
  -- twelfth of anything, and not annualised, because it does not
  -- happen again.
  if v_add > 0 then
    v_extra :=
      app.annual_tax(
        greatest(v_projected + v_add
                 - (v_relief
                    - least(v_epf_used, v_epf_cap)
                    + least(v_epf_used + v_add_epf, v_epf_cap)), 0),
        v_sched.id)
      - app.annual_tax(v_chargeable, v_sched.id);
    v_extra := greatest(v_extra, 0);
  end if;

  return query select
    greatest(app.round_statutory(v_remaining / v_n, 'nearest_5sen'), 0)
      + app.round_statutory(v_extra, 'nearest_5sen'),
    v_sched.id, v_sched.is_verified;
end;
$function$;


comment on function app.calc_pcb is
  'Monthly tax deduction under the Income Tax (Deduction from '
  'Remuneration) Rules. 0530: a disabled child in higher education is '
  'relieved RM14,000, being RM6,000 for the disability and RM8,000 for '
  'the education, which section 48 makes cumulative.';
