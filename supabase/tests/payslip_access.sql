-- =====================================================================
-- iAkauntan :: letting an auditor into the pay data, and writing it down
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/payslip_access.sql
--
-- What somebody is paid is the most private thing in the database, and
-- 0045 to 0048 built a way to let an auditor at it without handing over
-- standing access: a scoped request, an admin's decision, an expiry
-- that runs out on its own, and -- because Postgres cannot fire a
-- trigger on SELECT -- a read path that is the only way in, so the log
-- entry cannot be walked around.
--
-- None of it was called by a test. The failure mode is not a wrong
-- number, it is somebody reading a payslip they were never granted, or
-- reading one without leaving a trace, and neither announces itself.
--
-- The fixture is one company, two employees on different salaries, an
-- auditor granted access to one of them, and an admin who is not the
-- auditor. Every assertion below is about the boundary: what the grant
-- does not reach, what the closed table no longer allows, and what the
-- log ends up saying.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_owner   uuid := pg_temp.test_user();
  v_auditor uuid;
  v_other   uuid;
  v_anwar   uuid;
  v_balqis  uuid;
  v_period  uuid;
  v_run     uuid;
  v_req     uuid;
  v_req2    uuid;
  v_slip_a  uuid;
  v_slip_b  uuid;
  j         jsonb;
  r         record;
  v_role    text;
  v_slips   integer;
  v_lines   integer;
  v_runs    integer;
  v_log     integer;
  v_mine    integer;
  v_theirs  integer;
  v_wrote   boolean;
  v_deleted boolean;
