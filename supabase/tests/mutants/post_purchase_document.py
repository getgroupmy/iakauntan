# Mutants for app.post_purchase_document_internal -- the journal every
# bill, purchase credit note and purchase debit note posts, and the
# stock movement a bill receives when no goods received note did.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0691_the_matter_a_bill_and_an_invoice_belong_to.sql \
#       supabase/tests/posting_a_bill.sql \
#       supabase/tests/mutants/post_purchase_document.py

# PARTIAL RESULT, 6 October -- the sweep across the other files that
# post bills is still running; this header is rewritten when it ends.
#
#   posting_a_bill.sql alone: 10 of 20 killed, control alive. The ten
#   it misses: a contact's own payable account, the debit-note sign,
#   the exchange rate, a DRAFT receiving note counting as received,
#   the input tax line's tax_amount, the matter on a line, a return
#   off a bill skipping its outward movement, cartons vs pieces, the
#   unit cost's exchange rate, and the line's own warehouse.

F = "post_purchase_document_internal"

m("a contact's own payable account is ignored, so everything goes to 2110",
  F,
  "  select coalesce(c.payable_account_id,",
  "  select coalesce(null::uuid,",
  "coalesce(null::uuid,")

m("input tax is debited to output tax",
  F,
  "  select id into v_tax_account from public.accounts\n"
  "   where org_id = v_doc.org_id and code = '1410';",
  "  select id into v_tax_account from public.accounts\n"
  "   where org_id = v_doc.org_id and code = '2130';  -- input to output",
  "-- input to output")

m("a purchase credit note is posted the same way round as a bill",
  F,
  "  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;",
  "  v_sign := 1;  -- sign dropped",
  "-- sign dropped")

m("a purchase debit note is reversed like a credit note",
  F,
  "  v_sign := case when v_doc.doc_type = 'purchase_credit_note' then -1 else 1 end;",
  "  v_sign := case when v_doc.doc_type in ('purchase_credit_note', 'purchase_debit_note')"
  " then -1 else 1 end;",
  "'purchase_debit_note') then -1")

m("the exchange rate is ignored, so a foreign bill posts at face value",
  F,
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := 1;  -- rate dropped",
  "-- rate dropped")

m("the payable line debits and credits the same amount",
  F,
  "    'debit',       greatest(v_amount, 0),\n"
  "    'credit',      greatest(-v_amount, 0),\n"
  "    'contact_id',  v_doc.contact_id\n",
  "    'debit',       greatest(v_amount, 0),\n"
  "    'credit',      greatest(v_amount, 0),  -- both sides positive\n"
  "    'contact_id',  v_doc.contact_id\n",
  "-- both sides positive")

m("a bill from a POSTED goods received note capitalises the stock again",
  F,
  "  if v_from_grn then\n    select id into v_grni",
  "  v_from_grn := false;  -- grn forgotten\n  if v_from_grn then\n    select id into v_grni",
  "-- grn forgotten")

m("a DRAFT goods received note counts as having received the goods",
  F,
  "       and d.doc_type = 'goods_received'\n"
  "       and d.gl_entry_id is not null);",
  "       and d.doc_type = 'goods_received');  -- draft counts",
  "-- draft counts")

m("a stock item ignores its own inventory account, so it goes to 1310",
  F,
  "        coalesce(v_line.inventory_account_id,",
  "        coalesce(null::uuid,",
  "coalesce(null::uuid,\n")

m("shipping is debited to purchases rather than freight",
  F,
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5400'),\n"
  "      'description', 'Freight and handling',",
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5100'),\n"
  "      'description', 'Freight and handling',  -- freight to 5100",
  "-- freight to 5100")

m("rounding goes to freight",
  F,
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4990'),",
  "      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '5400'),"
  "  -- rounding to 5400",
  "-- rounding to 5400")

m("the input tax line carries no tax amount for the SST return",
  F,
  "      'tax_amount',  abs(v_amount)",
  "      'tax_amount',  0  -- tax amount dropped",
  "-- tax amount dropped")

m("the matter a bill line belongs to is dropped from the journal",
  F,
  "        'matter_id', v_line.matter_id",
  "        'matter_id', null  -- matter dropped",
  "-- matter dropped")

m("a purchase credit note is journalled as a bill",
  F,
  "    case when v_sign = -1 then 'purchase_credit_note'::app.journal_source",
  "    case when false then 'purchase_credit_note'::app.journal_source  -- source dropped",
  "-- source dropped")

m("a return off a bill skips its own outward movement",
  F,
  "      on d.id = m.source_id and d.doc_type = 'goods_received'",
  "      on d.id = m.source_id  -- any parent",
  "-- any parent")

m("a bill whose goods a receiving note already shelved shelves them again",
  F,
  "  if v_received = 0 then",
  "  if true then  -- always receive",
  "-- always receive")

m("a purchase credit note moves stock IN",
  F,
  "           case when v_sign = 1 then 'purchase_receipt' else 'purchase_return' end",
  "           'purchase_receipt'  -- type fixed\n",
  "-- type fixed")

m("cartons go on the shelf as cartons, not pieces",
  F,
  "           v_sign * coalesce(l.base_quantity, l.quantity),",
  "           v_sign * l.quantity,  -- base unit dropped",
  "-- base unit dropped")

m("the unit cost is in the bill's currency, not ringgit",
  F,
  "                else round(l.line_subtotal * v_rate\n",
  "                else round(l.line_subtotal  -- cost rate dropped\n",
  "-- cost rate dropped")

m("the stock goes to whichever warehouse, not the line's",
  F,
  "           coalesce(l.warehouse_id, (select id from public.warehouses",
  "           coalesce(null::uuid, (select id from public.warehouses",
  "coalesce(null::uuid, (select id from public.warehouses")

m("CONTROL -- a comment inside the function block",
  F,
  "  v_rate := coalesce(v_doc.exchange_rate, 1);",
  "  v_rate := coalesce(v_doc.exchange_rate, 1);"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
