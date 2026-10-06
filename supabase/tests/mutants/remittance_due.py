# Mutants for app.remittance_due (0457) -- the day a statutory body must
# have its money: the named day of the month AFTER the wages were paid.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0457_the_fifteenth_of_the_month_after.sql \
#       supabase/tests/statutory_remittances.sql \
#       supabase/tests/mutants/remittance_due.py
#
# RESULT: 4 mutants and a control. 4 killed in statutory_remittances.sql,
# which pins every body's due day, a pay date late in its month, and a
# body with no due day.

m("it is due in the month the wages were paid",
  "remittance_due",
  "         else (date_trunc('month', p_pay_date) + interval '1 month')::date",
  "         else (date_trunc('month', p_pay_date))::date  -- same month",
  "-- same month")

m("it counts from the pay date, not the month",
  "remittance_due",
  "         else (date_trunc('month', p_pay_date) + interval '1 month')::date",
  "         else (p_pay_date + interval '1 month')::date  -- from the day",
  "-- from the day")

m("the named day is a day late",
  "remittance_due",
  "              + (r.due_day - 1)",
  "              + r.due_day  -- day late",
  "-- day late")

m("a body with no due day is due on the 1st",
  "remittance_due",
  "  select case when r.due_day is null then null",
  "  select case when r.due_day is null then (date_trunc('month', p_pay_date) + interval '1 month')::date  -- the 1st",
  "-- the 1st")

m("CONTROL: a comment inside the block",
  "remittance_due",
  "  -- The month after the month the wages were paid in, on the day the",
  "  -- CONTROL\n  -- The month after the month the wages were paid in, on the day the",
  "-- CONTROL")
