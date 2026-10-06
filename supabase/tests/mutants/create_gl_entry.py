# Mutants for public.create_gl_entry -- the API's door to the ledger:
# a permission check and a pass-through to app.create_gl_entry_internal.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0056_internal_posting_path.sql \
#       supabase/tests/manual_journal.sql \
#       supabase/tests/mutants/create_gl_entry.py

m("anybody who can call it may post, whatever their role",
  "create_gl_entry",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- permission unchecked",
  "-- permission unchecked")

m("the permission is checked against the wrong company",
  "create_gl_entry",
  "  if not app.can_post(p_org_id) then",
  "  if not app.can_post((select org_id from public.org_members"
  " where user_id = auth.uid() limit 1)) then  -- any of mine",
  "-- any of mine")

m("the currency is dropped on the way through",
  "create_gl_entry",
  "    p_source_table, p_source_id, p_reference, p_currency, p_exchange_rate);",
  "    p_source_table, p_source_id, p_reference, 'MYR', p_exchange_rate);  -- currency lost",
  "-- currency lost")

m("the rate is dropped on the way through",
  "create_gl_entry",
  "    p_source_table, p_source_id, p_reference, p_currency, p_exchange_rate);",
  "    p_source_table, p_source_id, p_reference, p_currency, 1);  -- rate lost",
  "-- rate lost")

m("the reference is dropped on the way through",
  "create_gl_entry",
  "    p_source_table, p_source_id, p_reference, p_currency, p_exchange_rate);",
  "    p_source_table, p_source_id, null, p_currency, p_exchange_rate);  -- reference lost",
  "-- reference lost")

m("CONTROL -- a comment inside the function block",
  "create_gl_entry",
  "  return app.create_gl_entry_internal(",
  "  -- CONTROL: this cannot change a number.\n  return app.create_gl_entry_internal(",
  "-- CONTROL: this cannot change a number.")
