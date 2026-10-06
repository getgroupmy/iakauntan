# Mutants for the two daily jobs 0750 changed beyond those with files of
# their own: app.queue_sales_digest and app.queue_all_activity_reminders.
# Each is asked one thing -- does a company on trial get it, and does a
# suspended one not -- so each file kills its own function's pair and
# leaves the other's.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0750_what_earns_when_it_renews_and_who_is_trading.sql \
#       supabase/tests/pos_reports.sql \
#       supabase/tests/mutants/trial_is_trading.py
#
# then again against `activity_reminders.sql`.
#
# RESULT: 4 mutants and a control. 4 killed -- the digest's pair in
# pos_reports.sql, the reminders' pair in activity_reminders.sql. Before
# 0750 neither job's company loop was asserted by anything: the only
# test that named either checked that the cron job exists.

m("a shop on trial gets no digest, as before 0750",
  "queue_sales_digest",
  "       and app.org_status_is_live(o.status)  -- 0750: trial too",
  "       and coalesce(o.status, 'active') = 'active'  -- active only",
  "-- active only")

m("a suspended shop gets a digest",
  "queue_sales_digest",
  "       and app.org_status_is_live(o.status)  -- 0750: trial too",
  "       and true  -- every company",
  "-- every company")

m("a company on trial is not reminded, as before 0750",
  "queue_all_activity_reminders",
  "            where app.org_status_is_live(status)  -- 0750: trial too",
  "            where coalesce(status, 'active') = 'active'  -- active only",
  "-- active only")

m("a suspended company is reminded",
  "queue_all_activity_reminders",
  "            where app.org_status_is_live(status)  -- 0750: trial too",
  "            where true  -- every company",
  "-- every company")

m("CONTROL: a comment inside the block",
  "queue_sales_digest",
  "    -- A shop that was shut has nothing to report, and a mail every",
  "    -- CONTROL\n    -- A shop that was shut has nothing to report, and a mail every",
  "-- CONTROL")
