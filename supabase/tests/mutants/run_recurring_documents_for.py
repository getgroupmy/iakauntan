# Mutants for public.run_recurring_documents_for (0739) -- the button
# that runs one company's repeating invoices now.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/recurring_documents.sql \
#       supabase/tests/mutants/run_recurring_documents_for.py
#
# RESULT: 4 mutants and a control. 2 killed, 2 equivalent.
#
#   Killed in recurring_documents.sql's "The night run and the button,
#   rule by rule": the stranger, and the button that ran every company's
#   schedules (the trial company's count does not move).
#
#   EQUIVALENT by the callee, for the reason given in
#   run_recurring_documents.py: "the button runs a paused schedule" and
#   "the button runs a schedule not yet due" --
#   `advance_recurring_document` exits on both.

m("a stranger runs a company's schedules",
  "run_recurring_documents_for",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("the button runs every company's schedules",
  "run_recurring_documents_for",
  "     where org_id = p_org_id and is_active and next_run_date <= p_on",
  "     where is_active and next_run_date <= p_on  -- every org",
  "-- every org")

m("the button runs a paused schedule",
  "run_recurring_documents_for",
  "     where org_id = p_org_id and is_active and next_run_date <= p_on",
  "     where org_id = p_org_id and next_run_date <= p_on  -- paused too",
  "-- paused too")

m("the button runs a schedule not yet due",
  "run_recurring_documents_for",
  "     where org_id = p_org_id and is_active and next_run_date <= p_on",
  "     where org_id = p_org_id and is_active  -- early",
  "-- early")

m("CONTROL: a comment inside the block",
  "run_recurring_documents_for",
  "  for r in\n    select id from public.recurring_documents",
  "  -- CONTROL\n  for r in\n    select id from public.recurring_documents",
  "-- CONTROL")
