-- =====================================================================
-- iAkauntan :: 0360 the day nobody clocked in
--
-- `app.attendance_status` has seven values and four are reachable.
-- `clock_out` sets `public_holiday`, `rest_day`, `late` or `present`,
-- and that is every write there has ever been. The three it cannot
-- produce are the three about somebody who was *not* at work:
--
--   * `incomplete` — clocked in, never clocked out.
--   * `on_leave`   — away, with an approved leave request saying so.
--   * `absent`     — away, with nothing saying so.
--
-- The first is a falsehood rather than a gap, and the worse of the two
-- shapes. A row whose `clock_out` is null keeps `status = 'present'`
-- with `worked_minutes = 0`, so a register grouped by status — which is
-- what a register is for — counts somebody who forgot to clock out as a
-- normal day's attendance. Nothing on the screen distinguishes them
-- from a person who worked their shift.
--
-- The other two are absences, and their shape is that there is no row
-- at all. "Who was away yesterday" has no answer, because the register
-- only ever holds the days people turned up. That is also why the
-- payroll's unpaid-leave arithmetic reads `leave_requests` directly:
-- attendance could not tell it.
--
-- ---------------------------------------------------------------------
-- Who was expected, which is the only hard part
--
-- Absent means "expected and not there", so it needs the roster.
-- `employee_shifts` maps a person to a `work_shifts` row over a date
-- range, and that shift's `work_days` says which weekdays they work —
-- so `app.shift_for` already answers it and this adds nothing new.
--
-- A person with no shift assigned is not marked absent. Their working
-- pattern is unknown, and inventing one would put a red mark against
-- everybody in a company that has not filled the roster in — the same
-- reasoning `0264` used for `block_out_of_stock` and `0355` for an
-- empty ticket team. A control nobody maintains must not start refusing.
--
-- ---------------------------------------------------------------------
-- Rest days and holidays get no row, deliberately
--
-- The register's convention today is that a missing row means "not
-- expected", and writing `rest_day` for every employee every Sunday
-- would double the table to say what the absence of a row already says.
-- What is added is only the two facts that were missing: away with
-- leave, and away without.
-- =====================================================================

create or replace function app.close_attendance_day(
  p_org uuid, p_on date)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_emp     record;
  v_shift   public.work_shifts;
  v_holiday boolean;
  v_n       integer := 0;
  v_m       integer;
begin
  select exists (
    select 1 from public.public_holidays h
     where h.org_id = p_org and h.holiday_date = p_on and not h.is_working
  ) into v_holiday;

  -- The day somebody clocked into and never out of. Corrected rather
  -- than closed: what time they left is not knowable, and writing one
  -- would put hours on a payslip that nobody worked. The status says
  -- the record is incomplete, which is what an HR manager needs in
  -- order to go and ask.
  update public.attendance_records r
     set status = 'incomplete'
   where r.org_id = p_org
     and r.work_date = p_on
     and r.clock_in is not null
     and r.clock_out is null
     and r.status <> 'incomplete';
  get diagnostics v_n = row_count;

  if v_holiday then
    return v_n;
  end if;

  for v_emp in
    select e.id
      from public.employees e
     where e.org_id = p_org
       and e.employment_status not in ('resigned', 'terminated', 'retired')
       and e.hire_date <= p_on
       and (e.last_working_date is null or e.last_working_date >= p_on)
       and not exists (
         select 1 from public.attendance_records r
          where r.employee_id = e.id and r.work_date = p_on)
  loop
    v_shift := app.shift_for(v_emp.id, p_on);

    -- No roster, no expectation, no mark against them.
    continue when v_shift.id is null;
    -- `dow` rather than ISO, because `work_days` is written in `dow`
    -- everywhere else in this module and two conventions for the same
    -- column is how Sunday becomes Monday.
    continue when not (extract(dow from p_on)::integer = any (v_shift.work_days));

    insert into public.attendance_records
      (org_id, employee_id, work_date, shift_id, status)
    values (
      p_org, v_emp.id, p_on, v_shift.id,
      case when exists (
        select 1 from public.leave_requests lr
         where lr.employee_id = v_emp.id
           and lr.status = 'approved'
           and p_on between lr.start_date and lr.end_date)
      then 'on_leave'::app.attendance_status
      else 'absent'::app.attendance_status end);

    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

revoke all on function app.close_attendance_day(uuid, date)
  from public, anon, authenticated;

comment on function app.close_attendance_day(uuid, date) is
  'Closes a day''s attendance: marks a clock-in with no clock-out as '
  'incomplete, and writes a row for anybody rostered who has none — '
  'on_leave where an approved request explains it, absent where '
  'nothing does. Nobody without a roster is marked.';

-- ---------------------------------------------------------------------
-- Driven from the nightly run
-- ---------------------------------------------------------------------
-- Yesterday, not today. `iakauntan-daily` fires at 17:00 UTC, which is
-- one in the morning in Malaysia, so the day being closed is the one
-- that just finished — the same reason `queue_sales_digest` takes
-- `p_on - 1`.
--
-- Wrapped like its neighbours: a company whose roster is in a state
-- this cannot read must not stop the recurring invoices behind it.
create or replace function app.run_daily_jobs(p_on date default current_date)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare o record;
begin
  perform app.run_recurring_journals(p_on);
  perform app.run_recurring_documents(p_on);
  perform app.queue_overdue_reminders(p_on);

  begin
    perform public.chat_expire_calls();
  exception when others then
    raise warning 'chat_expire_calls failed: %', sqlerrm;
  end;

  begin
    perform public.prune_device_tokens();
  exception when others then
    raise warning 'prune_device_tokens failed: %', sqlerrm;
  end;

  begin
    perform app.queue_sales_digest(p_on - 1);
  exception when others then
    raise warning 'queue_sales_digest failed: %', sqlerrm;
  end;

  begin
    perform app.sweep_idempotency_keys(now() - interval '24 hours');
  exception when others then
    raise warning 'sweep_idempotency_keys failed: %', sqlerrm;
  end;

  for o in select id from public.organizations
            where coalesce(status, 'active') = 'active'
  loop
    begin
      if app.has_module(o.id, 'hr') then
        perform app.close_attendance_day(o.id, p_on - 1);
      end if;
    exception when others then
      raise warning 'close_attendance_day failed for %: %', o.id, sqlerrm;
    end;

    if extract(month from p_on) = 1 and extract(day from p_on) = 1 then
      perform app.roll_leave_year(o.id, extract(year from p_on)::integer);
    end if;

    if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then
      perform app.roll_einvoice_consolidation(
        o.id, (p_on - interval '1 month')::date);
    end if;
  end loop;
end;
$$;

revoke all on function app.run_daily_jobs(date) from public, anon, authenticated;
