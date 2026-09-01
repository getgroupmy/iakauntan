-- =====================================================================
-- iAkauntan :: a posted payslip is frozen
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/posted_payslip_is_frozen.sql
--
-- `0238` is called "the ledger becomes append-only" and its second
-- heading is "No hand may reach a posted journal". Nobody applied the
-- same reasoning to the payslip, though the payslip is what the EPF,
-- SOCSO and LHDN submissions and `0035`'s bank file are built from.
--
-- Measured before `0400`, as an `hr_manager` on a run whose status is
-- `posted`: a payslip line's amount rewritten from 550.00 to 1.00, the
-- header's `epf_employee` and `pcb` rewritten, a line deleted — all
-- accepted, and zero audit rows written by any of it. `payslip_lines`
-- carries no triggers at all.
--
-- ---------------------------------------------------------------------
-- Under `set local role authenticated`, for the reason `0399` learned
--
-- `pg_temp.sign_in_as` sets the JWT claims and does not change the
-- session role, so a test that only signs in runs as the table owner
-- and neither RLS nor a grant applies to it. The refusal here is a
-- trigger, which does fire for the owner too — but the *positive*
-- control is about what an ordinary caller may still do, and that is
-- only meaningful under the real role. So the role is changed and then
-- asserted.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pay (
  org uuid, hr uuid,
  open_run uuid, open_slip uuid, open_line uuid,
  posted_run uuid, posted_slip uuid, posted_line uuid);
grant select on t_pay to authenticated;

do $$
declare
  v_org uuid; v_owner uuid := pg_temp.test_user(); v_hr uuid; v_emp uuid;
  v_period uuid;
  v_open_run uuid; v_open_slip uuid; v_open_line uuid;
  v_run uuid; v_slip uuid; v_line uuid;
begin
  v_org := pg_temp.test_org('Gaji Beku Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'E1', 'Encik Ali', date '2020-01-01', 5000,
          date '1990-01-01', 'citizen') returning id into v_emp;
  insert into public.pay_periods
    (org_id, code, period_start, period_end, pay_date)
  values (v_org, '2026-08', date '2026-08-01', date '2026-08-31',
          date '2026-08-31') returning id into v_period;

  -- One run still being worked on, and one that has been posted. The
  -- pair is the whole point: the rule has to bite on the second and
  -- leave the first alone.
  insert into public.payroll_runs (org_id, run_no, period_id, status)
  values (v_org, 'PR-OPEN', v_period, 'calculated') returning id into v_open_run;
  insert into public.payslips
    (org_id, run_id, employee_id, employee_no, employee_name,
     basic_salary, gross_pay, total_deductions, net_pay,
     epf_wage, epf_employee, pcb)
  values (v_org, v_open_run, v_emp, 'E1', 'Encik Ali', 5000,
          5000, 550, 4450, 5000, 550, 0) returning id into v_open_slip;
  insert into public.payslip_lines
    (org_id, payslip_id, line_no, kind, code, description, amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable)
  values (v_org, v_open_slip, 1, 'deduction', 'EPF', 'EPF employee', 550,
          false, false, false, false) returning id into v_open_line;

  insert into public.payroll_runs (org_id, run_no, period_id, status)
  values (v_org, 'PR-POSTED', v_period, 'posted') returning id into v_run;
  insert into public.payslips
    (org_id, run_id, employee_id, employee_no, employee_name,
     basic_salary, gross_pay, total_deductions, net_pay,
     epf_wage, epf_employee, pcb)
  values (v_org, v_run, v_emp, 'E1', 'Encik Ali', 5000,
          5000, 550, 4450, 5000, 550, 0) returning id into v_slip;
  insert into public.payslip_lines
    (org_id, payslip_id, line_no, kind, code, description, amount,
     is_taxable, is_epf_liable, is_socso_liable, is_eis_liable)
  values (v_org, v_slip, 1, 'deduction', 'EPF', 'EPF employee', 550,
          false, false, false, false) returning id into v_line;

  v_hr := pg_temp.another_user('freeze@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_hr, 'hr_manager', 'active');

  insert into t_pay values (v_org, v_hr, v_open_run, v_open_slip,
    v_open_line, v_run, v_slip, v_line);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select hr from t_pay),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record; v_msg text;
