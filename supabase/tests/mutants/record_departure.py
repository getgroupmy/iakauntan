# Mutants for public.record_departure (0371) -- somebody leaving: the
# employee exists and the caller manages HR; the departure is resigned,
# terminated or retired, with a last working day not before they
# joined and not before a month already paid to them; before that day
# they are serving notice; a resignation keeps the day notice was
# given (today if none), the others keep none; the reason is trimmed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0371_the_leaver_who_was_still_being_paid.sql \
#       supabase/tests/departures.sql \
#       supabase/tests/mutants/record_departure.py
#
# RESULT: 16 mutants and a control. 15 killed by `departures.sql`;
# before its assertions, 7. Nothing had asked about a missing employee,
# a stranger, no last working day, a run not yet posted or a posted run
# that did not pay them (neither stops a departure), leaving TODAY
# (resigned, not serving notice), or the reason's spaces. The first
# version of the unposted-run mutant added 'draft' and survived: a
# calculated run is 'calculated', so it never matched what the fixture
# builds. It reads "anything not void" now.
#
# One is EQUIVALENT: the last day before the day they joined.
# `app.employee_departure_guard` refuses the same in the same words on
# the row, so removing this function's copy changes nothing a caller
# sees -- the earlier sweep of the guard found the mirror image.

F = "record_departure"

m("an employee who does not exist is not refused in words", F,
  "  if v_emp.id is null then\n    raise exception 'No such employee.'",
  "  if false then  -- no such\n    raise exception 'No such employee.'",
  "-- no such")
m("anybody may record a departure", F,
  "  if not app.can_manage_hr(v_emp.org_id) then\n    raise exception 'not permitted to record a departure'",
  "  if false then  -- anybody\n    raise exception 'not permitted to record a departure'",
  "-- anybody")
m("any status is a departure", F,
  "  if p_status not in ('resigned', 'terminated', 'retired') then",
  "  if false then  -- any status",
  "-- any status")
m("no last working day is taken", F,
  "  if p_last_working_date is null then",
  "  if false then  -- no date",
  "-- no date")
m("a last day before joining is taken", F,
  "  if p_last_working_date < v_emp.hire_date then",
  "  if false then  -- before joining",
  "-- before joining")
m("a month already paid is moved under", F,
  "  if v_run is not null then",
  "  if false then  -- paid ignored",
  "-- paid ignored")
m("a run not yet posted counts as paid", F,
  "     and r.status in ('posted', 'paid')",
  "     and r.status <> 'void'  -- unposted count",
  "-- unposted count")
m("a posted run does not count", F,
  "     and r.status in ('posted', 'paid')",
  "     and r.status in ('paid')  -- posted ignored",
  "-- posted ignored")
m("the month OF the last day counts as after it", F,
  "     and p.period_start > p_last_working_date",
  "     and p.period_end >= p_last_working_date  -- own month",
  "-- own month")
m("a run that did not pay them counts", F,
  "     and exists (select 1 from public.payslips s\n                  where s.run_id = r.id and s.employee_id = p_employee)",
  "     and true  -- anybody's run",
  "-- anybody's run")
m("a future day is not notice", F,
  "  v_final := case when p_last_working_date > v_today",
  "  v_final := case when false  -- never notice",
  "-- never notice")
m("today is notice", F,
  "  v_final := case when p_last_working_date > v_today",
  "  v_final := case when p_last_working_date >= v_today  -- today notice",
  "-- today notice")
m("the last day is not kept", F,
  "    last_working_date  = p_last_working_date,",
  "    last_working_date  = last_working_date,  -- not kept",
  "-- not kept")
m("a resignation with no date has none", F,
  "                              then coalesce(p_resignation_date, v_today)",
  "                              then p_resignation_date  -- no default",
  "-- no default")
m("a termination keeps a resignation date", F,
  "                              else null end,",
  "                              else coalesce(p_resignation_date, v_today) end,  -- always",
  "-- always")
m("the reason is kept with its spaces", F,
  "    termination_reason = nullif(trim(coalesce(p_reason, '')), ''),",
  "    termination_reason = nullif(coalesce(p_reason, ''), ''),  -- untrimmed",
  "-- untrimmed")
m("CONTROL", F,
  "  v_run   text;",
  "  v_run   text;  -- control",
  "-- control")
