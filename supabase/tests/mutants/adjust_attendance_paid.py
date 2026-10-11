# Mutants for public.adjust_attendance(uuid, timestamptz, timestamptz, text)
# (0818) -- a day the employee has a payslip for on a posted or paid run
# is refused, and the run named: the employee's own payslip, not the
# company's; posted and paid, not calculated; the period's first and
# last days and those between, not the month after.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0818_a_paid_day_is_kept_as_it_was_paid.sql \
#       supabase/tests/attendance_paid.sql \
#       supabase/tests/mutants/adjust_attendance_paid.py
#
# RESULT: 9 mutants and a control, all killed by `attendance_paid.sql`,
# the first time. The fixture was built for it: the first and last days
# of January as well as one between, a February nobody has run, a run
# asked while calculated and again once paid, and an employee entered
# after January was run -- whose January day is in a paid period and
# was not paid. SECURITY DEFINER flipped by hand fails the file too.

m("the paid-day check is never asked",
  "adjust_attendance",
  "  if v_run.run_no is not null then",
  "  if false then  -- never paid",
  "-- never paid")

m("any payslip in the company stops the day",
  "adjust_attendance",
  "   where s.employee_id = v_rec.employee_id\n",
  "   where s.org_id = v_rec.org_id  -- the company's\n",
  "-- the company's")

m("a paid run does not count",
  "adjust_attendance",
  "     and r.status in ('posted', 'paid')",
  "     and r.status in ('posted')  -- not paid",
  "-- not paid")

m("a calculated run counts too",
  "adjust_attendance",
  "     and r.status in ('posted', 'paid')",
  "     and r.status in ('calculated', 'posted', 'paid')  -- calculated too",
  "-- calculated too")

m("the period's first day is not in it",
  "adjust_attendance",
  "     and r.status in ('posted', 'paid')\n     and v_rec.work_date between pp.period_start and pp.period_end",
  "     and r.status in ('posted', 'paid')\n     and v_rec.work_date > pp.period_start and v_rec.work_date <= pp.period_end  -- first day out",
  "-- first day out")

m("the period's last day is not in it",
  "adjust_attendance",
  "     and r.status in ('posted', 'paid')\n     and v_rec.work_date between pp.period_start and pp.period_end",
  "     and r.status in ('posted', 'paid')\n     and v_rec.work_date >= pp.period_start and v_rec.work_date < pp.period_end  -- last day out",
  "-- last day out")

m("any paid period stops any day",
  "adjust_attendance",
  "     and r.status in ('posted', 'paid')\n     and v_rec.work_date between pp.period_start and pp.period_end",
  "     and r.status in ('posted', 'paid')\n     and true  -- any period",
  "-- any period")

m("the refusal is a different kind",
  "adjust_attendance",
  "      v_run.run_no, v_run.code, v_run.status\n      using errcode = '23514';",
  "      v_run.run_no, v_run.code, v_run.status\n      using errcode = 'P0001';  -- other kind",
  "-- other kind")

m("the refusal does not name the run",
  "adjust_attendance",
  "      v_run.run_no, v_run.code, v_run.status\n",
  "      'a run', v_run.code, v_run.status  -- unnamed\n",
  "-- unnamed")

m("CONTROL: a comment inside the block",
  "adjust_attendance",
  "  if v_run.run_no is not null then",
  "  if v_run.run_no is not null then  -- (control)",
  "(control)")
