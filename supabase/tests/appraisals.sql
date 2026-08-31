-- =====================================================================
-- iAkauntan :: whose half of the appraisal is whose
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/appraisals.sql
--
-- `0038` grants the person being appraised UPDATE on their own
-- appraisal row, and a row policy has no opinion about columns. So
-- until `0379` the subject could write their own `manager_rating`,
-- their own `final_rating`, their own `promotion_recommended` and their
-- own `recommended_bonus`, through the ordinary endpoint, and the row
-- afterwards was indistinguishable from one two people had written.
--
-- The first block is the one that matters: as the subject, every column
-- that is not theirs is refused. It is asserted column by column rather
-- than once, because "the update failed" and "that particular column is
-- not yours" are different claims and only the second is the rule.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- Somebody with a login, an employee record, and a manager.
create or replace function pg_temp.ap_person(
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

create or replace function pg_temp.ap_user(p_employee uuid)
returns uuid language sql as $$
  select user_id from public.employees where id = p_employee;
$$;

-- ---------------------------------------------------------------------
-- Opening a cycle, and the halves it opens
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid := pg_temp.test_org('Penilaian Prestasi Sdn Bhd');
  v_owner  uuid := pg_temp.test_user();
  v_mei    uuid;
  v_ali    uuid;
  v_gone   uuid;
  v_cycle  uuid;
  v_a_ali  uuid;
  v_a_mei  uuid;
  v_n      integer;
  v_said   text;
begin
  v_mei := pg_temp.ap_person(v_org, 'E1', 'Mei the manager', 'mei@ap.test');
  v_ali := pg_temp.ap_person(v_org, 'E2', 'Ali', 'ali@ap.test', v_mei);

  -- Left before the period ended, so not appraised for it.
  v_gone := pg_temp.ap_person(v_org, 'E3', 'Gone', 'gone@ap.test', v_mei);
  perform public.record_departure(v_gone, date '2026-03-31', 'resigned');

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end,
     self_review_due, manager_review_due, rating_scale_max)
  values (v_org, 'FY2026 H1', date '2026-01-01', date '2026-06-30',
          date '2026-07-07', date '2026-07-21', 5)
  returning id into v_cycle;

  v_n := public.open_appraisal_cycle(v_cycle);
  perform pg_temp.check_eq('a cycle opens one appraisal per person '
    'employed at the end of the period', v_n, 2);
  perform pg_temp.check_eq('and the cycle is now waiting on self reviews',
    (select status::text from public.appraisal_cycles where id = v_cycle),
    'self_review');

  select id into v_a_ali from public.appraisals
   where cycle_id = v_cycle and employee_id = v_ali;
  select id into v_a_mei from public.appraisals
   where cycle_id = v_cycle and employee_id = v_mei;

  perform pg_temp.check_eq('the reviewer is the reporting line',
    (select reviewer_id from public.appraisals where id = v_a_ali), v_mei);
  perform pg_temp.check_true('and nobody where there is no line',
    (select reviewer_id is null from public.appraisals where id = v_a_mei));

  -- Running it twice does not double anybody up.
  perform pg_temp.check_eq('opening it again opens nothing',
    public.open_appraisal_cycle(v_cycle), 0);

  -- -------------------------------------------------------------------
  -- The subject, and the columns that are not theirs
  -- -------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));

  begin
    update public.appraisals set manager_rating = 5 where id = v_a_ali;
    raise exception 'FAIL: the subject rated themselves as their manager';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the subject cannot write the manager rating',
    v_said like '%belongs to the named reviewer%');

  begin
    update public.appraisals set manager_comments = 'Outstanding'
     where id = v_a_ali;
    raise exception 'FAIL: the subject wrote their own manager comments';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set manager_submitted_at = now()
     where id = v_a_ali;
    raise exception 'FAIL: the subject stamped the manager review';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set promotion_recommended = true
     where id = v_a_ali;
    raise exception 'FAIL: the subject recommended their own promotion';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set recommended_bonus = 20000
     where id = v_a_ali;
    raise exception 'FAIL: the subject awarded themselves a bonus';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set recommended_increment_percent = 30
     where id = v_a_ali;
    raise exception 'FAIL: the subject awarded themselves a rise';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set development_plan = 'None needed'
     where id = v_a_ali;
    raise exception 'FAIL: the subject wrote their own development plan';
  exception when sqlstate '42501' then null;
  end;

  begin
    update public.appraisals set final_rating = 5 where id = v_a_ali;
    raise exception 'FAIL: the subject set their own final rating';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('nor the final rating',
    v_said like '%HR''s%');
  begin
    update public.appraisals set calibration_note = 'Agreed'
     where id = v_a_ali;
    raise exception 'FAIL: the subject wrote the calibration note';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set completed_at = now() where id = v_a_ali;
    raise exception 'FAIL: the subject completed their own appraisal';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set reviewer_id = v_ali where id = v_a_ali;
    raise exception 'FAIL: the subject made themselves the reviewer';
  exception when sqlstate '42501' then null;
  end;

  begin
    update public.appraisals set status = 'completed' where id = v_a_ali;
    raise exception 'FAIL: the subject jumped the appraisal to completed';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and the status is not a field',
    v_said like '%not a field%');

  -- Somebody else's appraisal is nothing to do with them at all.
  begin
    update public.appraisals set self_rating = 1 where id = v_a_mei;
    raise exception 'FAIL: one employee wrote another''s self review';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The two halves, said by the two people
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Dua Bahagian Sdn Bhd');
  v_mei   uuid;
  v_ali   uuid;
  v_cycle uuid;
  v_ap    uuid;
  v_goal  uuid;
  v_said  text;
  v_row   public.appraisals;
