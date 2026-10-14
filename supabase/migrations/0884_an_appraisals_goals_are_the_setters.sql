-- =====================================================================
-- iAkauntan :: 0884 an appraisal's goals are the setter's, and kept
--
-- `0379` gave appraisal goals a guard: what somebody is measured on is
-- set and redefined by the reviewer or by HR, never by the person
-- measured ("Choosing what you are measured on and then meeting it is
-- not an appraisal"). The trigger fires before INSERT and UPDATE, and
-- `appraisal_goals_all` admits the person appraised to every command,
-- DELETE included. The appraisal row refuses everybody but HR once it
-- is completed; its goals had no such rule.
--
-- Measured on 14 October 2026, locally, with the role `authenticated`:
-- the person appraised deleted a goal their reviewer had set, mid
-- cycle. After HR had finalised the appraisal, the reviewer re-weighted
-- a goal, changed its target, added one and deleted one, and the person
-- appraised deleted another -- each of them accepted.
--
-- Production held no appraisal cycle, appraisal or goal on 14 October.
--
-- Answered "the setter's goals, kept once complete":
--
--   * a goal is deleted by the reviewer or by HR, who set it, and by
--     nobody else -- a new BEFORE DELETE trigger, which asks a client's
--     own statement only, so that deleting a company, a cycle or an
--     appraisal still takes its goals with it;
--   * once the appraisal is completed, its goals are added to, changed
--     and deleted by HR alone, as the appraisal row is. HR reopening it
--     (`reopen_appraisal`) clears `completed_at`, and the reviewer may
--     write again.
--
-- The change guard's body is `pg_get_functiondef` of what was applied,
-- with the one block added.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.appraisal_goal_change_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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

  -- 0884: a completed appraisal is the record of a conversation that
  -- has happened, and what it was about is part of that record. HR,
  -- who completed it, may still correct it, as on the appraisal row.
  if v_a.completed_at is not null and v_part is distinct from 'hr' then
    raise exception
      'This appraisal was completed on %. It is the record of a '
      'conversation that has happened, and its goals are part of it.',
      to_char(v_a.completed_at, 'DD Mon YYYY') using errcode = '23514';
  end if;

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
end $function$;

create or replace function app.appraisal_goal_delete_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
declare
  v_a    public.appraisals;
  v_part text;
begin
  -- A client's own DELETE. Deleting the appraisal, its cycle or its
  -- company removes the goals one level down, as a cascade, and is
  -- asked by whatever guards that row.
  if current_user not in ('authenticated', 'anon')
     or pg_trigger_depth() > 1 then
    return old;
  end if;

  select * into v_a from public.appraisals where id = old.appraisal_id;
  if v_a.id is null then
    return old;
  end if;
  v_part := app.appraisal_part_of(v_a.org_id, v_a.employee_id,
                                  v_a.reviewer_id);

  if v_a.completed_at is not null and v_part is distinct from 'hr' then
    raise exception
      'This appraisal was completed on %. It is the record of a '
      'conversation that has happened, and its goals are part of it.',
      to_char(v_a.completed_at, 'DD Mon YYYY') using errcode = '23514';
  end if;
  if v_part is distinct from 'reviewer' and v_part is distinct from 'hr' then
    raise exception
      'Goals are set, and taken off, by the reviewer or by HR. Taking '
      'away what you are measured on is choosing it.'
      using errcode = '42501';
  end if;
  return old;
end $$;

revoke all on function app.appraisal_goal_delete_guard() from public;

drop trigger if exists appraisal_goals_delete_ck on public.appraisal_goals;
create trigger appraisal_goals_delete_ck
  before delete on public.appraisal_goals
  for each row execute function app.appraisal_goal_delete_guard();
