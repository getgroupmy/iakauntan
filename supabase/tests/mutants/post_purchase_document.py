# Mutants for app.post_purchase_document_internal -- the journal every
# bill, purchase credit note and purchase debit note posts, and the
# stock movement a bill receives when no goods received note did.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0691_the_matter_a_bill_and_an_invoice_belong_to.sql \
#       supabase/tests/posting_a_bill.sql \
#       supabase/tests/mutants/post_purchase_document.py

# RESULT, 6 October: 20 mutants, ALL KILLED, control alive, across
# nine files. posting_a_bill.sql alone killed 10 before this sweep and
# 14 after it; the rest die elsewhere:
#
#   control_accounts.sql     a contact's own payable account ignored
#   document_types.sql       a purchase debit note posted backwards
#   goods_received.sql       a DRAFT receiving note counted as received
#   bill_credit.sql          a return off a bill skipping its outward
#                            movement (also goods_received.sql)
#   multi_uom_documents.sql  cartons shelved as cartons, not pieces
#   matter_on_a_document.sql the matter dropped from a bill line
#   multicurrency.sql        the journal's exchange rate (now also here)
#
# THREE WERE UNASSERTED ANYWHERE, across 23 files, and are now asserted
# in posting_a_bill.sql:
#
#   - THE STOCK'S UNIT COST IGNORING THE EXCHANGE RATE. Every bill in
#     every file was in ringgit at a rate of one, where the right cost
#     and the wrong one are the same number. A dollar bill valued the
#     shelf -- and cost of sales -- at a fifth of what was paid, with a
#     journal that balanced. Section 6 buys in USD at 4.70.
#   - THE INPUT-TAX LINE'S tax_amount. Nothing in the database reads it
#     back (the SST return reads the documents), but the API serves it.
#   - THE LINE'S OWN WAREHOUSE. Killed only as a null-column CRASH in
#     bill_credit.sql, whose fixture has no default store. posting_a_
#     bill.sql had one store, the default, and put every line in it --
#     so the line's warehouse and the fallback were the same row.
#     CLAUDE.md's first trap. The lines now name a non-default store.

m("a contact's own payable account is ignored, so everything goes to 2110",
  "post_purchase_document_internal",
  "  select coalesce(c.payable_account_id,",
  "  select coalesce(null::uuid,",
  "coalesce(null::uuid,")

m("input tax is debited to output tax",
  "post_purchase_document_internal",
  "  select id into v_tax_account from public.accounts\n"
  "   where org_id = v_doc.org_id and code = '1410';",
  "  select id into v_tax_account from public.accounts\n"
  "   where org_id = v_doc.org_id and code = '2130';  -- input to output",
  "-- input to output")

m("a purchase credit note is posted the same way round as a bill",
  "post_purchase_document_internal",
  "  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;",
  "  v_sign := 1;  -- sign dropped",
  "-- sign dropped")

m("a purchase debit note is reversed like a credit note",
  "post_purchase_document_internal",
  "  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;",
  "  v_sign := case when v_doc.doc_type in ('purchase_credit_note', 'purchase_debit_note')"
  " then -1 else 1 end;",
  "'purchase_debit_note') then -1")

m("the exchange rate is ignored, so a foreign bill posts at face value",
  "post_purchase_document_internal",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := 1;  -- rate dropped",
  "-- rate dropped")

m("the payable line debits and credits the same amount",
  "post_purchase_document_internal",
  "    'debit',       greatest(v_amount, 0),\n"
  "    'credit',      greatest(-v_amount, 0),\n"
  "    'contact_id',  v_doc.contact_id\n",
  "    'debit',       greatest(v_amount, 0),\n"
  "    'credit',      greatest(v_amount, 0),  -- both sides positive\n"
  "    'contact_id',  v_doc.contact_id\n",
  "-- both sides positive")

m("a bill from a POSTED goods received note capitalises the stock again",
  "post_purchase_document_internal",
  "  if v_from_grn then\n    select id into v_grni",
  "  v_from_grn := false;  -- grn forgotten\n  if v_from_grn then\n    select id into v_grni",
  "-- grn forgotten")

m("a DRAFT goods received note counts as having received the goods",
  "post_purchase_document_internal",
  "       and d.doc_type = 'goods_received'\n"
  "       and d.gl_entry_id is not null);",
  "       and d.doc_type = 'goods_received');  -- draft counts",
  "-- draft counts")

m("a stock item ignores its own inventory account, so it goes to 1310",
  "post_purchase_document_internal",
  "        coalesce(v_line.inventory_account_id,",
  "        coalesce(null::uuid,",
  "coalesce(null::uuid,\n")

m("shipping is debited to purchases rather than freight",
  "post_purchase_document_internal",
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5400'),\n"
  "      'description', 'Freight and handling',",
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5100'),\n"
  "      'description', 'Freight and handling',  -- freight to 5100",
  "-- freight to 5100")

m("rounding goes to freight",
  "post_purchase_document_internal",
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4990'),",
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5400'),"
  "  -- rounding to 5400",
  "-- rounding to 5400")

m("the input tax line carries no tax amount for the SST return",
  "post_purchase_document_internal",
  "      'tax_amount',  abs(v_amount)",
  "      'tax_amount',  0  -- tax amount dropped",
  "-- tax amount dropped")

m("the matter a bill line belongs to is dropped from the journal",
  "post_purchase_document_internal",
  "        'matter_id', v_line.matter_id",
  "        'matter_id', null  -- matter dropped",
  "-- matter dropped")

m("a purchase credit note is journalled as a bill",
  "post_purchase_document_internal",
  "    case when v_sign = -1 then 'purchase_credit_note'::app.journal_source",
  "    case when false then 'purchase_credit_note'::app.journal_source  -- source dropped",
  "-- source dropped")

m("a return off a bill skips its own outward movement",
  "post_purchase_document_internal",
  "      on d.id = m.source_id and d.doc_type = 'goods_received'",
  "      on d.id = m.source_id  -- any parent",
  "-- any parent")

m("a bill whose goods a receiving note already shelved shelves them again",
  "post_purchase_document_internal",
  "  if v_received = 0 then",
  "  if true then  -- always receive",
  "-- always receive")

m("a purchase credit note moves stock IN",
  "post_purchase_document_internal",
  "           case when v_sign = 1 then 'purchase_receipt' else 'purchase_return' end",
  "           'purchase_receipt'  -- type fixed\n",
  "-- type fixed")

m("cartons go on the shelf as cartons, not pieces",
  "post_purchase_document_internal",
  "           v_sign * coalesce(l.base_quantity, l.quantity),",
  "           v_sign * l.quantity,  -- base unit dropped",
  "-- base unit dropped")

m("the unit cost is in the bill's currency, not ringgit",
  "post_purchase_document_internal",
  "                else round(l.line_subtotal * v_rate\n",
  "                else round(l.line_subtotal  -- cost rate dropped\n",
  "-- cost rate dropped")

m("the stock goes to whichever warehouse, not the line's",
  "post_purchase_document_internal",
  "           coalesce(l.warehouse_id, (select id from public.warehouses",
  "           coalesce(null::uuid, (select id from public.warehouses",
  "coalesce(null::uuid, (select id from public.warehouses")

m("CONTROL -- a comment inside the function block",
  "post_purchase_document_internal",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