begin
  v_mei := pg_temp.ap_person(v_org, 'E1', 'Mei', 'mei2@ap.test');
  v_ali := pg_temp.ap_person(v_org, 'E2', 'Ali', 'ali2@ap.test', v_mei);

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end,
     self_review_due, manager_review_due, rating_scale_max)
  values (v_org, 'FY2026', date '2026-01-01', date '2026-12-31',
          current_date + 7, current_date + 21, 5)
  returning id into v_cycle;
  perform public.open_appraisal_cycle(v_cycle);
  select id into v_ap from public.appraisals
   where cycle_id = v_cycle and employee_id = v_ali;

  -- The goals the appraisal is a judgement about are set by the reviewer.
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));
  begin
    insert into public.appraisal_goals
      (org_id, appraisal_id, title, weight_percent)
    values (v_org, v_ap, 'Turn up', 100);
    raise exception 'FAIL: the subject set their own goals';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('goals are set by whoever measures you',
    v_said like '%reviewer or by HR%');

  perform pg_temp.sign_in_as(pg_temp.ap_user(v_mei));
  insert into public.appraisal_goals
    (org_id, appraisal_id, title, weight_percent, target)
  values (v_org, v_ap, 'Ship the migration', 60, 'By June')
  returning id into v_goal;
  insert into public.appraisal_goals
    (org_id, appraisal_id, title, weight_percent)
  values (v_org, v_ap, 'Mentor a junior', 40);

  -- The manager cannot write the employee's half of a goal either.
  begin
    update public.appraisal_goals set self_rating = 5 where id = v_goal;
    raise exception 'FAIL: the reviewer rated the goal on the subject''s '
      'behalf';
  exception when sqlstate '42501' then null;
  end;

  -- Nor can the subject move the goalposts: what the goal is, what it
  -- is worth and what the target was belong to whoever set them.
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));
  begin
    update public.appraisal_goals set weight_percent = 5 where id = v_goal;
    raise exception 'FAIL: the subject reweighted their own goal';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the goal itself belongs to whoever set it',
    v_said like '%belongs to whoever set it%');
  begin
    update public.appraisal_goals set target = 'By December' where id = v_goal;
    raise exception 'FAIL: the subject moved their own target';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisal_goals set title = 'Turn up' where id = v_goal;
    raise exception 'FAIL: the subject rewrote their own goal';
  exception when sqlstate '42501' then null;
  end;
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_mei));

  -- -------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));

  -- A rating outside the cycle's own scale.
  begin
    perform public.submit_self_appraisal(v_ap, 7, 'Good year');
    raise exception 'FAIL: a 7 was accepted in a cycle rated out of 5';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the rating is bounded by the cycle''s scale',
    v_said like '%rated out of 5%');
  begin
    perform public.submit_self_appraisal(v_ap, 0, 'Good year');
    raise exception 'FAIL: nought was accepted as a rating';
  exception when sqlstate '23514' then null;
  end;

  -- A number with nothing beside it.
  begin
    perform public.submit_self_appraisal(v_ap, 4, '   ');
    raise exception 'FAIL: a self review was submitted with no words';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and a rating needs something said beside it',
    v_said like '%Say something%');

  -- The scale binds the goals as well as the overall rating. A goal
  -- rated 9 under a heading rated out of 5 is the same nonsense one
  -- level down, where nobody would look for it.
  begin
    update public.appraisal_goals set self_rating = 9 where id = v_goal;
    raise exception 'FAIL: a goal was rated 9 in a cycle rated out of 5';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a goal rating is bounded by the same scale',
    v_said like '%rated out of 5%');

  update public.appraisal_goals set self_rating = 4 where id = v_goal;
  perform public.submit_self_appraisal(v_ap, 4,
    'Shipped it in May. The mentoring slipped.');

  select * into v_row from public.appraisals where id = v_ap;
  perform pg_temp.check_eq('the self review is recorded',
    v_row.self_rating, 4);
  perform pg_temp.check_eq('with the words',
    v_row.self_comments, 'Shipped it in May. The mentoring slipped.');
  perform pg_temp.check_true('and stamped', v_row.self_submitted_at is not null);
  perform pg_temp.check_eq('and the appraisal is now the manager''s',
    v_row.status::text, 'manager_review');

  -- Submitted is submitted.
  begin
    perform public.submit_self_appraisal(v_ap, 5, 'Actually, excellent');
    raise exception 'FAIL: a self review was submitted twice';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a submitted self review cannot be resubmitted',
    v_said like '%Ask HR to reopen it%');
  begin
    update public.appraisals set self_rating = 5 where id = v_ap;
    raise exception 'FAIL: a submitted self review was edited underneath';
  exception when sqlstate '23514' then null;
  end;
  begin
    update public.appraisal_goals set self_rating = 5 where id = v_goal;
    raise exception 'FAIL: a goal rating was edited after submission';
  exception when sqlstate '23514' then null;
  end;
  begin
    update public.appraisals set self_submitted_at = null where id = v_ap;
    raise exception 'FAIL: the author took their own submission back';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and the author cannot take the submission '
    'back themselves', v_said like '%Only HR reopens%');

  -- -------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_mei));

  begin
    perform public.submit_manager_appraisal(v_ap, 9, 'Great');
    raise exception 'FAIL: a 9 was accepted in a cycle rated out of 5';
  exception when sqlstate '23514' then null;
  end;
  begin
    perform public.submit_manager_appraisal(v_ap, 3, '');
    raise exception 'FAIL: a manager review was submitted with no words';
  exception when sqlstate '23514' then null;
  end;

  begin
    update public.appraisal_goals set manager_rating = 9 where id = v_goal;
    raise exception 'FAIL: a goal was rated 9 by the manager';
  exception when sqlstate '23514' then null;
  end;
  update public.appraisal_goals
     set manager_rating = 4, comments = 'Landed on time', actual = 'May'
   where id = v_goal;

  perform public.submit_manager_appraisal(
    v_ap, 3, 'Agreed on the migration; the mentoring did not happen.',
    4.5, 3000, false, 'Pair with the new joiner from July.');

  select * into v_row from public.appraisals where id = v_ap;
  perform pg_temp.check_eq('the manager review is recorded',
    v_row.manager_rating, 3);
  perform pg_temp.check_eq('with what it led to', v_row.recommended_bonus, 3000);
  perform pg_temp.check_eq('and the increment proposed',
    v_row.recommended_increment_percent, 4.5);
  perform pg_temp.check_true('and no promotion this time',
    v_row.promotion_recommended is false);
  perform pg_temp.check_eq('and a plan',
    v_row.development_plan, 'Pair with the new joiner from July.');
  perform pg_temp.check_eq('and the appraisal is now HR''s',
    v_row.status::text, 'calibration');

  -- Submitted is submitted on this side too, and not only through the
  -- function: the rule is on the table, so the endpoint that writes the
  -- column directly meets it as well.
  begin
    perform public.submit_manager_appraisal(v_ap, 5, 'On reflection');
    raise exception 'FAIL: a manager review was submitted twice';
  exception when sqlstate '23514' then null;
  end;
  begin
    update public.appraisals set manager_rating = 5 where id = v_ap;
    raise exception 'FAIL: a submitted manager review was edited underneath';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a submitted manager review is not editable',
    v_said like '%Ask HR to reopen it%');
  begin
    update public.appraisal_goals set manager_rating = 5 where id = v_goal;
    raise exception 'FAIL: a goal was re-rated after the manager submitted';
  exception when sqlstate '23514' then null;
  end;

  -- -------------------------------------------------------------------
  -- Settling it
  -- -------------------------------------------------------------------
  begin
    perform public.finalise_appraisal(v_ap, 3);
    raise exception 'FAIL: the reviewer finalised the appraisal';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.sign_in_as(pg_temp.test_user());

  begin
    perform public.finalise_appraisal(v_ap, 4);
    raise exception 'FAIL: HR departed from the manager without a word';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a final rating away from the manager''s '
    'needs a reason', v_said like '%rated this 3.00 and you are settling on 4.00%');

  -- The goals have to weigh the whole job before the judgement about
  -- them is settled.
  update public.appraisal_goals set weight_percent = 50 where id = v_goal;
  begin
    perform public.finalise_appraisal(v_ap, 3);
    raise exception 'FAIL: an appraisal was completed over goals weighing 90';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('goals that do not weigh a hundred stop it',
    v_said like '%come to 90.00, not 100%');
  update public.appraisal_goals set weight_percent = 60 where id = v_goal;

  perform public.finalise_appraisal(v_ap, 4,
    'Moderated up: the mentoring goal was reassigned in March.');
  select * into v_row from public.appraisals where id = v_ap;
  perform pg_temp.check_eq('the final rating is settled', v_row.final_rating, 4);
  perform pg_temp.check_true('with the note that is the whole of what '
    'calibration leaves behind', v_row.calibration_note like 'Moderated up%');
  perform pg_temp.check_eq('and the appraisal is done',
    v_row.status::text, 'completed');
  perform pg_temp.check_true('and dated', v_row.completed_at is not null);

  -- -------------------------------------------------------------------
  -- The way back
  -- -------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));
  begin
    perform public.reopen_appraisal(v_ap, 'self');
    raise exception 'FAIL: the subject reopened their own submitted review';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  -- The message names which guard spoke. The trigger would refuse this
  -- too, and a test that accepted either would pass with the function's
  -- own check taken out — leaving the refusal to happen after the
  -- update had been attempted rather than before.
  perform pg_temp.check_true('and is refused before anything is written',
    v_said like '%not permitted to reopen%');
  begin
    update public.appraisals set self_submitted_at = null where id = v_ap;
    raise exception 'FAIL: the subject cleared their own submission stamp';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('only HR reopens a submitted review',
    v_said like '%Only HR reopens%');

  perform pg_temp.sign_in_as(pg_temp.test_user());
  begin
    perform public.reopen_appraisal(v_ap, 'everything');
    raise exception 'FAIL: an appraisal was reopened at nothing in particular';
  exception when sqlstate '22023' then null;
  end;

  -- Reopening is recognised from the change: a submission cleared and
  -- not a word touched. Clearing it while rewriting the words in the
  -- same statement is HR writing somebody's self review for them with
  -- an extra column set, and is refused as exactly that.
  begin
    update public.appraisals
       set self_submitted_at = null,
           self_comments = 'What they meant to say'
     where id = v_ap;
    raise exception 'FAIL: HR rewrote a self review while reopening it';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('reopening is not a licence to rewrite',
    v_said like '%person being appraised writes their own%');

  perform public.reopen_appraisal(v_ap, 'self');
  select * into v_row from public.appraisals where id = v_ap;
  perform pg_temp.check_true('reopening clears the stamp',
    v_row.self_submitted_at is null);
  perform pg_temp.check_true('and leaves what was written',
    v_row.self_comments like 'Shipped it in May%');
  perform pg_temp.check_eq('and puts it back to the self review',
    v_row.status::text, 'self_review');

  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));
  perform public.submit_self_appraisal(v_ap, 5,
    'On reflection, the mentoring was reassigned.');
  perform pg_temp.check_eq('and the author writes it again',
    (select self_rating from public.appraisals where id = v_ap), 5);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The deadline the manager's half waits on
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Tarikh Akhir Sdn Bhd');
  v_mei   uuid;
  v_ali   uuid;
  v_cycle uuid;
  v_ap    uuid;
  v_said  text;
  r       record;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_mei := pg_temp.ap_person(v_org, 'E1', 'Mei', 'mei3@ap.test');
  v_ali := pg_temp.ap_person(v_org, 'E2', 'Ali', 'ali3@ap.test', v_mei);

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end,
     self_review_due, manager_review_due, rating_scale_max)
  values (v_org, 'FY2026', date '2026-01-01', date '2026-12-31',
          v_today + 7, v_today + 21, 5)
  returning id into v_cycle;
  perform public.open_appraisal_cycle(v_cycle);
  select id into v_ap from public.appraisals
   where cycle_id = v_cycle and employee_id = v_ali;

  perform pg_temp.sign_in_as(pg_temp.ap_user(v_mei));
  begin
    perform public.submit_manager_appraisal(v_ap, 3, 'Fine');
    raise exception 'FAIL: the manager answered a self review nobody wrote';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('the employee goes first',
    v_said like '%not written their self review%');
  perform pg_temp.check_true('and is told when theirs is due',
    v_said like '%not due until%');

  -- The day passes. The cycle moves on without the half nobody wrote.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  update public.appraisal_cycles
     set self_review_due = v_today - 3 where id = v_cycle;

  -- Which is what the report is for, in the meantime.
  select * into r from public.report_appraisals_due(v_org);
  perform pg_temp.check_eq('the report names who is waited on',
    r.employee_name, 'Ali');
  perform pg_temp.check_eq('and which half', r.waiting_on, 'self review');
  perform pg_temp.check_eq('and by how long', r.days_late, 3);
  perform pg_temp.check_eq('and who is waiting', r.reviewer_name, 'Mei');
  perform pg_temp.check_eq('nothing is late as at the day it was due',
    (select count(*) from public.report_appraisals_due(v_org, v_today - 3)), 0);

  perform pg_temp.sign_in_as(pg_temp.ap_user(v_mei));
  perform public.submit_manager_appraisal(v_ap, 3,
    'No self review was given; rated on the goals as recorded.');
  perform pg_temp.check_eq('and afterwards the cycle has moved on',
    (select status::text from public.appraisals where id = v_ap),
    'calibration');

  -- With the manager's half in, the self review that never came is no
  -- longer anybody's outstanding question. Mei's own appraisal, which
  -- nobody has touched, still is.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('an appraisal the manager has answered drops '
    'out of the chase',
    (select count(*) from public.report_appraisals_due(v_org, v_today + 30)
      where employee_name = 'Ali'), 0);
  perform pg_temp.check_eq('and the one nobody has touched does not',
    (select count(*) from public.report_appraisals_due(v_org, v_today + 30)
      where employee_name = 'Mei'), 1);

  -- The chase list is HR's. It names everybody in the company and what
  -- they have not done, which is not a thing an employee reads about
  -- their colleagues.
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));
  perform pg_temp.check_eq('the chase list is closed to the people on it',
    (select count(*) from public.report_appraisals_due(v_org, v_today + 30)),
    0);
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- HR cannot write either half, however senior.
  begin
    update public.appraisals set self_comments = 'They meant to say'
     where id = v_ap;
    raise exception 'FAIL: HR wrote somebody''s self review for them';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set manager_rating = 5 where id = v_ap;
    raise exception 'FAIL: HR wrote the manager''s half';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('HR names a reviewer rather than being one',
    v_said like '%named reviewer%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who the reviewer is when nobody is named
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Garis Lapor Sdn Bhd');
  v_siti  uuid;
  v_mei   uuid;
  v_ali   uuid;
  v_cycle uuid;
  v_ap    uuid;
  v_said  text;
begin
  v_siti := pg_temp.ap_person(v_org, 'E0', 'Siti', 'siti4@ap.test');
  v_mei  := pg_temp.ap_person(v_org, 'E1', 'Mei', 'mei4@ap.test', v_siti);
  v_ali  := pg_temp.ap_person(v_org, 'E2', 'Ali', 'ali4@ap.test', v_mei);

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end, self_review_due,
     rating_scale_max)
  values (v_org, 'FY2026', date '2026-01-01', date '2026-12-31',
          (now() at time zone 'Asia/Kuala_Lumpur')::date - 1, 5)
  returning id into v_cycle;
  perform public.open_appraisal_cycle(v_cycle);
  select id into v_ap from public.appraisals
   where cycle_id = v_cycle and employee_id = v_ali;

  -- Siti manages Ali, two levels up. Mei is named on the appraisal, so
  -- the manager review is hers and not her boss's: two people who both
  -- count as the reviewer is two manager reviews, one overwriting the
  -- other.
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_siti));
  begin
    perform public.submit_manager_appraisal(v_ap, 3, 'Seems fine to me');
    raise exception 'FAIL: a skip-level wrote a named reviewer''s half';
  exception when sqlstate '42501' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a named reviewer is the reviewer',
    v_said like '%named reviewer%');

  -- With nobody named — a cycle opened before the reporting line was
  -- set, or a reviewer cleared — the line stands in, or the half is one
  -- nobody on earth could write.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  update public.appraisals set reviewer_id = null where id = v_ap;

  -- Nothing to settle yet: a final rating over one half of a
  -- conversation is just the other half again.
  begin
    perform public.finalise_appraisal(v_ap, 3);
    raise exception 'FAIL: an appraisal was settled before the manager '
      'had written anything';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a final rating needs a manager review under it',
    v_said like '%not written their half%');

  perform pg_temp.sign_in_as(pg_temp.ap_user(v_mei));
  perform public.submit_manager_appraisal(v_ap, 3,
    'Rated on the goals; no self review was given.');
  perform pg_temp.check_eq('and where none is named the line stands in',
    (select manager_rating from public.appraisals where id = v_ap), 3);

  -- No goals at all. Some cycles are an overall rating and a
  -- conversation, and a hundred per cent of nothing is not a shortfall.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('this appraisal has no goals',
    (select count(*) from public.appraisal_goals where appraisal_id = v_ap), 0);
  perform public.finalise_appraisal(v_ap, 3);
  perform pg_temp.check_eq('and settles on the manager''s rating',
    (select final_rating from public.appraisals where id = v_ap), 3);

  -- Ali never wrote his half and the cycle closed over it. Writing it
  -- into the record now would put a self review under a final rating
  -- that was settled without one.
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));
  begin
    perform public.submit_self_appraisal(v_ap, 5, 'Better late than never');
    raise exception 'FAIL: a self review was written into a closed appraisal';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a completed appraisal is the record of a '
    'conversation that has happened',
    v_said like '%record of a conversation%');

  -- And opening a cycle is HR's, not something an employee does.
  begin
    perform public.open_appraisal_cycle(v_cycle);
    raise exception 'FAIL: an employee opened an appraisal cycle';
  exception when sqlstate '42501' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The one person who runs the process
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Pengurus HR Sdn Bhd');
  v_owner uuid := pg_temp.test_user();
  v_hr    uuid;
  v_cycle uuid;
  v_ap    uuid;
