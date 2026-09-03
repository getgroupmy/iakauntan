-- =====================================================================
-- 0503  The button and the scheduler advance a schedule the same way
--
-- `app.advance_schedule` takes an anchor -- the day of the month the
-- schedule is really on -- and `0447` added it for one reason: without
-- it, a monthly standing journal dated the 31st lands on the 28th in
-- February and stays on the 28th for ever, because each run advances
-- from the last one rather than from the day the schedule was set on.
-- With the anchor it recovers to the 31st in March.
--
-- `app.run_recurring_journals`, the nightly job, passes
-- `r.start_date`. `public.run_recurring_journals_for`, the same body
-- for one company and the one a person reaches from the app, does not.
-- So the same standing journal drifts or does not drift depending on
-- which of the two ran the month -- and they write to the same
-- `next_run_date`, so a company that presses the button once in
-- February has a rent journal on the 28th for the rest of its life.
--
-- Measured rather than reasoned about:
--
--   advance_schedule('2026-02-28', 'monthly', 1)                → 2026-03-28
--   advance_schedule('2026-02-28', 'monthly', 1, '2026-01-31')  → 2026-03-31
--
-- Three functions call `advance_schedule`; the other two already pass
-- the anchor. This is the odd one out, and nothing else changes.
-- =====================================================================

create or replace function public.run_recurring_journals_for(
  p_org_id uuid,
  p_on     date default current_date)
returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r public.recurring_journals;
  v_n integer := 0;
begin
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;

  -- Deliberately not `app.run_recurring_journals`: that one walks every
  -- organization in the database, and a signed-in user may only post in
  -- their own. Same body, one org.
  for r in
    select * from public.recurring_journals
     where org_id = p_org_id and is_active
       and next_run_date is not null and next_run_date <= p_on
       and (end_date is null or next_run_date <= end_date)
  loop
    begin
      if r.auto_post then
        perform app.create_gl_entry_internal(
          p_org_id       => r.org_id,
          p_entry_date   => r.next_run_date,
          p_source       => 'recurring'::app.journal_source,
          p_lines        => r.template -> 'lines',
          p_description  => coalesce(r.description, r.name),
          p_source_table => 'recurring_journals',
          p_source_id    => r.id,
          p_reference    => r.name);
      end if;

      update public.recurring_journals
         set last_run_date = r.next_run_date,
             next_run_date = app.advance_schedule(
               r.next_run_date, r.frequency, r.interval_count, r.start_date),
             last_error = null, last_error_at = null
       where id = r.id;
      v_n := v_n + 1;
    exception when others then
      update public.recurring_journals
         set last_error = sqlerrm, last_error_at = now()
       where id = r.id;
    end;
  end loop;

  return v_n;
end;
$$;
