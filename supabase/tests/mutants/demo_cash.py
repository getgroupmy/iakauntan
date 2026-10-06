# Mutants for the two demo builders that move cash: app.demo_sinar_bank
# (Sinar's paid-up capital, and the receipts and supplier payments that
# settle its older invoices and bills) and app.demo_purchases (two bills
# from a supplier, one paid). Demo companies are what a prospect clicks
# through first, so a demo ledger that does not add up is a sales defect
# even though no customer's money is in it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0730_the_door_behind_the_twelve.sql \
#       supabase/tests/demo_rebuild.sql \
#       supabase/tests/mutants/demo_cash.py
#
# RESULT: the sweep was started on 6 October and this header is
# rewritten with the kill sheet when it ends. Pre-flight clean.

m("Sinar's capital is paid into the bank heading, not its own account",
  "demo_sinar_bank",
  "      jsonb_build_object('account_id', v_bank_gl,\n"
  "        'description', 'Paid-up capital', 'debit', 700000, 'credit', 0),",
  "      jsonb_build_object('account_id', (select id from public.accounts"
  " where org_id = p_org and code = '1120'),  -- capital to heading\n"
  "        'description', 'Paid-up capital', 'debit', 700000, 'credit', 0),",
  "-- capital to heading")

m("Sinar's capital is a tenth of what it is",
  "demo_sinar_bank",
  "        'description', 'Paid-up capital', 'debit', 700000, 'credit', 0),\n"
  "      jsonb_build_object('account_id', v_capital,\n"
  "        'description', 'Paid-up capital', 'debit', 0, 'credit', 700000)),",
  "        'description', 'Paid-up capital', 'debit', 70000, 'credit', 0),\n"
  "      jsonb_build_object('account_id', v_capital,\n"
  "        'description', 'Paid-up capital', 'debit', 0, 'credit', 70000)),  -- a tenth",
  "-- a tenth")

m("every invoice is settled, however recent",
  "demo_sinar_bank",
  "                  and d.doc_date <= app.today() - 45",
  "                  and d.doc_date <= app.today()  -- all settled",
  "-- all settled")

m("a receipt can be dated in the future",
  "demo_sinar_bank",
  "    v_date := least(v_doc.doc_date + 21, app.today());",
  "    v_date := v_doc.doc_date + 21;  -- future receipts",
  "-- future receipts")

m("receipts are never posted",
  "demo_sinar_bank",
  "    perform public.post_receipt(v_id);",
  "    -- receipt left draft",
  "-- receipt left draft")

m("supplier payments are never posted",
  "demo_sinar_bank",
  "    perform public.post_purchase_payment(v_id);",
  "    -- payment left draft",
  "-- payment left draft")

m("a supplier bill is paid however recent",
  "demo_sinar_bank",
  "                  and d.doc_date <= app.today() - 60",
  "                  and d.doc_date <= app.today()  -- all paid",
  "-- all paid")

m("the builder leaves the owner signed in behind it",
  "demo_sinar_bank",
  "  perform set_config('request.jwt.claims', '', true);\n\n"
  "  return format('Sinar cash:",
  "  -- identity left behind\n\n"
  "  return format('Sinar cash:",
  "-- identity left behind")

m("a demo bill ignores the expense account it was given",
  "demo_purchases",
  "  select id into v_acct from public.accounts\n"
  "   where org_id = p_org and code = p_account_code;",
  "  select null::uuid into v_acct;  -- account ignored",
  "-- account ignored")

m("a demo supplier is paid half the bill",
  "demo_purchases",
  "         v_bank, 'Settlement of ' || d.doc_no, 'MYR', 1, d.total_amount,",
  "         v_bank, 'Settlement of ' || d.doc_no, 'MYR', 1, round(d.total_amount / 2, 2),  -- half paid",
  "-- half paid")

m("a cash box pays by bank transfer",
  "demo_purchases",
  "         case when p_bank_type = 'cash' then '01' else '03' end,",
  "         '03',  -- mode fixed",
  "-- mode fixed")

m("the outstanding bill is never posted",
  "demo_purchases",
  "  perform public.post_purchase_document(v_doc);\n\n"
  "  perform app.demo_sync_bank_balance(p_org);",
  "  -- second bill left draft\n\n"
  "  perform app.demo_sync_bank_balance(p_org);",
  "-- second bill left draft")

m("the bank's shown balance is never brought up to date",
  "demo_purchases",
  "  perform app.demo_sync_bank_balance(p_org);",
  "  -- balance not synced",
  "-- balance not synced")

m("CONTROL -- a comment inside the function block",
  "demo_sinar_bank",
  "  v_payments integer := 0;",
  "  v_payments integer := 0;  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
