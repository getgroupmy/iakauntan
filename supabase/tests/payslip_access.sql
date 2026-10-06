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
  v_run2    uuid;
  v_slip_c  uuid;
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
  -- A grant is one person's, for one run, over one stretch of dates
  -- ==================================================================
  --
  -- `app.covering_grant` narrows on four things beyond being approved
  -- and unexpired, and three of them were asserted nowhere. Mutating
  -- each clause away left the whole file green:
  --
  --   * `requested_by = auth.uid()` — without it, one approved grant
  --     opens payslips for every member of the organization. The person
  --     who asked, the approval that names them, and the log that says
  --     who looked would all still be right; anybody else would simply
  --     be let in beside them.
  --   * `run_id` — a grant given for January's run opens every run
  --     there has ever been.
  --   * `period_from` / `period_to` — a grant bounded to a stretch of
  --     dates opens payslips outside it.
  --
  -- Salary is the most private thing this database holds, and the whole
  -- design of these grants is that they are narrow. Nothing was
  -- checking that they were.

  -- A second auditor, with no grant of their own, while the first one's
  -- is live.
  perform pg_temp.sign_in_as(v_owner);
  update public.payslip_access_requests
     set expires_at = now() + interval '30 days' where id = v_req2;
  -- The second auditor this file already has. They are an active
  -- member with every right an auditor gets — what they do not have is
  -- a grant, and that is the only thing between them and somebody's
  -- salary.
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_true(
    'somebody else''s grant is not a grant of your own',
    not public.my_payslip_access(v_org));
  begin
    perform public.audit_view_payslip(v_slip_a);
    raise exception 'FAIL: another auditor rode in on a grant they never asked for';
  exception when sqlstate '42501' then
    raise notice 'ok   and does not open a payslip for you';
  end;

  -- Scoped to one run, then asked about another.
  perform pg_temp.sign_in_as(v_owner);
  v_run2 := public.create_payroll_run(
    v_org, public.ensure_pay_period(v_org, 2026, 2), 'February');
  perform public.calculate_payroll_run(v_run2);
  select id into v_slip_c from public.payslips
   where run_id = v_run2 and employee_id = v_anwar;

  update public.payslip_access_requests
     set run_id = v_run where id = v_req2;
  perform pg_temp.sign_in_as(v_auditor);
  perform pg_temp.check_eq('a grant for one run still opens that run',
    public.audit_view_payslip(v_slip_a) ->> 'employee_name', 'Anwar');
  begin
    perform public.audit_view_payslip(v_slip_c);
    raise exception 'FAIL: a grant for January opened February';
  exception when sqlstate '42501' then
    raise notice 'ok   and opens no other run';
  end;

  -- Scoped to a stretch of dates, then asked about a pay date outside
  -- it. The bound is on the payslip's own pay date, which is why 0047
  -- takes it as an argument rather than reading the run.
  perform pg_temp.sign_in_as(v_owner);
  update public.payslip_access_requests
     set run_id = null,
         period_from = date '2026-01-01',
         period_to = date '2026-01-31'
   where id = v_req2;
  perform pg_temp.sign_in_as(v_auditor);
  perform pg_temp.check_eq('a grant for January opens a January payslip',
    public.audit_view_payslip(v_slip_a) ->> 'employee_name', 'Anwar');
  begin
    perform public.audit_view_payslip(v_slip_c);
    raise exception 'FAIL: a January grant opened a February payslip';
  exception when sqlstate '42501' then
    raise notice 'ok   and nothing paid after them';
  end;

  -- Both ends, separately. The first draft of this only pushed past
  -- `period_to`, so removing `period_from` altogether changed nothing
  -- and the mutant lived: a grant bounded to February would have opened
  -- every payslip ever paid before it. Turning the window around is
  -- what makes the lower bound load-bearing.
  perform pg_temp.sign_in_as(v_owner);
  update public.payslip_access_requests
     set period_from = date '2026-02-01', period_to = date '2026-02-28'
   where id = v_req2;
  perform pg_temp.sign_in_as(v_auditor);
  perform pg_temp.check_eq('a grant for February opens a February payslip',
    public.audit_view_payslip(v_slip_c) ->> 'employee_name', 'Anwar');
  begin
    perform public.audit_view_payslip(v_slip_a);
    raise exception 'FAIL: a February grant opened a January payslip';
  exception when sqlstate '42501' then
    raise notice 'ok   nor anything paid before them';
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

