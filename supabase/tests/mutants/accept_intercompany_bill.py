# Mutants for public.accept_intercompany_bill (0759, restating 0439's) --
# the buying company's bill raised from a group company's invoice: the
# same money, the same terms, the seller's number, the delivery charge.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0759_a_bills_discount_comes_off_its_costs.sql \
#       supabase/tests/intercompany_billing.sql \
#       supabase/tests/mutants/accept_intercompany_bill.py
#
# RESULT: 8 mutants and a control, all killed by `intercompany_billing.sql`.
# Five only after additions there: the delivery charge (0759), and four
# guards whose refusals were matched by SQLSTATE while another refusal
# behind each answered in its place -- plus a due date the payment terms
# would have recomputed to the same day.

m("the delivery charge is left behind (0439's shape)",
  "accept_intercompany_bill",
  "         d.shipping_amount\n    from public.sales_documents d",
  "         0  -- no delivery\n    from public.sales_documents d",
  "-- no delivery")

m("anybody raises the bill",
  "accept_intercompany_bill",
  "  if not app.can_write(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an invoice not addressed here is billed",
  "accept_intercompany_bill",
  "  if not found then",
  "  if false then  -- not ours",
  "-- not ours")

m("an invoice is billed twice",
  "accept_intercompany_bill",
  "  if v_row.already_billed then",
  "  if false then  -- twice",
  "-- twice")

m("a bill is owed to nobody",
  "accept_intercompany_bill",
  "  if v_row.supplier_contact_id is null then",
  "  if false then  -- nobody",
  "-- nobody")

m("the due date is not carried",
  "accept_intercompany_bill",
  "         d.due_date, d.payment_term_id, v_supplier,",
  "         null, d.payment_term_id, v_supplier,  -- undated",
  "-- undated")

m("the seller's number is not carried",
  "accept_intercompany_bill",
  "         d.doc_no, d.doc_date,\n",
  "         null, d.doc_date,  -- unnumbered\n",
  "-- unnumbered")

m("the tax code is carried by id, not by code",
  "accept_intercompany_bill",
  "             and t.code = (select s.code from public.tax_codes s\n                            where s.id = l.tax_code_id)),",
  "             and t.id = l.tax_code_id),  -- by id",
  "-- by id")

m("CONTROL: a comment inside the block",
  "accept_intercompany_bill",
  "  if v_row.already_billed then",
  "  if v_row.already_billed then  -- (control)",
  "(control)")
