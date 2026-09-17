-- =====================================================================
-- iAkauntan :: the shapes behind whose half of the appraisal is whose
--
-- `appraisals.sql` is the behaviour file for this surface and it makes
-- the assertion that matters: as the subject, every column that is not
-- theirs is refused, column by column. A sweep of 75 one-line mutants
-- against `app.appraisal_change_guard`,
-- `app.appraisal_goal_change_guard`, `app.appraisal_part` and
-- `app.appraisal_part_of` killed 49 of them, which is the best opening
-- result of this campaign and says the file is doing its job.
--
-- What it does not have is anybody standing OUTSIDE the two halves. Its
-- cast is a manager, the person who reports to them, and the owner —
-- who is HR by virtue of owning the place. So the bottom of
-- `appraisal_part_of`, where somebody who is neither party and not HR
-- gets nothing at all, had never been reached: `return 'hr'` for
-- everybody passed every assertion in the file.
--
-- Nor is there anybody who is BOTH. The rule at the top of that
-- function is written down in its own comment — "somebody who is both
-- HR and the person being appraised is the person being appraised" —
-- and it was the one line of the function nothing tested. An HR manager
-- with an appraisal of their own could have set their own final rating.
--
-- And the guard's other edges: the scale's floor and ceiling on three
-- of the five rating columns, the six-part rule that an appraisal opens
-- EMPTY, reopening a half and rewriting it in the same statement, and
-- the half of a goal that belongs to the reviewer rather than to the
-- person being measured.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ag_person(
  p_org uuid, p_no text, p_name text, p_email text,
  p_manager uuid default null)
returns uuid language plpgsql as $$
declare v_user uuid := pg_temp.another_user(p_email); v_emp uuid;
begin
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

do $$
declare
  v_org    uuid := pg_temp.test_org('Penilaian Tepi Sdn Bhd');
  v_owner  uuid := pg_temp.test_user();
  v_mei    uuid;   -- the manager
  v_ali    uuid;   -- reports to Mei, and is appraised
  v_hana   uuid;   -- HR, and appraised herself
  v_zul    uuid;   -- neither party, and not HR
  v_cycle  uuid;
  v_a_ali  uuid;
  v_a_hana uuid;
  v_goal   uuid;
  v_nowt   uuid;
