# Mutants for app.fs_lodge_by (0497) -- s.259: thirty days from the
# circulation, or from the six-month deadline when there was none.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0497_tell_somebody.sql \
#       supabase/tests/fs_deadlines.sql \
#       supabase/tests/mutants/fs_lodge_by.py
#
# then again against `mbrs.sql` and `notifications.sql`.
#
# RESULT: 3 mutants and a control. 3 killed in fs_deadlines.sql, whose
# first block asks the rule directly: uncirculated, circulated early,
# circulated late, and thirty days that are not a calendar month.

m("the circulation date is ignored",
  "fs_lodge_by",
  "  select coalesce(p_circulated_on,\n                  (p_fy_end + interval '6 months')::date) + 30;",
  "  select (p_fy_end + interval '6 months')::date + 30;  -- deadline only",
  "-- deadline only")

m("thirty days is a month",
  "fs_lodge_by",
  "                  (p_fy_end + interval '6 months')::date) + 30;",
  "                  (p_fy_end + interval '6 months')::date) + 31;  -- 31",
  "-- 31")

m("with nothing circulated it runs from the year end",
  "fs_lodge_by",
  "                  (p_fy_end + interval '6 months')::date) + 30;",
  "                  p_fy_end) + 30;  -- year end",
  "-- year end")

m("CONTROL: a comment inside the block",
  "fs_lodge_by",
  "  select coalesce(p_circulated_on,",
  "  -- CONTROL\n  select coalesce(p_circulated_on,",
  "-- CONTROL")
