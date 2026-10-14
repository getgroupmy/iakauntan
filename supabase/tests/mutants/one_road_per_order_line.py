# Mutants for 0903 -- on a purchase order, a goods received note and a
# bill raised straight from the order draw on the one quantity.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0903_one_road_per_order_line.sql \
#       supabase/tests/one_road_per_order_line.sql \
#       supabase/tests/mutants/one_road_per_order_line.py

m('each road counts only itself again',
  'transfer_document',
  "        when v_source_type = 'purchase_order'\n"
  "          then r.quantity_received + r.quantity_billed\n",
  "        -- each road its own\n",
  '-- each road its own')

m('an order counts only what its notes took',
  'transfer_document',
  "          then r.quantity_received + r.quantity_billed\n",
  "          then r.quantity_received  -- notes only\n",
  '-- notes only')

m('the refusal does not say where to go',
  'transfer_document',
  "    if not v_is_sales and v_source_type = 'purchase_order'\n",
  "    if false and v_source_type = 'purchase_order'  -- no pointer\n",
  '-- no pointer')

m('the pointer asks the wrong road',
  'transfer_document',
  "                      and case p_target_type when 'bill' then l.quantity_received\n",
  "                      and case p_target_type when 'goods_received' then l.quantity_received  -- crossed\n",
  '-- crossed')

m('the dialog offers what the note took',
  'transfer_outstanding',
  "             greatest(l.quantity - case\n"
  "               when v_type = 'purchase_order'\n",
  "             greatest(l.quantity - case\n"
  "               when false  -- dialog\n",
  '-- dialog')

m('the dialog says nothing was taken',
  'transfer_outstanding',
  "             case when v_type = 'purchase_order'\n",
  "             case when false  -- taken\n",
  '-- taken')

m('an order split between the roads is never done',
  'refresh_purchase_progress',
  "                and l.quantity_received + l.quantity_billed < l.quantity)",
  "                and greatest(l.quantity_received, l.quantity_billed) < l.quantity)  -- the larger",
  '-- the larger')

m('CONTROL: a comment inside the function',
  'transfer_document',
  "    if not v_is_sales and v_source_type = 'purchase_order'\n",
  "    -- control\n    if not v_is_sales and v_source_type = 'purchase_order'\n",
  '-- control')
