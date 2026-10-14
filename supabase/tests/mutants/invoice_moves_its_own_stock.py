# Mutants for 0902 -- an invoice raised from a delivery order moves its
# own stock, as every other invoice does.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0902_an_invoice_moves_its_own_stock.sql \
#       supabase/tests/invoice_moves_its_own_stock.sql \
#       supabase/tests/mutants/invoice_moves_its_own_stock.py

m('the delivery-order skip is back',
  'post_sales_document_internal',
  "   where l.document_id = p_id\n     and l.line_type = 'item'\n",
  "   where l.document_id = p_id\n     and l.line_type = 'item'\n"
  "     and not exists (select 1 from public.sales_documents d\n"
  "                      where d.id = v_doc.parent_id\n"
  "                        and d.doc_type = 'delivery_order')  -- skip a DO\n",
  '-- skip a DO')

m('any document with a parent skips',
  'post_sales_document_internal',
  "   where l.document_id = p_id\n     and l.line_type = 'item'\n",
  "   where l.document_id = p_id\n     and l.line_type = 'item'\n"
  "     and v_doc.parent_id is null  -- orphans only\n",
  '-- orphans only')

m('the goods come back on to the shelf',
  'post_sales_document_internal',
  "         -v_sign * coalesce(l.base_quantity, l.quantity),\n",
  "         v_sign * coalesce(l.base_quantity, l.quantity),  -- wrong way\n",
  '-- wrong way')

m('CONTROL: a comment inside the function',
  'post_sales_document_internal',
  "   where l.document_id = p_id\n     and l.line_type = 'item'\n",
  "   where l.document_id = p_id  -- control\n     and l.line_type = 'item'\n",
  '-- control')
