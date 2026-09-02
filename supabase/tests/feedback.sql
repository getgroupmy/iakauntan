-- =====================================================================
-- iAkauntan :: somewhere to say it is broken
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/feedback.sql
--
-- `tickets` is the service desk a tenant runs for its own customers.
-- Nothing pointed the other way, at us, so a person who found a fault
-- in the payroll screen had an e-mail address to guess at.
--
-- Most of what is asserted here is about who may read a report and who
-- may change one, because a feedback board is the obvious way to breach
-- `no_tenant_sees_another.sql` by accident: people paste screenshots,
-- and a screenshot of the payroll screen is a list of salaries.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Raising one
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_id   uuid;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Pelapor Sdn Bhd');

  v_id := public.report_feedback(
    'Payroll totals do not add up', 'bug',
    'The employer EPF column is blank for one employee.',
    '/hr/payroll', '1.4.2', 2::smallint, v_org);
  perform pg_temp.check_true('anybody can report a fault', v_id is not null);

  perform pg_temp.check_eq('and it comes back to them',
    (select count(*)::integer from public.my_feedback(v_org)
      where id = v_id), 1);
  perform pg_temp.check_eq('as theirs',
    (select is_mine::text from public.my_feedback(v_org) where id = v_id),
    'true');
  perform pg_temp.check_eq('waiting to be looked at',
    (select status::text from public.my_feedback(v_org) where id = v_id),
    'new');
  perform pg_temp.check_eq('with where in the app it happened',
    (select screen from public.my_feedback(v_org) where id = v_id),
    '/hr/payroll');

  -- A request and a suggestion are not faults, and carry no severity
  -- that would sort them in among the faults.
  v_id := public.report_feedback(
    'Let me export a payslip as a PDF', 'feature', null, null, null,
    2::smallint, v_org);
  perform pg_temp.check_true('a feature request carries no severity',
    (select severity from public.feedback_reports where id = v_id) is null);

  -- A line saying what is wrong is the whole minimum.
  begin
    perform public.report_feedback('   ', 'bug', 'body only',
      null, null, null, v_org);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('a report needs a line saying what', not v_took);

  -- And it is reported against a company you are actually in.
  begin
    perform public.report_feedback('Not mine', 'bug', null, null, null,
      null, gen_random_uuid());
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'and against a company you belong to', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- Who reads it
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_other  uuid;
  v_clerk  uuid;
  v_admin  uuid;
  v_id     uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Pelapor Sulit Sdn Bhd');

  v_clerk := pg_temp.another_user('clerk-0460@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'accounts_clerk', 'active', now());

  perform pg_temp.sign_in_as(v_clerk);
  v_id := public.report_feedback(
    'The bank import drops the last row', 'bug', null, '/banking',
    null, 2::smallint, v_org);

  perform pg_temp.check_eq('the reporter sees their own',
    (select count(*)::integer from public.my_feedback(v_org)
      where id = v_id), 1);

  -- The company's administrator sees what was raised from inside their
  -- company, because it is usually about their data.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('and the company''s administrator does too',
    (select count(*)::integer from public.my_feedback(v_org)
      where id = v_id), 1);

  -- But an ordinary colleague does not. "Anybody in the company" and
  -- "the administrators of the company" are different sets, and the
  -- owner of a test fixture belongs to both -- so this is asked of
  -- somebody who belongs to only one.
  v_admin := pg_temp.another_user('colleague-0460@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_admin, 'accounts_clerk', 'active', now());
  perform pg_temp.sign_in_as(v_admin);
  perform pg_temp.check_eq(
    'while a colleague who is not an administrator does not',
    (select count(*)::integer from public.my_feedback(v_org)
      where id = v_id), 0);

  -- Somebody at another company sees nothing of it. This is the one
  -- that matters: people paste screenshots into bug reports.
  v_other := pg_temp.another_user('stranger-0460@iakauntan.test');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_eq('and another company sees none of it',
    (select count(*)::integer from public.my_feedback(v_org)), 0);
end $$;

-- The reader function is one answer; the policy underneath it is the
-- one that has to hold. This file runs as the table's owner, for whom
-- row-level security is not enforced at all, so the direct read is
-- asked as a client role the way `no_tenant_sees_another.sql` does.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users
                             where email = 'stranger-0460@iakauntan.test'),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
begin
  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_eq(
    'and the policy itself hands a stranger nothing',
    (select count(*)::integer from public.feedback_reports), 0);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- What the reporter may change, and what they may not
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_id    uuid;
  v_admin uuid;
  v_took  boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Pelapor Ubah Sdn Bhd');
  v_id := public.report_feedback(
    'Tpyo in the invoice screen', 'bug', null, '/sales', null,
    4::smallint, v_org);

  -- Correcting your own report is allowed. An author who cannot fix a
  -- typo writes a second report.
  update public.feedback_reports
     set title = 'Typo in the invoice screen' where id = v_id;
  perform pg_temp.check_eq('an author can correct their own report',
    (select title from public.feedback_reports where id = v_id),
    'Typo in the invoice screen');

  -- Marking it done is not theirs to do.
  begin
    update public.feedback_reports set status = 'done' where id = v_id;
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('but not mark it done', not v_took);

  begin
    update public.feedback_reports
       set platform_note = 'Fixed, honestly' where id = v_id;
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('nor write the answer to it', not v_took);

  -- Nor is the platform's list theirs to read.
  begin
    perform * from public.platform_feedback();
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true(
    'nor read every company''s reports at once', not v_took);

  begin
    perform public.set_feedback_status(v_id, 'done', 'by me');
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('nor set a status through the door', not v_took);
end $$;

-- ---------------------------------------------------------------------
-- Triage
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_ops   uuid;
  v_bug   uuid;
  v_idea  uuid;
  r       record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org  := pg_temp.test_org('Pelapor Triaj Sdn Bhd');
  v_idea := public.report_feedback('An idea', 'feature', null, null,
    null, null, v_org);
  v_bug  := public.report_feedback('Something is broken', 'bug', null,
    null, null, 1::smallint, v_org);

  v_ops := pg_temp.another_user('ops-0460@iakauntan.test');
  insert into public.platform_admins (user_id, note) values (v_ops, 'test');
  perform pg_temp.sign_in_as(v_ops);

  perform pg_temp.check_true('the platform sees every company''s reports',
    (select count(*) from public.platform_feedback()) >= 2);

  -- Faults first, worst first: a list where a suggestion sits above a
  -- system that will not open is a list nobody works down.
  --
  -- Asked as "no suggestion appears above any fault" rather than
  -- "the first row is a fault": the list spans every company, so the
  -- first row is whatever the whole platform happens to hold, and that
  -- was a fault by luck rather than by ordering.
  perform pg_temp.check_eq('with every fault above every suggestion',
    (select count(*)::integer
       from (select kind, row_number() over () as rn
               from public.platform_feedback()) t
      where t.kind <> 'bug'
        and t.rn < (select max(rn) from
                      (select kind as k, row_number() over () as rn
                         from public.platform_feedback()) u
                     where u.k = 'bug')),
    0);

  perform public.set_feedback_status(v_bug, 'in_progress', 'Reproduced.');
  perform pg_temp.check_eq('a status can be moved on',
    (select status::text from public.feedback_reports where id = v_bug),
    'in_progress');
  perform pg_temp.check_true('and nothing is closed until it is closed',
    (select resolved_at from public.feedback_reports where id = v_bug)
      is null);

  perform public.set_feedback_status(v_bug, 'done', 'Fixed in 1.4.3.');
  perform pg_temp.check_true('closing one dates it',
    (select resolved_at from public.feedback_reports where id = v_bug)
      is not null);
  perform pg_temp.check_eq('and says so back to the reporter',
    (select platform_note from public.feedback_reports where id = v_bug),
    'Fixed in 1.4.3.');

  -- Which the reporter can then read.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('the reporter is told what happened',
    (select platform_note from public.my_feedback(v_org) where id = v_bug),
    'Fixed in 1.4.3.');
end $$;

-- ---------------------------------------------------------------------
-- The screenshot
--
-- Attachments already exist and are generic. Two of their helpers had
-- to learn about feedback, and both had reasons a bug report cannot
-- satisfy: one wants the `attachments` module, the other opens with
-- `can_write`.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_id    uuid;
  v_emp   uuid;
  v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- Deliberately a company without the attachments module. Reporting a
  -- fault is not a feature anybody buys.
  v_org := pg_temp.test_org('Pelapor Gambar Sdn Bhd', array['accounting']);

  -- An employee, who holds no write permission at all and is exactly
  -- the person most likely to have hit the fault.
  v_emp := pg_temp.another_user('emp-0460@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_emp, 'employee', 'active', now());

  perform pg_temp.sign_in_as(v_emp);
  v_id := public.report_feedback('It crashed', 'bug', null, '/dashboard',
    null, 1::smallint, v_org);

  perform pg_temp.check_true(
    'the person who hit it can put a picture on it',
    app.can_attach_to(v_org, 'feedback_reports', v_id));

  perform pg_temp.check_true('and can see it afterwards',
    app.can_read_attachment(v_org, 'feedback_reports', v_id));

  -- Somebody else's report is not theirs to add to.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_true('an administrator can read the picture',
    app.can_read_attachment(v_org, 'feedback_reports', v_id));
  perform pg_temp.check_true('but not add to somebody else''s report',
    not app.can_attach_to(v_org, 'feedback_reports', v_id));

  -- And a stranger neither.
  v_other := pg_temp.another_user('nobody-0460@iakauntan.test');
  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_true('a stranger sees no picture',
    not app.can_read_attachment(v_org, 'feedback_reports', v_id));

  -- Restating those two helpers must not have cost them what they did
  -- before. An employee's own expense claim is the case that would go
  -- quietly if it had.
  perform pg_temp.check_true(
    'and the helpers still know what they knew before',
    position('expense_claims' in pg_get_functiondef(
      to_regprocedure('app.can_attach_to(uuid, text, uuid)'))) > 0
    and position('employee_documents' in pg_get_functiondef(
      to_regprocedure('app.can_read_attachment(uuid, text, uuid)'))) > 0);
end $$;

rollback;
