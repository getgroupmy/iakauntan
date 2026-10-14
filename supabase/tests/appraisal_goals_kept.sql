-- =====================================================================
-- iAkauntan :: an appraisal's goals are the setter's, and kept (0884)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/appraisal_goals_kept.sql
--
-- `0379` refused the person appraised setting or redefining their own
-- goals, before INSERT and UPDATE; the policy let them DELETE one. And
-- once HR had completed an appraisal, its goals could still be
-- re-weighted, rewritten, added to and deleted, while the appraisal row
-- refused everybody but HR. Asked with the role `authenticated`, as the
-- app asks.
--
-- Every refusal is paired with the same act by somebody entitled to
-- it, which goes through.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Somebody with a login, a membership, an employee record and a manager.
create or replace function pg_temp.ag_person(
  p_org uuid, p_no text, p_name text, p_email text, p_role text,
  p_manager uuid default null)
returns uuid language plpgsql as $$
declare v_user uuid := pg_temp.another_user(p_email); v_emp uuid;
begin
  insert into public.org_members (org_id, user_id, role, status)
  values (p_org, v_user, p_role::app.member_role, 'active');
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, user_id, manager_id)
  values (p_org, p_no, p_name, date '2020-01-01', 5000,
          date '1990-01-01', 'single', 'citizen', v_user, p_manager)
  returning id into v_emp;
  return v_emp;
end $$;

create or replace function pg_temp.ag_user(p_employee uuid)
returns uuid language sql as $$
  select user_id from public.employees where id = p_employee;
$$;

-- The goals of one appraisal, as somebody reading the record would.
create or replace function pg_temp.ag_goals(p_appraisal uuid)
returns text language sql as $$
  select coalesce(string_agg(title || ' ' || weight_percent::text || ' '
                             || coalesce(target, '-'), '; '
                             order by sort_order, title), 'none')
    from public.appraisal_goals where appraisal_id = p_appraisal;
$$;

create temporary table t_ag (org uuid, owner uuid, mei uuid, ali uuid,
  hana uuid, siti uuid, ap_ali uuid, ap_siti uuid, sales uuid,
  complaints uuid, siti_goal uuid);
grant select on t_ag to authenticated;

do $$
declare r t_ag; v_cycle uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org   := pg_temp.test_org('Matlamat Kekal Sdn Bhd');
  r.owner := pg_temp.test_user();
  -- Mei manages Ali. Hana is the HR Manager, and manages Siti too.
  r.mei  := pg_temp.ag_person(r.org, 'E1', 'Mei', 'mei@matlamat.test', 'employee');
  r.ali  := pg_temp.ag_person(r.org, 'E2', 'Ali', 'ali@matlamat.test', 'employee', r.mei);
  r.hana := pg_temp.ag_person(r.org, 'E3', 'Hana', 'hana@matlamat.test', 'hr_manager');
  r.siti := pg_temp.ag_person(r.org, 'E4', 'Siti', 'siti@matlamat.test', 'employee', r.hana);

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end,
     self_review_due, manager_review_due, rating_scale_max)
  values (r.org, 'FY2026 H1', date '2026-01-01', date '2026-06-30',
          date '2026-07-07', date '2026-07-21', 5)
  returning id into v_cycle;
  perform public.open_appraisal_cycle(v_cycle);
  select id into r.ap_ali from public.appraisals
   where cycle_id = v_cycle and employee_id = r.ali;
  select id into r.ap_siti from public.appraisals
   where cycle_id = v_cycle and employee_id = r.siti;
  insert into t_ag select r.*;
end $$;

-- The reviewers set the goals.
select pg_temp.sign_in_as(pg_temp.ag_user((select mei from t_ag)));
set local role authenticated;
insert into public.appraisal_goals
  (org_id, appraisal_id, title, weight_percent, target, sort_order)
select org, ap_ali, 'Sales', 60, 'RM1m', 1 from t_ag;
insert into public.appraisal_goals
  (org_id, appraisal_id, title, weight_percent, target, sort_order)
select org, ap_ali, 'Complaints', 40, 'none upheld', 2 from t_ag;
reset role;

select pg_temp.sign_in_as(pg_temp.ag_user((select hana from t_ag)));
set local role authenticated;
insert into public.appraisal_goals
  (org_id, appraisal_id, title, weight_percent, target, sort_order)
