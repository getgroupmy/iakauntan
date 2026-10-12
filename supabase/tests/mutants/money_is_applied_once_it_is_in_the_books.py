# Mutants for 0832 -- the knock-off doors refuse money or a document not
# in the books, and record_settlement records, applies and posts in one
# transaction, applying before posting.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0832_money_is_applied_once_it_is_in_the_books.sql \
#       supabase/tests/settlement_in_one_go.sql \
#       supabase/tests/mutants/money_is_applied_once_it_is_in_the_books.py
#
# The three flows `0832` restates to apply through the bodies --
# record_group_payment, settle_from_client_account and
# demo_practice_books -- keep their mutants in their own files
# (`record_group_payment.py`, `client_money_crossing.py`,
# `demo_practice.py`), each against the file that calls it; each has
# one more there now, applying through the door instead, and each is
# killed.
#
# RESULT, 12 October: 17 of 17 killed by settlement_in_one_go.sql, the
# control surviving.

# -- allocate_with_discount -------------------------------------------
m('the receipt door is never asked',
  'allocate_with_discount',
  '  if v_rcp.id is not null and v_inv.id is not null\n     and v_inv.org_id = v_rcp.org_id then',
  '  if false then  -- door open',
  '-- door open')

m('a receipt not posted is applied',
  'allocate_with_discount',
  '    if v_rcp.gl_entry_id is null then',
  '    if false then  -- draft money',
  '-- draft money')

m('an invoice not posted is settled',
  'allocate_with_discount',
  '    if v_inv.gl_entry_id is null then',
  '    if false then  -- draft invoice',
  '-- draft invoice')

m('a voided invoice is settled',
  'allocate_with_discount',
  "    if v_inv.status = 'void' then",
  '    if false then  -- void invoice',
  '-- void invoice')

m('draft money is refused as some other kind',
  'allocate_with_discount',
  "        v_rcp.receipt_no using errcode = '23514';",
  "        v_rcp.receipt_no using errcode = 'P0001';  -- other kind",
  '-- other kind')

# -- allocate_payment_with_discount -----------------------------------
m('the payment door is never asked',
  'allocate_payment_with_discount',
  '  if v_pay.id is not null and v_bill.id is not null\n     and v_bill.org_id = v_pay.org_id then',
  '  if false then  -- door open',
  '-- door open')

m('a payment not posted is applied',
  'allocate_payment_with_discount',
  '    if v_pay.gl_entry_id is null then',
  '    if false then  -- draft money',
  '-- draft money')

m('a bill not posted is settled',
  'allocate_payment_with_discount',
  '    if v_bill.gl_entry_id is null then',
  '    if false then  -- draft bill',
  '-- draft bill')

m('a voided bill is settled',
  'allocate_payment_with_discount',
  "    if v_bill.status = 'void' then",
  '    if false then  -- void bill',
  '-- void bill')

# -- record_settlement ------------------------------------------------
m('anybody records a settlement',
  'record_settlement',
  '  if not app.can_post(p_org_id)\n     or not app.can_write_module(p_org_id,',
  '  if false\n     and not app.can_write_module(p_org_id,  -- anybody',
  '-- anybody')

m('a retry records it again',
  'record_settlement',
  '  if v_seen is not null then\n    return nullif',
  '  if false then  -- retry twice\n    return nullif',
  '-- retry twice')

m('the receipt is posted before it is applied',
  'record_settlement',
  "    for a in select * from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) loop\n"
  "      perform app.allocate_with_discount_internal(\n"
  "        v_id, (a ->> 'document_id')::uuid, (a ->> 'amount')::numeric,\n"
  "        nullif((a ->> 'discount')::numeric, 0), null);\n"
  "    end loop;\n"
  "    perform public.post_receipt(v_id);",
  "    perform public.post_receipt(v_id);  -- posted first\n"
  "    for a in select * from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) loop\n"
  "      perform app.allocate_with_discount_internal(\n"
  "        v_id, (a ->> 'document_id')::uuid, (a ->> 'amount')::numeric,\n"
  "        nullif((a ->> 'discount')::numeric, 0), null);\n"
  "    end loop;",
  '-- posted first')

m('the receipt is applied through the door, as a draft',
  'record_settlement',
  '      perform app.allocate_with_discount_internal(\n        v_id,',
  '      perform public.allocate_with_discount(  -- through the door\n        v_id,',
  '-- through the door')

m('the payment is applied through the door, as a draft',
  'record_settlement',
  '      perform app.allocate_payment_with_discount_internal(\n        v_id,',
  '      perform public.allocate_payment_with_discount(  -- through the door\n        v_id,',
  '-- through the door')

m('the receipt is never posted',
  'record_settlement',
  '    perform public.post_receipt(v_id);',
  '    perform 1;  -- never posted',
  '-- never posted')

m('the payment is never posted',
  'record_settlement',
  '    perform public.post_purchase_payment(v_id);',
  '    perform 1;  -- never posted',
  '-- never posted')

m('every settlement is a receipt',
  'record_settlement',
  '  if p_is_receipt then\n    insert into public.receipts',
  '  if true then  -- all receipts\n    insert into public.receipts',
  '-- all receipts')

m('CONTROL: a comment inside record_settlement',
  'record_settlement',
  '  return v_id;\nend $$;',
  '  return v_id;  -- (control)\nend $$;',
  '(control)')
