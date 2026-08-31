-- =====================================================================
-- iAkauntan :: 0371 the leaver who was still being paid
--
-- The employee editor has offered "Resigned", "Terminated" and "Retired"
-- since it was written. `calculate_payroll_run` has never read
-- `employment_status`. It picks the people to pay by date:
--
--     and (e.last_working_date is null
--          or e.last_working_date >= v_period.period_start)
--
-- and `last_working_date` is a column since `0025` that no screen has
-- ever set. So somebody marks a leaver Resigned, the record says
-- Resigned, every list shows Resigned — and the payroll run pays them a
-- full month's salary, contributes EPF and SOCSO on it, deducts and
-- remits PCB against their tax file, and the bank payment file from
-- `0035` sends the money to their account. Every month. Until somebody
-- notices.
--
-- This is worse than the ordinary shape of this document, and it is
-- worth saying why. An unreachable feature is an **absence**: nothing
-- happens, and an option missing from a menu is at least indistinguisha-
-- ble from one that was never built. This is a **falsehood** — a control
-- that appears to have been applied. The person who set the dropdown did
-- the thing the software asked of them, and the software then did the
-- opposite of what they asked.
--
-- ---------------------------------------------------------------------
-- One fact, written once
--
-- The temptation is to make the engine read the status as well, so that
-- either one stops the payment. That is two sources of truth for one
-- fact, and two sources of truth are how they come to disagree — a
-- leaver excluded by status with no last day cannot be paid the days
-- they did work in their final month, which is a different wrong answer.
--
-- So the date stays the only thing the engine reads, and the database
-- refuses to let the two say different things:
-- `employees_departure_ck` will not accept a **newly declared** leaver
-- without a last working day.
--
-- Judging the change and not the row, which `0367` is the note on. A
-- record already sitting in a leaving status with no date — every one
-- ever set through the editor — must stay editable: somebody has to be
-- able to correct their phone number without being told to fill in a
-- departure first. The trigger fires when the departure is being
-- declared or moved, which is the moment the question is answerable.
-- The `do` block below names the ones already in that state, because a
-- diagnostic that does not say who is not a diagnostic.
--
-- ---------------------------------------------------------------------
-- `notice` is derived, not chosen
--
-- `app.employment_status` has carried `notice` since `0025` and the
-- dropdown offered it beside the rest, which made it a thing somebody
-- typed rather than a thing that was true. Serving notice is exactly
-- "has resigned, and the last working day has not arrived", so
-- `record_departure` works it out. It is one of the sixth sweep's
-- unreachable-in-practice values reached properly: it now means
-- something no other value means.
--
-- ---------------------------------------------------------------------
-- What it will not do
--
-- Restate a month that has been posted. If a payroll run covering a
-- period that begins after the last working day has been posted, the
-- money left the company and the contributions were remitted; moving the
-- last working day backwards makes the ledger and the record disagree
-- without unwinding anything. The run is named and the departure is
-- refused, so the sequence is void the run, then record the departure.
--
-- And `reinstate_employee` exists because a departure recorded against
-- the wrong person, or a resignation withdrawn, are both ordinary — and
-- a state with no way out of it is how somebody ends up deleting an
-- employee record to fix a typo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Who is already in this state
-- ---------------------------------------------------------------------
do $$
declare r record; v_n integer := 0;
begin
  for r in
    select e.org_id, e.employee_no, e.full_name, e.employment_status
      from public.employees e
     where e.employment_status in ('resigned', 'terminated', 'retired')
       and e.last_working_date is null
     order by e.org_id, e.employee_no
  loop
    v_n := v_n + 1;
    raise notice
      '0371: % (%) in org % is % with no last working day, and has been '
      'paid in every run since.', r.full_name, r.employee_no, r.org_id,
      r.employment_status;
  end loop;
  if v_n > 0 then
    raise notice
      '0371: % employee(s) above. Record a departure for each; until then '
      'the payroll run still includes them.', v_n;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A leaver has a last day
-- ---------------------------------------------------------------------
create or replace function app.employee_departure_guard()
returns trigger
language plpgsql
set search_path = public, app, pg_temp
as $$
begin
  -- Only when the departure is being declared or moved. A row already
  -- in this state keeps being editable, because the alternative is
  -- refusing to let somebody fix a bank account number until they have
  -- answered a question about a colleague who left last year.
  if new.employment_status not in ('resigned', 'terminated', 'retired') then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and old.employment_status = new.employment_status
     and old.last_working_date is not distinct from new.last_working_date then
    return new;
  end if;

  if new.last_working_date is null then
    raise exception
      'Somebody who has left needs a last working day. Without it the '
      'payroll run still pays them: it goes by the date, not by the '
      'status.'
      using errcode = '23514';
  end if;
  if new.last_working_date < new.hire_date then
    raise exception 'A last working day cannot come before the day they joined.'
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger employees_departure_ck
  before insert or update on public.employees
  for each row execute function app.employee_departure_guard();

