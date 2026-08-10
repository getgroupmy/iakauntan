-- =====================================================================
-- iAkauntan :: 0050 payroll posts claims to their own accounts
--
-- Salary expense is debited net of the reimbursements riding along with
-- it, and each claim goes to the account its claim type names.
-- =====================================================================


create or replace function public.post_payroll_run(p_run_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run    public.payroll_runs;
  v_period public.pay_periods;
  v_set    public.payroll_settings;
  v_lines  jsonb := '[]'::jsonb;
  v_entry  uuid;
  v_year   integer;
  v_claims numeric := 0;
  v_alloc  record;
begin
  select * into v_run from public.payroll_runs where id = p_run_id;
  if v_run.id is null then
    raise exception 'Payroll run not found' using errcode = 'P0002';
  end if;
  if not app.can_run_payroll(v_run.org_id) then
    raise exception 'Not permitted to post payroll' using errcode = '42501';
  end if;
  if v_run.status not in ('calculated', 'approved') then
    raise exception 'Only a calculated run can be posted; this one is %',
      v_run.status using errcode = '22023';
  end if;
  if v_run.employee_count = 0 then
    raise exception 'This run has no payslips to post' using errcode = '22023';
  end if;

  select * into v_period from public.pay_periods where id = v_run.period_id;
  select * into v_set from public.payroll_settings where org_id = v_run.org_id;
  v_year := extract(year from v_period.pay_date)::integer;

  select coalesce(sum(claims_amount), 0) into v_claims
    from public.payslips where run_id = p_run_id;

  -- Salary expense, net of the reimbursements riding along with it. A
  -- claim is somebody's expense, not their pay.
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.salary_expense_account_id, '6100',
    v_run.total_gross - v_claims, 0, 'Salaries and wages');

  -- Each claim to the account its type names.
  for v_alloc in
    select a.account_id, sum(a.amount) as amount
      from public.expense_claims c
      join public.payslips p
        on p.employee_id = c.employee_id and p.run_id = p_run_id
      cross join lateral app.claim_expense_allocation(c.id) a
     where c.status = 'approved'
       and c.pay_with_payroll
       and c.paid_at is null
       and c.claim_date <= v_period.period_end
     group by a.account_id
  loop
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', v_alloc.account_id,
      'description', 'Staff expense claims',
      'debit', v_alloc.amount, 'credit', 0));
  end loop;

  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.epf_expense_account_id, '6110',
    v_run.total_epf_employer, 0, 'EPF employer contribution');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.socso_expense_account_id, '6120',
    v_run.total_socso_employer, 0, 'SOCSO employer contribution');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.eis_expense_account_id, '6130',
    v_run.total_eis_employer, 0, 'EIS employer contribution');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.hrdf_expense_account_id, '6150',
    v_run.total_hrdf, 0, 'HRD Corp levy');

  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.epf_payable_account_id, '2150',
    0, v_run.total_epf_employee + v_run.total_epf_employer, 'EPF payable');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.socso_payable_account_id, '2160',
    0, v_run.total_socso_employee + v_run.total_socso_employer, 'SOCSO payable');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.eis_payable_account_id, '2170',
    0, v_run.total_eis_employee + v_run.total_eis_employer, 'EIS payable');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.pcb_payable_account_id, '2180',
    0, v_run.total_pcb, 'PCB / MTD payable');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.zakat_payable_account_id, '2185',
    0, v_run.total_zakat, 'Zakat payable');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, null, '2195', 0, v_run.total_hrdf, 'HRD Corp levy payable');
  v_lines := v_lines || app.payroll_gl_line(
    v_run.org_id, v_set.salary_payable_account_id, '2145',
    0, v_run.total_net, 'Net salaries payable');

  v_entry := public.create_gl_entry(
    p_org_id       => v_run.org_id,
    p_entry_date   => v_period.pay_date,
    p_source       => 'payroll'::app.journal_source,
    p_lines        => v_lines,
    p_description  => format('Payroll %s', v_period.code),
    p_source_table => 'payroll_runs',
    p_source_id    => p_run_id,
    p_reference    => v_run.run_no
  );

  update public.payroll_runs
     set status = 'posted', gl_entry_id = v_entry, posted_at = now(),
         total_claims = v_claims
   where id = p_run_id;

  insert into public.payroll_ytd as y (
    org_id, employee_id, tax_year, gross_pay, taxable_income,
    epf_employee, epf_employer, socso_employee, socso_employer,
    eis_employee, eis_employer, pcb, zakat, net_pay, months_paid)
  select p.org_id, p.employee_id, v_year, p.gross_pay, p.taxable_income,
         p.epf_employee, p.epf_employer, p.socso_employee, p.socso_employer,
         p.eis_employee, p.eis_employer, p.pcb + p.cp38, p.zakat, p.net_pay, 1
    from public.payslips p
   where p.run_id = p_run_id
  on conflict (employee_id, tax_year) do update set
    gross_pay      = y.gross_pay      + excluded.gross_pay,
    taxable_income = y.taxable_income + excluded.taxable_income,
    epf_employee   = y.epf_employee   + excluded.epf_employee,
    epf_employer   = y.epf_employer   + excluded.epf_employer,
    socso_employee = y.socso_employee + excluded.socso_employee,
    socso_employer = y.socso_employer + excluded.socso_employer,
    eis_employee   = y.eis_employee   + excluded.eis_employee,
    eis_employer   = y.eis_employer   + excluded.eis_employer,
    pcb            = y.pcb            + excluded.pcb,
    zakat          = y.zakat          + excluded.zakat,
    net_pay        = y.net_pay        + excluded.net_pay,
    months_paid    = y.months_paid    + 1;

  -- Marked settled only now, after their allocation has been posted.
  update public.expense_claims c
     set paid_at = now(),
         gl_entry_id = coalesce(c.gl_entry_id, v_entry),
         posted_at = coalesce(c.posted_at, now())
   from public.payslips p
   where p.run_id = p_run_id
     and c.employee_id = p.employee_id
     and c.status = 'approved'
     and c.pay_with_payroll
     and c.paid_at is null
     and c.claim_date <= v_period.period_end;

  return v_entry;
end;
$$;

comment on function public.post_payroll_run is
  'Posts a calculated run: salaries net of reimbursed claims, each claim to the account its type names, statutory amounts to their payables.';
