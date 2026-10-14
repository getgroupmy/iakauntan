# Mutants for 0901 -- a client may not write the link from a credit note
# to the invoice or bill it credits; the credit functions may.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0901_a_credit_is_linked_by_crediting.sql \
#       supabase/tests/credit_linked_by_crediting.sql \
#       supabase/tests/mutants/credit_linked_by_crediting.py

m('the credit functions are refused too',
  'a_credit_is_linked_by_crediting',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then\n",
  "  if pg_trigger_depth() > 1 then  -- everyone\n",
  '-- everyone')

m('nobody is asked',
  'a_credit_is_linked_by_crediting',
  "     or pg_trigger_depth() > 1 then\n",
  "     or pg_trigger_depth() > 0 then  -- nobody\n",
  '-- nobody')

m('an unchanged link is refused on update',
  'a_credit_is_linked_by_crediting',
  "  if tg_op = 'UPDATE' and v_new is not distinct from (to_jsonb(old) ->> v_col) then\n",
  "  if false then  -- every update\n",
  '-- every update')

m('a note with no link is refused',
  'a_credit_is_linked_by_crediting',
  "  if tg_op = 'INSERT' and v_new is null then\n",
  "  if false then  -- every insert\n",
  '-- every insert')

m('the wrong column is read',
  'a_credit_is_linked_by_crediting',
  "  v_col text := tg_argv[0];\n",
  "  v_col text := tg_argv[1];  -- the label\n",
  '-- the label')

m('a bill is called an invoice',
  'a_credit_is_linked_by_crediting',
  "    tg_argv[1], tg_argv[1], tg_argv[1]\n",
  "    'invoice', 'invoice', 'invoice'  -- always invoice\n",
  '-- always invoice')

m('CONTROL: a comment inside the function',
  'a_credit_is_linked_by_crediting',
  "  if tg_op = 'INSERT' and v_new is null then\n",
  "  -- control\n  if tg_op = 'INSERT' and v_new is null then\n",
  '-- control')
