-- =====================================================================
-- iAkauntan :: 0379 the appraisal you could write for yourself
--
-- `appraisals` has carried both halves of a performance review since
-- `0036`: `self_rating` and `self_comments` against
-- `manager_rating` and `manager_comments`, each with its own
-- `*_submitted_at`, then `final_rating` and `calibration_note` over the
-- top, and what the whole thing was for underneath —
-- `recommended_increment_percent`, `recommended_bonus`,
-- `promotion_recommended`, `development_plan`.
--
-- Nine of those columns have never been written by anything. The talent
-- screen lists appraisals and opens their goals; nothing creates one,
-- nothing submits one, and nothing has ever read
-- `appraisal_cycles.rating_scale_max`, `self_review_due` or
-- `manager_review_due`. `app.appraisal_status` has six values and the
-- rows only ever hold the default.
--
-- ---------------------------------------------------------------------
-- The falsehood underneath the absence
--
-- The missing screens are an ordinary seventh-sweep absence. What is
-- underneath them is not. `0038` says:
--
--     -- Appraisals: mine, my reports', or all of them if HR.
--     create policy appraisals_update on public.appraisals
--       for update to authenticated
--       using (app.can_manage_hr(org_id)
--              or employee_id = app.my_employee_id(org_id)
--              or reviewer_id = app.my_employee_id(org_id))
--
-- A row policy grants the row. It has no opinion about columns, and
-- there is no column-level grant behind it. So the person being
-- appraised may — through the ordinary PostgREST endpoint, today —
-- set their own `manager_rating`, write their own `manager_comments`,
-- stamp `manager_submitted_at`, set `final_rating` to the top of the
-- scale, set `promotion_recommended` to true, put a number in
-- `recommended_bonus`, and mark the row `completed`.
--
-- That is the shape `0371` is the note on. An unreachable feature is an
-- absence and announces itself. This is a **falsehood**: a document
-- whose entire purpose is that two people said two things separately,
-- and either of them could have written both. Every appraisal in the
-- system is evidence of nothing, and looks exactly like evidence.
--
-- ---------------------------------------------------------------------
-- Whose half is whose
--
-- The rule cannot be written as a policy, because policies judge rows.
-- It is written as a trigger that judges the **change**: which columns
-- moved, and whether the person moving them owns that half.
--
--   subject   self_rating, self_comments, self_submitted_at
--   reviewer  manager_rating, manager_comments, manager_submitted_at,
--             recommended_increment_percent, recommended_bonus,
--             promotion_recommended, development_plan
--   HR        final_rating, calibration_note, completed_at,
--             reviewer_id, and the status moves nobody else may make
--
-- Being the subject wins over every other part somebody holds. An HR
-- manager is HR on everybody's appraisal except their own, where they
-- are the subject like anyone else — otherwise the one person who could
-- write their own manager rating would be the person who runs the
-- process.
--
-- HR is deliberately *not* given the self half. Correcting a typo in
-- somebody's self-assessment and rewriting it are the same UPDATE, and
-- the column is only worth anything if nobody but its author can touch
-- it. The way through is `reopen_appraisal`, which clears the
-- submission and lets the author write it again, and which leaves a
-- record that it happened.
--
-- The manager half is the reviewer's, not HR's, for the same reason.
-- Where no reviewer can be worked out, HR's job is to name one.
--
-- ---------------------------------------------------------------------
-- The three columns on the cycle
--
-- `rating_scale_max` exists so a 1-5 cycle and a 1-10 cycle can coexist,
-- and until now a 7 in a 1-5 cycle stored perfectly. Every rating on the
-- appraisal and on each goal is now bounded by its own cycle's scale, so
-- the number means the same thing to the person who reads it next year.
--
-- `self_review_due` is not a reminder. It is what stops the manager's
-- half waiting forever on an employee who never writes theirs: before
-- that date the manager is refused, after it they may proceed and the
-- appraisal records that the self review was never given. A deadline
-- that only sends emails is a deadline the process does not have.
--
-- `manager_review_due` is what `report_appraisals_due` measures, which
-- is the question HR actually asks in the last week of a cycle.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What is already there
-- ---------------------------------------------------------------------
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.appraisals;
  if v_n > 0 then
    raise notice
      '0379: % appraisal(s) already exist. Until now either party could '
      'write either half of them, so nothing in them is evidence of who '
      'said it. The rule below applies from here on; it cannot say what '
      'happened before it.', v_n;
  end if;
