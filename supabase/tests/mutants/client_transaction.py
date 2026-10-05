# Mutants for public.post_client_transaction -- a movement on a
# solicitor's CLIENT account, which is money the firm holds and does not
# own.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0282_client_money_never_sits_in_the_office_account.sql \
#       supabase/tests/client_account.sql \
#       supabase/tests/mutants/client_transaction.py
#
# then again against `matter_transfer.sql`, `matter_closing.sql`,
# `client_money_crossing.sql` and `money_names_the_account.sql`.
#
# RESULT, 5 October: 26 mutants (25 plus a control). 15 killed on
# `client_account.sql` and 11 survived; 16 across all five files. 25 of
# 25 after the work, nothing equivalent, control alive -- and every one
# of the ten real gaps was closable in the file the function is named
# for.
#
# THE TEN THAT LIVED ARE ALL OF ONE KIND: **the two rules in
# `client_account.sql`'s own header are asserted thoroughly and nothing
# else is.** Rule 1 (client money in a client account, never the firm's)
# kills four mutants on its own; rule 2 (one client's money is not
# another's) is a deferred constraint trigger with its own block. And
# then:
#
#   both guards at the TOP of the function    nothing
#   the two "run setup_legal_module" refusals nothing
#   the journal's date                        nothing
#   the journal's reference                   nothing
#   the movement's own description, and the
#     fallback to its number                  nothing
#   posted_at                                 nothing
#
# A file that knows exactly what it is for can be exhaustive about that
# and empty about everything beside it. This one names the Solicitors'
# Accounts Rules 1990 in its header and quotes two of them -- and a
# breach of those rules is a disciplinary matter rather than a
# bookkeeping one, which makes "who posted it, and when" the part a
# regulator reads first and the part nothing asserted.
#
# `scripts/state_write_coverage.py` had flagged `posted_at` here, which
# is the second time that survey pointed at a real gap.
#
# One mutant is INVERTED rather than dropped (the client bank's org
# scope), for the determinism reason noted beside it.
#
# The most consequential small function in the schema. Client money is
# held under the Solicitors' Accounts Rules: it is not the firm's, it
# may not sit in the firm's own account, and a shortfall is a
# disciplinary matter rather than a bookkeeping one. The function is
# eighty lines and does four things, every one of which is the kind of
# rule this sweep keeps finding unasserted.
#
# ONE FEATURE DECIDES EVERYTHING AND HAS NO BRANCH: the SIGN of
# `v_txn.amount`. Both legs are built with `greatest(v_amount, 0)` and
# `greatest(-v_amount, 0)`, so money in and money out are the same two
# lines read in opposite directions. A fixture that only ever pays money
# IN cannot see half of it, and the `greatest` pairs can be mutated
# four ways without unbalancing anything.
#
# `scripts/state_write_coverage.py` also flagged `posted_at` here.

m("anybody can post a movement on the client account",
  "post_client_transaction",
  "  if not app.can_post(v_txn.org_id) then",
  "  if false then  -- client post guard dropped",
  "-- client post guard dropped")

m("a movement already posted is posted a second time",
  "post_client_transaction",
  "  if v_txn.gl_entry_id is not null then",
  "  if false then  -- repost guard dropped",
  "-- repost guard dropped")

m("client money can be held in the FIRM's own bank account",
  "post_client_transaction",
  "     where b.id = v_txn.bank_account_id and b.is_client_account;",
  "     where b.id = v_txn.bank_account_id;  -- client-account check dropped",
  "-- client-account check dropped")

m("naming the firm's own account is quietly redirected rather than refused",
  "post_client_transaction",
  "    if v_bank_acct is null then\n"
  "      select name into v_bank_name from public.bank_accounts",
  "    if false then\n"
  "      select name into v_bank_name from public.bank_accounts"
  "  -- not-a-client-account refusal dropped",
  "-- not-a-client-account refusal dropped")

m("a movement naming NO account falls to the firm's cash rather than 1150",
  "post_client_transaction",
  "    select id into v_bank_acct from public.accounts\n"
  "     where org_id = v_txn.org_id and code = '1150';",
  "    select id into v_bank_acct from public.accounts\n"
  "     where org_id = v_txn.org_id and code = '1120';"
  "  -- client bank fallback moved to 1120",
  "-- client bank fallback moved to 1120")

# INVERTED rather than dropped, for determinism. `select ... into` over
# two matching rows takes whichever the planner scans first and raises
# nothing, so a "scope dropped" mutant on a fixture with two firms is a
# coin flip -- the trap `client_money_crossing.sql` already paid for
# once. Inverted, it has exactly one answer: the other firm's 1150,
# which `gl_lines`' composite foreign key on (org_id, account_id)
# refuses.
m("ANOTHER FIRM's client account is used",
  "post_client_transaction",
  "    select id into v_bank_acct from public.accounts\n"
  "     where org_id = v_txn.org_id and code = '1150';",
  "    select id into v_bank_acct from public.accounts\n"
  "     where org_id <> v_txn.org_id and code = '1150';"
  "  -- client bank org scope inverted",
  "-- client bank org scope inverted")

m("a firm with no client account set up posts anyway",
  "post_client_transaction",
  "    if v_bank_acct is null then\n"
  "      raise exception 'No client account configured.",
  "    if false then\n"
  "      raise exception 'No client account configured."
  "  -- missing client account no longer refused",
  "-- missing client account no longer refused")