-- ---------------------------------------------------------------------
-- Recording it
-- ---------------------------------------------------------------------
create or replace function public.record_departure(
  p_employee uuid,
  p_last_working_date date,
  p_status text,
  p_reason text default null,
  p_resignation_date date default null)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_emp   public.employees;
  v_run   text;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_final app.employment_status;
begin
  select * into v_emp from public.employees where id = p_employee;
  if v_emp.id is null then
    raise exception 'No such employee.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_emp.org_id) then
    raise exception 'not permitted to record a departure'
      using errcode = '42501';
  end if;
  if p_status not in ('resigned', 'terminated', 'retired') then
    raise exception
      'A departure is one of resigned, terminated or retired; got %.',
      p_status using errcode = '22023';
  end if;
  if p_last_working_date is null then
    raise exception 'A departure needs a last working day.'
      using errcode = '23514';
  end if;
  if p_last_working_date < v_emp.hire_date then
    raise exception 'A last working day cannot come before the day they joined.'
      using errcode = '23514';
  end if;

  -- A month already paid. The contributions were remitted and the money
  -- has gone; the run has to be voided before the record can say the
  -- person was not there for it.
  select r.run_no into v_run
    from public.payroll_runs r
    join public.pay_periods p on p.id = r.period_id
   where r.org_id = v_emp.org_id
     and r.status in ('posted', 'paid')
     and p.period_start > p_last_working_date
     and exists (select 1 from public.payslips s
                  where s.run_id = r.id and s.employee_id = p_employee)
   order by p.period_start limit 1;
  if v_run is not null then
    raise exception
      'Payroll run % has been posted for a month after that date, and it '
      'paid them. Void it first — moving the last working day now would '
      'leave the ledger saying one thing and the record another.', v_run
      using errcode = '23514';
  end if;

  -- Serving notice is not a separate decision. It is this decision, seen
  -- before the day arrives.
  v_final := case when p_last_working_date > v_today
                  then 'notice'::app.employment_status
                  else p_status::app.employment_status end;

  update public.employees set
    employment_status  = v_final,
    last_working_date  = p_last_working_date,
    -- The day they gave notice, which is not the day they leave. Only a
    -- resignation has one; a termination and a retirement do not.
    resignation_date   = case when p_status = 'resigned'
                              then coalesce(p_resignation_date, v_today)
                              else null end,
    termination_reason = nullif(trim(coalesce(p_reason, '')), ''),
    updated_at         = now()
  where id = p_employee;
end $$;

create or replace function public.reinstate_employee(p_employee uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_emp public.employees;
begin
  select * into v_emp from public.employees where id = p_employee;
  if v_emp.id is null then
    raise exception 'No such employee.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_emp.org_id) then
    raise exception 'not permitted to reinstate an employee'
      using errcode = '42501';
  end if;

  update public.employees set
    employment_status  = case when v_emp.confirmation_date is null
                              then 'probation'::app.employment_status
                              else 'active'::app.employment_status end,
    last_working_date  = null,
    resignation_date   = null,
    termination_reason = null,
    updated_at         = now()
  where id = p_employee;
end $$;

revoke all on function public.record_departure(uuid, date, text, text, date)
  from public, anon;
revoke all on function public.reinstate_employee(uuid) from public, anon;
grant execute on function public.record_departure(uuid, date, text, text, date)
  to authenticated;
grant execute on function public.reinstate_employee(uuid) to authenticated;

comment on function public.record_departure(uuid, date, text, text, date) is
  'Takes somebody off the payroll. The payroll run goes by '
  'last_working_date and has never read employment_status, so a leaver '
  'marked only in the dropdown kept drawing a full salary, kept having '
  'EPF and PCB remitted, and kept being paid by the bank file.';
comment on function public.reinstate_employee(uuid) is
  'Undoes a departure. A resignation withdrawn and a departure recorded '
  'against the wrong person are both ordinary, and a state with no way '
  'out of it is how somebody deletes an employee record to fix a typo.';