begin
  -- The HR manager is an employee too, and gets appraised like anybody.
  insert into public.employees
    (org_id, employee_no, full_name, hire_date, basic_salary,
     date_of_birth, marital_status, residency_status, user_id)
  values (v_org, 'HR1', 'The HR manager', date '2020-01-01', 9000,
          date '1985-01-01', 'single', 'citizen', v_owner)
  returning id into v_hr;

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end, rating_scale_max)
  values (v_org, 'FY2026', date '2026-01-01', date '2026-12-31', 5)
  returning id into v_cycle;
  perform public.open_appraisal_cycle(v_cycle);
  select id into v_ap from public.appraisals where cycle_id = v_cycle;

  -- Being the subject beats being HR. Otherwise the one person who
  -- could write their own manager rating is the person who runs the
  -- process.
  begin
    update public.appraisals set manager_rating = 5 where id = v_ap;
    raise exception 'FAIL: HR rated themselves as their own manager';
  exception when sqlstate '42501' then null;
  end;
  begin
    update public.appraisals set final_rating = 5 where id = v_ap;
    raise exception 'FAIL: HR settled their own final rating';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.finalise_appraisal(v_ap, 5);
    raise exception 'FAIL: HR finalised their own appraisal';
  exception when sqlstate '42501' then null;
  end;

  -- And their self review is theirs to write, like anybody's.
  perform public.submit_self_appraisal(v_ap, 4, 'A steady year.');
  perform pg_temp.check_eq('the person who runs the process is appraised '
    'like anybody', (select self_rating from public.appraisals where id = v_ap),
    4);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What a cycle and an appraisal are
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.test_org('Skala Sdn Bhd');
  v_emp  uuid;
  v_late uuid;
  v_c1   uuid;
  v_c2   uuid;
  v_ap   uuid;
  v_said text;
