# Mutants for 0908 -- an approval covers the amount, in ringgit, and the
# party that were approved, and every reader of a rule's amount reads
# it in ringgit.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0908_an_approval_covers_what_was_approved.sql \
#       supabase/tests/an_approval_covers_what_was_approved.sql \
#       supabase/tests/mutants/an_approval_covers_what_was_approved.py

m('any approval covers any amount, as before',
  'is_approved',
  "       and q.amount >= app.approval_amount(p_kind, p_entity_id)\n",
  "       and true  -- any amount\n",
  '-- any amount')

m('any approval covers any party',
  'is_approved',
  "       and q.contact_id is not distinct from app.approval_party(p_kind, p_entity_id));",
  "       and true);  -- any party",
  '-- any party')

m('an approval covers only the exact amount, so coming down needs another',
  'is_approved',
  "       and q.amount >= app.approval_amount(p_kind, p_entity_id)\n",
  "       and q.amount = app.approval_amount(p_kind, p_entity_id)  -- exact\n",
  '-- exact')

m('the amount is read off base_total_amount, which a new rate does not move',
  'approval_amount',
  "      (select round(d.total_amount * coalesce(d.exchange_rate, 1), 2)\n         from public.sales_documents d where d.id = p_entity_id)",
  "      (select d.base_total_amount  -- stored\n         from public.sales_documents d where d.id = p_entity_id)",
  '-- stored')

m('the amount is in the document''s own currency',
  'approval_amount',
  "      (select round(d.total_amount * coalesce(d.exchange_rate, 1), 2)\n         from public.sales_documents d where d.id = p_entity_id)",
  "      (select d.total_amount  -- own currency\n         from public.sales_documents d where d.id = p_entity_id)",
  '-- own currency')

m('the posting gate measures a rule in the document''s own currency',
  'refuse_unapproved_posting',
  "    v_amount := round(new.total_amount * coalesce(new.exchange_rate, 1), 2);",
  "    v_amount := new.total_amount;  -- own currency",
  '-- own currency')

m('the posting gate does not say what was approved',
  'refuse_unapproved_posting',
  "    if v_was.id is not null then\n",
  "    if false then  -- silent\n",
  '-- silent')

m('the editor measures a rule in the document''s own currency',
  'approval_state',
  "  v_amount := app.approval_amount(p_kind, p_entity_id);\n",
  "  null;  -- own currency\n",
  '-- own currency')

m('the transfer measures a rule in the document''s own currency',
  'transfer_document',
  "  v_amount := app.approval_amount(v_kind, p_source_id);",
  "  v_amount := case when v_is_sales then v_sales.total_amount else v_purchase.total_amount end;  -- own currency",
  '-- own currency')

m('a request does not record whom it was for',
  'submit_for_approval',
  "          app.approval_party(p_kind, p_entity_id))",
  "          null)  -- nobody",
  '-- nobody')

m('CONTROL: a comment inside the function',
  'is_approved',
  "       and q.amount >= app.approval_amount(p_kind, p_entity_id)\n",
  "       and q.amount >= app.approval_amount(p_kind, p_entity_id)  -- control\n",
  '-- control')