m("ANOTHER FIRM's client-monies-held account is credited",
  "post_client_transaction",
  "  select id into v_liab_acct from public.accounts\n"
  "   where org_id = v_txn.org_id and code = '2300';",
  "  select id into v_liab_acct from public.accounts\n"
  "   where code = '2300';  -- liability org scope dropped",
  "-- liability org scope dropped")

m("what the firm OWES the client is posted to the wrong account",
  "post_client_transaction",
  "  select id into v_liab_acct from public.accounts\n"
  "   where org_id = v_txn.org_id and code = '2300';",
  "  select id into v_liab_acct from public.accounts\n"
  "   where org_id = v_txn.org_id and code = '2310';"
  "  -- liability account changed",
  "-- liability account changed")

m("a firm with no client-monies-held account posts anyway",
  "post_client_transaction",
  "  if v_liab_acct is null then\n    raise exception\n"
  "      'No client monies held account configured.",
  "  if false then\n    raise exception\n"
  "      'No client monies held account configured."
  "  -- missing liability account no longer refused",
  "-- missing liability account no longer refused")

m("money OUT of the client account is debited to it like money in",
  "post_client_transaction",
  "      'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0)),",
  "      'debit', abs(v_amount), 'credit', 0),  -- client bank always debited",
  "-- client bank always debited")

m("money IN to the client account is credited to it",
  "post_client_transaction",
  "      'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0)),",
  "      'debit', greatest(-v_amount, 0), 'credit', greatest(v_amount, 0)),"
  "  -- client bank sides swapped",
  "-- client bank sides swapped")

m("what the firm owes the client moves the WRONG WAY",
  "post_client_transaction",
  "      'debit', greatest(-v_amount, 0), 'credit', greatest(v_amount, 0))",
  "      'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0))"
  "  -- liability sides swapped",
  "-- liability sides swapped")

m("the movement's own description is dropped for its number",
  "post_client_transaction",
  "      'description', coalesce(v_txn.description, v_txn.transaction_no),",
  "      'description', v_txn.transaction_no,  -- own description ignored",
  "-- own description ignored")

m("a movement with no description of its own gets none",
  "post_client_transaction",
  "      'description', coalesce(v_txn.description, v_txn.transaction_no),",
  "      'description', v_txn.description,  -- description fallback dropped",
  "-- description fallback dropped")

m("the journal is dated the day it was typed, not the day the money moved",
  "post_client_transaction",
  "    v_txn.org_id, v_txn.transaction_date, 'manual'::app.journal_source,",
  "    v_txn.org_id, app.today(), 'manual'::app.journal_source,"
  "  -- client journal date forced to today",
  "-- client journal date forced to today")

m("the journal does not point back at the movement",
  "post_client_transaction",
  "    'client_account_transactions', v_txn.id, v_txn.reference,",
  "    'client_account_transactions', null, v_txn.reference,"
  "  -- source movement forgotten",
  "-- source movement forgotten")

m("the reference the money came with is not carried",
  "post_client_transaction",
  "    'client_account_transactions', v_txn.id, v_txn.reference,",
  "    'client_account_transactions', v_txn.id, null,"
  "  -- client reference dropped",
  "-- client reference dropped")

m("the movement does not remember the journal it posted",
  "post_client_transaction",
  "     set gl_entry_id = v_entry, status = 'posted',",
  "     set status = 'posted',  -- client entry not linked",
  "-- client entry not linked")

m("a posted movement still reads as a draft",
  "post_client_transaction",
  "     set gl_entry_id = v_entry, status = 'posted',",
  "     set gl_entry_id = v_entry,  -- client status not advanced",
  "-- client status not advanced")

m("WHEN the client movement was posted is not recorded",
  "post_client_transaction",
  "         posted_at = now(), posted_by = auth.uid()",
  "         posted_by = auth.uid()  -- client posted_at not recorded",
  "-- client posted_at not recorded")

m("WHO posted the client movement is not recorded",
  "post_client_transaction",
  "         posted_at = now(), posted_by = auth.uid()",
  "         posted_at = now()  -- client posted_by not recorded",
  "-- client posted_by not recorded")

m("the client bank balance is not moved",
  "post_client_transaction",
  "       set current_balance = current_balance + v_amount",
  "       set current_balance = current_balance"
  "  -- client balance not moved",
  "-- client balance not moved")

m("a payment OUT raises the client bank balance",
  "post_client_transaction",
  "       set current_balance = current_balance + v_amount",
  "       set current_balance = current_balance + abs(v_amount)"
  "  -- client balance always raised",
  "-- client balance always raised")

m("a movement on the DEFAULT client account moves no balance at all",
  "post_client_transaction",
  "  if v_txn.bank_account_id is not null then\n"
  "    update public.bank_accounts",
  "  if false then\n    update public.bank_accounts"
  "  -- client balance update skipped",
  "-- client balance update skipped")

m("CONTROL -- a comment beside the amount",
  "post_client_transaction",
  "  v_amount := v_txn.amount;",
  "  v_amount := v_txn.amount;  -- CONTROL: this cannot change a figure.",
  "-- CONTROL: this cannot change a figure.")