-- ---------------------------------------------------------------------
-- request, decide and revoke, rule by rule
--
-- A sweep of `0046`'s three functions over this file and
-- `statutory.sql` left seventeen mutants alive. Most were refusals
-- asserted by SQLSTATE alone, where the next guard down raises the same
-- one: a stranger asking is refused by the membership check AND by the
-- auditor check, both 42501, so either could go. One was the guard the
-- scheme exists for: an auditor approving their own request was only
-- ever tried while they were an auditor, whom the admin check refuses
-- first. It matters to somebody who has since been MADE an administrator
-- -- which is the case here. The rest were what a decision and a
-- revocation write, which nothing read.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org uuid := pg_temp.test_org('Akses Slip Peraturan Sdn Bhd');
  v_a uuid := pg_temp.another_user('a.auditor@akses.test');
  v_b uuid := pg_temp.another_user('b.auditor@akses.test');
  v_staff uuid := pg_temp.another_user('staff@akses.test');
  v_req_a uuid; v_req_b uuid; v_req_b2 uuid;
  r record;
begin
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_a, 'auditor', 'active'), (v_org, v_b, 'auditor', 'active'),
         (v_org, v_staff, 'employee', 'active');

  -- WHO MAY ASK, by what they are told.
  perform pg_temp.sign_in_as(pg_temp.another_user('nobody@elsewhere-akses.test'));
  perform pg_temp.check_refused('a stranger is told they are not a member',
    format('select public.request_payslip_access(%L, %L)', v_org, 'Let me in'),
    '%Not a member of this company%', '42501');
  perform pg_temp.sign_in_as(v_staff);
  perform pg_temp.check_refused('a member who is not an auditor is told only an auditor may',
    format('select public.request_payslip_access(%L, %L)', v_org, 'Curious'),
    '%Only an auditor may request%', '42501');

  -- WHAT A REQUEST KEEPS. A period of one day is a period; the reason
  -- is kept as said, without the spaces round it.
  perform pg_temp.sign_in_as(v_a);
  v_req_a := public.request_payslip_access(v_org, '  Year-end cut-off  ',
    date '2026-01-31', date '2026-01-31');
  select * into r from public.payslip_access_requests where id = v_req_a;
  perform pg_temp.check_eq('the reason is kept trimmed', r.reason, 'Year-end cut-off');
  perform pg_temp.check_eq('and a one-day period is kept',
    r.period_from::text || '..' || r.period_to::text, '2026-01-31..2026-01-31');

  -- One pending request each -- not one for the company.
  perform pg_temp.sign_in_as(v_b);
  v_req_b := public.request_payslip_access(v_org, 'Payroll walkthrough');
  perform pg_temp.check_true('a second auditor may ask while the first waits',
    v_req_b is not null);

  -- DECIDING.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_refused('a request that is not there says so',
    format('select public.decide_payslip_access(%L, true)', gen_random_uuid()),
    '%Request not found%', 'P0002');

  -- The auditor, since made an administrator, and their own request.
  update public.org_members set role = 'admin'
   where org_id = v_org and user_id = v_a;
  perform pg_temp.sign_in_as(v_a);
  perform pg_temp.check_refused(
    'an auditor made administrator still cannot approve their own request',
    format('select public.decide_payslip_access(%L, true)', v_req_a),
    '%cannot approve your own request%', '42501');

  -- A refusal needs no number of days, and is given no expiry.
  perform pg_temp.sign_in_as(v_owner);
  perform public.decide_payslip_access(v_req_b, false, 'Not this quarter', 0);
  select * into r from public.payslip_access_requests where id = v_req_b;
  perform pg_temp.check_eq('a refusal is a refusal', r.status::text, 'rejected');
  perform pg_temp.check_true('with no expiry', r.expires_at is null);
  perform pg_temp.check_eq('and dated when it was made', r.decided_at::text, now()::text);

  -- An approval for seven days expires in exactly seven.
  perform public.decide_payslip_access(v_req_a, true, 'For the cut-off', 7);
  perform pg_temp.check_eq('seven days means seven',
    (select expires_at::text from public.payslip_access_requests where id = v_req_a),
    (now() + interval '7 days')::text);

  -- REVOKING.
  perform pg_temp.check_refused('a request that is not there cannot be revoked',
    format('select public.revoke_payslip_access(%L)', gen_random_uuid()),
    '%Request not found%', 'P0002');
  perform public.revoke_payslip_access(v_req_a);
  select * into r from public.payslip_access_requests where id = v_req_a;
  perform pg_temp.check_eq('a revocation is dated', r.revoked_at::text, now()::text);
  perform pg_temp.check_eq('and with nothing to say leaves the decision''s note',
    r.decision_note, 'For the cut-off');

  perform pg_temp.sign_in_as(v_b);
  v_req_b2 := public.request_payslip_access(v_org, 'Payroll walkthrough, again');
  perform pg_temp.sign_in_as(v_owner);
  perform public.decide_payslip_access(v_req_b2, true, null, 3);
  perform public.revoke_payslip_access(v_req_b2, 'Walkthrough done early');
  perform pg_temp.check_eq('while a revocation that says something is kept',
    (select decision_note from public.payslip_access_requests where id = v_req_b2),
    'Walkthrough done early');
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The grant and the two audited reads, rule by rule
--
-- Sweeps of `app.covering_grant` (0047), `audit_view_payslip` (0048) and
-- `audit_list_payslips` (0281) over this file left twelve mutants
-- alive:
--
--   * the grant's edges. Nothing sat ON a boundary: a grant expiring at
--     this instant, or a period whose first or last day is the pay date.
--   * which grant is named when two cover, and whether a grant in one
--     company answers for another. Every auditor here belonged to one
--     company, so there was no other company's grant to find.
--   * the list's run filter, the tenant column it strips, and the count
--     it logs -- the fixture's list was only ever one payslip long.
--   * three refusals of the single read asserted by SQLSTATE alone,
--     each with a later guard that raises the same code.
--
-- The grants are written straight into the table, approved, so each
-- edge is set exactly rather than by the days `decide_payslip_access`
-- counts from now.
-- ---------------------------------------------------------------------
create or replace function pg_temp.grant_for(
  p_org uuid, p_user uuid, p_expires timestamptz,
  p_from date default null, p_to date default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.payslip_access_requests
    (org_id, requested_by, reason, status, decided_by, decided_at,
     expires_at, period_from, period_to)
  values (p_org, p_user, 'Fixture grant', 'approved', pg_temp.test_user(),
          now(), p_expires, p_from, p_to)
  returning id into v;
  return v;
end $$;

create or replace function pg_temp.payroll_of(p_org uuid, p_names text[])
returns uuid[] language plpgsql as $$
declare v_runs uuid[] := '{}'; i integer; m integer;
begin
  insert into public.payroll_settings (org_id, pay_day)
  values (p_org, 25) on conflict (org_id) do nothing;
  for i in 1 .. array_length(p_names, 1) loop
    insert into public.employees
      (org_id, employee_no, full_name, hire_date, basic_salary,
       date_of_birth, residency_status)
    values (p_org, 'E' || i, p_names[i], date '2020-01-01', 4000 + i * 1000,
            date '1990-01-01', 'citizen');
  end loop;
  for m in 1 .. 2 loop
    v_runs := v_runs || public.create_payroll_run(
      p_org, public.ensure_pay_period(p_org, 2026, m), 'Month ' || m);
    perform public.calculate_payroll_run(v_runs[m]);
  end loop;
  return v_runs;
end $$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_x uuid := pg_temp.another_user('x.auditor@gaji-peraturan.test');
  v_a uuid; v_b uuid; v_runs uuid[]; v_b_runs uuid[];
  v_emp uuid; v_slip uuid;
  v_day uuid; v_short uuid; v_long uuid; v_theirs uuid;
  j jsonb;
begin
  perform pg_temp.allow_many_companies();
  v_a := pg_temp.test_org('Gaji Peraturan Sdn Bhd');
  v_runs := pg_temp.payroll_of(v_a, array['Chong', 'Devi']);
  v_b := pg_temp.test_org('Gaji Jiran Sdn Bhd');
  v_b_runs := pg_temp.payroll_of(v_b, array['Elias']);
  insert into public.org_members (org_id, user_id, role, status)
  values (v_a, v_x, 'auditor', 'active'), (v_b, v_x, 'auditor', 'active');
  select id into v_emp from public.employees where org_id = v_a and employee_no = 'E1';
  select id into v_slip from public.payslips where run_id = v_runs[1] and employee_id = v_emp;

  -- THE SINGLE READ'S REFUSALS, by what they say.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_refused('a payslip that is not there says so',
    format('select public.audit_view_payslip(%L)', gen_random_uuid()),
    '%Payslip not found%', 'P0002');
  perform pg_temp.check_refused('payroll is sent to its own screens for one payslip too',
    format('select public.audit_view_payslip(%L)', v_slip),
    '%Use the payroll screens%', '22023');
  perform pg_temp.sign_in_as(pg_temp.another_user('nobody@gaji-peraturan.test'));
  perform pg_temp.check_refused('a stranger is told they are not a member',
    format('select public.audit_view_payslip(%L)', v_slip),
    '%Not a member of this company%', '42501');

  -- THE EDGES. A grant for the one day 25 January covers a payslip paid
  -- that day -- both bounds are inclusive.
  v_day := pg_temp.grant_for(v_a, v_x, now() + interval '5 days',
                             date '2026-01-25', date '2026-01-25');
  perform pg_temp.sign_in_as(v_x);
  perform pg_temp.check_eq('a grant for one day covers a payslip paid that day',
    app.covering_grant(v_a, v_runs[1], v_emp, date '2026-01-25'), v_day);
  -- And expiring NOW is expired.
  update public.payslip_access_requests set expires_at = now() where id = v_day;
  perform pg_temp.check_true('a grant expiring this instant covers nothing',
    app.covering_grant(v_a, v_runs[1], v_emp, date '2026-01-25') is null);

  -- WHICH GRANT, OF TWO. The one that lasts longer -- and only this
  -- company's, though the neighbour's grant to the same auditor lasts
  -- longer still.
  v_short  := pg_temp.grant_for(v_a, v_x, now() + interval '1 day');
  v_long   := pg_temp.grant_for(v_a, v_x, now() + interval '10 days');
  v_theirs := pg_temp.grant_for(v_b, v_x, now() + interval '20 days');
  perform pg_temp.check_eq('of two grants, the one that lasts longer is named',
    app.covering_grant(v_a, v_runs[2], v_emp, date '2026-02-25'), v_long);

  -- THE LIST. Four payslips here, one next door that this auditor may
  -- also read -- and a list of this company's has four.
  j := public.audit_list_payslips(v_a);
  perform pg_temp.check_eq('the list holds this company''s payslips only',
    jsonb_array_length(j), 4);
  perform pg_temp.check_true('without the tenant column on any of them',
    not exists (select 1 from jsonb_array_elements(j) e where e ? 'org_id'));
  perform pg_temp.check_eq('and the log counts all four',
    (select payslip_count from public.payslip_access_log
      where org_id = v_a and action = 'list' and actor_id = v_x), 4);
  j := public.audit_list_payslips(v_a, v_runs[2]);
  perform pg_temp.check_eq('a list of one run holds that run''s',
    jsonb_array_length(j), 2);
  perform pg_temp.check_true('and nothing from the other',
    not exists (select 1 from jsonb_array_elements(j) e
                 where (e ->> 'run_id')::uuid <> v_runs[2]));
  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- An undated payslip is outside a bounded grant (0753)
