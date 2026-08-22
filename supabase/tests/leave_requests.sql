-- =====================================================================
-- iAkauntan :: filing leave, and deciding it
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/leave_requests.sql
--
-- Leave looks like an HR formality until you follow where it goes.
-- calculate_payroll_run reads approved requests whose leave type is not
-- paid and turns them into a negative earning line -- payroll_run.sql's
-- W3 is exactly that -- so an approved unpaid request comes off gross
-- pay, off the EPF wage, off the SOCSO and EIS wages and off taxable
-- income. Who may file one, and who may approve it, decides somebody's
-- statutory figures.
--
-- Neither function was called by a test, and submit_leave_request's
-- permission guard did not work: `v_emp <> app.my_employee_id(p_org_id)`
-- goes null for a caller with no employee record, and a null condition
-- never raises. 0283 makes the comparison null-safe. The first section
-- below is the regression test for it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org      uuid;
  v_owner    uuid := pg_temp.test_user();
  v_clerk    uuid;
  v_boss     uuid;
  v_staff    uuid;
  v_e_boss   uuid;
  v_e_staff  uuid;
  v_annual   uuid;
  v_unpaid   uuid;
  v_req      uuid;
  v_req2     uuid;
  v_unpaid_req uuid;
  r          record;
  v_msg      text;
