# Mutants for app.close_attendance_day (0360) -- the night after a
# working day: a clock-in with no clock-out is marked incomplete, and
# everybody rostered who has no row gets one, on leave or absent.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0360_the_day_nobody_clocked_in.sql \
#       supabase/tests/attendance_close.sql \
#       supabase/tests/mutants/close_attendance_day.py
#
# then again against `scheduled_work.sql`, which kills nine of its own
# but none the first file misses.
#
# RESULT: 25 mutants and a control. 25 killed by `attendance_close.sql`,
# fifteen only after a rule-by-rule block there. The fixture was one
# company of five people, all active and hired months before, so nothing
# said whose holiday, clock-in or employee counted; nothing pressed the
# edges of employment (resigned, retired, not yet started, first day,
# last day, past it); no open clock-in sat on another day nor a finished
# one on this; and `dow` and ISO weekdays differ only on a Sunday, which
# no roster here worked.

m("another company's holiday closes this one",
  "close_attendance_day",
  "     where h.org_id = p_org and h.holiday_date = p_on and not h.is_working",
  "     where h.holiday_date = p_on and not h.is_working  -- any company",
  "-- any company")

m("a working holiday is a holiday",
  "close_attendance_day",
  "     where h.org_id = p_org and h.holiday_date = p_on and not h.is_working",
  "     where h.org_id = p_org and h.holiday_date = p_on  -- worked or not",
  "-- worked or not")

m("another company's open clock-ins are marked",
  "close_attendance_day",
  "   where r.org_id = p_org\n     and r.work_date = p_on\n     and r.clock_in is not null",
  "   where true  -- any company\n     and r.work_date = p_on\n     and r.clock_in is not null",
  "-- any company")

m("another day's open clock-ins are marked",
  "close_attendance_day",
  "     and r.work_date = p_on\n     and r.clock_in is not null",
  "     and true  -- any day\n     and r.clock_in is not null",
  "-- any day")

m("a closed day is marked incomplete",
  "close_attendance_day",
  "     and r.clock_out is null\n     and r.status <> 'incomplete';",
  "     and true  -- closed too\n     and r.status <> 'incomplete';",
  "-- closed too")

m("a row nobody clocked into is marked incomplete",
  "close_attendance_day",
  "     and r.clock_in is not null\n     and r.clock_out is null",
  "     and true  -- never in\n     and r.clock_out is null",
  "-- never in")

m("the incomplete are not counted",
  "close_attendance_day",
  "  get diagnostics v_n = row_count;",
  "  v_n := 0;  -- uncounted",
  "-- uncounted")

m("a holiday marks the absent too",
  "close_attendance_day",
  "  if v_holiday then\n    return v_n;\n  end if;",
  "  if false then  -- no holiday\n    return v_n;\n  end if;",
  "-- no holiday")

m("another company's staff are marked",
  "close_attendance_day",
  "     where e.org_id = p_org\n       and e.employment_status",
  "     where true  -- any company\n       and e.employment_status",
  "-- any company")

m("somebody who has left is marked absent",
  "close_attendance_day",
  "       and e.employment_status not in ('resigned', 'terminated', 'retired')",
  "       and true  -- leavers too",
  "-- leavers too")

m("a retired employee is marked absent",
  "close_attendance_day",
  "       and e.employment_status not in ('resigned', 'terminated', 'retired')",
  "       and e.employment_status not in ('resigned', 'terminated')  -- retired too",
  "-- retired too")

m("somebody not yet hired is marked absent",
  "close_attendance_day",
  "       and e.hire_date <= p_on\n",
  "       and true  -- before they started\n",
  "-- before they started")

m("somebody hired that day is not marked",
  "close_attendance_day",
  "       and e.hire_date <= p_on\n",
  "       and e.hire_date < p_on  -- not on day one\n",
  "-- not on day one")

m("somebody past their last day is marked absent",
  "close_attendance_day",
  "       and (e.last_working_date is null or e.last_working_date >= p_on)",
  "       and true  -- after they left",
  "-- after they left")

m("somebody on their last day is not marked",
  "close_attendance_day",
  "       and (e.last_working_date is null or e.last_working_date >= p_on)",
  "       and (e.last_working_date is null or e.last_working_date > p_on)  -- not the last day",
  "-- not the last day")

m("somebody with a row already gets another",
  "close_attendance_day",
  "          where r.employee_id = e.id and r.work_date = p_on)",
  "          where false)  -- twice",
  "-- twice")

m("a row on another day counts as this day's",
  "close_attendance_day",
  "          where r.employee_id = e.id and r.work_date = p_on)",
  "          where r.employee_id = e.id)  -- any day",
  "-- any day")

m("nobody without a roster is spared",
  "close_attendance_day",
  "    continue when v_shift.id is null;",
  "    null;  -- rosterless too",
  "-- rosterless too")

m("a rest day is marked absent",
  "close_attendance_day",
  "    continue when not (extract(dow from p_on)::integer = any (v_shift.work_days));",
  "    null;  -- every day a working day",
  "-- every day a working day")

m("the ISO weekday is read",
  "close_attendance_day",
  "    continue when not (extract(dow from p_on)::integer = any (v_shift.work_days));",
  "    continue when not (extract(isodow from p_on)::integer = any (v_shift.work_days));  -- ISO",
  "-- ISO")

m("leave is never an explanation",
  "close_attendance_day",
  "           and lr.status = 'approved'\n           and p_on between lr.start_date and lr.end_date)",
  "           and false)  -- no excuse",
  "-- no excuse")

m("a leave request not yet approved explains it",
  "close_attendance_day",
  "           and lr.status = 'approved'\n",
  "           and lr.status <> 'rejected'  -- asked is enough\n",
  "-- asked is enough")

m("leave on another day explains it",
  "close_attendance_day",
  "           and p_on between lr.start_date and lr.end_date)",
  "           and true)  -- any leave",
  "-- any leave")

m("somebody else's leave explains it",
  "close_attendance_day",
  "         where lr.employee_id = v_emp.id\n",
  "         where true  -- anybody's\n",
  "-- anybody's")

m("the absent are not counted",
  "close_attendance_day",
  "    v_n := v_n + 1;\n  end loop;",
  "    null;  -- uncounted\n  end loop;",
  "-- uncounted")

m("CONTROL: a comment inside the block",
  "close_attendance_day",
  "    -- No roster, no expectation, no mark against them.",
  "    -- No roster, no expectation, no mark against them. (control)",
  "(control)")