select org, ap_siti, 'Payroll on time', 100, '12 of 12', 1 from t_ag;
reset role;

update t_ag set
  sales      = (select id from public.appraisal_goals where title = 'Sales'),
  complaints = (select id from public.appraisal_goals where title = 'Complaints'),
  siti_goal  = (select id from public.appraisal_goals where title = 'Payroll on time');

-- ---------------------------------------------------------------------
-- Mid cycle: the person appraised takes no goal away
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as(pg_temp.ag_user((select ali from t_ag)));
set local role authenticated;
do $$
begin
  perform pg_temp.check_refused('the person appraised deletes no goal',
    format('delete from public.appraisal_goals where id = %L',
           (select complaints from t_ag)),
    'Goals are set, and taken off, by the reviewer or by HR.%', '42501');
end $$;
reset role;

do $$
begin
  perform pg_temp.check_eq('so both goals are still there',
    pg_temp.ag_goals((select ap_ali from t_ag)),
    'Sales 60.00 RM1m; Complaints 40.00 none upheld');
end $$;

-- The reviewer and HR, who set goals, take them off.
select pg_temp.sign_in_as(pg_temp.ag_user((select mei from t_ag)));
set local role authenticated;
insert into public.appraisal_goals
  (org_id, appraisal_id, title, weight_percent, sort_order)
select org, ap_ali, 'Set in error', 0, 9 from t_ag;
delete from public.appraisal_goals where title = 'Set in error';
reset role;

do $$
begin
  perform pg_temp.check_eq('the reviewer takes off a goal they set',
    pg_temp.ag_goals((select ap_ali from t_ag)),
    'Sales 60.00 RM1m; Complaints 40.00 none upheld');
end $$;

select pg_temp.sign_in_as((select owner from t_ag));
set local role authenticated;
insert into public.appraisal_goals
  (org_id, appraisal_id, title, weight_percent, sort_order)
select org, ap_ali, 'HR set in error', 0, 9 from t_ag;
delete from public.appraisal_goals where title = 'HR set in error';
reset role;

do $$
begin
  perform pg_temp.check_eq('and so does HR',
    pg_temp.ag_goals((select ap_ali from t_ag)),
    'Sales 60.00 RM1m; Complaints 40.00 none upheld');
end $$;

-- ---------------------------------------------------------------------
-- Completed: the goals are part of the record
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as(pg_temp.ag_user((select ali from t_ag)));
set local role authenticated;
select public.submit_self_appraisal((select ap_ali from t_ag), 4, 'A good half');
reset role;

select pg_temp.sign_in_as(pg_temp.ag_user((select mei from t_ag)));
set local role authenticated;
update public.appraisal_goals set manager_rating = 2 where id = (select sales from t_ag);
update public.appraisal_goals set manager_rating = 5 where id = (select complaints from t_ag);
select public.submit_manager_appraisal((select ap_ali from t_ag), 3, 'Fair',
  0, 0, false, null);
reset role;

select pg_temp.sign_in_as((select owner from t_ag));
set local role authenticated;
select public.finalise_appraisal((select ap_ali from t_ag), 3, null);
reset role;

select pg_temp.sign_in_as(pg_temp.ag_user((select mei from t_ag)));
set local role authenticated;
do $$
declare d t_ag;
begin
  select * into d from t_ag;
  perform pg_temp.check_refused('the reviewer re-weights no goal of a completed appraisal',
    format('update public.appraisal_goals set weight_percent = 10 where id = %L', d.sales),
    'This appraisal was completed on %', '23514');
  perform pg_temp.check_refused('adds none to it',
    format($q$insert into public.appraisal_goals (org_id, appraisal_id, title, weight_percent)
              values (%L, %L, 'Afterthought', 0)$q$, d.org, d.ap_ali),
    'This appraisal was completed on %', '23514');
  perform pg_temp.check_refused('and takes none off',
    format('delete from public.appraisal_goals where id = %L', d.sales),
    'This appraisal was completed on %', '23514');
end $$;
reset role;

