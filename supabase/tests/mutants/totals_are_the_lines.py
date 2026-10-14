# Mutants for 0905 -- a sales or purchase document's subtotal, tax,
# rounding, total and base total are worked out from its lines.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0905_a_documents_totals_are_its_lines.sql \
#       supabase/tests/totals_are_the_lines.sql \
#       supabase/tests/mutants/totals_are_the_lines.py

m('nobody is asked',
  'document_totals_are_its_lines',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then\n",
  "  if true then  -- nobody asked\n",
  '-- nobody asked')

m('the owner is refused too',
  'document_totals_are_its_lines',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then\n",
  "  if pg_trigger_depth() > 1 then  -- everyone\n",
  '-- everyone')

m('an insert is not asked',
  'document_totals_are_its_lines',
  "    if tg_op = 'INSERT' and (v_new ->> v_col)::numeric <> 0 then\n",
  "    if false then  -- inserts free\n",
  '-- inserts free')

m('an update is not asked',
  'document_totals_are_its_lines',
  "    if tg_op = 'UPDATE' and (v_new -> v_col) is distinct from (v_old -> v_col) then\n",
  "    if false then  -- updates free\n",
  '-- updates free')

m('the tax is left off the list',
  'document_totals_are_its_lines',
  "  foreach v_col in array array['subtotal', 'tax_amount', 'rounding_amount',\n",
  "  foreach v_col in array array['subtotal', 'rounding_amount',  -- no tax\n",
  '-- no tax')

m('the total in ringgit is left off the list',
  'document_totals_are_its_lines',
  "                               'total_amount', 'base_total_amount'] loop\n",
  "                               'total_amount'] loop  -- no base\n",
  '-- no base')

m('CONTROL: a comment inside the function',
  'document_totals_are_its_lines',
  "  if tg_op = 'UPDATE' then\n",
  "  -- control\n  if tg_op = 'UPDATE' then\n",
  '-- control')
