# Mutants for 0898 -- a stock transfer is received on the later of today
# and its own date, movement and journal both.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0898_a_transfer_arrives_no_earlier_than_it_leaves.sql \
#       supabase/tests/transfer_arrives_after_it_leaves.sql \
#       supabase/tests/mutants/transfer_arrives_after_it_leaves.py

m('received today again',
  'receive_stock_transfer',
  "  v_on := greatest(app.today(), v_t.transfer_date);\n",
  "  v_on := app.today();  -- today only\n",
  '-- today only')

m("always on the transfer's own date",
  'receive_stock_transfer',
  "  v_on := greatest(app.today(), v_t.transfer_date);\n",
  "  v_on := v_t.transfer_date;  -- its own date\n",
  '-- its own date')

m('the movement in is dated today',
  'receive_stock_transfer',
  "        v_on, 'transfer_in', v_line.item_id,\n",
  "        app.today(), 'transfer_in', v_line.item_id,  -- movement today\n",
  '-- movement today')

m('the journal is dated today',
  'receive_stock_transfer',
  "      v_t.org_id, v_on, 'stock_movement', v_lines,\n",
  "      v_t.org_id, app.today(), 'stock_movement', v_lines,  -- journal today\n",
  '-- journal today')

m('CONTROL: a comment inside the function',
  'receive_stock_transfer',
  "  -- 0898: it arrives no earlier than it leaves. Sending posts on the\n",
  "  -- 0898: it arrives no earlier than it leaves. Sending posts on the\n  -- control\n",
  '-- control')
