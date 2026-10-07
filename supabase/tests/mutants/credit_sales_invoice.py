# Mutants for public.credit_sales_invoice (0440) -- a credit note against
# an invoice that has reached the ledger: never more than is left of a
# line, the header charges apportioned by the share credited, and linked
# to the invoice it credits.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0440_the_delivery_a_full_return_kept_charging.sql \
#       supabase/tests/credit_note_return.sql \
#       supabase/tests/mutants/credit_sales_invoice.py
#
# RESULT: 21 mutants and a control, all killed by `credit_note_return.sql`
# as it stood -- 0440's header had measured four of them.

m("a quotation is credited",
  "credit_sales_invoice",
  "   where d.id = p_invoice and d.doc_type = 'invoice';",
  "   where d.id = p_invoice;  -- any document",
  "-- any document")

m("an invoice that does not exist is credited in silence",
  "credit_sales_invoice",
  "  if v_doc.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody credits an invoice",
  "credit_sales_invoice",
  "  if not app.can_post(v_doc.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a draft invoice is credited",
  "credit_sales_invoice",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'partial', 'completed', 'draft') then  -- draft",
  "-- draft")

m("a counter sale cannot be credited",
  "credit_sales_invoice",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'partial') then  -- till refused",
  "-- till refused")

m("the note is not linked to the invoice",
  "credit_sales_invoice",
  "    p_invoice, p_invoice,",
  "    null, p_invoice,  -- unlinked",
  "-- unlinked")

m("a reason given is not kept",
  "credit_sales_invoice",
  "    coalesce(nullif(btrim(coalesce(p_reason, '')), ''),",
  "    coalesce(null,  -- reason dropped",
  "-- reason dropped")

m("a note is credited to a different rate",
  "credit_sales_invoice",
  "    v_doc.contact_id, v_doc.currency, v_doc.exchange_rate, 'draft',",
  "    v_doc.contact_id, v_doc.currency, 1, 'draft',  -- rate dropped",
  "-- rate dropped")

m("naming no lines credits nothing",
  "credit_sales_invoice",
  "    v_want := case when p_lines is null then v_row.remaining",
  "    v_want := case when p_lines is null then 0  -- nothing",
  "-- nothing")

m("a line not named is credited in full",
  "credit_sales_invoice",
  "                   else coalesce(v_row.asked, 0) end;",
  "                   else coalesce(v_row.asked, v_row.remaining) end;  -- unnamed",
  "-- unnamed")

m("more than is left of a line is credited",
  "credit_sales_invoice",
  "    if v_want > v_row.remaining then",
  "    if false then  -- invented return",
  "-- invented return")

m("a credit line has the invoice's price changed",
  "credit_sales_invoice",
  "           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,",
  "           v_want, l.uom_code, 0, l.tax_code_id, l.tax_rate,  -- free",
  "-- free")

m("a credit line loses its tax",
  "credit_sales_invoice",
  "           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,",
  "           v_want, l.uom_code, l.unit_price, null, 0,  -- untaxed",
  "-- untaxed")

m("an empty note is left behind",
  "credit_sales_invoice",
  "  if v_n = 0 then",
  "  if false then  -- empty note",
  "-- empty note")

m("a part credit takes the whole delivery charge",
  "credit_sales_invoice",
  "    else v_new_net / v_src_net",
  "    else 1  -- whole charge",
  "-- whole charge")

m("a zero-net invoice credited whole takes none of its charges",
  "credit_sales_invoice",
  "    when v_src_net = 0 then case when p_lines is null then 1 else 0 end",
  "    when v_src_net = 0 then 0  -- no charges",
  "-- no charges")

m("the delivery charge is not credited",
  "credit_sales_invoice",
  "     set shipping_amount = round(coalesce(v_doc.shipping_amount, 0) * v_share, 2),",
  "     set shipping_amount = 0,  -- kept charging",
  "-- kept charging")

m("the discount is not credited",
  "credit_sales_invoice",
  "         discount_amount = round(coalesce(v_doc.discount_amount, 0) * v_share, 2),",
  "         discount_amount = 0,  -- discount kept",
  "-- discount kept")

m("the service charge is not credited",
  "credit_sales_invoice",
  "           round(coalesce(v_doc.service_charge_amount, 0) * v_share, 2)",
  "           0  -- service kept",
  "-- service kept")

m("the totals are not recomputed",
  "credit_sales_invoice",
  "  update public.sales_document_lines\n     set line_no = line_no where document_id = v_note;",
  "  perform 1;  -- stale totals",
  "-- stale totals")

m("the note is never posted",
  "credit_sales_invoice",
  "  perform app.post_sales_document_internal(v_note);",
  "  perform 1;  -- draft forever",
  "-- draft forever")

m("CONTROL: a comment inside the block",
  "credit_sales_invoice",
  "  if v_n = 0 then",
  "  if v_n = 0 then  -- (control)",
  "(control)")
