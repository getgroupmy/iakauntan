-- =====================================================================
-- iAkauntan :: 0030 hrms doc prefixes and pcb
-- Applied as project migration 20260810054710.
-- =====================================================================

-- Numbering prefixes for the HR documents.
create or replace function app.default_doc_prefix(p_doc_type text)
returns text language sql immutable as $$
  select case p_doc_type
    when 'quotation'            then 'QT-'
    when 'sales_order'          then 'SO-'
    when 'delivery_order'       then 'DO-'
    when 'invoice'              then 'INV-'
    when 'credit_note'          then 'CN-'
    when 'debit_note'           then 'DN-'
    when 'refund_note'          then 'RN-'
    when 'proforma'             then 'PF-'
    when 'purchase_request'     then 'PR-'
    when 'purchase_order'       then 'PO-'
    when 'goods_received'       then 'GRN-'
    when 'bill'                 then 'BILL-'
    when 'purchase_credit_note' then 'PCN-'
    when 'purchase_debit_note'  then 'PDN-'
    when 'purchase_return'      then 'PRT-'
    when 'receipt'              then 'RCP-'
    when 'payment'              then 'PAY-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'matter'               then 'MAT-'
    when 'client_transaction'   then 'CLI-'
    when 'employee'             then 'EMP-'
    when 'payroll_run'          then 'PYR-'
    when 'leave_request'        then 'LV-'
    when 'expense_claim'        then 'CLM-'
    when 'job_requisition'      then 'JR-'
    else 'DOC-'
  end;
$$;

-- Monthly tax deduction.
--
-- PCB is an instalment against an annual liability: project the year at
-- the current month's rate, take off the reliefs the employee is
-- entitled to, tax the result, then spread what remains over the months
-- still to come. That is what LHDN's computerised method does; the M/R/B
-- table in the manual method is a precomputed form of the same sum.
create or replace function app.calc_pcb(
  p_employee_id uuid,
  p_taxable_this_month numeric,
  p_epf_this_month numeric,
  p_socso_eis_this_month numeric,
  p_zakat_this_month numeric,
  p_pay_date date
)
returns table (pcb numeric, schedule_id uuid, is_verified boolean)
language plpgsql stable
set search_path = public, app, pg_temp as $$
declare
  v_emp        public.employees;
  v_sched      public.statutory_schedules;
  v_year       integer := extract(year from p_pay_date)::integer;
  v_month      integer := extract(month from p_pay_date)::integer;
  v_n          integer;                 -- months left including this one
  v_ytd        record;
  v_open       public.employee_ytd_opening;
  v_flat_rate  numeric;
  v_projected  numeric;
  v_relief     numeric := 0;
  v_epf_relief numeric;
  v_soc_relief numeric;
  v_children   numeric := 0;
  v_manual     numeric := 0;
  v_chargeable numeric;
  v_tax        numeric;
  v_zakat_year numeric;
  v_remaining  numeric;
begin
  select * into v_emp from public.employees where id = p_employee_id;
  if v_emp.id is null or not v_emp.pcb_eligible then
    return query select 0::numeric, null::uuid, false;
    return;
  end if;

  v_sched := app.statutory_schedule_on('pcb', p_pay_date);
  if v_sched.id is null then
    return query select 0::numeric, null::uuid, false;
    return;
  end if;

  -- A non-resident is deducted at a flat rate with no reliefs at all.
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

  select coalesce(y.taxable_income, 0) as taxable,
         coalesce(y.epf_employee, 0) as epf,
         coalesce(y.socso_employee, 0) + coalesce(y.eis_employee, 0) as socso_eis,
         coalesce(y.pcb, 0) as pcb,
         coalesce(y.zakat, 0) as zakat
    into v_ytd
    from public.payroll_ytd y
   where y.employee_id = p_employee_id and y.tax_year = v_year;

  if v_ytd is null then
    v_ytd := row(0::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric);
  end if;

  select * into v_open from public.employee_ytd_opening
   where employee_id = p_employee_id and tax_year = v_year;

  -- Everything already earned this year, plus this month projected
  -- across the months that remain.
  v_projected := coalesce(v_ytd.taxable, 0) + coalesce(v_open.gross_pay, 0)
               + p_taxable_this_month * v_n;

  -- Automatic reliefs
  select coalesce(sum(case when tr.code = 'individual' then tr.default_amount else 0 end), 0)
    into v_relief
    from public.tax_reliefs tr
   where tr.schedule_id = v_sched.id and tr.is_automatic;

  select coalesce(max(max_amount), 4000) into v_epf_relief
    from public.tax_reliefs where schedule_id = v_sched.id and code = 'epf';
  v_relief := v_relief + least(
    coalesce(v_ytd.epf, 0) + coalesce(v_open.epf_employee, 0)
      + p_epf_this_month * v_n,
    v_epf_relief);

  select coalesce(max(max_amount), 350) into v_soc_relief
    from public.tax_reliefs where schedule_id = v_sched.id and code = 'socso_eis';
  v_relief := v_relief + least(
    coalesce(v_ytd.socso_eis, 0) + p_socso_eis_this_month * v_n, v_soc_relief);

  -- Family reliefs
  if v_emp.marital_status = 'married' and not v_emp.spouse_is_working then
    v_relief := v_relief + coalesce(
      (select default_amount from public.tax_reliefs
        where schedule_id = v_sched.id and code = 'spouse'), 4000);
  end if;
  if v_emp.is_disabled then
    v_relief := v_relief + coalesce(
      (select default_amount from public.tax_reliefs
        where schedule_id = v_sched.id and code = 'disabled_self'), 6000);
  end if;
  if v_emp.spouse_is_disabled then
    v_relief := v_relief + coalesce(
      (select default_amount from public.tax_reliefs
        where schedule_id = v_sched.id and code = 'disabled_spouse'), 5000);
  end if;

  -- Children. A disabled child in higher education attracts the larger
  -- of the two amounts rather than both.
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

  -- What the employee has told payroll they will claim.
  select coalesce(sum(amount), 0) into v_manual
    from public.employee_tax_reliefs
   where employee_id = p_employee_id and tax_year = v_year;
  v_relief := v_relief + v_manual;

  v_chargeable := greatest(v_projected - v_relief, 0);
  v_tax := app.annual_tax(v_chargeable, v_sched.id);

  -- Zakat is a rebate against tax, not a relief against income.
  v_zakat_year := coalesce(v_ytd.zakat, 0) + coalesce(v_open.zakat_paid, 0)
                + p_zakat_this_month * v_n;
  v_tax := greatest(v_tax - v_zakat_year, 0);

  v_remaining := v_tax - coalesce(v_ytd.pcb, 0) - coalesce(v_open.pcb_paid, 0);

  return query select
    greatest(app.round_statutory(v_remaining / v_n, 'nearest_5sen'), 0),
    v_sched.id, v_sched.is_verified;
end;
$$;

comment on function app.calc_pcb is
  'Monthly tax deduction: projects the year, applies reliefs, taxes the result and spreads the balance over the remaining months.';
