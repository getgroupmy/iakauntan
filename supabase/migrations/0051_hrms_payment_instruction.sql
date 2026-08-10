-- =====================================================================
-- iAkauntan :: 0051 paying a posted payroll run
--
-- Posting a run books the liability; it does not move any money. This
-- turns a posted run into a payment instruction — one line per employee
-- with the bank, the account number, the net pay and a reference the
-- payer can reconcile against — and lets the run be marked paid once
-- the bank has taken the file.
--
-- Rows with nothing to pay to are not dropped. An employee missing a
-- bank account is far more dangerous when they silently vanish from the
-- file than when they show up flagged, so every payslip is returned and
-- the trouble is named in `problem`.
-- =====================================================================


create or replace function public.payroll_payment_instruction(p_run_id uuid)
returns table (
  employee_no     text,
  employee_name   text,
  bank_name       text,
  bank_account_no text,
  amount          numeric,
  reference       text,
  problem         text)
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare
  v_run    public.payroll_runs;
  v_period public.pay_periods;
begin
  select * into v_run from public.payroll_runs where id = p_run_id;
  if v_run.id is null then
    raise exception 'Payroll run not found' using errcode = 'P0002';
  end if;
  if not app.can_run_payroll(v_run.org_id) then
    raise exception 'Not permitted to see payroll' using errcode = '42501';
  end if;
  if v_run.status not in ('posted', 'paid') then
    raise exception
      'Pay a run once it is posted; this one is %', v_run.status
      using errcode = '22023';
  end if;

  select * into v_period from public.pay_periods where id = v_run.period_id;

  return query
  select p.employee_no,
         p.employee_name,
         p.bank_name,
         p.bank_account_no,
         p.net_pay,
         format('%s %s', coalesce(v_period.code, ''), v_run.run_no),
         case
           when coalesce(btrim(p.bank_account_no), '') = ''
             then 'No bank account on file'
           when coalesce(btrim(p.bank_name), '') = ''
             then 'No bank named'
           when p.net_pay <= 0
             then 'Nothing to pay'
         end
    from public.payslips p
   where p.run_id = p_run_id
   order by p.employee_no;
end;
$$;


-- Marking a run paid is a statement about the outside world, so it is
-- deliberately a separate step from producing the file: the run stays
-- posted until someone confirms the bank took it.
create or replace function public.mark_payroll_paid(p_run_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare v_run public.payroll_runs;
begin
  select * into v_run from public.payroll_runs where id = p_run_id;
  if v_run.id is null then
    raise exception 'Payroll run not found' using errcode = 'P0002';
  end if;
  if not app.can_run_payroll(v_run.org_id) then
    raise exception 'Not permitted to run payroll' using errcode = '42501';
  end if;
  if v_run.status <> 'posted' then
    raise exception 'Only a posted run can be marked paid; this one is %',
      v_run.status using errcode = '22023';
  end if;

  update public.payroll_runs
     set status = 'paid', paid_at = now() where id = p_run_id;
end;
$$;

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
