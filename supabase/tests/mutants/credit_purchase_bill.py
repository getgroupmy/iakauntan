# Mutants for public.credit_purchase_bill (0440) -- the buying side of
# credit_sales_invoice: a supplier's credit against a bill that reached
# the ledger, never more than is left of a line, shipping and discount
# apportioned by the share credited.
#
# No "empty note left behind" mutant here: the raise that follows
# unwinds the insert, and the function says so in place.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0440_the_delivery_a_full_return_kept_charging.sql \
#       supabase/tests/bill_credit.sql \
#       supabase/tests/mutants/credit_purchase_bill.py
#
# RESULT: 20 mutants and a control. 19 killed by `bill_credit.sql`,
# thirteen only after "The buying side, rule by rule" block there, where
# `credit_note_return.sql` already killed every one of the selling side's.
# Writing that block found `0759`: no bill carrying a header discount
# could be posted at all, so the file had never been able to hold one.
#
# One EQUIVALENT: "a purchase order is credited". `bill_credit_remaining`
# refuses it in the same words before a line is written; noted beside the
# assertion.

m("a purchase order is credited",
  "credit_purchase_bill",
  "   where d.id = p_bill and d.doc_type = 'bill';",
  "   where d.id = p_bill;  -- any document",
  "-- any document")

m("a bill that does not exist is credited in silence",
  "credit_purchase_bill",
  "  if v_doc.id is null then",
  "  if false then  -- no such",
  "-- no such")

m("anybody credits a bill",
  "credit_purchase_bill",
  "  if not app.can_post(v_doc.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a draft bill is credited",
  "credit_purchase_bill",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'partial', 'completed', 'draft') then  -- draft",
  "-- draft")

m("a counter sale cannot be credited",
  "credit_purchase_bill",
  "  if v_doc.status not in ('posted', 'partial', 'completed') then",
  "  if v_doc.status not in ('posted', 'partial') then  -- till refused",
  "-- till refused")

m("the note is not linked to the bill",
  "credit_purchase_bill",
  "    p_bill, p_bill,",
  "    null, p_bill,  -- unlinked",
  "-- unlinked")

m("a reason given is not kept",
  "credit_purchase_bill",
  "    coalesce(nullif(btrim(coalesce(p_reason, '')), ''),",
  "    coalesce(null,  -- reason dropped",
  "-- reason dropped")

m("a note is credited to a different rate",
  "credit_purchase_bill",
  "    v_doc.exchange_rate, 'draft',",
  "    1, 'draft',  -- rate dropped",
  "-- rate dropped")

m("naming no lines credits nothing",
  "credit_purchase_bill",
  "    v_want := case when p_lines is null then v_row.remaining",
  "    v_want := case when p_lines is null then 0  -- nothing",
  "-- nothing")

m("a line not named is credited in full",
  "credit_purchase_bill",
  "                   else coalesce(v_row.asked, 0) end;",
  "                   else coalesce(v_row.asked, v_row.remaining) end;  -- unnamed",
  "-- unnamed")

m("more than is left of a line is credited",
  "credit_purchase_bill",
  "    if v_want > v_row.remaining then",
  "    if false then  -- invented return",
  "-- invented return")

m("a credit line has the bill's price changed",
  "credit_purchase_bill",
  "           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,",
  "           v_want, l.uom_code, 0, l.tax_code_id, l.tax_rate,  -- free",
  "-- free")

m("a credit line loses its tax",
  "credit_purchase_bill",
  "           v_want, l.uom_code, l.unit_price, l.tax_code_id, l.tax_rate,",
  "           v_want, l.uom_code, l.unit_price, null, 0,  -- untaxed",
  "-- untaxed")

m("a part credit takes the whole delivery charge",
  "credit_purchase_bill",
  "    else v_new_net / v_src_net",
  "    else 1  -- whole charge",
  "-- whole charge")

m("a zero-net bill credited whole takes none of its charges",
  "credit_purchase_bill",
  "    when v_src_net = 0 then case when p_lines is null then 1 else 0 end",
  "    when v_src_net = 0 then 0  -- no charges",
  "-- no charges")

m("the delivery charge is not credited",
  "credit_purchase_bill",
  "     set shipping_amount = round(coalesce(v_doc.shipping_amount, 0) * v_share, 2),",
  "     set shipping_amount = 0,  -- kept charging",
  "-- kept charging")

m("the discount is not credited",
  "credit_purchase_bill",
  "         discount_amount = round(coalesce(v_doc.discount_amount, 0) * v_share, 2)\n",
  "         discount_amount = 0  -- discount kept\n",
  "-- discount kept")

m("the totals are not recomputed",
  "credit_purchase_bill",
  "  update public.purchase_document_lines\n     set line_no = line_no where document_id = v_note;",
  "  perform 1;  -- stale totals",
  "-- stale totals")

m("the note is never posted",
  "credit_purchase_bill",
  "  perform app.post_purchase_document_internal(v_note);",
  "  perform 1;  -- draft forever",
  "-- draft forever")

m("a credit line goes to a different account",
  "credit_purchase_bill",
  "           l.is_tax_inclusive, l.warehouse_id, l.account_id",
  "           l.is_tax_inclusive, l.warehouse_id, null  -- default account",
  "-- default account")

m("CONTROL: a comment inside the block",
  "credit_purchase_bill",
  "  if v_want <= 0 then",
  "  if v_want <= 0 then  -- (control)",
  "(control)")
