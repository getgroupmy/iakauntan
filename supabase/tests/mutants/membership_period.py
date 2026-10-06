# Mutants for app.membership_period (0750) -- which period of a
# membership a date falls in, counted from the day it was bought.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0750_what_earns_when_it_renews_and_who_is_trading.sql \
#       supabase/tests/pos_service.sql \
#       supabase/tests/mutants/membership_period.py
#
# RESULT: 6 mutants and a control. 6 killed, in pos_service.sql's
# "A membership renews on the day it was bought (0750)", including the
# walk 0750 replaced.

m("the period is walked from the last one, as before 0750",
  "membership_period",
  "  period_start := (v_start + v_step * v_n)::date;",
  "  period_start := (v_start + v_step * v_n)::date;\n  for i in 1..v_n loop v_start := (v_start + v_step)::date; end loop; period_start := v_start;  -- walked",
  "-- walked")

m("a period starts a step late",
  "membership_period",
  "  while v_start + v_step * (v_n + 1) <= p_on loop",
  "  while v_start + v_step * (v_n + 1) < p_on loop  -- renewal day is the old period",
  "-- renewal day is the old period")

m("the period ends on the renewal day",
  "membership_period",
  "  period_end   := (v_start + v_step * (v_n + 1) - interval '1 day')::date;",
  "  period_end   := (v_start + v_step * (v_n + 1))::date;  -- overlaps",
  "-- overlaps")

m("a week is a month",
  "membership_period",
  "              when 'weekly'    then interval '7 days'",
  "              when 'weekly'    then interval '1 month'  -- week",
  "-- week")

m("a quarter is a month",
  "membership_period",
  "              when 'quarterly' then interval '3 months'",
  "              when 'quarterly' then interval '1 month'  -- quarter",
  "-- quarter")

m("a year is a quarter",
  "membership_period",
  "              else                  interval '1 year'",
  "              else                  interval '3 months'  -- year",
  "-- year")

m("CONTROL: a comment inside the block",
  "membership_period",
  "  -- Still counted rather than divided, because months are not a fixed",
  "  -- CONTROL\n  -- Still counted rather than divided, because months are not a fixed",
  "-- CONTROL")
