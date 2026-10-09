-- =====================================================================
-- iAkauntan :: 0778 a project closes, by any road, only when billed
--
-- `close_project` (`0389`) refuses to close a project while billable
-- time on it is still to be invoiced, naming the amount and the number
-- of entries, unless it is told to write that time off -- which marks
-- the entries non-billable, so the decision to forgo the fee is
-- recorded rather than implied. Hours left on a closed job are hours
-- nobody is looking at: the project drops out of the open list, the
-- unbilled-time column with it, and the fee is lost without anybody
-- having decided to lose it.
--
-- The refusal lived in the function and nowhere else. The table's own
-- policies (`projects_update` and `projects_write`: `can_write`) let any
-- member who can write set `is_active` to false directly, and nothing
-- on the table looked at the time. Measured on 9 October 2026, locally:
-- signed in as a member who may write but not post, one UPDATE closed a
-- project holding RM3,000 of unbilled time -- a member `close_project`
-- itself would have refused twice, once for the time and once for not
-- being allowed to write it off. The app's own screen goes through
-- `close_project`; this was the API's road.
--
-- Answered "guard the table". A trigger now asks the same question of
-- every change that takes a project from open to closed, whichever road
-- it came by, in `close_project`'s own words. `close_project` keeps its
-- own check, which runs first and says the same thing, and its write-off
-- still works: it marks the time non-billable BEFORE it closes the
-- project, so by the time this asks there is nothing left to ask about.
-- Reopening is never refused here, and neither is any other edit of a
-- closed project.
--
-- SECURITY DEFINER so the count is the true count, whatever a caller's
-- row-level security on `time_entries` lets them see now or later.
--
-- Production held five projects on 9 October, all open, all of them the
-- demo companies' -- whose rebuild only ever inserts open projects --
-- so nothing that exists or is rebuilt daily is refused by this.
-- =====================================================================

create or replace function app.project_closes_only_when_billed()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_time numeric(18, 2);
  v_n    integer;
begin
  -- Only open to closed is asked about.
  if new.is_active or not old.is_active then
    return new;
  end if;

  -- The same rows `close_project` and `report_project_budget` read.
  select coalesce(sum(t.amount), 0), count(*)
    into v_time, v_n
    from public.time_entries t
   where t.project_id = new.id
     and t.is_billable
     and not t.is_billed;

  if v_n > 0 then
    raise exception
      'This project still has % of billable time nobody has invoiced, '
      'across % entries. Bill it, or close the project writing the time '
      'off, which says the decision was taken. Hours left on a closed '
      'job are hours nobody is looking at.',
      to_char(round(v_time, 2), 'FM999G999G990D00'), v_n
      using errcode = '23514';
  end if;

  return new;
end $$;

revoke all on function app.project_closes_only_when_billed() from public, anon, authenticated;

comment on function app.project_closes_only_when_billed() is
  'Refuses to take a project from open to closed while billable time on '
  'it is still to be invoiced -- `close_project`''s rule, on every road '
  'into the table rather than on one function. `close_project` with a '
  'write-off marks the time non-billable first, so it still closes. '
  'Reads the time entries as its owner, so the caller''s row-level '
  'security cannot hide them. 0778.';

create trigger projects_close_only_when_billed
  before update of is_active on public.projects
  for each row execute function app.project_closes_only_when_billed();