begin
  v_emp := pg_temp.ap_person(v_org, 'E1', 'Someone', 'someone@ap.test');

  begin
    insert into public.appraisal_cycles
      (org_id, name, period_start, period_end, rating_scale_max)
    values (v_org, 'Nonsense', date '2026-01-01', date '2026-12-31', 0);
    raise exception 'FAIL: a cycle was rated out of nothing';
  exception when sqlstate '23514' then null;
  end;

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end, rating_scale_max)
  values (v_org, 'FY2026', date '2026-01-01', date '2026-12-31', 5)
  returning id into v_c1;
  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end, rating_scale_max)
  values (v_org, 'FY2027', date '2027-01-01', date '2027-12-31', 10)
  returning id into v_c2;

  perform public.open_appraisal_cycle(v_c1);
  select id into v_ap from public.appraisals where cycle_id = v_c1;

  -- An appraisal opened with a half already in it would be a half
  -- nobody said.
  -- Somebody the cycle did not cover, so this is an insert and not a
  -- collision with the row `open_appraisal_cycle` already made.
  v_late := pg_temp.ap_person(v_org, 'E2', 'Joined late', 'late@ap.test');
  begin
    insert into public.appraisals
      (org_id, cycle_id, employee_id, self_rating, self_comments)
    values (v_org, v_c1, v_late, 5, 'Excellent');
    raise exception 'FAIL: an appraisal was created with a half filled in';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('an appraisal is opened empty',
    v_said like '%opened empty%');

  begin
    update public.appraisals set cycle_id = v_c2 where id = v_ap;
    raise exception 'FAIL: an appraisal was moved to another cycle';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and belongs to one person in one cycle',
    v_said like '%one person in one cycle%');

  -- The scale is the cycle's own, which is the point of the column: the
  -- same 7 is nonsense in one and ordinary in the other, and until now
  -- both stored perfectly.
  perform public.open_appraisal_cycle(v_c2);
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_emp));
  begin
    perform public.submit_self_appraisal(v_ap, 7, 'A seven.');
    raise exception 'FAIL: a 7 was accepted in a cycle rated out of five';
  exception when sqlstate '23514' then null;
  end;
  perform public.submit_self_appraisal(
    (select id from public.appraisals
      where cycle_id = v_c2 and employee_id = v_emp), 7, 'A seven.');
  perform pg_temp.check_eq('the same 7 is a rating in a cycle rated out '
    'of ten',
    (select self_rating from public.appraisals
      where cycle_id = v_c2 and employee_id = v_emp), 7);
  perform pg_temp.sign_in_as(pg_temp.test_user());

  begin
    perform public.open_appraisal_cycle(gen_random_uuid());
    raise exception 'FAIL: a cycle that does not exist was opened';
  exception when sqlstate 'P0002' then null;
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The answer the screen gets
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.test_org('Skrin Sdn Bhd');
  v_mei   uuid;
  v_ali   uuid;
  v_cycle uuid;
  v_ap    uuid;
