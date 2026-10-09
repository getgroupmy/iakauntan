# Mutants for app.matter_closes_only_when_empty (0775) -- the trigger
# that asks close_matter's two rules of every road into the table: a
# change INTO closed or archived is refused while the client account
# holds money for THIS matter (void transactions not counted), and a
# closing date before the opening date is refused; leaving closed is
# never refused.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0775_a_matter_closes_by_any_road_only_when_empty.sql \
#       supabase/tests/matter_closing.sql \
#       supabase/tests/mutants/matter_closes_only_when_empty.py
#
# RESULT: 7 mutants and a control. 6 killed by `matter_closing.sql`.
#
# One is EQUIVALENT since `0776`: "a closed file is asked about money
# again on every change". It was killed by a late receipt posted to a
# closed file, which then had its date corrected; `0776` refuses that
# receipt, and every other road onto a closed file, so a closed or
# archived matter can no longer hold money and asking again finds none.

m("archiving is not asked about the money",
  "matter_closes_only_when_empty",
  "  if new.status not in ('closed', 'archived') then",
  "  if new.status not in ('closed') then  -- archive unguarded",
  "-- archive unguarded")

m("a closing date before the opening date is taken",
  "matter_closes_only_when_empty",
  "  if new.closed_date is not null and new.closed_date < new.opened_date then",
  "  if false then  -- any date",
  "-- any date")

m("a matter cannot close on the day it opened",
  "matter_closes_only_when_empty",
  "  if new.closed_date is not null and new.closed_date < new.opened_date then",
  "  if new.closed_date is not null and new.closed_date <= new.opened_date then  -- not the same day",
  "-- not the same day")

m("money held does not stop it",
  "matter_closes_only_when_empty",
  "  if round(v_funds, 2) <> 0 then",
  "  if false then  -- money ignored",
  "-- money ignored")

m("a void transaction counts as money held",
  "matter_closes_only_when_empty",
  "   where t.matter_id = new.id and t.status <> 'void';",
  "   where t.matter_id = new.id;  -- void counted",
  "-- void counted")

m("another matter's money holds this one open",
  "matter_closes_only_when_empty",
  "   where t.matter_id = new.id and t.status <> 'void';",
  "   where t.org_id = new.org_id and t.status <> 'void';  -- any matter",
  "-- any matter")

m("a closed file is asked about money again on every change",
  "matter_closes_only_when_empty",
  "  if old.status is not distinct from new.status then\n    return new;\n  end if;",
  "  if false then  -- asked every time\n    return new;\n  end if;",
  "-- asked every time")

m("CONTROL: a comment inside the block",
  "matter_closes_only_when_empty",
  "  if round(v_funds, 2) <> 0 then",
  "  if round(v_funds, 2) <> 0 then  -- (control)",
  "(control)")
