# Mutants for app.check_leave_days (0397) -- the trigger that keeps a
# leave request's day count honest: some leave, at least half a day, no
# more days than its dates cover, and a half day that is one.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0397_the_leave_request_for_minus_twenty_days.sql \
#       supabase/tests/leave_requests.sql \
#       supabase/tests/mutants/check_leave_days.py
#
# RESULT: 9 mutants and a control. 9 killed in leave_requests.sql, which
# asks every refusal by what it says. leave_type_rules.sql and
# leave_year_shapes.sql insert no bad request and kill none, as expected.

m("a request for no leave is accepted",
  "check_leave_days",
  "  if coalesce(new.total_days, 0) <= 0 then",
  "  if coalesce(new.total_days, 0) < 0 then  -- zero fine",
  "-- zero fine")

m("a negative request is accepted",
  "check_leave_days",
  "  if coalesce(new.total_days, 0) <= 0 then",
  "  if false then  -- negative fine",
  "-- negative fine")

m("a quarter day is accepted",
  "check_leave_days",
  "  if new.total_days < 0.5 then",
  "  if false then  -- quarter fine",
  "-- quarter fine")

m("more days than the dates cover are accepted",
  "check_leave_days",
  "  if new.total_days > v_span then",
  "  if false then  -- any number",
  "-- any number")

m("the span is a day short",
  "check_leave_days",
  "  v_span integer := (new.end_date - new.start_date) + 1;",
  "  v_span integer := (new.end_date - new.start_date);  -- day short",
  "-- day short")

m("a half day of a whole day is accepted",
  "check_leave_days",
  "    if new.total_days <> 0.5 then",
  "    if false then  -- any half",
  "-- any half")

m("a half day across two dates is accepted",
  "check_leave_days",
  "    if new.start_date <> new.end_date then",
  "    if false then  -- two dates",
  "-- two dates")

m("half a day without the flag is accepted",
  "check_leave_days",
  "  elsif new.total_days = 0.5 then",
  "  elsif false then  -- unflagged",
  "-- unflagged")

m("a morning on a full day is accepted",
  "check_leave_days",
  "  if new.half_day_period is not null\n     and not coalesce(new.is_half_day, false) then",
  "  if false then  -- period anywhere",
  "-- period anywhere")

m("CONTROL: a comment inside the block",
  "check_leave_days",
  "  -- Which half is only meaningful on a half day.",
  "  -- CONTROL\n  -- Which half is only meaningful on a half day.",
  "-- CONTROL")
