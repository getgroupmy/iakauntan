-- =====================================================================
-- iAkauntan :: 0783 a closed job takes no billable time
--
-- `0778` stopped a project being closed, by any road, while billable
-- time on it is uninvoiced. The other door was still open: time could
-- ARRIVE on a project already closed. `time_entries_write` asks
-- `can_write` and the time module, and nothing asked about the
-- project's state. Measured on 9 October 2026, locally, as a member who
-- may write but not post: RM500 of billable time logged onto a closed
-- project was accepted -- and was then invisible, because a closed
-- project leaves the open list and its unbilled time goes with it. The
-- state `0778` exists to prevent, reached the other way. The app's
-- timesheet offers only open projects; this was the API's road.
--
-- Answered "refuse; reopen first". Any change that raises the billable,
-- uninvoiced time on a closed project is refused, naming the project
-- and saying what to do -- a new entry, one moved onto it, one made
-- billable again, one un-billed, an amount raised. Non-billable time
-- stays allowed on a closed project (the utilisation report counts
-- hours people worked), and so does anything that lowers the figure:
-- an invoice marking time billed, `close_project`'s write-off, a
-- deletion.
--
-- Asked of the ROW, as `0776` is, so a function written later cannot
-- forget it -- and of entries as well as money, because `close_project`
-- counts entries: a billable hour at no rate yet is still one somebody
-- should bill. It fires after the triggers that price an entry (they
-- sort first by name), so the amount it compares is the real one.
-- SECURITY DEFINER so the project's state is read as it is.
--
-- Production held no closed project on 9 October.
-- =====================================================================

create or replace function app.closed_project_takes_no_billable_time()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_code text;
begin
  -- Only a row that IS billable time still to invoice, on a project,
  -- can add to it.
  if new.project_id is null or not new.is_billable or new.is_billed then
    return new;
  end if;

  -- The same entry, on the same project, already counted there, not
  -- raised: it adds nothing. `close_project` counts entries as well as
  -- money, so a new one adds even at no rate.
  if tg_op = 'UPDATE'
     and old.project_id is not distinct from new.project_id
     and old.is_billable and not old.is_billed
     and coalesce(new.amount, 0) <= coalesce(old.amount, 0) then
    return new;
  end if;

  select p.code into v_code
    from public.projects p
   where p.id = new.project_id and not p.is_active;

  if v_code is not null then
    raise exception
      'Project % is closed. Reopen it before logging billable time to it.',
      v_code using errcode = '23514';
  end if;

  return new;
end $$;

revoke all on function app.closed_project_takes_no_billable_time() from public, anon, authenticated;

comment on function app.closed_project_takes_no_billable_time() is
  'Refuses any change to the time entries that would raise the billable, '
  'uninvoiced time on a closed project -- an entry logged, moved onto '
  'it, made billable or un-billed again, or an amount raised. '
  'Non-billable time, and anything that lowers the figure, is allowed. '
  'The other half of 0778. 0783.';

create trigger time_not_onto_a_closed_project
  before insert or update on public.time_entries
  for each row execute function app.closed_project_takes_no_billable_time();
