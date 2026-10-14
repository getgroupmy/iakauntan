# Mutants for 0881 -- the seven functions that raise one side's
# documents ask the side, through app.require_side.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0881_each_sides_functions_ask_the_side_too.sql \
#       supabase/tests/each_side_by_its_functions.sql \
#       supabase/tests/mutants/each_side_by_its_functions.py

m('the helper never refuses',
  'require_side',
  "  if app.writes_side(p_org_id, p_side) then\n",
  "  if true then  -- never refuses\n",
  '-- never refuses')

m('the helper has one sentence for both sides',
  'require_side',
  "  if p_side = 'purchases' then\n",
  "  if true then  -- one sentence\n",
  '-- one sentence')

m('a quotation is not asked',
  'quote_opportunity',
  "  perform app.require_side(v_o.org_id, 'sales');\n",
  "  null;  -- quote unasked\n",
  '-- quote unasked')

m('a quotation asks the wrong side',
  'quote_opportunity',
  "  perform app.require_side(v_o.org_id, 'sales');\n",
  "  perform app.require_side(v_o.org_id, 'purchases');  -- wrong side\n",
  '-- wrong side')

m('a sales import is not asked',
  'import_sales_transactions',
  "  perform app.require_side(p_org_id, 'sales');\n",
  "  null;  -- sales import unasked\n",
  '-- sales import unasked')

m('a purchase import is not asked',
  'import_purchase_transactions',
  "  perform app.require_side(p_org_id, 'purchases');\n",
  "  null;  -- purchase import unasked\n",
  '-- purchase import unasked')

m('a bill from an e-Invoice is not asked',
  'draft_bill_from_received_einvoice',
  "  perform app.require_side(v_row.org_id, 'purchases');\n",
  "  null;  -- draft unasked\n",
  '-- draft unasked')

m('orders from the forecast are not asked',
  'create_po_from_suggestions',
  "  perform app.require_side(p_org, 'purchases');\n",
  "  null;  -- forecast unasked\n",
  '-- forecast unasked')

m('an intercompany bill is not asked',
  'accept_intercompany_bill',
  "  perform app.require_side(p_org_id, 'purchases');\n",
  "  null;  -- intercompany unasked\n",
  '-- intercompany unasked')

m('a transfer is not asked',
  'transfer_document',
  "  perform app.require_side(v_org, case when v_is_sales then 'sales' else 'purchases' end);\n",
  "  null;  -- transfer unasked\n",
  '-- transfer unasked')

m('a transfer asks the other side',
  'transfer_document',
  "  perform app.require_side(v_org, case when v_is_sales then 'sales' else 'purchases' end);\n",
  "  perform app.require_side(v_org, case when v_is_sales then 'purchases' else 'sales' end);  -- flipped\n",
  '-- flipped')

m('CONTROL: a comment inside the helper',
  'require_side',
  "  if app.writes_side(p_org_id, p_side) then\n",
  "  if app.writes_side(p_org_id, p_side) then  -- control\n",
  '-- control')