begin
  v_org := pg_temp.test_org('Rahsia Gaji Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.payroll_settings (org_id, pay_day)
  values (v_org, 25) on conflict (org_id) do nothing;

  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'E1', 'Anwar', date '2020-01-01', 5000,
          date '1990-01-01', 'citizen')
  returning id into v_anwar;
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, residency_status)
  values (v_org, 'E2', 'Balqis', date '2020-01-01', 9000,
          date '1991-01-01', 'citizen')
  returning id into v_balqis;

  v_period := public.ensure_pay_period(v_org, 2026, 1);
  v_run := public.create_payroll_run(v_org, v_period, 'January');
  perform public.calculate_payroll_run(v_run);
  select id into v_slip_a from public.payslips
   where run_id = v_run and employee_id = v_anwar;
  select id into v_slip_b from public.payslips
   where run_id = v_run and employee_id = v_balqis;

  -- 0045 gave the payslip its own pay date so an access check never has
  -- to join back to the period. If it were null the period bounds on a
  -- grant would stop applying, so it is worth knowing it is set.
  perform pg_temp.check_eq('a payslip carries its own pay date',
    (select pay_date::text from public.payslips where id = v_slip_a),
    '2026-01-25');

  v_auditor := pg_temp.another_user('auditor@example.test');
  v_other   := pg_temp.another_user('otherauditor@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_auditor, 'auditor', 'active'),
         (v_org, v_other,   'auditor', 'active');

  -- ==================================================================
  -- Asking
  -- ==================================================================
  perform pg_temp.sign_in_as(v_owner);
  begin
    perform public.request_payslip_access(v_org, 'I run payroll already');
    raise exception 'FAIL: somebody with payroll rights asked for access';
  exception when sqlstate '22023' then
    raise notice 'ok   payroll does not need to ask for what it has';
  end;

  perform pg_temp.sign_in_as(v_auditor);
  begin
    perform public.request_payslip_access(v_org, '   ');
    raise exception 'FAIL: a request with no reason was accepted';
  exception when sqlstate '22023' then
    raise notice 'ok   a request has to say why';
  end;

  begin
    perform public.request_payslip_access(v_org, 'Backwards',
      date '2026-03-01', date '2026-01-01');
    raise exception 'FAIL: a period that ends before it starts was accepted';
  exception when sqlstate '22023' then
    raise notice 'ok   the period has to end after it starts';
  end;

  -- Scoped to Balqis alone, which is the whole point of the fixture.
  v_req := public.request_payslip_access(
    v_org, 'Statutory audit of the January run', null, null, null, v_balqis);
  select * into r from public.payslip_access_requests where id = v_req;
  perform pg_temp.check_eq('a new request is pending', r.status::text, 'pending');
  perform pg_temp.check_eq('and remembers who asked', r.requested_by, v_auditor);
  perform pg_temp.check_eq('and why', r.reason,
    'Statutory audit of the January run');
  perform pg_temp.check_true('with nothing decided yet', r.decided_at is null);
  perform pg_temp.check_true('and no expiry until it is approved',
    r.expires_at is null);

  begin
    perform public.request_payslip_access(v_org, 'Asking again');
    raise exception 'FAIL: a second pending request was accepted';
  exception when sqlstate '23505' then
    raise notice 'ok   one request awaiting a decision at a time';
  end;

  -- Access is not open before anybody decides.
  perform pg_temp.check_true('a pending request grants nothing',
    not public.my_payslip_access(v_org));
  begin
    perform public.audit_view_payslip(v_slip_b);
    raise exception 'FAIL: a pending request opened a payslip';
  exception when sqlstate '42501' then
    raise notice 'ok   and opens no payslip';
  end;

  -- ==================================================================
  -- Deciding
  -- ==================================================================
  perform pg_temp.sign_in_as(v_other);
  begin
    perform public.decide_payslip_access(v_req, true);
    raise exception 'FAIL: another auditor decided the request';
  exception when sqlstate '42501' then
    raise notice 'ok   an auditor cannot decide a request';
  end;

  -- The one that makes the whole scheme more than decorative.
  perform pg_temp.sign_in_as(v_auditor);
  begin
    perform public.decide_payslip_access(v_req, true);
    raise exception 'FAIL: the auditor approved their own request';
  exception when sqlstate '42501' then
    raise notice 'ok   nobody approves their own request for access';
  end;

  perform pg_temp.sign_in_as(v_owner);
  begin
    perform public.decide_payslip_access(v_req, true, 'Forever', 0);
    raise exception 'FAIL: access was approved with no expiry';
  exception when sqlstate '22023' then
    raise notice 'ok   access has to expire';
  end;

  perform public.decide_payslip_access(v_req, true, 'Approved for the audit', 30);
  select * into r from public.payslip_access_requests where id = v_req;
  perform pg_temp.check_eq('the request is approved', r.status::text, 'approved');
  perform pg_temp.check_eq('by the admin who decided it', r.decided_by, v_owner);
  perform pg_temp.check_true('with the note kept',
    r.decision_note = 'Approved for the audit');
  perform pg_temp.check_true('and an expiry thirty days out',
    r.expires_at between now() + interval '29 days'
                     and now() + interval '31 days');

  begin
    perform public.decide_payslip_access(v_req, false, 'Changed my mind');
    raise exception 'FAIL: a decided request was decided again';
  exception when sqlstate '22023' then
    raise notice 'ok   a request is decided once';
  end;

  -- ==================================================================
  -- What the grant reaches, and what it does not
  -- ==================================================================
  perform pg_temp.sign_in_as(v_auditor);
  perform pg_temp.check_true('the auditor now holds access',
    public.my_payslip_access(v_org));

  -- 0047 closed the table itself. A grant is not a policy widening; it
  -- is permission to use the logged route, and this is the assertion
  -- that keeps an unlogged read impossible.
  --
  -- Under `authenticated`, because the file otherwise runs as the owner
  -- and the owner is not subject to row level security -- a read that
  -- looks blocked would simply be a read nobody was checking. v_role is
  -- carried back out so a silently skipped role switch fails rather
  -- than passing.
  begin
    set local role authenticated;
    v_role  := current_user;
    select count(*) into v_slips from public.payslips where org_id = v_org;
    select count(*) into v_lines from public.payslip_lines where org_id = v_org;
    select count(*) into v_runs  from public.payroll_runs where id = v_run;
  end;
  reset role;

  perform pg_temp.check_eq('the read test ran under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_eq('a grant does not open the payslip table',
    v_slips, 0);
  perform pg_temp.check_eq('nor the lines', v_lines, 0);
  -- The run header stays readable: org level totals, and the same
  -- figures already sit in the payroll journal in the general ledger.
  perform pg_temp.check_eq('but the run header is readable', v_runs, 1);

  j := public.audit_view_payslip(v_slip_b);
  perform pg_temp.check_eq('the covered payslip opens',
    j ->> 'employee_name', 'Balqis');
  perform pg_temp.check_true('with its lines',
    jsonb_array_length(j -> 'payslip_lines') > 0);
  perform pg_temp.check_eq('and the run it belongs to',
    j -> 'payroll_runs' -> 'pay_periods' ->> 'code', '2026-01');
  perform pg_temp.check_true('and without the tenant column',
    not (j ? 'org_id'));

  begin
    perform public.audit_view_payslip(v_slip_a);
    raise exception 'FAIL: the grant reached an employee it did not name';
  exception when sqlstate '42501' then
    raise notice 'ok   and Anwar, whom the grant does not name, does not';
  end;

  -- ==================================================================
  -- The list, and the grant it is logged against
  -- ==================================================================
  j := public.audit_list_payslips(v_org);
  perform pg_temp.check_eq('the list holds only what the grant covers',
    jsonb_array_length(j), 1);
  perform pg_temp.check_eq('which is Balqis',
    j -> 0 ->> 'employee_name', 'Balqis');

  select * into r from public.payslip_access_log
   where org_id = v_org and action = 'list';
  perform pg_temp.check_eq('the list read is logged once', r.payslip_count, 1);
  perform pg_temp.check_eq('against the auditor', r.actor_id, v_auditor);
  -- 0281. Before it, the grant was looked up from an arbitrary payslip
  -- in the whole company rather than from the covered set, so a grant
  -- narrower than the company logged grant_id = null and the read could
  -- not be attributed to the approval that permitted it.
  perform pg_temp.check_eq('and against the grant that permitted it',
    r.grant_id, v_req);

  select * into r from public.payslip_access_log
   where org_id = v_org and action = 'view';
  perform pg_temp.check_eq('the view is logged against the same grant',
    r.grant_id, v_req);
  perform pg_temp.check_eq('naming who was looked at',
    r.employee_name, 'Balqis');
  perform pg_temp.check_eq('and which period', r.period_code, '2026-01');
  perform pg_temp.check_eq('and which payslip', r.payslip_id, v_slip_b);

  -- Payroll is not routed through here and is not tracked here.
  perform pg_temp.sign_in_as(v_owner);
  begin
    perform public.audit_list_payslips(v_org);
    raise exception 'FAIL: payroll read through the audited route';
  exception when sqlstate '22023' then
    raise notice 'ok   payroll is told to use its own screens';
  end;

  -- ==================================================================
  -- The log is a record, not a working table
  -- ==================================================================
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_log
      from public.payslip_access_log where org_id = v_org;
    begin
      insert into public.payslip_access_log
        (org_id, actor_id, action, payslip_count)
      values (v_org, v_owner, 'list', 99);
      v_wrote := true;
    exception when insufficient_privilege then v_wrote := false;
    end;
    begin
      delete from public.payslip_access_log where org_id = v_org;
      v_deleted := true;
    exception when insufficient_privilege then v_deleted := false;
    end;
  end;
  reset role;

  perform pg_temp.check_eq('the log test ran under row level security',
    v_role, 'authenticated');
  perform pg_temp.check_eq('an admin can read who looked at what', v_log, 2);
  -- 0047 gave the table a select policy and nothing else, so there is
  -- no route by which the record of a read can be tidied up afterwards.
  perform pg_temp.check_true('the log cannot be written from the API',
    not v_wrote);
  perform pg_temp.check_true('nor deleted', not v_deleted);

  -- An auditor sees their own entries: being watched is not the same as
  -- being watched secretly. Somebody else's are not theirs to see.
  perform pg_temp.sign_in_as(v_auditor);
  begin
    set local role authenticated;
    select count(*) into v_mine
      from public.payslip_access_log where actor_id = v_auditor;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_other);
  begin
    set local role authenticated;
    select count(*) into v_theirs
      from public.payslip_access_log where actor_id = v_auditor;
  end;
  reset role;
  perform pg_temp.check_eq('the auditor can see their own entries', v_mine, 2);
  perform pg_temp.check_eq('and not another auditor''s', v_theirs, 0);

  -- ==================================================================
  -- Taking it back, and running out
  -- ==================================================================
  perform pg_temp.sign_in_as(v_auditor);
  begin
    perform public.revoke_payslip_access(v_req);
    raise exception 'FAIL: the auditor revoked their own grant';
  exception when sqlstate '42501' then
    raise notice 'ok   an auditor cannot work the revoke either';
  end;

  perform pg_temp.sign_in_as(v_owner);
  perform public.revoke_payslip_access(v_req, 'Audit finished');
  select * into r from public.payslip_access_requests where id = v_req;
  perform pg_temp.check_eq('the grant is revoked', r.status::text, 'revoked');
  perform pg_temp.check_eq('by whoever took it back', r.revoked_by, v_owner);

  perform pg_temp.sign_in_as(v_auditor);
  perform pg_temp.check_true('and the access is gone',
    not public.my_payslip_access(v_org));
  begin
    perform public.audit_view_payslip(v_slip_b);
    raise exception 'FAIL: a revoked grant still opened a payslip';
  exception when sqlstate '42501' then
    raise notice 'ok   a revoked grant opens nothing';
  end;
  perform pg_temp.check_eq('and the list is empty',
    jsonb_array_length(public.audit_list_payslips(v_org)), 0);
  perform pg_temp.check_eq('an empty list is not logged as a read',
    (select count(*) from public.payslip_access_log
      where org_id = v_org and action = 'list'), 1);

  perform pg_temp.sign_in_as(v_owner);
  begin
    perform public.revoke_payslip_access(v_req);
    raise exception 'FAIL: a revoked grant was revoked again';
  exception when sqlstate '22023' then
    raise notice 'ok   and cannot be revoked twice';
  end;

  -- Expiry does the same job without anyone remembering to act. The
  -- grant below is approved and never revoked; it has simply run out.
  perform pg_temp.sign_in_as(v_auditor);
  v_req2 := public.request_payslip_access(v_org, 'A second look');
  perform pg_temp.sign_in_as(v_owner);
  perform public.decide_payslip_access(v_req2, true, null, 30);
  perform pg_temp.sign_in_as(v_auditor);
  perform pg_temp.check_true('a fresh grant covers everything it did not narrow',
    public.my_payslip_access(v_org));
  perform pg_temp.check_eq('including the employee the first one missed',
    public.audit_view_payslip(v_slip_a) ->> 'employee_name', 'Anwar');

  update public.payslip_access_requests
     set expires_at = now() - interval '1 minute' where id = v_req2;
  perform pg_temp.check_true('once it has run out it grants nothing',
    not public.my_payslip_access(v_org));
  begin
    perform public.audit_view_payslip(v_slip_a);
    raise exception 'FAIL: an expired grant still opened a payslip';
  exception when sqlstate '42501' then
    raise notice 'ok   and an expired grant opens nothing';
  end;

  -- ==================================================================
  -- Nobody outside the company at all
  -- ==================================================================
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform public.request_payslip_access(v_org, 'Let me in');
    raise exception 'FAIL: a stranger asked for access';
  exception when sqlstate '42501' then
    raise notice 'ok   a stranger cannot ask';
  end;
  begin
    perform public.audit_list_payslips(v_org);
    raise exception 'FAIL: a stranger listed payslips';
  exception when sqlstate '42501' then
    raise notice 'ok   nor list';
  end;
  begin
    perform public.audit_view_payslip(v_slip_a);
    raise exception 'FAIL: a stranger opened a payslip';
  exception when sqlstate '42501' then
    raise notice 'ok   nor open one';
  end;
  perform pg_temp.sign_out();
end $$;

rollback;