begin
  select * into c from t_pay;

  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('and this member really may run payroll',
    app.can_run_payroll(c.org));
  perform pg_temp.check_eq('one run is posted',
    (select status::text from public.payroll_runs where id = c.posted_run),
    'posted');

  -- ------------------------------------------------------------------
  -- The posted run
  -- ------------------------------------------------------------------
  begin
    update public.payslip_lines set amount = 1 where id = c.posted_line;
    raise exception
      'FAIL: a line on a posted payslip was rewritten by hand';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal names the run and its state',
      v_msg like '%PR-POSTED is posted%');
    raise notice 'ok   a posted payslip line cannot be rewritten';
  end;
  perform pg_temp.check_eq('so the statutory figure is unchanged',
    (select amount from public.payslip_lines where id = c.posted_line), 550);

  begin
    update public.payslips set epf_employee = 1, pcb = 0
     where id = c.posted_slip;
    raise exception 'FAIL: a posted payslip header was rewritten';
  exception when sqlstate '42501' then
    raise notice 'ok   nor can the header it is summed into';
  end;
  perform pg_temp.check_eq('and that figure is unchanged too',
    (select epf_employee from public.payslips where id = c.posted_slip), 550);

  begin
    delete from public.payslip_lines where id = c.posted_line;
    raise exception 'FAIL: a line was deleted from a posted payslip';
  exception when sqlstate '42501' then
    raise notice 'ok   and a line cannot be taken off it';
  end;
  perform pg_temp.check_eq('the line is still there',
    (select count(*) from public.payslip_lines where id = c.posted_line), 1);

  begin
    delete from public.payslips where id = c.posted_slip;
    raise exception 'FAIL: a posted payslip was deleted';
  exception when sqlstate '42501' then
    raise notice 'ok   nor the payslip itself';
  end;

  -- ------------------------------------------------------------------
  -- The run still being worked on
  -- ------------------------------------------------------------------
  -- The positive control, and the reason this is a trigger on the
  -- status rather than a revoked grant: correcting a payroll before it
  -- is posted is the ordinary business of running one.
  update public.payslip_lines set amount = 600 where id = c.open_line;
  perform pg_temp.check_eq('an unposted run is still HR''s to correct',
    (select amount from public.payslip_lines where id = c.open_line), 600);
  update public.payslips set epf_employee = 600 where id = c.open_slip;
  perform pg_temp.check_eq('header and all',
    (select epf_employee from public.payslips where id = c.open_slip), 600);
  delete from public.payslip_lines where id = c.open_line;
  perform pg_temp.check_eq('and a line may still be taken off it',
    (select count(*) from public.payslip_lines where id = c.open_line), 0);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The rule follows the run's status, so it has to be checked at each one
-- ---------------------------------------------------------------------
do $$
declare
  c record; v_state text; v_refused boolean;
begin
  select * into c from t_pay;
  foreach v_state in array array['draft', 'calculated', 'approved',
                                 'posted', 'paid', 'void']
  loop
    update public.payroll_runs set status = v_state::app.payroll_status
     where id = c.posted_run;
    begin
      update public.payslip_lines set amount = 550
       where id = c.posted_line;
      v_refused := false;
    exception when sqlstate '42501' then
      v_refused := true;
    end;

    if v_state in ('posted', 'paid') then
      if not v_refused then
        raise exception 'FAIL: a % run let its payslip be edited', v_state;
      end if;
    else
      if v_refused then
        raise exception
          'FAIL: a % run refused an edit; only posted and paid should', v_state;
      end if;
    end if;
  end loop;
  raise notice 'ok   frozen at posted and paid, editable at draft, '
    'calculated, approved and void';
end $$;

rollback;
