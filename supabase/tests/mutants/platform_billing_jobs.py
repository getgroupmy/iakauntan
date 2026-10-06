# Mutants for app.bill_the_month and app.chase_platform_invoices (0739)
# -- the platform's own billing: last month's modules invoiced on the
# first, and an unpaid platform invoice reminded on chosen days.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/module_subscription.sql \
#       supabase/tests/mutants/platform_billing_jobs.py
#
# RESULT: 11 mutants and a control. 10 killed, 1 equivalent.
#
#   The first sweep killed 5. Every company billed or chased was active
#   and real, and the chase was configured with 7, 14 and 30 days --
#   exactly its defaults, so reading the configuration and ignoring it
#   sent the same mail. "Who the platform bills and chases, rule by rule"
#   kills the rest, with a trial company on the side that is NOT billed:
#   0750 made trial live for every daily job but these two.
#
#   EQUIVALENT by the callee: "a demo company is billed".
#   `app.bill_org_modules` returns null for a demo company itself, so
#   `bill_the_month`'s own `not is_demo` saves a call, not an invoice.
#   (The demo company in the chase test was billed while it was real and
#   made a demo afterwards -- the one way a demo comes to hold a platform
#   invoice -- which is how "a demo company is chased" is killed.)

m("this month is billed instead of last",
  "bill_the_month",
  "  v_month date := (date_trunc('month', p_on) - interval '1 month')::date;",
  "  v_month date := date_trunc('month', p_on)::date;  -- this month",
  "-- this month")

m("a suspended company is billed",
  "bill_the_month",
  "            where coalesce(status, 'active') = 'active' and not is_demo",
  "            where not is_demo  -- suspended too",
  "-- suspended too")

m("a demo company is billed",
  "bill_the_month",
  "            where coalesce(status, 'active') = 'active' and not is_demo",
  "            where coalesce(status, 'active') = 'active'  -- demo too",
  "-- demo too")

m("a company with nothing to bill is counted",
  "bill_the_month",
  "    if app.bill_org_modules(o.id, v_month) is not null then",
  "    if app.bill_org_modules(o.id, v_month) is null or true then  -- all",
  "-- all")

m("the configured reminder days are ignored",
  "chase_platform_invoices",
  "  if array_length(v_days, 1) is null then",
  "  if true then  -- defaults always",
  "-- defaults always")

m("with nothing configured there are no reminders",
  "chase_platform_invoices",
  "    v_days := array[7, 14, 30];",
  "    v_days := array[]::integer[];  -- none",
  "-- none")

m("a paid platform invoice is chased",
  "chase_platform_invoices",
  "     where i.status = 'issued'",
  "     where true  -- any status",
  "-- any status")

m("a demo company is chased",
  "chase_platform_invoices",
  "       and not o.is_demo\n",
  "       and true  -- demo too\n",
  "-- demo too")

m("a suspended company is chased",
  "chase_platform_invoices",
  "       and coalesce(o.status, 'active') = 'active'\n       and (p_on - i.issue_date)",
  "       and true  -- suspended too\n       and (p_on - i.issue_date)",
  "-- suspended too")

m("every day is a reminder day",
  "chase_platform_invoices",
  "       and (p_on - i.issue_date) = any (v_days)",
  "       and (p_on - i.issue_date) > 0  -- every day",
  "-- every day")

m("the 7th and the 14th are the same mail",
  "chase_platform_invoices",
  "         'platform-reminder:' || r.id::text || ':' || r.age::text,",
  "         'platform-reminder:' || r.id::text,  -- one key",
  "-- one key")

m("CONTROL: a comment inside the block",
  "chase_platform_invoices",
  "  return v_n;",
  "  -- CONTROL\n  return v_n;",
  "-- CONTROL")
