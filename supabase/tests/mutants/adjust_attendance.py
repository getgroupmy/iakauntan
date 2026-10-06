# Mutants for public.adjust_attendance and app.recompute_attendance
# (0363) -- HR correcting a day's clock times, and the arithmetic that
# turns a day's times into worked minutes, lateness and overtime.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0363_correcting_a_day_that_was_never_closed.sql \
#       supabase/tests/attendance_adjust.sql \
#       supabase/tests/mutants/adjust_attendance.py
#
# then again against `clock_out.sql` and `attendance.sql`.
#
# RESULT: 42 mutants and a control. 42 killed across `attendance_adjust.sql`
# and `clock_out.sql` (`attendance.sql` adds none), fourteen only after a
# rule-by-rule block in `attendance_adjust.sql`. Every corrected day had
# been an ordinary weekday in a company with no holidays, no night shift
# and no closed pay period but the one the refusal used: so nothing said
# whose holiday or closed period counts, that a night shift's hours are
# its hours and not a negative schedule, what lateness a rest day or a
# holiday carries, or that the overtime reported includes the rest-day
# kind; and four refusals were tried only where another guard refused
# first. The six the block leaves (a working holiday, a day with no
# roster, the evening punch not re-reading the morning, early leaving,
# holiday overtime, a holiday on a rest day) are `clock_out.sql`'s.

# --- adjust_attendance -----------------------------------------------

m("a record that does not exist is corrected in silence",
  "adjust_attendance",
  "  if v_rec.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody corrects a timesheet",
  "adjust_attendance",
  "  if not app.can_manage_hr(v_rec.org_id) then",
  "  if false then  -- anyone",
  "-- anyone")

m("a correction needs no reason",
  "adjust_attendance",
  "  if coalesce(btrim(p_reason), '') = '' then",
  "  if p_reason is null then  -- blank will do",
  "-- blank will do")

m("a corrected day needs no start",
  "adjust_attendance",
  "  if p_clock_in is null then",
  "  if false then  -- no start",
  "-- no start")

m("a day may end before it starts",
  "adjust_attendance",
  "  if p_clock_out is not null and p_clock_out <= p_clock_in then",
  "  if false then  -- backwards",
  "-- backwards")

m("a day may end the instant it starts",
  "adjust_attendance",
  "  if p_clock_out is not null and p_clock_out <= p_clock_in then",
  "  if p_clock_out is not null and p_clock_out < p_clock_in then  -- zero length",
  "-- zero length")

m("a closed pay period is corrected anyway",
  "adjust_attendance",
  "  if v_closed is not null then",
  "  if false then  -- reopened by nobody",
  "-- reopened by nobody")

m("another company's closed period refuses this one",
  "adjust_attendance",
  "   where pp.org_id = v_rec.org_id\n     and pp.is_closed",
  "   where true  -- any company\n     and pp.is_closed",
  "-- any company")

m("an open period refuses",
  "adjust_attendance",
  "     and pp.is_closed\n",
  "     and true  -- open too\n",
  "-- open too")

m("any closed period refuses",
  "adjust_attendance",
  "     and v_rec.work_date between pp.period_start and pp.period_end",
  "     and true  -- any dates",
  "-- any dates")

m("the clock-in is not changed",
  "adjust_attendance",
  "     set clock_in = p_clock_in,",
  "     set clock_in = clock_in,  -- unchanged",
  "-- unchanged")

m("the clock-out is not changed",
  "adjust_attendance",
  "         clock_out = p_clock_out,",
  "         clock_out = clock_out,  -- unchanged",
  "-- unchanged")

m("the row does not say it was adjusted",
  "adjust_attendance",
  "         is_adjusted = true,",
  "         is_adjusted = false,  -- quietly",
  "-- quietly")

m("nobody is named as adjusting it",
  "adjust_attendance",
  "         adjusted_by = auth.uid(),",
  "         adjusted_by = null,  -- anonymous",
  "-- anonymous")

m("the reason is kept untrimmed",
  "adjust_attendance",
  "         adjustment_reason = btrim(p_reason)",
  "         adjustment_reason = p_reason  -- as typed",
  "-- as typed")

m("the morning is not re-read",
  "adjust_attendance",
  "  perform app.recompute_attendance(p_record, p_reread_lateness => true);",
  "  perform app.recompute_attendance(p_record, p_reread_lateness => false);  -- arrival kept",
  "-- arrival kept")

m("the day is not recomputed at all",
  "adjust_attendance",
  "  perform app.recompute_attendance(p_record, p_reread_lateness => true);",
  "  null;  -- stale",
  "-- stale")

m("overtime reported is normal overtime only",
  "adjust_attendance",
  "    'overtime_minutes', v_rec.ot_normal_minutes\n                      + v_rec.ot_restday_minutes\n                      + v_rec.ot_holiday_minutes);",
  "    'overtime_minutes', v_rec.ot_normal_minutes);  -- weekdays only",
  "-- weekdays only")

# --- recompute_attendance --------------------------------------------

m("a missing record is recomputed in silence",
  "recompute_attendance",
  "  if v_rec.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("another company's holiday counts",
  "recompute_attendance",
  "     where h.org_id = v_rec.org_id and h.holiday_date = v_rec.work_date",
  "     where h.holiday_date = v_rec.work_date  -- any company",
  "-- any company")