begin
  v_mei := pg_temp.ap_person(v_org, 'E1', 'Mei', 'mei5@ap.test');
  v_ali := pg_temp.ap_person(v_org, 'E2', 'Ali', 'ali5@ap.test', v_mei);

  insert into public.appraisal_cycles
    (org_id, name, period_start, period_end, rating_scale_max)
  values (v_org, 'FY2026', date '2026-01-01', date '2026-12-31', 5)
  returning id into v_cycle;
  perform public.open_appraisal_cycle(v_cycle);
  select id into v_ap from public.appraisals
   where cycle_id = v_cycle and employee_id = v_ali;

  -- The screen asks the database whose half is whose rather than
  -- working the rule out again, so this is the same answer the trigger
  -- judges changes by.
  perform pg_temp.sign_in_as(pg_temp.ap_user(v_ali));
  perform pg_temp.check_eq('the subject is told they are the subject',
    (select my_part from public.my_appraisal_parts(v_org)
      where appraisal_id = v_ap), 'subject');
  perform pg_temp.check_eq('and sees only their own',
    (select count(*) from public.my_appraisal_parts(v_org)), 1);

  perform pg_temp.sign_in_as(pg_temp.ap_user(v_mei));
  perform pg_temp.check_eq('the reviewer is told they are the reviewer',
    (select my_part from public.my_appraisal_parts(v_org)
      where appraisal_id = v_ap), 'reviewer');
  perform pg_temp.check_eq('and sees their own as the subject of it',
    (select my_part from public.my_appraisal_parts(v_org)
      where appraisal_id <> v_ap), 'subject');

  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.check_eq('HR is told they are HR, on both',
    (select count(*) from public.my_appraisal_parts(v_org)
      where my_part = 'hr'), 2);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('opening a cycle is closed to anon',
    not has_function_privilege('anon',
      'public.open_appraisal_cycle(uuid)', 'execute'));
  perform pg_temp.check_true('and submitting a self review',
    not has_function_privilege('anon',
      'public.submit_self_appraisal(uuid, numeric, text)', 'execute'));
  perform pg_temp.check_true('and a manager review',
    not has_function_privilege('anon',
      'public.submit_manager_appraisal(uuid, numeric, text, numeric, '
      'numeric, boolean, text)', 'execute'));
  perform pg_temp.check_true('and finalising one',
    not has_function_privilege('anon',
      'public.finalise_appraisal(uuid, numeric, text)', 'execute'));
  perform pg_temp.check_true('and reopening one',
    not has_function_privilege('anon',
      'public.reopen_appraisal(uuid, text)', 'execute'));
  perform pg_temp.check_true('and the report of who is late',
    not has_function_privilege('anon',
      'public.report_appraisals_due(uuid, date)', 'execute'));
  perform pg_temp.check_true('and being told whose half is whose',
    not has_function_privilege('anon',
      'public.my_appraisal_parts(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may submit theirs',
    has_function_privilege('authenticated',
      'public.submit_self_appraisal(uuid, numeric, text)', 'execute'));
end $$;

rollback;
