# Mutants for 0909 -- a client's change of a document's discount,
# shipping or rate on the header works its totals out again.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0909_a_header_change_moves_the_totals.sql \
#       supabase/tests/a_header_change_moves_the_totals.sql \
#       supabase/tests/mutants/a_header_change_moves_the_totals.py

m('nothing is worked out again',
  'recalc_totals_on_a_clients_header_change',
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if true then  -- nobody\n",
  '-- nobody')

m('the owner''s own writes are worked over too',
  'recalc_totals_on_a_clients_header_change',
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if false then  -- everyone\n",
  '-- everyone')

m('an invoice is worked out as if it were a bill',
  'recalc_totals_on_a_clients_header_change',
  "    perform app.recalc_sales_totals_for(new.id);\n",
  "    perform app.recalc_purchase_totals_for(new.id);  -- wrong side\n",
  '-- wrong side')

m('a bill is worked out as if it were an invoice',
  'recalc_totals_on_a_clients_header_change',
  "    perform app.recalc_purchase_totals_for(new.id);\n  end if;",
  "    perform app.recalc_sales_totals_for(new.id);  -- wrong side\n  end if;",
  '-- wrong side')

m('CONTROL: a comment inside the function',
  'recalc_totals_on_a_clients_header_change',
  "  return null;\nend;",
  "  return null;  -- control\nend;",
  '-- control')
