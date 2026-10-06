# Mutants for the two demo builders that model a practice:
# app.demo_practice_books (a year of monthly retainer invoices, the older
# ones settled) and app.demo_legal_guaman (a law firm's three matters,
# money held in the client account, a fee transferred to office, time
# billed by the hour). A prospect evaluating either vertical sees these
# first.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0730_the_door_behind_the_twelve.sql \
#       supabase/tests/demo_practice.sql \
#       supabase/tests/mutants/demo_practice.py
#
# RESULT, 6 October: 14 mutants, 13 killed, 1 EQUIVALENT, control alive.
# Against the demo files as they were: 5 killed. New assertions:
#
#   demo_rebuild.sql  Guaman Aziz's figures as figures -- RM 3,200 left
#                     in the client account (kills the unposted payment
#                     out and the tenth-sized fee transfer), the tenancy
#                     bill at RM 1,800 (kills the billed file note, the
#                     tenth rate and the narrowed window), the agreed
#                     fee of RM 6,000; and no demo INVOICE dated after
#                     today (the check covered receipts and payments)
#   demo_practice.sql every practice receipt applied in full
#
# Every Guaman check before this was a RELATION -- register against
# ledger, a matter against itself -- and six breakages moved both sides
# together.
#
# EQUIVALENT: "the retainer is invoiced to whichever revenue account
# comes first" (account_id null). The builder passes 4100 explicitly
# and a line with no account falls back to 4100, so the ledger is the
# same either way. The fixture cannot tell them apart and, for a demo,
# nothing needs to.

m("the retainer is invoiced to whichever revenue account comes first",
  "demo_practice_books",
  "    values (p_org, v_doc, 1, 'item', p_what, 1, p_fee, v_na, v_rate, v_rev);",
  "    values (p_org, v_doc, 1, 'item', p_what, 1, p_fee, v_na, v_rate, null);  -- revenue dropped",
  "-- revenue dropped")

m("only January is invoiced",
  "demo_practice_books",
  "  while v_month <= app.today() loop",
  "  while v_month < date_trunc('year', app.today())::date + 1 loop  -- one month",
  "-- one month")

m("an invoice can be dated after today",
  "demo_practice_books",
  "    v_date := least(v_month + 6, app.today());",
  "    v_date := v_month + 6;  -- future invoices",
  "-- future invoices")

m("every invoice is settled, however recent",
  "demo_practice_books",
  "    if v_date < (app.today() - 60) then",
  "    if true then  -- all settled",
  "-- all settled")

m("the settling receipt is never posted",
  "demo_practice_books",
  "      perform public.post_receipt(v_rcp);",
  "      -- receipt left draft",
  "-- receipt left draft")

m("the receipt is never applied to the invoice it pays",
  "demo_practice_books",
  "      perform public.allocate_with_discount(v_rcp, v_doc, p_fee, null,\n"
  "                                            v_date + 30);",
  "      -- receipt left unapplied",
  "-- receipt left unapplied")

m("the completion money paid out is never posted",
  "demo_legal_guaman",
  "          'Tetuan Chong & Co', p_owner)\n"
  "  returning id into v_txn;\n"
  "  perform public.post_client_transaction(v_txn);",
  "          'Tetuan Chong & Co', p_owner)\n"
  "  returning id into v_txn;\n"
  "  -- payment out left unposted",
  "-- payment out left unposted")

m("the deposit received is a tenth of what it was",
  "demo_legal_guaman",
  "          v_client, 50000, 'MYR',",
  "          v_client, 5000, 'MYR',  -- a tenth",
  "-- a tenth")

m("the fee transferred to office is a tenth of the bill",
  "demo_legal_guaman",
  "    v_m1, v_inv1, 4500, v_today - 12, v_office);",
  "    v_m1, v_inv1, 450, v_today - 12, v_office);  -- a tenth transferred",
  "-- a tenth transferred")

m("the fee is 'transferred' to the client account itself",
  "demo_legal_guaman",
  "    v_m1, v_inv1, 4500, v_today - 12, v_office);",
  "    v_m1, v_inv1, 4500, v_today - 12, v_client);  -- to client account",
  "-- to client account")

m("the internal file note is billed to the client",
  "demo_legal_guaman",
  "     20, v_rate, round(20 / 60.0 * v_rate, 2), false),",
  "     20, v_rate, round(20 / 60.0 * v_rate, 2), true),  -- note billed",
  "-- note billed")

m("time is billed at a tenth of the hourly rate",
  "demo_legal_guaman",
  "  v_rate numeric(18, 2) := 450.00;",
  "  v_rate numeric(18, 2) := 45.00;  -- a tenth the rate",
  "-- a tenth the rate")

m("the hourly bill misses the first attendance",
  "demo_legal_guaman",
  "  v_inv2 := public.bill_matter_time(v_m2, v_today - 40, v_today,",
  "  v_inv2 := public.bill_matter_time(v_m2, v_today - 28, v_today,  -- window narrowed",
  "-- window narrowed")

m("the corporate matter has no agreed fee to run over",
  "demo_legal_guaman",
  "    v_c3, null, 'corporate', p_owner, p_owner,\n    6000, v_rate, null);",
  "    v_c3, null, 'corporate', p_owner, p_owner,\n    null, v_rate, null);  -- no agreed fee",
  "-- no agreed fee")

m("CONTROL -- a comment inside the function block",
  "demo_practice_books",
  "  v_settled  integer := 0;",
  "  v_settled  integer := 0;  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
