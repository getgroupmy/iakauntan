# Mutants for 0889 -- a note that names its invoice or bill is not posted
# dated before it, and "credit this" dates the note on the later of today
# and the original's day.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0889_a_note_never_comes_before_what_it_adjusts.sql \
#       supabase/tests/note_after_what_it_adjusts.sql \
#       supabase/tests/mutants/note_after_what_it_adjusts.py

m('a sales note is posted before its invoice again',
  'post_sales_document_internal',
  "  if v_doc.original_invoice_id is not null and v_doc.doc_date < (\n",
  "  if false and v_doc.doc_date < (  -- early note\n",
  '-- early note')

m("a sales note is not posted on its invoice's day either",
  'post_sales_document_internal',
  "  if v_doc.original_invoice_id is not null and v_doc.doc_date < (\n",
  "  if v_doc.original_invoice_id is not null and v_doc.doc_date <= (  -- not that day\n",
  '-- not that day')

m('EQUIVALENT: the named-invoice test dropped',
  'post_sales_document_internal',
  "  if v_doc.original_invoice_id is not null and v_doc.doc_date < (\n",
  "  if v_doc.doc_date < (  -- any note\n",
  '-- any note')

m('a purchase note is posted before its bill again',
  'post_purchase_document_internal',
  "  if v_doc.original_bill_id is not null and v_doc.doc_date < (\n",
  "  if false and v_doc.doc_date < (  -- early note\n",
  '-- early note')

m("a purchase note is not posted on its bill's day either",
  'post_purchase_document_internal',
  "  if v_doc.original_bill_id is not null and v_doc.doc_date < (\n",
  "  if v_doc.original_bill_id is not null and v_doc.doc_date <= (  -- not that day\n",
  '-- not that day')

m('an invoice dated ahead is credited today again',
  'credit_sales_invoice',
  "    greatest(app.today(), v_doc.doc_date), greatest(app.today(), v_doc.doc_date),\n",
  "    least(app.today(), v_doc.doc_date), least(app.today(), v_doc.doc_date),  -- today again\n",
  '-- today again')

m("an invoice is always credited on its own day",
  'credit_sales_invoice',
  "    greatest(app.today(), v_doc.doc_date), greatest(app.today(), v_doc.doc_date),\n",
  "    v_doc.doc_date, v_doc.doc_date,  -- its own day\n",
  '-- its own day')

m('a bill dated ahead is credited today again',
  'credit_purchase_bill',
  "    greatest(app.today(), v_doc.doc_date), greatest(app.today(), v_doc.doc_date),\n",
  "    least(app.today(), v_doc.doc_date), least(app.today(), v_doc.doc_date),  -- today again\n",
  '-- today again')

m("a bill is always credited on its own day",
  'credit_purchase_bill',
  "    greatest(app.today(), v_doc.doc_date), greatest(app.today(), v_doc.doc_date),\n",
  "    v_doc.doc_date, v_doc.doc_date,  -- its own day\n",
  '-- its own day')

m('CONTROL: a comment inside the sales check',
  'post_sales_document_internal',
  "  if v_doc.original_invoice_id is not null and v_doc.doc_date < (\n",
  "  if v_doc.original_invoice_id is not null and v_doc.doc_date < (  -- control\n",
  '-- control')
