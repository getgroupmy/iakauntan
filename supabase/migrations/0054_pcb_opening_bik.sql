-- =====================================================================
-- iAkauntan :: 0054 benefits in kind count as income
--
-- employee_ytd_opening.benefits_in_kind was stored and never read.
-- Benefits in kind and perquisites are employment income under section
-- 13 of the Income Tax Act, so they belong in the annual projection
-- alongside the gross already paid this year.
--
-- The rest of the function is unchanged; it is restated in full because
-- plpgsql bodies are replaced whole.
-- =====================================================================

create or replace function app.calc_pcb(
  p_employee_id uuid, p_taxable_this_month numeric, p_epf_this_month numeric,
  p_socso_eis_this_month numeric, p_zakat_this_month numeric, p_pay_date date)
returns table (pcb numeric, schedule_id uuid, is_verified boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
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
  v_epf_cap    numeric;
  v_soc_cap    numeric;
  v_children   numeric := 0;
  v_manual     numeric := 0;
  v_chargeable numeric;
  v_tax        numeric;
  v_zakat_year numeric;
  v_remaining  numeric;
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

  if v_emp.residency_status in ('expatriate', 'foreign_worker') then
    select r.employee_rate into v_flat_rate
      from public.statutory_rates r
     where r.schedule_id = v_sched.id and r.category = 'nonresident'
     limit 1;
    return query select
      app.round_statutory(p_taxable_this_month * coalesce(v_flat_rate, 0) / 100,
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
  v_relief := v_relief + least(
    v_ytd_epf + coalesce(v_open.epf_employee, 0) + p_epf_this_month * v_n,
    v_epf_cap);

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
        when d.is_disabled and d.in_higher_education then 8000
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

  return query select
    greatest(app.round_statutory(v_remaining / v_n, 'nearest_5sen'), 0),
    v_sched.id, v_sched.is_verified;
end; $$;

do $do$
declare fn record;
begin
  for fn in
    select n.nspname as s, p.proname as f,
           pg_get_function_identity_arguments(p.oid) as a
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
  loop
    execute format('revoke all on function %I.%I(%s) from public, anon', fn.s, fn.f, fn.a);
    execute format('grant execute on function %I.%I(%s) to authenticated, service_role', fn.s, fn.f, fn.a);
  end loop;
end
$do$;
