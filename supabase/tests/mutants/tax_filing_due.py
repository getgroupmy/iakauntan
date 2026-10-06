# Mutants for app.tax_filing_due and app.tax_filing_fixed_date (0668) --
# the date every LHDN obligation falls due, from the four ways the
# Income Tax Act counts.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0668_the_dates_lhdn_counts_from.sql \
#       supabase/tests/tax_filing_calendar.sql \
#       supabase/tests/mutants/tax_filing_due.py
#
# RESULT: 16 mutants and a control. 16 killed in tax_filing_calendar.sql.
#
#   The calendar's own obligations killed 12. The four it left were
#   rules no obligation reaches: every basis period opens on the 1st,
#   every fixed-date obligation's period sits inside one calendar year,
#   every fixed day is the last of its month -- where the clamp hides a
#   day counted one too far -- and every obligation names its month.
#   "tax_filing_due and tax_filing_fixed_date, rule by rule" asks the two
#   functions directly.

m("before the period means the day it opens",
  "tax_filing_due",
  "      p_period_start - coalesce(p_days_before, 0)",
  "      p_period_start  -- no days before",
  "-- no days before")

m("before the period means after it opens",
  "tax_filing_due",
  "      p_period_start - coalesce(p_days_before, 0)",
  "      p_period_start + coalesce(p_days_before, 0)  -- after",
  "-- after")

m("seven months from the close, not from the day after",
  "tax_filing_due",
  "      ((p_period_end + 1)\n         + make_interval(months => coalesce(p_months_after, 0))\n         - interval '1 day')::date",
  "      (p_period_end\n         + make_interval(months => coalesce(p_months_after, 0)))::date  -- from the close",
  "-- from the close")

m("seven months from the day after, with no day back",
  "tax_filing_due",
  "         + make_interval(months => coalesce(p_months_after, 0))\n         - interval '1 day')::date",
  "         + make_interval(months => coalesce(p_months_after, 0)))::date  -- no day back",
  "-- no day back")

m("the months after are ignored",
  "tax_filing_due",
  "         + make_interval(months => coalesce(p_months_after, 0))\n         - interval '1 day')::date",
  "         - interval '1 day')::date  -- no months",
  "-- no months")

m("month n of the period is counted from the month before",
  "tax_filing_due",
  "         + make_interval(months => coalesce(p_period_month, 1))\n         - interval '1 day')::date",
  "         + make_interval(months => coalesce(p_period_month, 1) - 1)\n         - interval '1 day')::date  -- a month early",
  "-- a month early")

m("month n of the period is its first day, not its last",
  "tax_filing_due",
  "      (date_trunc('month', p_period_start)\n         + make_interval(months => coalesce(p_period_month, 1))\n         - interval '1 day')::date",
  "      (date_trunc('month', p_period_start)\n         + make_interval(months => coalesce(p_period_month, 1) - 1))::date  -- first day",
  "-- first day")

m("month n counts from the period's day, not its month",
  "tax_filing_due",
  "      (date_trunc('month', p_period_start)\n         + make_interval(months => coalesce(p_period_month, 1))",
  "      (p_period_start  -- not truncated\n         + make_interval(months => coalesce(p_period_month, 1))",
  "-- not truncated")

m("the year of assessment's fixed date is in the year itself",
  "tax_filing_due",
  "    when 'month_day_after_ya' then\n      app.tax_filing_fixed_date(\n        extract(year from p_period_end)::integer + 1,",
  "    when 'month_day_after_ya' then\n      app.tax_filing_fixed_date(\n        extract(year from p_period_end)::integer,  -- same year",
  "-- same year")

m("the calendar year's fixed date is in the year itself",
  "tax_filing_due",
  "    when 'month_day_after_year' then\n      app.tax_filing_fixed_date(\n        extract(year from p_period_end)::integer + 1,",
  "    when 'month_day_after_year' then\n      app.tax_filing_fixed_date(\n        extract(year from p_period_end)::integer,  -- same year",
  "-- same year")

m("the year is read from the period's start",
  "tax_filing_due",
  "    when 'month_day_after_ya' then\n      app.tax_filing_fixed_date(\n        extract(year from p_period_end)::integer + 1,",
  "    when 'month_day_after_ya' then\n      app.tax_filing_fixed_date(\n        extract(year from p_period_start)::integer + 1,  -- from start",
  "-- from start")

m("a day past the month's end is not clamped",
  "tax_filing_fixed_date",
  "    else least(",
  "    else greatest(  -- unclamped",
  "-- unclamped")

m("the day is one late",
  "tax_filing_fixed_date",
  "         + make_interval(days => greatest(coalesce(p_day, 31), 1) - 1))::date,",
  "         + make_interval(days => greatest(coalesce(p_day, 31), 1)))::date,  -- day late",
  "-- day late")

m("no day given is the first, not the last",
  "tax_filing_fixed_date",
  "         + make_interval(days => greatest(coalesce(p_day, 31), 1) - 1))::date,",
  "         + make_interval(days => greatest(coalesce(p_day, 1), 1) - 1))::date,  -- first",
  "-- first")

m("no month given is January",
  "tax_filing_fixed_date",
  "    when p_month is null then null",
  "    when p_month is null then make_date(p_year, 1, 1)  -- january",
  "-- january")

m("CONTROL: a comment inside the block",
  "tax_filing_due",
  "    -- Thirty days before the period opens.",
  "    -- CONTROL\n    -- Thirty days before the period opens.",
  "-- CONTROL")
