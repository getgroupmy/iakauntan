# Mutants for public.draft_bill_from_received_einvoice (0650) -- a bill
# drafted from an e-Invoice a supplier sent us: once, to a linked
# supplier, the right purchase document for the type, in a currency we
# know, with the supplier's own number and date, line discounts and
# charges where they belong, and a note when our total and theirs differ.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0650_the_invoice_a_supplier_sent_us.sql \
#       supabase/tests/received_einvoice.sql \
#       supabase/tests/mutants/draft_bill_from_received_einvoice.py
#
# RESULT: 15 mutants and a control, all killed by `received_einvoice.sql`.
# Four only after its rule-by-rule block: a missing document, a debit
# note, the bill dated by the supplier, and a line's own discount.

m("a document that does not exist is not said so",
  "draft_bill_from_received_einvoice",
  "    raise exception 'No such received e-Invoice' using errcode = 'P0002';",
  "    raise notice 'No such received e-Invoice';  -- said only",
  "-- said only")

m("anybody drafts a bill",
  "draft_bill_from_received_einvoice",
  "  if not app.can_write(v_row.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a document already on a bill is billed again",
  "draft_bill_from_received_einvoice",
  "  if v_row.bill_id is not null then",
  "  if false then  -- billed twice",
  "-- billed twice")

m("a bill is drafted with no supplier",
  "draft_bill_from_received_einvoice",
  "  if v_row.contact_id is null then",
  "  if false then  -- no supplier",
  "-- no supplier")

m("a credit note becomes a bill",
  "draft_bill_from_received_einvoice",
  "    when '02' then 'purchase_credit_note'",
  "    when '02' then 'bill'  -- wrong sign",
  "-- wrong sign")

m("a debit note becomes a bill",
  "draft_bill_from_received_einvoice",
  "    when '03' then 'purchase_debit_note'",
  "    when '03' then 'bill'  -- not a debit note",
  "-- not a debit note")

m("a type with nothing to become is guessed at",
  "draft_bill_from_received_einvoice",
  "  if v_type is null then",
  "  if false then  -- guessed",
  "-- guessed")

m("a currency nobody knows is taken",
  "draft_bill_from_received_einvoice",
  "  if v_row.currency is null\n     or not exists (select 1 from public.ref_currencies where code = v_row.currency)\n  then",
  "  if false  -- any currency\n  then",
  "-- any currency")

m("the bill is dated the day it was drafted",
  "draft_bill_from_received_einvoice",
  "    coalesce(v_row.issue_date, app.today()),",
  "    app.today(),  -- drafted day",
  "-- drafted day")

m("the supplier's own number is lost",
  "draft_bill_from_received_einvoice",
  "    v_row.doc_no, v_row.issue_date,",
  "    null, v_row.issue_date,  -- no supplier number",
  "-- no supplier number")

m("a charge stated only on the document is lost",
  "draft_bill_from_received_einvoice",
  "    v_row.total_charges,\n",
  "    0,  -- charges lost\n",
  "-- charges lost")

m("a line's discount is lost",
  "draft_bill_from_received_einvoice",
  "      v_line.discount_amount, v_line.tax_rate, false);",
  "      0, v_line.tax_rate, false);  -- discount lost",
  "-- discount lost")

m("a line's tax is lost",
  "draft_bill_from_received_einvoice",
  "      v_line.discount_amount, v_line.tax_rate, false);",
  "      v_line.discount_amount, 0, false);  -- untaxed",
  "-- untaxed")

m("a difference from what the supplier asked is not noted",
  "draft_bill_from_received_einvoice",
  "  if abs(v_diff) > 0.005 then",
  "  if false then  -- unnoted",
  "-- unnoted")

m("the document is not marked billed",
  "draft_bill_from_received_einvoice",
  "     set bill_id = v_bill, status = 'billed'",
  "     set bill_id = v_bill  -- unmarked",
  "-- unmarked")

m("CONTROL: a comment inside the block",
  "draft_bill_from_received_einvoice",
  "  if v_row.contact_id is null then",
  "  if v_row.contact_id is null then  -- (control)",
  "(control)")