--
-- Until 0753, `p_pay_date is null` passed both of a grant's period
-- bounds, so a grant limited to January also opened any payslip with
-- no pay date. A bound that lapses where the date is missing is no
-- bound. An unbounded grant still covers it.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_y uuid := pg_temp.another_user('y.auditor@tanpa-tarikh.test');
  v_org uuid; v_runs uuid[]; v_emp uuid; v_slip uuid;
  v_january uuid; v_open uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Tanpa Tarikh Sdn Bhd');
  v_runs := pg_temp.payroll_of(v_org, array['Farah']);
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_y, 'auditor', 'active');
  select id into v_emp from public.employees where org_id = v_org;
  select id into v_slip from public.payslips
   where run_id = v_runs[1] and employee_id = v_emp;
  update public.payslips set pay_date = null where id = v_slip;

  v_january := pg_temp.grant_for(v_org, v_y, now() + interval '5 days',
                                 date '2026-01-01', date '2026-01-31');
  perform pg_temp.sign_in_as(v_y);
  perform pg_temp.check_eq('a January grant covers a January pay date',
    app.covering_grant(v_org, v_runs[1], v_emp, date '2026-01-25'), v_january);
  perform pg_temp.check_true('but not a payslip with no pay date at all',
    app.covering_grant(v_org, v_runs[1], v_emp, null) is null);
  perform pg_temp.check_refused('so the undated payslip does not open',
    format('select public.audit_view_payslip(%L)', v_slip),
    '%does not cover this payslip%', '42501');

  v_open := pg_temp.grant_for(v_org, v_y, now() + interval '5 days');
  perform pg_temp.check_eq('while a grant with no period still covers it',
    app.covering_grant(v_org, v_runs[1], v_emp, null), v_open);
  perform pg_temp.sign_out();
end $$;

rollback;