end $$;

-- A scale of nought is not a scale.
alter table public.appraisal_cycles
  drop constraint if exists appraisal_cycles_scale_ck;
alter table public.appraisal_cycles
  add constraint appraisal_cycles_scale_ck
  check (rating_scale_max >= 1);

-- ---------------------------------------------------------------------
-- Which part of this appraisal the caller holds
-- ---------------------------------------------------------------------

-- Taken from the row's own columns rather than by id, so the trigger can
-- ask about the row it is holding without selecting it back out.
create or replace function app.appraisal_part_of(
  p_org uuid, p_employee uuid, p_reviewer uuid)
returns text
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare v_me uuid := app.my_employee_id(p_org);
begin
  -- Subject first, and unconditionally. Somebody who is both HR and the
  -- person being appraised is the person being appraised.
  if v_me is not null and v_me = p_employee then return 'subject'; end if;
  if v_me is not null and v_me = p_reviewer then return 'reviewer'; end if;
  -- Where nobody is named, the reporting line stands in — a cycle opened
  -- before somebody got a manager would otherwise have a half nobody on
  -- earth could write. Where somebody *is* named, they are the reviewer
  -- and their skip-level is not: two people who both count as the
  -- reviewer is two manager reviews, one of which overwrites the other.
  if p_reviewer is null and app.manages_employee(p_employee) then
    return 'reviewer';
  end if;
  if app.can_manage_hr(p_org) then return 'hr'; end if;
  return null;
end $$;

create or replace function app.appraisal_part(p_appraisal uuid)
returns text
language plpgsql stable security definer
set search_path = public, app, pg_temp
as $$
declare v_a public.appraisals;
begin
  select * into v_a from public.appraisals where id = p_appraisal;
  if v_a.id is null then return null; end if;
  return app.appraisal_part_of(v_a.org_id, v_a.employee_id, v_a.reviewer_id);
end $$;

-- ---------------------------------------------------------------------
-- The guard: which columns moved, and who moved them
-- ---------------------------------------------------------------------
create or replace function app.appraisal_change_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_part  text;
  v_max   integer;
  v_self        boolean;
  v_mgr         boolean;
  v_final       boolean;
  v_self_body   boolean;
  v_mgr_body    boolean;
  v_self_reopen boolean;
  v_mgr_reopen  boolean;
