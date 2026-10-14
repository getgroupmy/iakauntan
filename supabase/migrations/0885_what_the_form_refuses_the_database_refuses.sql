-- =====================================================================
-- iAkauntan :: 0885 what the form refuses, the database refuses
--
-- Two rules the app says and the database did not.
--
-- A resignation after the last working day. The departure form refuses
-- one ("They cannot have given notice after they had already left") and
-- its comment says the database says the same things last. It did not:
-- `record_departure` took a resignation dated after the last working
-- day, and with none given filled in today -- so a departure recorded a
-- month after the person left, the ordinary late entry, stored
-- "resigned 14 Oct, last day 14 Sep". An HR edit of the row could store
-- the same. Measured on 14 October 2026, locally, with the role
-- `authenticated`: both shapes, through the function.
--
-- A negative hourly rate on a time entry. The matter screen refuses one
-- ("A rate cannot be below zero"); `time_entries` took ten hours at
-- -RM300 and stored an amount of -3,000. Billing skips it, so it sat
-- unbilled and took 3,000 off every figure that sums the time's value.
--
-- Production on 14 October: no departed employee, no resignation date,
-- and 28 time entries, none with a negative rate.
--
-- Answered "refuse it; default to the last day" and "refuse a negative
-- rate":
--
--   * `record_departure` refuses a resignation dated after the last
--     working day, and with none given uses the earlier of today and
--     the last working day;
--   * `employees` carries a check that a resignation is no later than
--     the last working day, whichever road writes them;
--   * `time_entries.hourly_rate` is never below zero. Zero stays: the
--     default-rate trigger reads it as "use the billing rate".
--
-- The function's body is `pg_get_functiondef` of what was applied, with
-- the two changes marked 0885.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.record_departure(p_employee uuid, p_last_working_date date, p_status text, p_reason text DEFAULT NULL::text, p_resignation_date date DEFAULT NULL::date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
  -- 0885: the form has always said this; now the database does too.
  if p_status = 'resigned' and p_resignation_date > p_last_working_date then
    raise exception
      'They cannot have given notice after they had already left: the '
      'resignation is dated %, the last working day %.',
      to_char(p_resignation_date, 'DD Mon YYYY'),
      to_char(p_last_working_date, 'DD Mon YYYY')
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
    -- 0885: with no date given, today -- unless they have already
    -- gone, when the latest they can have given notice is their last
    -- day. A departure recorded a month late is not a resignation
    -- handed in after the person left.
    resignation_date   = case when p_status = 'resigned'
                              then coalesce(p_resignation_date,
                                            least(v_today, p_last_working_date))
                              else null end,
    termination_reason = nullif(trim(coalesce(p_reason, '')), ''),
    updated_at         = now()
  where id = p_employee;
end $function$;

alter table public.employees
  add constraint employees_resignation_before_leaving_ck
  check (resignation_date is null or last_working_date is null
         or resignation_date <= last_working_date);

comment on constraint employees_resignation_before_leaving_ck
  on public.employees is
  'Notice is given on or before the last working day, never after it. '
  'The departure form says so first; 0885.';

alter table public.time_entries
  add constraint time_entries_hourly_rate_ck
  check (hourly_rate >= 0);

comment on constraint time_entries_hourly_rate_ck
  on public.time_entries is
  'An hour of work is charged at nothing or more. Zero means the billing '
  'rate applies (app.time_entry_default_rate). The matter screen says so '
  'first; 0885.';
