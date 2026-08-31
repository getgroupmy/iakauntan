-- =====================================================================
-- iAkauntan :: what an HR manager may do
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/hr_manager_role.sql
--
-- `hr_manager` has been in `app.member_role` since `0024` and no
-- company could give it to anybody: the Flutter map the invite dialog
-- and the role dropdown are both built from never gained the value, so
-- the role that `app.can_manage_hr` and `app.can_run_payroll` are
-- defined by, and that `0119` and `0121` route expense claims to,
-- existed only for a test to set by hand. Payroll was delegable in the
-- database and admin-only in the app, and `0285` was written for
-- exactly the person who could not be appointed — "an owner running
-- their own company, or an outsourced HR administrator".
--
-- The app now offers it, and the row of words next to it in the invite
-- dialog is a promise about what the database will allow. This file is
-- that promise, asserted: an HR manager runs the people side and does
-- not get the ledger with it.
--
-- Both halves matter and the second is the one worth having. A role
-- that grants too little is a complaint on the first day; a role that
-- quietly grants the ledger is a segregation-of-duties failure nobody
-- sees until an auditor asks who could post.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org uuid;
  v_hr  uuid;
begin
  v_org := pg_temp.test_org('Delegated HR Sdn Bhd');
  v_hr  := pg_temp.another_user('hr.manager@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_hr, 'hr_manager', 'active');
  perform pg_temp.sign_in_as(v_hr);

  -- What the role is for.
  perform pg_temp.check_true('an HR manager manages HR',
    app.can_manage_hr(v_org));
  perform pg_temp.check_true('and runs payroll, which is the point of '
    'delegating it at all', app.can_run_payroll(v_org));

  -- And what comes with it, which is nothing.
  perform pg_temp.check_true('but does not post to the ledger',
    not app.can_post(v_org));
  perform pg_temp.check_true('nor read it — payroll is people, and the '
    'general ledger and audit trail are not',
    not app.can_read_ledger(v_org));
  perform pg_temp.check_true('nor raise an invoice or touch the CRM',
    not app.can_write(v_org));
  perform pg_temp.check_true('nor administer the company',
    not app.can_admin(v_org));

  -- The control. Every claim above is about `hr_manager` rather than
  -- about membership, and a `has_org_role` that ignored its argument
  -- would satisfy the four refusals for a viewer too — and the two
  -- permissions for nobody.
  update public.org_members set role = 'viewer'
   where org_id = v_org and user_id = v_hr;
  perform pg_temp.check_true('a viewer does not manage HR',
    not app.can_manage_hr(v_org));
  perform pg_temp.check_true('and does not run payroll',
    not app.can_run_payroll(v_org));

  perform pg_temp.sign_out();
end $$;

rollback;