begin
  select rating_scale_max into v_max
    from public.appraisal_cycles where id = new.cycle_id;
  if v_max is null then
    raise exception 'An appraisal belongs to a cycle.' using errcode = '23502';
  end if;

  -- The scale is the cycle's, and it binds every rating on the row.
  -- Nought is not a rating either: it is the value a numeric field
  -- holds when somebody tabbed past it.
  if (new.self_rating is not null
      and (new.self_rating <= 0 or new.self_rating > v_max))
     or (new.manager_rating is not null
         and (new.manager_rating <= 0 or new.manager_rating > v_max))
     or (new.final_rating is not null
         and (new.final_rating <= 0 or new.final_rating > v_max)) then
    raise exception
      'This cycle is rated out of %. A rating outside the scale means '
      'nothing to whoever reads it next year.', v_max
      using errcode = '23514';
  end if;

  if tg_op = 'INSERT' then
    -- An appraisal starts empty. The two halves are written by the two
    -- people, afterwards, each in their own right.
    if new.self_rating is not null or new.self_comments is not null
       or new.self_submitted_at is not null
       or new.manager_rating is not null or new.manager_comments is not null
       or new.manager_submitted_at is not null then
      raise exception
        'An appraisal is opened empty. Neither half can be filled in at '
        'the moment it is created, because at that moment nobody has '
        'said anything yet.' using errcode = '23514';
    end if;
    return new;
  end if;

  if new.cycle_id is distinct from old.cycle_id
     or new.employee_id is distinct from old.employee_id then
    raise exception
      'An appraisal is one person in one cycle. Moving it to another is '
      'not an edit; open the one you meant.' using errcode = '23514';
  end if;

  v_self_body := new.self_rating is distinct from old.self_rating
              or new.self_comments is distinct from old.self_comments;
  v_mgr_body  := new.manager_rating is distinct from old.manager_rating
              or new.manager_comments is distinct from old.manager_comments
              or new.recommended_increment_percent
                   is distinct from old.recommended_increment_percent
              or new.recommended_bonus is distinct from old.recommended_bonus
              or new.promotion_recommended
                   is distinct from old.promotion_recommended
              or new.development_plan is distinct from old.development_plan;

  -- Taking the stamp off is HR reopening the half, not HR writing in it,
  -- and it is the only thing HR may do to either half. It is recognised
  -- from the change itself — a submission cleared and not a word touched
  -- — rather than from a flag the caller sets, so a direct UPDATE that
  -- looks like a reopen is a reopen and one that does not, is not.
  v_self_reopen := old.self_submitted_at is not null
               and new.self_submitted_at is null
               and not v_self_body;
  v_mgr_reopen  := old.manager_submitted_at is not null
               and new.manager_submitted_at is null
               and not v_mgr_body;

  v_self := v_self_body
         or new.self_submitted_at is distinct from old.self_submitted_at;
  v_mgr  := v_mgr_body
         or new.manager_submitted_at is distinct from old.manager_submitted_at;
  v_final := new.final_rating is distinct from old.final_rating
          or new.calibration_note is distinct from old.calibration_note
          or new.completed_at is distinct from old.completed_at
          or new.reviewer_id is distinct from old.reviewer_id;

  if not (v_self or v_mgr or v_final
          or new.status is distinct from old.status) then
    return new;
  end if;

  v_part := app.appraisal_part_of(new.org_id, new.employee_id,
                                  new.reviewer_id);

  if v_self_reopen or v_mgr_reopen then
    if v_part is distinct from 'hr' then
      raise exception 'Only HR reopens a review that has been submitted.'
        using errcode = '42501';
    end if;
  else
    if v_self and v_part is distinct from 'subject' then
      raise exception
        'Only the person being appraised writes their own self review. '
        'That is the whole of what the column is worth.'
        using errcode = '42501';
    end if;
    if v_mgr and v_part is distinct from 'reviewer' then
      raise exception
        'The manager''s half belongs to the named reviewer, or to '
        'whoever they report to if none is named.'
        using errcode = '42501';
    end if;
  end if;
  if v_final and v_part is distinct from 'hr' then
    raise exception
      'The final rating, the calibration note and who reviews whom are '
      'HR''s.' using errcode = '42501';
  end if;

  -- A submission is a record of what somebody said on a day. Writing
  -- over it afterwards is not editing, it is changing the evidence.
  if v_self and old.self_submitted_at is not null
     and new.self_submitted_at is not distinct from old.self_submitted_at then
    raise exception
      'This self review was submitted on %. Ask HR to reopen it if it '
      'has to change.', to_char(old.self_submitted_at, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  if v_mgr and old.manager_submitted_at is not null
     and new.manager_submitted_at
           is not distinct from old.manager_submitted_at then
    raise exception
      'This manager review was submitted on %. Ask HR to reopen it if it '
      'has to change.', to_char(old.manager_submitted_at, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  if old.completed_at is not null and v_part is distinct from 'hr' then
    raise exception
      'This appraisal was completed on %. It is the record of a '
      'conversation that has happened.',
      to_char(old.completed_at, 'DD Mon YYYY') using errcode = '23514';
  end if;

  -- Status moves with the half that was written, and only forwards.
  -- Anything else is HR's.
  if new.status is distinct from old.status and v_part <> 'hr' then
    if not ((v_part = 'subject' and old.status = 'self_review'
             and new.status = 'manager_review')
         or (v_part = 'reviewer'
             and old.status in ('self_review', 'manager_review')
             and new.status = 'calibration')) then
      raise exception
        'An appraisal moves from % to the next stage when the half that '
        'stage is waiting for is submitted. It is not a field.',
        old.status using errcode = '23514';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists appraisals_change_ck on public.appraisals;
create trigger appraisals_change_ck
  before insert or update on public.appraisals
  for each row execute function app.appraisal_change_guard();

-- ---------------------------------------------------------------------
-- The same rule, one level down
-- ---------------------------------------------------------------------
create or replace function app.appraisal_goal_change_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_a    public.appraisals;
  v_part text;
  v_max  integer;
  v_def  boolean;
  v_self boolean;
  v_mgr  boolean;
begin
  select * into v_a from public.appraisals where id = new.appraisal_id;
  if v_a.id is null then
    raise exception 'No such appraisal.' using errcode = 'P0002';
  end if;
  select rating_scale_max into v_max
    from public.appraisal_cycles where id = v_a.cycle_id;

  if (new.self_rating is not null
      and (new.self_rating <= 0 or new.self_rating > v_max))
     or (new.manager_rating is not null
         and (new.manager_rating <= 0 or new.manager_rating > v_max)) then
    raise exception
      'This cycle is rated out of %. A rating outside the scale means '
      'nothing to whoever reads it next year.', v_max
      using errcode = '23514';
  end if;
  if new.weight_percent < 0 then
    raise exception 'A goal cannot carry less than none of the job.'
      using errcode = '23514';
  end if;

  v_part := app.appraisal_part_of(v_a.org_id, v_a.employee_id,
                                  v_a.reviewer_id);

  if tg_op = 'INSERT' then
    -- What somebody is measured on is set by whoever measures them.
    if v_part not in ('reviewer', 'hr') then
      raise exception
        'Goals are set by the reviewer or by HR. Choosing what you are '
        'measured on and then meeting it is not an appraisal.'
        using errcode = '42501';
    end if;
    return new;
  end if;

  v_def := new.title is distinct from old.title
        or new.description is distinct from old.description
        or new.category is distinct from old.category
        or new.weight_percent is distinct from old.weight_percent
        or new.target is distinct from old.target
        or new.sort_order is distinct from old.sort_order;
  v_self := new.self_rating is distinct from old.self_rating;
  v_mgr  := new.manager_rating is distinct from old.manager_rating
         or new.comments is distinct from old.comments
         or new.actual is distinct from old.actual;

  if v_def and v_part not in ('reviewer', 'hr') then
    raise exception
      'The goal itself — what it is, what it is worth, what the target '
      'was — belongs to whoever set it.' using errcode = '42501';
  end if;
  if v_self and v_part is distinct from 'subject' then
    raise exception
      'Only the person being appraised rates themselves against a goal.'
      using errcode = '42501';
  end if;
  if v_mgr and v_part is distinct from 'reviewer' then
    raise exception
      'The manager''s rating against a goal is the reviewer''s.'
      using errcode = '42501';
  end if;
  if v_self and v_a.self_submitted_at is not null then
    raise exception
      'This self review was submitted on %. Ask HR to reopen it if it '
      'has to change.', to_char(v_a.self_submitted_at, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  if v_mgr and v_a.manager_submitted_at is not null then
    raise exception
      'This manager review was submitted on %. Ask HR to reopen it if it '
      'has to change.', to_char(v_a.manager_submitted_at, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists appraisal_goals_change_ck on public.appraisal_goals;
create trigger appraisal_goals_change_ck
  before insert or update on public.appraisal_goals
  for each row execute function app.appraisal_goal_change_guard();

-- ---------------------------------------------------------------------
-- Opening a cycle
-- ---------------------------------------------------------------------
create or replace function public.open_appraisal_cycle(p_cycle uuid)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_c public.appraisal_cycles;
  v_n integer := 0;
begin
  select * into v_c from public.appraisal_cycles where id = p_cycle;
  if v_c.id is null then
    raise exception 'No such appraisal cycle.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_c.org_id) then
    raise exception 'not permitted to open an appraisal cycle'
      using errcode = '42501';
  end if;
  if v_c.status = 'completed' then
    raise exception '% is closed.', v_c.name using errcode = '23514';
  end if;
  if v_c.period_end < v_c.period_start then
    raise exception 'A cycle ends after it starts.' using errcode = '23514';
  end if;

  -- Everybody employed at the end of the period being reviewed. Someone
  -- who left during it is not appraised; someone hired during it is,
  -- on the part of it they were here for.
  insert into public.appraisals
    (org_id, cycle_id, employee_id, reviewer_id, status)
  select v_c.org_id, v_c.id, e.id, e.manager_id, 'self_review'
    from public.employees e
   where e.org_id = v_c.org_id
     and e.hire_date <= v_c.period_end
     and (e.last_working_date is null
          or e.last_working_date >= v_c.period_end)
     and not exists (select 1 from public.appraisals a
                      where a.cycle_id = v_c.id and a.employee_id = e.id);
  get diagnostics v_n = row_count;

  update public.appraisal_cycles
     set status = case when status = 'draft' then 'self_review'
                       else status end
   where id = p_cycle;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- Saying your half
-- ---------------------------------------------------------------------
create or replace function public.submit_self_appraisal(
  p_appraisal uuid,
  p_rating    numeric,
  p_comments  text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_a public.appraisals;
begin
  select * into v_a from public.appraisals where id = p_appraisal;
  if v_a.id is null then
    raise exception 'No such appraisal.' using errcode = 'P0002';
  end if;
  if app.appraisal_part(p_appraisal) is distinct from 'subject' then
    raise exception 'Only the person being appraised writes their own '
      'self review.' using errcode = '42501';
  end if;
  if v_a.self_submitted_at is not null then
    raise exception
      'You submitted this on %. Ask HR to reopen it if it has to change.',
      to_char(v_a.self_submitted_at, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if p_comments is null or btrim(p_comments) = '' then
    raise exception
      'Say something. A rating with nothing written beside it is a number '
      'your manager has to guess the meaning of.' using errcode = '23514';
  end if;

  update public.appraisals set
    self_rating       = p_rating,
    self_comments     = btrim(p_comments),
    self_submitted_at = now(),
    status            = case when status = 'self_review'
                             then 'manager_review'::app.appraisal_status
                             else status end,
    updated_at        = now()
  where id = p_appraisal;
end $$;

create or replace function public.submit_manager_appraisal(
  p_appraisal        uuid,
  p_rating           numeric,
  p_comments         text,
  p_increment        numeric default null,
  p_bonus            numeric default null,
  p_promotion        boolean default false,
  p_development_plan text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_a   public.appraisals;
  v_due date;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  select * into v_a from public.appraisals where id = p_appraisal;
  if v_a.id is null then
    raise exception 'No such appraisal.' using errcode = 'P0002';
  end if;
  if app.appraisal_part(p_appraisal) is distinct from 'reviewer' then
    raise exception
      'The manager''s half belongs to the named reviewer, or to whoever '
      'they report to if none is named.' using errcode = '42501';
  end if;
  if v_a.manager_submitted_at is not null then
    raise exception
      'You submitted this on %. Ask HR to reopen it if it has to change.',
      to_char(v_a.manager_submitted_at, 'DD Mon YYYY')
      using errcode = '23514';
  end if;
  if p_comments is null or btrim(p_comments) = '' then
    raise exception
      'Say something. A rating with nothing written beside it is what the '
      'person being rated will spend the year trying to interpret.'
      using errcode = '23514';
  end if;

  -- The employee goes first — until the day their half was due. After
  -- that the cycle moves on without it, because a review nobody wrote
  -- cannot be allowed to stop the one somebody did.
  if v_a.self_submitted_at is null then
    select self_review_due into v_due
      from public.appraisal_cycles where id = v_a.cycle_id;
    if v_due is null or v_due >= v_today then
      raise exception
        'They have not written their self review yet%. Yours is the '
        'answer to theirs.',
        case when v_due is null then ''
             else format(', and it is not due until %s',
                         to_char(v_due, 'DD Mon YYYY')) end
        using errcode = '23514';
    end if;
  end if;

  update public.appraisals set
    manager_rating                = p_rating,
    manager_comments              = btrim(p_comments),
    manager_submitted_at          = now(),
    recommended_increment_percent = p_increment,
    recommended_bonus             = p_bonus,
    promotion_recommended         = coalesce(p_promotion, false),
    development_plan              = nullif(btrim(coalesce(
                                      p_development_plan, '')), ''),
    -- From `self_review` as well: where the employee let their own
    -- deadline pass, the stage waiting on them is over too.
    status                        = case
                                      when status in ('self_review',
                                                      'manager_review')
                                      then 'calibration'::app.appraisal_status
                                      else status end,
    updated_at                    = now()
  where id = p_appraisal;
end $$;

-- ---------------------------------------------------------------------
-- Settling it
-- ---------------------------------------------------------------------
create or replace function public.finalise_appraisal(
  p_appraisal        uuid,
  p_final_rating     numeric,
  p_calibration_note text default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_a      public.appraisals;
  v_weight numeric;
  v_goals  integer;
begin
  select * into v_a from public.appraisals where id = p_appraisal;
  if v_a.id is null then
    raise exception 'No such appraisal.' using errcode = 'P0002';
  end if;
  if app.appraisal_part(p_appraisal) is distinct from 'hr' then
    raise exception 'not permitted to finalise an appraisal'
      using errcode = '42501';
  end if;
  if v_a.completed_at is not null then
    raise exception 'This appraisal was completed on %.',
      to_char(v_a.completed_at, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if v_a.manager_submitted_at is null then
    raise exception
      'The manager has not written their half. A final rating over one '
      'half of a conversation is just the other half again.'
      using errcode = '23514';
  end if;
  if p_final_rating is null then
    raise exception 'A completed appraisal has a final rating.'
      using errcode = '23514';
  end if;

  -- Weights that do not come to a hundred make the overall rating mean
  -- whatever the reader assumes. The dialog has warned about this since
  -- goals were reachable; on the way to completed it is a refusal.
  select count(*), coalesce(sum(weight_percent), 0) into v_goals, v_weight
    from public.appraisal_goals where appraisal_id = p_appraisal;
  if v_goals > 0 and round(v_weight, 2) <> 100 then
    raise exception
      'The goals on this appraisal come to %, not 100. The overall '
      'rating is a weighted judgement about them.', round(v_weight, 2)
      using errcode = '23514';
  end if;

  -- Calibration is the act of departing from what the manager said, so
  -- departing from it without a word is the one thing it cannot be.
  if p_final_rating is distinct from v_a.manager_rating
     and (p_calibration_note is null or btrim(p_calibration_note) = '') then
    raise exception
      'The manager rated this % and you are settling on %. Say why: that '
      'difference is the only thing calibration leaves behind.',
      coalesce(v_a.manager_rating::text, 'nothing'),
      round(p_final_rating, 2)::text
      using errcode = '23514';
  end if;

  update public.appraisals set
    final_rating     = p_final_rating,
    calibration_note = nullif(btrim(coalesce(p_calibration_note, '')), ''),
    completed_at     = now(),
    status           = 'completed',
    updated_at       = now()
  where id = p_appraisal;
end $$;

-- ---------------------------------------------------------------------
-- The way back
-- ---------------------------------------------------------------------
create or replace function public.reopen_appraisal(
  p_appraisal uuid,
  p_side      text)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_a public.appraisals;
begin
  select * into v_a from public.appraisals where id = p_appraisal;
  if v_a.id is null then
    raise exception 'No such appraisal.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_a.org_id) then
    raise exception 'not permitted to reopen an appraisal'
      using errcode = '42501';
  end if;
  if p_side not in ('self', 'manager', 'final') then
    raise exception
      'Reopen the self review, the manager review or the final rating; '
      'got %.', p_side using errcode = '22023';
  end if;

  -- Clearing the stamp is what makes the half writable again: the guard
  -- refuses a change to a half that carries one. Nothing that was
  -- written is erased, so the author edits their own words rather than
  -- starting from a blank box.
  if p_side = 'self' then
    update public.appraisals set
      self_submitted_at = null,
      completed_at      = null,
      status            = 'self_review',
      updated_at        = now()
    where id = p_appraisal;
  elsif p_side = 'manager' then
    update public.appraisals set
      manager_submitted_at = null,
      completed_at         = null,
      status               = 'manager_review',
      updated_at           = now()
    where id = p_appraisal;
  else
    update public.appraisals set
      completed_at = null,
      status       = 'calibration',
      updated_at   = now()
    where id = p_appraisal;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Who has not written theirs
-- ---------------------------------------------------------------------
create or replace function public.report_appraisals_due(
  p_org   uuid,
  p_as_at date default null)
returns table (
  appraisal_id  uuid,
  cycle_name    text,
  employee_name text,
  reviewer_name text,
  waiting_on    text,
  due_on        date,
  days_late     integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with asof as (
    select coalesce(p_as_at,
             (now() at time zone 'Asia/Kuala_Lumpur')::date) as d
  )
  select a.id,
         c.name,
         e.full_name,
         r.full_name,
         w.side,
         w.due,
         (select d from asof)::date - w.due
    from public.appraisals a
    join public.appraisal_cycles c on c.id = a.cycle_id
    join public.employees e on e.id = a.employee_id
    left join public.employees r on r.id = a.reviewer_id
   cross join lateral (
     -- One half is outstanding at a time. The self review stops being
     -- the thing anybody is waiting for the moment the manager's is in
     -- — where the employee let their own deadline pass, the cycle has
     -- moved on and chasing them for it is chasing a closed question.
     select case
              when a.manager_submitted_at is not null then null
              when a.self_submitted_at is null then 'self review'
              else 'manager review' end as side,
            case
              when a.self_submitted_at is null then c.self_review_due
              else c.manager_review_due end as due
   ) w
   where a.org_id = p_org
     and app.can_manage_hr(p_org)
     and a.completed_at is null
     and a.status not in ('cancelled', 'completed')
     and w.side is not null
     and w.due is not null
     and w.due < (select d from asof)
   order by w.due, e.full_name;
$$;

-- ---------------------------------------------------------------------
-- The same answer, for the screen
-- ---------------------------------------------------------------------

-- A screen that offers an action the database will refuse teaches people
-- that the software is broken, so it has to know whose half is whose.
-- The tempting way to give it that is to work the rule out again in
-- Dart, and two implementations of one permission rule are how they come
-- to disagree — with the copy that is wrong being the one a person
-- actually reads.
--
-- So the screen asks. One row per appraisal the caller can see, with the
-- part they hold on it, from the same function the trigger uses.
create or replace function public.my_appraisal_parts(p_org uuid)
returns table (appraisal_id uuid, my_part text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select a.id,
         app.appraisal_part_of(a.org_id, a.employee_id, a.reviewer_id)
    from public.appraisals a
   where a.org_id = p_org
     and (app.can_manage_hr(p_org)
          or a.employee_id = app.my_employee_id(p_org)
          or a.reviewer_id = app.my_employee_id(p_org)
          or app.manages_employee(a.employee_id));
$$;

-- ---------------------------------------------------------------------
revoke all on function public.my_appraisal_parts(uuid) from public, anon;
grant execute on function public.my_appraisal_parts(uuid) to authenticated;
comment on function public.my_appraisal_parts(uuid) is
  'Which part the caller holds on each appraisal they can see, from the '
  'same app.appraisal_part_of the trigger judges changes with. The '
  'screen asks rather than working the rule out a second time: two '
  'implementations of one permission rule disagree eventually, and the '
  'one that is wrong is the one somebody reads.';

revoke all on function public.open_appraisal_cycle(uuid) from public, anon;
revoke all on function
  public.submit_self_appraisal(uuid, numeric, text) from public, anon;
revoke all on function public.submit_manager_appraisal(
  uuid, numeric, text, numeric, numeric, boolean, text) from public, anon;
revoke all on function
  public.finalise_appraisal(uuid, numeric, text) from public, anon;
revoke all on function public.reopen_appraisal(uuid, text) from public, anon;
revoke all on function
  public.report_appraisals_due(uuid, date) from public, anon;

grant execute on function public.open_appraisal_cycle(uuid) to authenticated;
grant execute on function
  public.submit_self_appraisal(uuid, numeric, text) to authenticated;
grant execute on function public.submit_manager_appraisal(
  uuid, numeric, text, numeric, numeric, boolean, text) to authenticated;
grant execute on function
  public.finalise_appraisal(uuid, numeric, text) to authenticated;
grant execute on function public.reopen_appraisal(uuid, text) to authenticated;
grant execute on function
  public.report_appraisals_due(uuid, date) to authenticated;

comment on function app.appraisal_change_guard() is
  'Judges the change to an appraisal rather than the row. `0038` grants '
  'the subject UPDATE on their own row, and a row policy has no opinion '
  'about columns — so until this trigger, the person being appraised '
  'could write their own manager rating, their own final rating and '
  'their own promotion recommendation.';
comment on function public.submit_manager_appraisal(
  uuid, numeric, text, numeric, numeric, boolean, text) is
  'The reviewer''s half. Refused until the employee has submitted '
  'theirs, or until the cycle''s self_review_due has passed — a review '
  'nobody wrote cannot stop the one somebody did.';
comment on function public.report_appraisals_due(uuid, date) is
  'Who is late, and on which half. Reads appraisal_cycles.self_review_due '
  'and manager_review_due, which were columns nothing had ever looked at.';