begin
  v_org := pg_temp.test_org('Cuti Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);

  v_boss  := pg_temp.another_user('manager@example.test');
  v_staff := pg_temp.another_user('staff@example.test');
  v_clerk := pg_temp.another_user('clerk@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_boss,  'viewer', 'active'),
         (v_org, v_staff, 'viewer', 'active'),
         -- A member with a real role, real access, and no employee
         -- record of their own. This is the account the guard missed.
         (v_org, v_clerk, 'accounts_clerk', 'active');

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, user_id)
  values (v_org, 'E1', 'Puan Siti', date '2020-01-01', 8000,
          date '1985-01-01', 'citizen', v_boss)
  returning id into v_e_boss;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status, user_id, manager_id)
  values (v_org, 'E2', 'Encik Zul', date '2021-01-01', 4000,
          date '1995-01-01', 'citizen', v_staff, v_e_boss)
  returning id into v_e_staff;

  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'AL', 'Annual leave', true) returning id into v_annual;
  insert into public.leave_types (org_id, code, name, is_paid)
  values (v_org, 'UNPAID', 'Unpaid leave', false) returning id into v_unpaid;

  insert into public.leave_balances
    (org_id, employee_id, leave_type_id, leave_year, entitled_days)
  values (v_org, v_e_staff, v_annual, 2026, 8);

  -- ==================================================================
  -- Filing for somebody else
  -- ==================================================================
  -- The regression test. Before 0283 the accounts clerk -- a member of
  -- the company, not HR, with no employee record -- could file leave
  -- against anybody, because the guard compared against a null and a
  -- null condition does not raise.
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true('the clerk really has no employee record',
    app.my_employee_id(v_org) is null);
  perform pg_temp.check_true('and really is not HR',
    not app.can_manage_hr(v_org));
  begin
    perform public.submit_leave_request(
      v_org, v_unpaid, date '2026-03-02', date '2026-03-06', 5,
      'Not mine to file', false, null, v_e_staff);
    raise exception
      'FAIL: a member with no employee record filed leave for somebody else';
  exception when sqlstate '42501' then
    raise notice 'ok   a member who is not HR cannot file leave for another';
  end;
  perform pg_temp.check_eq('and nothing was filed',
    (select count(*) from public.leave_requests where org_id = v_org), 0);
  -- Nor is a hold left behind on the balance the request never reached.
  perform pg_temp.check_eq('nor held against anybody''s balance',
    (select coalesce(sum(pending_days), 0) from public.leave_balances
      where org_id = v_org), 0);

  -- Filing for themselves is a different refusal: there is nobody to
  -- file for, which is P0002 rather than a permission error.
  begin
    perform public.submit_leave_request(
      v_org, v_unpaid, date '2026-03-02', date '2026-03-06', 5);
    raise exception 'FAIL: somebody with no employee record filed their own leave';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and cannot file their own, having no record to file it against';
  end;

  -- HR may, which is what the guard exists to allow.
  perform pg_temp.sign_in_as(v_owner);
  v_req := public.submit_leave_request(
    v_org, v_annual, date '2026-04-06', date '2026-04-07', 2,
    'Filed by HR', false, null, v_e_staff);
  perform pg_temp.check_eq('HR may file for an employee',
    (select employee_id from public.leave_requests where id = v_req),
    v_e_staff);
  perform pg_temp.check_eq('and it is submitted, not approved',
    (select status::text from public.leave_requests where id = v_req),
    'submitted');
  perform pg_temp.check_eq('numbered from the leave series',
    left((select request_no from public.leave_requests where id = v_req), 3),
    'LV-');

  -- ==================================================================
  -- The hold on the balance
  -- ==================================================================
  perform pg_temp.check_eq('a submitted request is held against the balance',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 2);
  perform pg_temp.check_eq('and nothing is taken yet',
    (select taken_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 0);

  -- Eight days entitled, two held. Seven more would fit the entitlement
  -- but not the entitlement less the hold, which is the whole reason
  -- the hold exists: two requests must not each pass a check the pair
  -- of them would fail.
  perform pg_temp.sign_in_as(v_staff);
  begin
    perform public.submit_leave_request(
      v_org, v_annual, date '2026-05-04', date '2026-05-12', 7,
      'Seven more');
    raise exception 'FAIL: two requests together exceeded the entitlement';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal says how many days are left',
      v_msg like '%6.00 day(s) of Annual leave%');
    raise notice 'ok   a pending request is counted against the next one';
  end;

  -- Six fits exactly.
  v_req2 := public.submit_leave_request(
    v_org, v_annual, date '2026-05-04', date '2026-05-11', 6, 'Six');
  perform pg_temp.check_eq('what is left may be taken to the day',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 8);

  -- Unpaid leave has no entitlement to run out of.
  v_unpaid_req := public.submit_leave_request(
    v_org, v_unpaid, date '2026-06-01', date '2026-06-30', 30,
    'A month unpaid');
  perform pg_temp.check_true('unpaid leave is not checked against a balance',
    v_unpaid_req is not null);

  begin
    perform public.submit_leave_request(
      v_org, v_annual, date '2026-07-10', date '2026-07-01', 1, 'Backwards');
    raise exception 'FAIL: leave that ends before it starts was filed';
  exception when sqlstate '22023' then
    raise notice 'ok   leave has to end after it starts';
  end;

  begin
    perform public.submit_leave_request(
      v_org, gen_random_uuid(), date '2026-07-01', date '2026-07-02', 2, 'What');
    raise exception 'FAIL: an unknown leave type was accepted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and be of a leave type the company has';
  end;

  -- ==================================================================
  -- Deciding
  -- ==================================================================
  perform pg_temp.sign_in_as(v_staff);
  begin
    perform public.decide_leave_request(v_req2, true);
    raise exception 'FAIL: an employee approved their own leave';
  exception when sqlstate '42501' then
    raise notice 'ok   nobody approves their own leave';
  end;

  -- The manager may, because Encik Zul reports to Puan Siti.
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('the manager is recognised as the manager',
    app.manages_employee(v_e_staff));
  perform public.decide_leave_request(v_req2, false, 'Too close to the audit');

  select * into r from public.leave_requests where id = v_req2;
  perform pg_temp.check_eq('a rejected request says so', r.status::text,
    'rejected');
  perform pg_temp.check_eq('with the reason kept', r.decision_note,
    'Too close to the audit');
  perform pg_temp.check_eq('and the approver recorded', r.approver_id, v_boss);
  -- Rejecting releases the hold and takes nothing.
  perform pg_temp.check_eq('rejecting gives the days back',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 2);
  perform pg_temp.check_eq('and takes none of them',
    (select taken_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 0);

  begin
    perform public.decide_leave_request(v_req2, true);
    raise exception 'FAIL: a decided request was decided again';
  exception when sqlstate '22023' then
    raise notice 'ok   a request is decided once';
  end;

  -- Approving moves the days from held to taken.
  perform public.decide_leave_request(v_req, true, 'Enjoy');
  perform pg_temp.check_eq('approving releases the hold',
    (select pending_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 0);
  perform pg_temp.check_eq('and consumes the entitlement',
    (select taken_days from public.leave_balances
      where employee_id = v_e_staff and leave_type_id = v_annual), 2);
  perform pg_temp.check_eq('the request is approved',
    (select status::text from public.leave_requests where id = v_req),
    'approved');

  -- A stranger is refused on a request that is still open, so the
  -- refusal is the permission check and not the decided-once guard
  -- standing in front of it.
  perform pg_temp.check_eq('the unpaid month is still undecided',
    (select status::text from public.leave_requests where id = v_unpaid_req),
    'submitted');
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform public.decide_leave_request(v_unpaid_req, true);
    raise exception 'FAIL: a stranger decided a leave request';
  exception when sqlstate '42501' then
    raise notice 'ok   a stranger cannot decide somebody''s leave';
  end;

  -- The handover to payroll. calculate_payroll_run selects approved
  -- requests whose leave type is not paid; payroll_run.sql asserts what
  -- it does with one, and this is the point at which one comes to exist.
  perform pg_temp.sign_in_as(v_boss);
  perform public.decide_leave_request(v_unpaid_req, true, 'Granted unpaid');
  perform pg_temp.check_eq(
    'an approved unpaid request is what payroll goes looking for',
    (select count(*) from public.leave_requests lr
       join public.leave_types lt on lt.id = lr.leave_type_id
      where lr.employee_id = v_e_staff and lr.status = 'approved'
        and not lt.is_paid), 1);
  perform pg_temp.check_eq('for the days it was granted for',
    (select lr.total_days from public.leave_requests lr
       join public.leave_types lt on lt.id = lr.leave_type_id
      where lr.employee_id = v_e_staff and lr.status = 'approved'
        and not lt.is_paid), 30);
  perform pg_temp.sign_out();
end $$;

rollback;
