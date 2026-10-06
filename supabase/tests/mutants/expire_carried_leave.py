# Mutants for app.expire_carried_leave (0739) -- carried-forward leave
# that was not taken by the expiry month lapses; what was taken stays.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/leave_type_rules.sql \
#       supabase/tests/mutants/expire_carried_leave.py
#
# then again against `leave_year_shapes.sql` and `scheduled_work.sql`.
#
# RESULT: 9 mutants and a control. 8 killed, 1 equivalent.
#
#   Killed between them: leave_type_rules.sql takes the expiry month,
#   the day and the type that never expires; leave_year_shapes.sql
#   takes the company, the retired type and the year already gone.
#
#   EQUIVALENT by the code's shape: "what is kept is what was taken even
#   beyond the carry". The update only reaches rows where
#   `carried_forward > least(taken_days, carried_forward)`, which is
#   true only when taken_days < carried_forward -- and there
#   `least(taken, carried)` IS `taken`. The `least` in `keep` can only
#   matter on a row the WHERE has already turned away.

m("the carry is cut to nothing, taken or not",
  "expire_carried_leave",
  "           least(coalesce(b.taken_days, 0), coalesce(b.carried_forward, 0))\n             as keep",
  "           0::numeric  -- all of it\n             as keep",
  "-- all of it")

m("what is kept is what was taken even beyond the carry",
  "expire_carried_leave",
  "           least(coalesce(b.taken_days, 0), coalesce(b.carried_forward, 0))\n             as keep",
  "           coalesce(b.taken_days, 0)  -- uncapped\n             as keep",
  "-- uncapped")

m("another company's leave lapses",
  "expire_carried_leave",
  "     where b.org_id = p_org\n",
  "     where true  -- any org\n",
  "-- any org")

m("a retired leave type lapses",
  "expire_carried_leave",
  "       and t.is_active\n",
  "       and true  -- retired too\n",
  "-- retired too")

m("a type whose carry never expires lapses",
  "expire_carried_leave",
  "       and coalesce(t.carry_forward_expiry_months, 0) > 0",
  "       and true  -- no expiry",
  "-- no expiry")

m("a year already gone is swept",
  "expire_carried_leave",
  "       and b.leave_year = extract(year from p_on)::integer",
  "       and b.leave_year <= extract(year from p_on)::integer  -- old years",
  "-- old years")

m("it lapses before the expiry month",
  "expire_carried_leave",
  "       and p_on >= (make_date(b.leave_year, 1, 1)\n                    + make_interval(months => t.carry_forward_expiry_months))",
  "       and true  -- early",
  "-- early")

m("it lapses a day late",
  "expire_carried_leave",
  "       and p_on >= (make_date(b.leave_year, 1, 1)",
  "       and p_on > (make_date(b.leave_year, 1, 1)  -- day late",
  "-- day late")

m("a balance with nothing to lapse is counted",
  "expire_carried_leave",
  "       and coalesce(b.carried_forward, 0)\n           > least(coalesce(b.taken_days, 0), coalesce(b.carried_forward, 0))",
  "       and true  -- nothing to lapse",
  "-- nothing to lapse")

m("CONTROL: a comment inside the block",
  "expire_carried_leave",
  "  get diagnostics v_n = row_count;",
  "  -- CONTROL\n  get diagnostics v_n = row_count;",
  "-- CONTROL")
