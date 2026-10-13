-- =====================================================================
-- iAkauntan :: a task's owner ticks it, and does nothing else to it (0870)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/onboarding_task_ticked.sql
--
-- The line manager who owns a new joiner's onboarding task could rewrite
-- it directly: rename it, make it optional, tick it with no time and
-- with somebody else as the one who ticked it. He ticks it through
-- `set_onboarding_task_done` now, which stamps him and the time and
-- works out whether the checklist is done; HR still edits tasks.
-- Asked with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ot (org uuid, mgr_user uuid, hr uuid,
  mgr uuid, joiner uuid, checklist uuid, laptop uuid, nda uuid);
grant select on t_ot to authenticated;

do $$
declare r t_ot;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Sambut Baru Sdn Bhd', array['hr']);
  r.mgr_user := pg_temp.another_user('ketua@sambutbaru.test');
  r.hr       := pg_temp.another_user('hr@sambutbaru.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.mgr_user, 'sales', 'active'),
         (r.org, r.hr, 'hr_manager', 'active');

  insert into public.employees (org_id, employee_no, full_name, user_id, hire_date)
  values (r.org, 'E1', 'Ketua Jualan', r.mgr_user, pg_temp.today())
  returning id into r.mgr;
  insert into public.employees (org_id, employee_no, full_name, manager_id, hire_date)
  values (r.org, 'E2', 'Pekerja Baru', r.mgr, pg_temp.today())
  returning id into r.joiner;

  insert into public.onboarding_checklists (org_id, employee_id, start_date)
  values (r.org, r.joiner, pg_temp.today())
  returning id into r.checklist;
  insert into public.onboarding_tasks
    (org_id, checklist_id, title, owner_employee_id, is_mandatory, sort_order)
  values (r.org, r.checklist, 'Laptop issued', r.mgr, true, 1)
  returning id into r.laptop;
  insert into public.onboarding_tasks
    (org_id, checklist_id, title, owner_employee_id, is_mandatory, sort_order)
  values (r.org, r.checklist, 'NDA signed', null, true, 2)
  returning id into r.nda;
  insert into t_ot select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The owner: the tick, and nothing else
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select mgr_user from t_ot));
set local role authenticated;

do $$
declare d t_ot; v_rows int; v_finished boolean;
begin
  select * into d from t_ot;
  perform pg_temp.check_true('the premise: the manager is not HR, owns the laptop task and reads it',
    not app.can_manage_hr(d.org)
    and (select owner_employee_id = d.mgr from public.onboarding_tasks where id = d.laptop));

  update public.onboarding_tasks
     set title = 'Laptop (not needed)', is_mandatory = false,
         is_done = true, done_by = d.hr
   where id = d.laptop;
  get diagnostics v_rows = row_count;
  perform pg_temp.check_eq('he cannot rewrite his task directly',
    v_rows, 0);
  perform pg_temp.check_eq('so it is as HR set it: named, mandatory, not done, ticked by nobody',
    (select title || ' / ' || is_mandatory || ' / ' || is_done || ' / '
            || coalesce(done_by::text, 'nobody')
       from public.onboarding_tasks where id = d.laptop),
    'Laptop issued / true / false / nobody');

  v_finished := public.set_onboarding_task_done(d.laptop);
  perform pg_temp.check_true('he ticks it through the function, which leaves the NDA open',
    not v_finished);
  perform pg_temp.check_true('and the tick is his, and timed',
    (select is_done and done_by = d.mgr_user and done_at is not null
       from public.onboarding_tasks where id = d.laptop));

  v_finished := public.set_onboarding_task_done(d.laptop, false);
  perform pg_temp.check_true('and he unticks it the same way, forgetting who and when',
    (select not is_done and done_by is null and done_at is null
       from public.onboarding_tasks where id = d.laptop));
end $$;

reset role;

-- ---------------------------------------------------------------------
-- HR still edits a task
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select hr from t_ot));
set local role authenticated;

do $$
declare d t_ot;
begin
  select * into d from t_ot;
  update public.onboarding_tasks
     set title = 'NDA signed (if asked)', is_mandatory = false
   where id = d.nda;
  perform pg_temp.check_eq('HR renames a task and makes it optional',
    (select title || ' / ' || is_mandatory
       from public.onboarding_tasks where id = d.nda),
    'NDA signed (if asked) / false');
end $$;

reset role;

-- And the owner's tick is now the last mandatory one.
select pg_temp.sign_in_as((select mgr_user from t_ot));
set local role authenticated;

do $$
declare d t_ot;
begin
  select * into d from t_ot;
  perform pg_temp.check_true('the owner''s tick finishes the checklist',
    public.set_onboarding_task_done(d.laptop));
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('and the checklist says so',
    (select completed_at is not null from public.onboarding_checklists
      where id = (select checklist from t_ot)));
end $$;

rollback;
