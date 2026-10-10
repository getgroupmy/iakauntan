# Mutants for public.ensure_pay_period (0279) -- the month a payroll
# run is raised against: only somebody who runs payroll raises one; it
# runs from the first to the last of the month; the pay date is the
# company's pay day counted from the first and capped at the month's
# end, 0 meaning the last day and no settings meaning the 25th; and a
# period already raised keeps its pay date.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0279_the_twenty_ninth_is_not_the_end_of_the_month.sql \
#       supabase/tests/payroll_periods.sql \
#       supabase/tests/mutants/ensure_pay_period.py
#
# RESULT: 8 mutants and a control. 7 killed by `payroll_periods.sql`
# as it stood -- the file was written rule by rule and needed nothing
# added. (The short period is killed by `pay_periods`' own check
# constraint rather than an assertion: the period's end has to follow
# its pay date.)
#
# One is EQUIVALENT: the inner `coalesce(pay_day, 25)` on a settings
# row. `payroll_settings.pay_day` is NOT NULL, default 25, so a row
# with no pay day cannot exist; only the outer coalesce, for a company
# with no row at all, ever decides -- and that one is asserted.

F = "ensure_pay_period"

m("anybody may raise a pay period", F,
  "  if not app.can_run_payroll(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("the period ends a day early", F,
  "  v_end date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;",
  "  v_end date := (make_date(p_year, p_month, 1) + interval '1 month - 2 days')::date;  -- short",
  "-- short")

m("a pay day nobody set is the first", F,
  "  v_pay_day := coalesce(v_pay_day, 25);",
  "  v_pay_day := coalesce(v_pay_day, 1);  -- first",
  "-- first")

m("a settings row with no pay day is the first", F,
  "  select coalesce(pay_day, 25) into v_pay_day",
  "  select coalesce(pay_day, 1) into v_pay_day  -- row first",
  "-- row first")

m("day 0 is the first, not the last", F,
  "  v_pay := case when v_pay_day = 0 then v_end",
  "  v_pay := case when v_pay_day = 0 then v_start  -- zero first",
  "-- zero first")

m("the pay day is not capped at the month's end", F,
  "                else least(v_start + (v_pay_day - 1), v_end) end;",
  "                else v_start + (v_pay_day - 1) end;  -- uncapped",
  "-- uncapped")

m("the pay day is counted from the day before", F,
  "                else least(v_start + (v_pay_day - 1), v_end) end;",
  "                else least(v_start + v_pay_day, v_end) end;  -- off by one",
  "-- off by one")

m("an existing period's pay date is moved", F,
  "  on conflict (org_id, code) do update set code = excluded.code",
  "  on conflict (org_id, code) do update set code = excluded.code, pay_date = excluded.pay_date  -- moved",
  "-- moved")

m("CONTROL", F,
  "  v_pay_day integer;",
  "  v_pay_day integer;  -- control",
  "-- control")