begin
  v_mei  := pg_temp.ag_person(v_org, 'E1', 'Mei the manager', 'mei@ag.test');
  v_ali  := pg_temp.ag_person(v_org, 'E2', 'Ali', 'ali@ag.test', v_mei);
  v_hana := pg_temp.ag_person(v_org, 'E3', 'Hana of HR', 'hana@ag.test');
  v_zul  := pg_temp.ag_person(v_org, 'E4', 'Zul from the next desk',
                              'zul@ag.test');

  -- Hana runs HR. Zul is a member of the company like anybody else and
  -- has no say in what anybody is paid, which is the case the bottom of
  -- `appraisal_part_of` exists for and which nothing had ever stood up.
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, pg_temp.ag_user(v_hana), 'hr_manager', 'active', now()),
         (v_org, pg_temp.ag_user(v_zul), 'employee', 'active', now());

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end,
     self_review_due, manager_review_due, rating_scale_max)
  values (v_org, 'FY2026 H1', date '2026-01-01', date '2026-06-30',
          date '2026-07-07', date '2026-07-21', 5)
  returning id into v_cycle;
  perform public.open_appraisal_cycle(v_cycle);

  select id into v_a_ali from public.appraisals
   where cycle_id = v_cycle and employee_id = v_ali;
  select id into v_a_hana from public.appraisals
   where cycle_id = v_cycle and employee_id = v_hana;

  -- ------------------------------------------------------------------
  -- An appraisal opens EMPTY, and it is six columns rather than one
  --
  -- The two halves are written by the two people, afterwards, each in
  -- their own right. A row created with either half already in it is a
  -- row nobody said anything for. Each column is asserted on its own,
  -- because a guard listing six conditions passes with five of them
  -- deleted if only the sixth is ever tried.
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('an appraisal opened with a self rating in it',
    format($q$insert into public.appraisals
                (org_id, cycle_id, employee_id, self_rating)
              values (%L, %L, %L, 4)$q$, v_org, v_cycle, v_zul),
    'An appraisal is opened empty.%', '23514');
  perform pg_temp.check_refused('with self comments in it',
    format($q$insert into public.appraisals
                (org_id, cycle_id, employee_id, self_comments)
              values (%L, %L, %L, 'I did well')$q$, v_org, v_cycle, v_zul),
    'An appraisal is opened empty.%', '23514');
  perform pg_temp.check_refused('already submitted',
    format($q$insert into public.appraisals
                (org_id, cycle_id, employee_id, self_submitted_at)
              values (%L, %L, %L, now())$q$, v_org, v_cycle, v_zul),
    'An appraisal is opened empty.%', '23514');
  perform pg_temp.check_refused('with a manager rating in it',
    format($q$insert into public.appraisals
                (org_id, cycle_id, employee_id, manager_rating)
              values (%L, %L, %L, 4)$q$, v_org, v_cycle, v_zul),
    'An appraisal is opened empty.%', '23514');
  perform pg_temp.check_refused('with manager comments in it',
    format($q$insert into public.appraisals
                (org_id, cycle_id, employee_id, manager_comments)
              values (%L, %L, %L, 'Steady')$q$, v_org, v_cycle, v_zul),
    'An appraisal is opened empty.%', '23514');
  perform pg_temp.check_refused('with the manager half already stamped',
    format($q$insert into public.appraisals
                (org_id, cycle_id, employee_id, manager_submitted_at)
              values (%L, %L, %L, now())$q$, v_org, v_cycle, v_zul),
    'An appraisal is opened empty.%', '23514');

  -- And an appraisal in no cycle at all is refused BY THE GUARD, in a
  -- sentence, rather than by the foreign key underneath it. A row
  -- trigger runs first, so the two are separable and the guard's own
  -- words are what an assertion should read.
  perform pg_temp.check_refused('an appraisal that belongs to no cycle',
    format($q$insert into public.appraisals (org_id, cycle_id, employee_id)
              values (%L, %L, %L)$q$,
           v_org, '00000000-0000-0000-0000-000000000009'::uuid, v_zul),
    'An appraisal belongs to a cycle.%', '23502');

  -- ------------------------------------------------------------------
  -- The scale is the cycle's, and it binds every rating column
  --
  -- Nought is not a rating: it is what a numeric field holds when
  -- somebody tabbed past it. Five columns carry a rating and each end
  -- of the scale binds all of them.
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_mei));
  perform pg_temp.check_refused('nought is not a manager rating',
    format('update public.appraisals set manager_rating = 0 where id = %L',
           v_a_ali),
    'This cycle is rated out of 5.%', '23514');

  perform pg_temp.sign_in_as(pg_temp.ag_user(v_hana));
  perform pg_temp.check_refused('nor a final rating',
    format('update public.appraisals set final_rating = 0 where id = %L',
           v_a_ali),
    'This cycle is rated out of 5.%', '23514');
  perform pg_temp.check_refused('and a final rating off the top is refused too',
    format('update public.appraisals set final_rating = 6 where id = %L',
           v_a_ali),
    'This cycle is rated out of 5.%', '23514');

  -- ------------------------------------------------------------------
  -- An appraisal is one person in one cycle
  -- ------------------------------------------------------------------
  perform pg_temp.check_refused('an appraisal is not moved to another person',
    format('update public.appraisals set employee_id = %L where id = %L',
           v_zul, v_a_ali),
    'An appraisal is one person in one cycle.%', '23514');

  -- ------------------------------------------------------------------
  -- Reopening a half is not writing in it
  --
  -- HR takes the stamp off so the person can say it again. Taking the
  -- stamp off and writing the words in the same statement is HR writing
  -- somebody else's half with a reopen wrapped round it, and the guard
  -- recognises a reopen from the change itself rather than from a flag.
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_mei));
  update public.appraisals
     set manager_rating = 4, manager_comments = 'A good half year'
   where id = v_a_ali;
  update public.appraisals set manager_submitted_at = now(),
         status = 'calibration'
   where id = v_a_ali;

  perform pg_temp.sign_in_as(pg_temp.ag_user(v_hana));
  perform pg_temp.check_refused(
    'HR reopening a half and rewriting it in one go is not a reopen',
    format($q$update public.appraisals
                 set manager_submitted_at = null,
                     manager_comments = 'HR would have put it differently'
               where id = %L$q$, v_a_ali),
    'The manager''s half belongs to the named reviewer%', '42501');
  -- The reopen on its own is HR's to do, which is the line above's
  -- other half: the guard has to allow one and refuse the other.
  update public.appraisals set manager_submitted_at = null
   where id = v_a_ali;
  perform pg_temp.check_true('and the reopen on its own is HR''s to do',
    (select manager_submitted_at is null
       from public.appraisals where id = v_a_ali));

  -- ------------------------------------------------------------------
  -- The ladder, and how far up it the reviewer may push
  --
  -- The reviewer moves an appraisal into calibration when their half is
  -- in. Calibration is as far as they go: what happens after it is
  -- HR's, and a reviewer who can set the status to anything can mark
  -- their own report completed without a calibration meeting.
  -- ------------------------------------------------------------------
  update public.appraisals set status = 'manager_review' where id = v_a_ali;
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_mei));
  perform pg_temp.check_refused('the reviewer does not close the appraisal',
    format('update public.appraisals set status = ''completed'' where id = %L',
           v_a_ali),
    'An appraisal moves from % to the next stage%', '23514');

  -- ------------------------------------------------------------------
  -- Somebody who is neither party, and is not HR
  --
  -- Zul sits at the next desk. He is a member of the company with a
  -- login and an employee record, and he is nobody in this appraisal.
  -- Every branch of `appraisal_part_of` falls through for him, and what
  -- falls out of the bottom is nothing at all.
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_zul));
  perform pg_temp.check_true('a bystander is no part of an appraisal',
    app.appraisal_part(v_a_ali) is null);
  perform pg_temp.check_refused('and sets nobody''s final rating',
    format('update public.appraisals set final_rating = 5 where id = %L',
           v_a_ali),
    'The final rating, the calibration note and who reviews whom are%',
    '42501');
  perform pg_temp.check_refused('nor writes somebody else''s self review',
    format('update public.appraisals set self_rating = 5 where id = %L',
           v_a_ali),
    'Only the person being appraised writes their own self review.%', '42501');

  -- ------------------------------------------------------------------
  -- Somebody who is both HR and the person being appraised
  --
  -- The rule is in the function's own comment: they are the person
  -- being appraised. Hana runs HR and has an appraisal of her own, and
  -- if HR were read first she could hand herself a five.
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_hana));
  perform pg_temp.check_eq('HR being appraised is the person being appraised',
    app.appraisal_part(v_a_hana), 'subject');
  perform pg_temp.check_refused('so HR does not rate their own appraisal',
    format('update public.appraisals set final_rating = 5 where id = %L',
           v_a_hana),
    'The final rating, the calibration note and who reviews whom are%',
    '42501');
  -- And is still HR everywhere else.
  perform pg_temp.check_eq('and is HR on everybody else''s',
    app.appraisal_part(v_a_ali), 'hr');
  -- A part is read for an appraisal that exists, and for one that does
  -- not there is no part to read.
  perform pg_temp.check_true('an appraisal nobody opened has no parts',
    app.appraisal_part('00000000-0000-0000-0000-000000000009'::uuid) is null);
  -- `appraisal_part` returns early for an appraisal that is not there,
  -- and the early return cannot be observed: every branch of
  -- `appraisal_part_of` falls through for a row of nulls anyway, because
  -- nobody is an employee of no company and nobody runs HR at one. That
  -- is the rule the early return leans on, and it is the rule asserted.
  perform pg_temp.check_true('and no company has a part in anything',
    app.appraisal_part_of(null, null, null) is null);

  -- ------------------------------------------------------------------
  -- A goal, and the halves of it
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_mei));
  insert into public.appraisal_goals
    (org_id, appraisal_id, title, description, category,
     weight_percent, target, sort_order)
  values (v_org, v_a_ali, 'Ship the ledger rewrite',
          'The one everybody is waiting on', 'delivery', 40, 'By June', 1)
  returning id into v_goal;

  perform pg_temp.check_refused('a goal cannot carry less than none of the job',
    format($q$insert into public.appraisal_goals
                (org_id, appraisal_id, title, weight_percent)
              values (%L, %L, 'A goal worth less than nothing', -1)$q$,
           v_org, v_a_ali),
    'A goal cannot carry less than none of the job.%', '23514');
  perform pg_temp.check_refused('and a goal against no appraisal is refused',
    format($q$insert into public.appraisal_goals
                (org_id, appraisal_id, title, weight_percent)
              values (%L, %L, 'A goal for nobody', 10)$q$,
           v_org, '00000000-0000-0000-0000-000000000009'::uuid),
    'No such appraisal.%', 'P0002');

  -- The subject rates themselves against it, and nothing else about it.
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_ali));
  perform pg_temp.check_refused('nought is not a rating against a goal',
    format('update public.appraisal_goals set self_rating = 0 where id = %L',
           v_goal),
    'This cycle is rated out of 5.%', '23514');
  perform pg_temp.check_refused('the subject does not retitle the goal',
    format($q$update public.appraisal_goals set description = 'Something easier'
             where id = %L$q$, v_goal),
    'The goal itself%', '42501');
  perform pg_temp.check_refused('nor refile it under something else',
    format($q$update public.appraisal_goals set category = 'admin'
             where id = %L$q$, v_goal),
    'The goal itself%', '42501');
  perform pg_temp.check_refused('nor move it up the page',
    format('update public.appraisal_goals set sort_order = 99 where id = %L',
           v_goal),
    'The goal itself%', '42501');
  -- The manager's half of a goal is three columns, not one: the rating,
  -- what they said about it, and what actually happened.
  perform pg_temp.check_refused('nor write the comment against it',
    format($q$update public.appraisal_goals set comments = 'I was marvellous'
             where id = %L$q$, v_goal),
    'The manager''s rating against a goal is the reviewer''s.%', '42501');
  perform pg_temp.check_refused('nor say what actually happened',
    format($q$update public.appraisal_goals set actual = 'Shipped in April'
             where id = %L$q$, v_goal),
    'The manager''s rating against a goal is the reviewer''s.%', '42501');

  -- And the reviewer's half is the reviewer's, HR included.
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_mei));
  perform pg_temp.check_refused('nought is not a manager rating on a goal',
    format('update public.appraisal_goals set manager_rating = 0 where id = %L',
           v_goal),
    'This cycle is rated out of 5.%', '23514');
  perform pg_temp.sign_in_as(pg_temp.ag_user(v_hana));
  perform pg_temp.check_refused('HR does not rate a goal for the reviewer',
    format('update public.appraisal_goals set manager_rating = 4 where id = %L',
           v_goal),
    'The manager''s rating against a goal is the reviewer''s.%', '42501');

  perform pg_temp.sign_in_as(v_owner);
end $$;

rollback;