select pg_temp.sign_in_as(pg_temp.ag_user((select ali from t_ag)));
set local role authenticated;
do $$
begin
  perform pg_temp.check_refused('nor does the person appraised',
    format('delete from public.appraisal_goals where id = %L',
           (select sales from t_ag)),
    'This appraisal was completed on %', '23514');
end $$;
reset role;

do $$
begin
  perform pg_temp.check_eq('the completed appraisal''s goals are as they were',
    pg_temp.ag_goals((select ap_ali from t_ag)),
    'Sales 60.00 RM1m; Complaints 40.00 none upheld');
end $$;

-- HR, who completed it, may still correct it.
select pg_temp.sign_in_as((select owner from t_ag));
set local role authenticated;
update public.appraisal_goals set target = 'RM1m net' where id = (select sales from t_ag);
reset role;

do $$
begin
  perform pg_temp.check_eq('HR corrects a completed appraisal''s goal',
    pg_temp.ag_goals((select ap_ali from t_ag)),
    'Sales 60.00 RM1m net; Complaints 40.00 none upheld');
end $$;

-- Reopened, it is the reviewer's to write again.
select pg_temp.sign_in_as((select owner from t_ag));
set local role authenticated;
select public.reopen_appraisal((select ap_ali from t_ag), 'final');
reset role;

select pg_temp.sign_in_as(pg_temp.ag_user((select mei from t_ag)));
set local role authenticated;
update public.appraisal_goals set target = 'RM1.1m' where id = (select sales from t_ag);
reset role;

do $$
begin
  perform pg_temp.check_eq('reopened by HR, the reviewer rewrites a goal',
    pg_temp.ag_goals((select ap_ali from t_ag)),
    'Sales 60.00 RM1.1m; Complaints 40.00 none upheld');
end $$;

-- ---------------------------------------------------------------------
-- A cascade is not a client taking a goal off
-- ---------------------------------------------------------------------
-- Siti's appraisal completed, under Hana: the HR Manager, and here the
-- reviewer, which is the part that counts on this appraisal.
select pg_temp.sign_in_as(pg_temp.ag_user((select siti from t_ag)));
set local role authenticated;
select public.submit_self_appraisal((select ap_siti from t_ag), 5, 'Every month');
reset role;

select pg_temp.sign_in_as(pg_temp.ag_user((select hana from t_ag)));
set local role authenticated;
update public.appraisal_goals set manager_rating = 5 where id = (select siti_goal from t_ag);
select public.submit_manager_appraisal((select ap_siti from t_ag), 5, 'Every month',
  0, 0, false, null);
reset role;

select pg_temp.sign_in_as((select owner from t_ag));
set local role authenticated;
select public.finalise_appraisal((select ap_siti from t_ag), 5, null);
reset role;

select pg_temp.sign_in_as(pg_temp.ag_user((select hana from t_ag)));
set local role authenticated;
do $$
begin
  perform pg_temp.check_refused('the reviewer takes no goal off it, HR Manager or not',
    format('delete from public.appraisal_goals where id = %L',
           (select siti_goal from t_ag)),
    'This appraisal was completed on %', '23514');
end $$;
-- But the appraisal is HR's to delete, and its goals go with it.
--
-- The guard lets this through twice over, and the mutant that drops
-- `pg_trigger_depth() > 1` lives: equivalent, measured. The foreign
-- key's cascade deletes the goal as the table's owner, one level
-- down -- a trigger here read `current_user=postgres depth=2` -- so
-- the owner test alone already passes it. The depth test stays for
-- an invoker trigger that may one day delete a goal as the client;
-- none does today.
delete from public.appraisals where id = (select ap_siti from t_ag);
reset role;

do $$
begin
  perform pg_temp.check_eq('deleting the appraisal takes its goals with it',
    (select count(*) from public.appraisal_goals
      where appraisal_id = (select ap_siti from t_ag))::int, 0);
end $$;

-- Nor is the database's owner, working outside the app, asked -- even
-- while the last person signed in is the one appraised.
select pg_temp.sign_in_as(pg_temp.ag_user((select ali from t_ag)));
delete from public.appraisal_goals where id = (select complaints from t_ag);

do $$
begin
  perform pg_temp.check_eq('the owner of the database removes a goal outside the app',
    pg_temp.ag_goals((select ap_ali from t_ag)), 'Sales 60.00 RM1.1m');
end $$;

rollback;
