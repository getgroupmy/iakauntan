# Mutants for app.post_receipt_internal -- where money that has arrived
# is debited to.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0731_where_the_card_money_lands.sql \
#       supabase/tests/money_names_the_account.sql \
#       supabase/tests/mutants/post_receipt.py
#
# `0728` found this was the LAST surviving `code = '1120'` fallback: a
# receipt naming no bank account was debited to the parent of every bank
# account, so the money appeared on no reconciliation. `0731` replaced
# it with a documented three-tier resolution -- the gateway's settlement
# account, else the company's default ACTIVE account, else the OLDEST
# active one, never a closed or client account, and written back onto
# the receipt. Every tier is a mutant here.
#
# RESULT, 5 October: 10 mutants, all accounted for, THREE REAL GAPS.
#
#   money_names_the_account.sql  kills 7 (was 4 before the gaps closed)
#   control_accounts.sql         the contact's own receivable account
#   bank_reconciliation.sql      the bank charge, on a balance failure
#   multicurrency.sql            the exchange rate
#
# THE THREE GAPS, and the first two shared one cause:
#
#  1. dropping `b.is_default desc` from the tiebreak
#  2. reversing `b.created_at` to `desc`
#
# Both survived SEVEN files, masked by the same fixture: the default
# account was ALSO the oldest active one, so the two orderings pick the
# same row and neither can say which was used. docs/widget-tests.md's
# twelfth way, in a bank-account fixture.
#
# Closing it turned up something worse. `bank_accounts.created_at`
# defaults to `now()`, which in Postgres is the TRANSACTION timestamp --
# so every account a fixture creates has the SAME created_at and
# `order by b.created_at` orders nothing at all. The new block sets them
# apart by hand with `now() - interval '2 days'`. Nothing else in the
# suite does, so no other test can say anything about that tier.
#
#  3. the repost guard. `if v_rcp.gl_entry_id is not null then raise`
#     could be dropped entirely and every file that posts a receipt
#     stayed green. A receipt posted twice banks the same money twice
#     and doubles the customer's credit.

m("a CLOSED bank account can receive the money",
  "post_receipt_internal",
  "     where b.org_id = v_rcp.org_id\n"
  "       and b.is_active\n"
  "       and not b.is_client_account",
  "     where b.org_id = v_rcp.org_id\n"
  "       and not b.is_client_account",
  "v_rcp.org_id\n       and not b.is_client_account")

m("a CLIENT account can receive the firm's money",
  "post_receipt_internal",
  "       and b.is_active\n       and not b.is_client_account",
  "       and b.is_active  -- client-account test dropped",
  "-- client-account test dropped")

m("the gateway's settlement account loses its priority",
  "post_receipt_internal",
  "     order by (b.id = (select g.settlement_bank_account_id",
  "     order by (null = (select g.settlement_bank_account_id",
  "order by (null = (select g.settlement_bank_account_id")

m("the company's default account loses its priority",
  "post_receipt_internal",
  "              b.is_default desc, b.created_at",
  "              b.created_at",
  "nulls last,\n              b.created_at")

m("the NEWEST account is chosen rather than the oldest",
  "post_receipt_internal",
  "              b.is_default desc, b.created_at\n     limit 1;",
  "              b.is_default desc, b.created_at desc\n     limit 1;",
  "b.created_at desc\n     limit 1;")

m("a company with no bank account posts anyway, silently",
  "post_receipt_internal",
  "    if v_bank_acct is null then\n      raise exception",
  "    if false then\n      raise exception",
  "if false then\n      raise exception")

m("the contact's own receivable account is ignored",
  "post_receipt_internal",
  "  select coalesce(c.receivable_account_id,\n"
  "                  (select id from public.accounts"
  " where org_id = v_rcp.org_id and code = '1210'))",
  "  select coalesce(null::uuid,\n"
  "                  (select id from public.accounts"
  " where org_id = v_rcp.org_id and code = '1210'))",
  "coalesce(null::uuid,")

m("the bank's charge is not taken off what reached the bank",
  "post_receipt_internal",
  "  v_net := round((v_rcp.amount - coalesce(v_rcp.bank_charges, 0))"
  " * v_rate, 2);",
  "  v_net := round(v_rcp.amount * v_rate, 2);  -- charges ignored",
  "-- charges ignored")

m("the exchange rate is ignored",
  "post_receipt_internal",
  "  v_rate := coalesce(v_rcp.exchange_rate, 1);",
  "  v_rate := 1;  -- rate dropped",
  "-- rate dropped")

m("an already-posted receipt can be posted twice",
  "post_receipt_internal",
  "  if v_rcp.gl_entry_id is not null then",
  "  if false then  -- repost guard dropped",
  "-- repost guard dropped")

m("CONTROL -- a comment inside the function block",
  "post_receipt_internal",
  "  v_rate := coalesce(v_rcp.exchange_rate, 1);",
  "  v_rate := coalesce(v_rcp.exchange_rate, 1);"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
