# Mutants for app.closed_project_takes_no_billable_time (0783) -- a
# change to the time entries that adds billable, uninvoiced time to a
# CLOSED project is refused, naming it: logged, moved onto it, made
# billable or un-billed again, raised -- counted by entry as well as by
# money, as `close_project` counts. Non-billable time, and an edit to an
# entry already counted there that does not raise it, are not.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0783_a_closed_job_takes_no_billable_time.sql \
#       supabase/tests/project_budget.sql \
#       supabase/tests/mutants/closed_project_takes_no_billable_time.py
#
# RESULT: 11 mutants and a control, all killed by `project_budget.sql`.
# "Invoiced time is refused" survived the first run: nothing edited an
# invoiced hour on a closed job until the block annotated one.

m("nothing is asked",
  "closed_project_takes_no_billable_time",
  "  if v_code is not null then",
  "  if false then  -- never refused",
  "-- never refused")

m("an open project is refused too",
  "closed_project_takes_no_billable_time",
  "   where p.id = new.project_id and not p.is_active;",
  "   where p.id = new.project_id;  -- any project",
  "-- any project")

m("non-billable time is refused",
  "closed_project_takes_no_billable_time",
  "  if new.project_id is null or not new.is_billable or new.is_billed then",
  "  if new.project_id is null or new.is_billed then  -- non-billable asked",
  "-- non-billable asked")

m("invoiced time is refused",
  "closed_project_takes_no_billable_time",
  "  if new.project_id is null or not new.is_billable or new.is_billed then",
  "  if new.project_id is null or not new.is_billable then  -- billed asked",
  "-- billed asked")

m("an edit to a counted entry is always let through",
  "closed_project_takes_no_billable_time",
  "     and coalesce(new.amount, 0) <= coalesce(old.amount, 0) then",
  "     and true then  -- raised too",
  "-- raised too")

m("an edit to a counted entry is never let through",
  "closed_project_takes_no_billable_time",
  "  if tg_op = 'UPDATE'\n     and old.project_id is not distinct from new.project_id",
  "  if false  -- every edit asked\n     and old.project_id is not distinct from new.project_id",
  "-- every edit asked")

m("an entry moved from another project counts as already here",
  "closed_project_takes_no_billable_time",
  "     and old.project_id is not distinct from new.project_id\n",
  "     and true  -- moved counts as here\n",
  "-- moved counts as here")

m("a written-off entry counts as already billable",
  "closed_project_takes_no_billable_time",
  "     and old.is_billable and not old.is_billed\n",
  "     and not old.is_billed  -- written-off counts\n",
  "-- written-off counts")

m("an invoiced entry counts as still to bill",
  "closed_project_takes_no_billable_time",
  "     and old.is_billable and not old.is_billed\n",
  "     and old.is_billable  -- billed counts\n",
  "-- billed counts")

m("an equal amount is a raise",
  "closed_project_takes_no_billable_time",
  "     and coalesce(new.amount, 0) <= coalesce(old.amount, 0) then",
  "     and coalesce(new.amount, 0) < coalesce(old.amount, 0) then  -- equal is a raise",
  "-- equal is a raise")

m("refused as a plain exception",
  "closed_project_takes_no_billable_time",
  "      v_code using errcode = '23514';",
  "      v_code using errcode = 'P0001';  -- plain raise",
  "-- plain raise")

m("CONTROL: a comment inside the block",
  "closed_project_takes_no_billable_time",
  "  if v_code is not null then",
  "  if v_code is not null then  -- (control)",
  "(control)")
