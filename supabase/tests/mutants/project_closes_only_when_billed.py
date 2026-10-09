# Mutants for app.project_closes_only_when_billed (0778) -- the trigger
# that asks close_project's rule of every road into the table: a change
# from open to closed is refused while billable, uninvoiced time is on
# THIS project, naming the amount and the number of entries; reopening,
# and editing a project without closing it, are never refused.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0778_a_project_closes_by_any_road_only_when_billed.sql \
#       supabase/tests/project_budget.sql \
#       supabase/tests/mutants/project_closes_only_when_billed.py
#
# RESULT: 11 mutants and a control. 11 killed by `project_budget.sql`.
#
# Not here, because the harness mutates the function's body and this
# is an attribute of it: SECURITY DEFINER. Flipped by hand to SECURITY
# INVOKER on 9 October and the file still passed -- EQUIVALENT today,
# since `time_entries_select` shows every member of the company every
# entry, so the caller's count and the owner's are the same count. It
# stays DEFINER so a narrower select policy later cannot hide time.

m("time to bill does not stop it",
  "project_closes_only_when_billed",
  "  if v_n > 0 then",
  "  if false then  -- time ignored",
  "-- time ignored")

m("one entry to bill is not enough",
  "project_closes_only_when_billed",
  "  if v_n > 0 then",
  "  if v_n > 1 then  -- two or more",
  "-- two or more")

m("every close is refused",
  "project_closes_only_when_billed",
  "  if v_n > 0 then",
  "  if v_n >= 0 then  -- always",
  "-- always")

m("billed time counts as time to bill",
  "project_closes_only_when_billed",
  "     and not t.is_billed;",
  "     and true;  -- billed counted",
  "-- billed counted")

m("never-billable time counts as time to bill",
  "project_closes_only_when_billed",
  "     and t.is_billable\n",
  "     and true  -- non-billable counted\n",
  "-- non-billable counted")

m("another job's time holds this one open",
  "project_closes_only_when_billed",
  "   where t.project_id = new.id\n",
  "   where t.org_id = new.org_id  -- any job\n",
  "-- any job")

m("an edit that keeps a job open is asked",
  "project_closes_only_when_billed",
  "  if new.is_active or not old.is_active then",
  "  if not old.is_active then  -- open edits asked",
  "-- open edits asked")

m("an edit to a closed job is asked again",
  "project_closes_only_when_billed",
  "  if new.is_active or not old.is_active then",
  "  if new.is_active then  -- closed edits asked",
  "-- closed edits asked")

m("the amount is named in minutes",
  "project_closes_only_when_billed",
  "  select coalesce(sum(t.amount), 0), count(*)",
  "  select coalesce(sum(t.minutes), 0), count(*)  -- minutes",
  "-- minutes")

m("the amount loses its thousands separator",
  "project_closes_only_when_billed",
  "      to_char(round(v_time, 2), 'FM999G999G990D00'), v_n",
  "      to_char(round(v_time, 2), 'FM999999990D00'), v_n  -- no separator",
  "-- no separator")

m("refused as a plain exception",
  "project_closes_only_when_billed",
  "      using errcode = '23514';",
  "      using errcode = 'P0001';  -- plain raise",
  "-- plain raise")

m("CONTROL: a comment inside the block",
  "project_closes_only_when_billed",
  "  if v_n > 0 then",
  "  if v_n > 0 then  -- (control)",
  "(control)")