m("a working holiday is a holiday",
  "recompute_attendance",
  "       and not h.is_working\n  ) into v_is_holiday;",
  "       and true  -- worked or not\n  ) into v_is_holiday;",
  "-- worked or not")

m("no day is a rest day",
  "recompute_attendance",
  "    v_is_restday := not (extract(dow from v_rec.work_date)::integer\n                         = any (v_shift.work_days));",
  "    v_is_restday := false;  -- every day a working day",
  "-- every day a working day")

m("a day with no roster is scheduled for nothing",
  "recompute_attendance",
  "    when v_shift.id is null then 480",
  "    when v_shift.id is null then 1  -- nothing expected",
  "-- nothing expected")

m("a night shift is scheduled backwards",
  "recompute_attendance",
  "           + case when v_shift.crosses_midnight then interval '24 hours'",
  "           + case when false then interval '24 hours'  -- same day",
  "-- same day")

m("the break is scheduled as work",
  "recompute_attendance",
  "         - coalesce(v_shift.break_minutes, 0))\n  end;",
  "         - 0)  -- no break\n  end;",
  "-- no break")

m("an open day is not marked incomplete",
  "recompute_attendance",
  "             when v_rec.clock_in is not null then 'incomplete'",
  "             when false then 'incomplete'  -- left as it was",
  "-- left as it was")

m("an open day keeps its worked minutes",
  "recompute_attendance",
  "       set worked_minutes = 0,\n",
  "       set worked_minutes = worked_minutes,  -- kept\n",
  "-- kept")

m("the break is worked",
  "recompute_attendance",
  "    (extract(epoch from (v_rec.clock_out - v_rec.clock_in)) / 60)::integer\n    - coalesce(v_shift.break_minutes, 0));",
  "    (extract(epoch from (v_rec.clock_out - v_rec.clock_in)) / 60)::integer\n    - 0);  -- paid break",
  "-- paid break")

m("a punch re-reads the morning",
  "recompute_attendance",
  "    when not p_reread_lateness then coalesce(v_rec.late_minutes, 0)",
  "    when false then coalesce(v_rec.late_minutes, 0)  -- always re-read",
  "-- always re-read")

m("lateness counts on a rest day",
  "recompute_attendance",
  "    when v_shift.id is null or v_is_restday or v_is_holiday then 0",
  "    when v_shift.id is null or v_is_holiday then 0  -- rest day too",
  "-- rest day too")

m("lateness counts on a holiday",
  "recompute_attendance",
  "    when v_shift.id is null or v_is_restday or v_is_holiday then 0",
  "    when v_shift.id is null or v_is_restday then 0  -- holiday too",
  "-- holiday too")

m("there is no grace",
  "recompute_attendance",
  "              + make_interval(mins => coalesce(v_shift.grace_minutes, 0)))",
  "              + make_interval(mins => 0))  -- no grace",
  "-- no grace")

m("lateness is read in UTC",
  "recompute_attendance",
  "           (v_rec.clock_in at time zone 'Asia/Kuala_Lumpur')",
  "           (v_rec.clock_in at time zone 'UTC')  -- wrong clock",
  "-- wrong clock")

m("overtime starts at the first minute",
  "recompute_attendance",
  "  v_ot := greatest(0, v_worked - v_scheduled);",
  "  v_ot := v_worked;  -- every minute",
  "-- every minute")

m("leaving early is never recorded",
  "recompute_attendance",
  "    early_leave_minutes = greatest(0, v_scheduled - v_worked),",
  "    early_leave_minutes = 0,  -- never early",
  "-- never early")

m("holiday overtime is not holiday overtime",
  "recompute_attendance",
  "    ot_holiday_minutes = case when v_is_holiday then v_ot else 0 end,",
  "    ot_holiday_minutes = 0,  -- not a holiday",
  "-- not a holiday")

m("a holiday that falls on a rest day pays twice",
  "recompute_attendance",
  "    ot_restday_minutes = case when v_is_restday and not v_is_holiday",
  "    ot_restday_minutes = case when v_is_restday  -- and the holiday",
  "-- and the holiday")

m("rest-day overtime is normal overtime",
  "recompute_attendance",
  "    ot_normal_minutes  = case when not v_is_holiday and not v_is_restday",
  "    ot_normal_minutes  = case when not v_is_holiday  -- rest day too",
  "-- rest day too")

m("a holiday worked is just present",
  "recompute_attendance",
  "      when v_is_holiday then 'public_holiday'::app.attendance_status",
  "      when false then 'public_holiday'::app.attendance_status  -- ordinary",
  "-- ordinary")

m("a rest day worked is just present",
  "recompute_attendance",
  "      when v_is_restday then 'rest_day'::app.attendance_status",
  "      when false then 'rest_day'::app.attendance_status  -- ordinary",
  "-- ordinary")

m("nobody is ever late",
  "recompute_attendance",
  "      when v_late > 0 then 'late'::app.attendance_status",
  "      when false then 'late'::app.attendance_status  -- punctual",
  "-- punctual")

m("CONTROL: a comment inside the block",
  "recompute_attendance",
  "  v_ot := greatest(0, v_worked - v_scheduled);",
  "  v_ot := greatest(0, v_worked - v_scheduled);  -- (control)",
  "(control)")
