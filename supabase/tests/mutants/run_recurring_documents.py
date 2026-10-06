# Mutants for app.run_recurring_documents (0750, after 0739) -- the
# nightly run of every company's repeating invoices. Its button,
# `run_recurring_documents_for`, is still 0739's and has its own file.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0750_what_earns_when_it_renews_and_who_is_trading.sql \
#       supabase/tests/recurring_documents.sql \
#       supabase/tests/mutants/run_recurring_documents.py
#
# then again against `recurring_shapes.sql`, `scheduled_work.sql` and
# `utc_is_not_today.sql`.
#
# RESULT: 6 mutants and a control. 4 killed, 2 equivalent.
#
#   Killed in recurring_documents.sql's "The night run and the button,
#   rule by rule": the suspended company, the trial company (0750), the
#   schedule due that very day, and the count.
#
#   EQUIVALENT by the callee: "a paused schedule runs at night" and "a
#   schedule not yet due runs at night". `app.advance_recurring_document`
#   opens its loop with `exit when not r.is_active` and `exit when
#   r.next_run_date > p_on`, so a schedule the runner should have passed
#   over is handed in and raises nothing. The runner's own filters save
#   a call, not a document.

m("a paused schedule runs at night",
  "run_recurring_documents",
  "     where d.is_active\n",
  "     where true  -- paused too\n",
  "-- paused too")

m("a suspended company's schedules run at night",
  "run_recurring_documents",
  "       and app.org_status_is_live(o.status)  -- 0750: trial too",
  "       and true  -- suspended too",
  "-- suspended too")

m("a schedule not yet due runs at night",
  "run_recurring_documents",
  "       and d.next_run_date <= p_on",
  "       and true  -- early",
  "-- early")

m("a schedule due today waits a day at night",
  "run_recurring_documents",
  "       and d.next_run_date <= p_on",
  "       and d.next_run_date < p_on  -- a day late",
  "-- a day late")

m("the night run counts nothing",
  "run_recurring_documents",
  "    v_n := v_n + app.advance_recurring_document(r.id, p_on);",
  "    perform app.advance_recurring_document(r.id, p_on);  -- uncounted",
  "-- uncounted")


# 0750 -- a trial company's schedules run.
m("a trial company's schedules do not run",
  "run_recurring_documents",
  "       and app.org_status_is_live(o.status)  -- 0750: trial too",
  "       and coalesce(o.status, 'active') = 'active'  -- active only",
  "-- active only")

m("CONTROL: a comment inside the block",
  "run_recurring_documents",
  "  return v_n;",
  "  -- CONTROL\n  return v_n;",
  "-- CONTROL")
