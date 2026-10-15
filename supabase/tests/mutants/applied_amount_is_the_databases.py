# Mutants for 0907 -- an invoice's applied_amount is the database's to
# write, like its status, paid figure and balance.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0907_what_is_set_against_an_invoice_is_the_databases.sql \
#       supabase/tests/applied_amount_is_the_databases.sql \
#       supabase/tests/mutants/applied_amount_is_the_databases.py

m('an update of it is not asked',
  'document_state_is_the_databases',
  "  foreach v_col in array array['status', 'paid_amount', 'balance_amount',\n                               'applied_amount'] loop\n",
  "  foreach v_col in array array['status', 'paid_amount', 'balance_amount'] loop  -- as 0781\n",
  '-- as 0781')

m('an insert is not asked about it',
  'document_state_is_the_databases',
  "    if coalesce((to_jsonb(new) ->> 'applied_amount')::numeric, 0) <> 0 then\n",
  "    if false then  -- inserts free\n",
  '-- inserts free')

m('only a positive amount is refused on insert',
  'document_state_is_the_databases',
  "    if coalesce((to_jsonb(new) ->> 'applied_amount')::numeric, 0) <> 0 then\n",
  "    if coalesce((to_jsonb(new) ->> 'applied_amount')::numeric, 0) > 0 then  -- positive\n",
  '-- positive')

m('the column is read off the row, which a bill does not have',
  'document_state_is_the_databases',
  "    if coalesce((to_jsonb(new) ->> 'applied_amount')::numeric, 0) <> 0 then\n",
  "    if coalesce(new.applied_amount, 0) <> 0 then  -- off the row\n",
  '-- off the row')

m('the owner is refused too',
  'document_state_is_the_databases',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then\n",
  "  if pg_trigger_depth() > 1 then  -- everyone\n",
  '-- everyone')

m('CONTROL: a comment inside the function',
  'document_state_is_the_databases',
  "  v_old := to_jsonb(old);\n",
  "  v_old := to_jsonb(old);  -- control\n",
  '-- control')
