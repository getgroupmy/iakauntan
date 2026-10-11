-- =====================================================================
-- iAkauntan :: 0818 a paid day is kept as it was paid
--
-- `adjust_attendance` is how HR corrects a day, and since `0811` the
-- only way. It has refused, since `0363`, "a day inside a closed pay
-- period" -- "the overtime on this row has been paid, and moving it
-- afterwards makes the timesheet and the payslip disagree". It asks
-- `pay_periods.is_closed`, and nothing in the schema has ever set it:
-- not `post_payroll_run`, not `mark_payroll_paid`, nothing. Production
-- held nine periods with paid runs on 11 October, none closed. And since
-- `0817` no client can set it either.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: January posted, paying one hour's overtime on 7
-- January -- RM18.75. The day then adjusted to five hours, "Afterthought",
-- and accepted. February's run paid no overtime, because it reads
-- February's days: the timesheet said five hours, the payslip had paid
-- one, and nothing said they disagreed.
--
-- Answered "refuse days already paid". `adjust_attendance` now also
-- refuses a day when the employee has a payslip on a posted or paid run
-- whose period the day falls in, and names the run. It is asked of the
-- runs themselves, so it holds for every period already paid without a
-- row being changed. The `is_closed` check stays as it was. A paid day
-- is corrected by voiding the run and raising another -- for which, as
-- `0817` said, there is no function yet.
-- =====================================================================

create or replace function public.adjust_attendance(
  p_record    uuid,
  p_clock_in  timestamptz,
  p_clock_out timestamptz,
  p_reason    text)
returns jsonb
language plpgsql
security definer
set search_path = public, app, pg_temp
as $function$
declare
  v_rec    public.attendance_records;
  v_closed text;
  v_run    record;
begin
  select * into v_rec from public.attendance_records where id = p_record;
  if v_rec.id is null then
    raise exception 'No such attendance record.' using errcode = 'P0002';
  end if;
  if not app.can_manage_hr(v_rec.org_id) then
    raise exception 'Only HR may correct somebody''s timesheet'
      using errcode = '42501';
  end if;

  -- The reason is the point of the three columns. A corrected timesheet
  -- with no reason is a changed number nobody can account for, and the
  -- person it belongs to is the one who will be asked about it.
  if coalesce(btrim(p_reason), '') = '' then
    raise exception
      'Say why the day is being corrected. It goes on the record beside '
      'the change.'
      using errcode = '23514';
  end if;

  if p_clock_in is null then
    raise exception 'A corrected day still needs a time somebody started.'
      using errcode = '23514';
  end if;
  if p_clock_out is not null and p_clock_out <= p_clock_in then
    raise exception 'The day cannot end before it started.'
      using errcode = '23514';
  end if;

  -- Not inside a closed pay period. The overtime on this row has been
  -- paid, and moving it afterwards makes the timesheet and the payslip
  -- disagree — with the payslip being the one that was remitted
  -- against.
  select pp.code into v_closed
    from public.pay_periods pp
   where pp.org_id = v_rec.org_id
     and pp.is_closed
     and v_rec.work_date between pp.period_start and pp.period_end
   limit 1;
  if v_closed is not null then
    raise exception
      'Pay period % is closed and this day was paid in it. Reopen the '
      'period first if the correction is meant to change what was paid.',
      v_closed
      using errcode = '23514';
  end if;

  -- Nor a day this employee has been paid for (0818). Nothing has ever
  -- set `is_closed`, so the check above has never refused anything: a
  -- day whose overtime was paid on a posted run was rewritten after it,
  -- and the next run, which reads its own month's days, never saw the
  -- difference. The run is the record of what was paid, so it is asked
  -- directly -- this employee's payslip, on a run that is posted or paid,
  -- for a period the day falls in.
  select r.run_no, r.status::text as status, pp.code
    into v_run
    from public.payslips s
    join public.payroll_runs r on r.id = s.run_id
    join public.pay_periods pp on pp.id = r.period_id
   where s.employee_id = v_rec.employee_id
     and r.status in ('posted', 'paid')
     and v_rec.work_date between pp.period_start and pp.period_end
   order by pp.period_start
   limit 1;
  if v_run.run_no is not null then
    raise exception
      'Payroll run % for % is %, and this day was paid on it. The '
      'timesheet is what the payslip paid; correcting it now would make '
      'the two disagree, with the payslip the one remitted against.',
      v_run.run_no, v_run.code, v_run.status
      using errcode = '23514';
  end if;

  update public.attendance_records
     set clock_in = p_clock_in,
         clock_out = p_clock_out,
         is_adjusted = true,
         adjusted_by = auth.uid(),
         adjustment_reason = btrim(p_reason)
   where id = p_record;

  -- The arrival time is what changed, so the morning is re-read too.
  perform app.recompute_attendance(p_record, p_reread_lateness => true);

  select * into v_rec from public.attendance_records where id = p_record;
  return jsonb_build_object(
    'status', v_rec.status,
    'worked_minutes', v_rec.worked_minutes,
    'late_minutes', v_rec.late_minutes,
    'overtime_minutes', v_rec.ot_normal_minutes
                      + v_rec.ot_restday_minutes
                      + v_rec.ot_holiday_minutes);
end $function$;


revoke all on function public.adjust_attendance(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.adjust_attendance(uuid, timestamptz, timestamptz, text)
  to authenticated, service_role;
