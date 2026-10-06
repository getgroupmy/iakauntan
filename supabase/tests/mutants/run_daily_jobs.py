# Mutants for app.run_daily_jobs (0750, after 0739) -- the morning pass:
# the calendar branches and which companies it walks.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0750_what_earns_when_it_renews_and_who_is_trading.sql \
#       supabase/tests/monthly_jobs.sql \
#       supabase/tests/mutants/run_daily_jobs.py
#
# then again against `module_subscription.sql` and `scheduled_work.sql`.
#
# RESULT: 8 mutants and a control. 8 killed between the two files:
# monthly_jobs.sql takes the trial company (0750), the suspended one and
# the four consolidation mutants; module_subscription.sql takes billing
# on any day and the chase that never runs. Neither file kills the
# other's.

m("a trial company is passed by, as before 0750",
  "run_daily_jobs",
  "            where app.org_status_is_live(status)\n",
  "            where coalesce(status, 'active') = 'active'  -- active only\n",
  "-- active only")

m("a suspended company gets the daily pass",
  "run_daily_jobs",
  "            where app.org_status_is_live(status)\n",
  "            where true  -- every company\n",
  "-- every company")

m("the consolidation runs on any day",
  "run_daily_jobs",
  "      if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then",
  "      if app.has_module(o.id, 'einvoice') then  -- any day",
  "-- any day")

m("the consolidation ignores the module",
  "run_daily_jobs",
  "      if extract(day from p_on) = 1 and app.has_module(o.id, 'einvoice') then",
  "      if extract(day from p_on) = 1 then  -- no module",
  "-- no module")

m("the consolidation gathers this month, not the last",
  "run_daily_jobs",
  "          o.id, (p_on - interval '1 month')::date);",
  "          o.id, p_on);  -- this month",
  "-- this month")

m("one company's failed consolidation stops the rest",
  "run_daily_jobs",
  "    exception when others then\n      raise warning 'roll_einvoice_consolidation failed for %: %',",
  "    exception when division_by_zero then  -- unguarded\n      raise warning 'roll_einvoice_consolidation failed for %: %',",
  "-- unguarded")

m("the month is billed on any day",
  "run_daily_jobs",
  "    if extract(day from p_on) = 1 then\n      perform app.bill_the_month(p_on);",
  "    if true then  -- any day\n      perform app.bill_the_month(p_on);",
  "-- any day")

m("the platform's invoices are never chased",
  "run_daily_jobs",
  "    perform app.chase_platform_invoices(p_on);",
  "    null;  -- no chase",
  "-- no chase")

m("CONTROL: a comment inside the block",
  "run_daily_jobs",
  "    -- 0375. Wrapped like the rest: a shop whose till sweep fails must",
  "    -- CONTROL\n    -- 0375. Wrapped like the rest: a shop whose till sweep fails must",
  "-- CONTROL")
