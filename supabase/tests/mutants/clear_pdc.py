# Mutants for public.clear_pdc -- the moment a post-dated cheque stops
# being a promise and becomes money: the holding account empties, the
# bank balance moves, and the cheque is stamped cleared.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0728_the_rest_of_the_money_that_went_to_the_heading.sql \
#       supabase/tests/post_dated_cheques.sql \
#       supabase/tests/mutants/clear_pdc.py
#
# then again against `money_names_the_account.sql` and `idempotency.sql`.
#
# RESULT, 5 October: 26 mutants (25 plus a control). 9 killed on
# `post_dated_cheques.sql` and 17 survived; 24 of 25 across all four
# files that reach it, with one proven EQUIVALENT. The control lived.
#
#   post_dated_cheques.sql       kills 9, then 22
#   money_names_the_account.sql  kills "a cheque can clear through no
#                                account at all" -- the 1120 heading bug
#   idempotency.sql              kills "a cleared cheque is not marked
#                                cleared"
#   cash_forecast.sql            kills nothing of this function
#
# NINE OF TWENTY-SIX IS THE WORST FIRST-RUN SCORE OF THIS SWEEP SO FAR,
# and the cause is one sentence: every clearing in the dedicated file
# asserts the BANK BALANCE and little else. A balance is one number, and
# it is the same number whether
#
#   * the cheque's own holding account was emptied or the other
#     direction's was (1140 Cheques on Hand, an asset, against 2115
#     Cheques Issued, a liability);
#   * the journal says which cheque it was for;
#   * the cheque remembers what settled it, or through which account;
#   * anybody is named on either leg;
#   * it cleared on the day it cleared or the day it was typed.
#
# Every one of those still balances. The outgoing clearing's journal was
# not asserted at all -- only that the balance fell by 8,000.
#
# AND THE STATUS WRITE IS THE SECOND OF ITS KIND IN THIS TRIO.
# `set status = 'cleared'` survives the whole dedicated file and dies in
# `idempotency.sql`, which asserts nothing about clearing: a cheque left
# `held` can be cleared twice, so a generic refuses-a-repeat check
# catches a specific defect in a status write. `bounce_pdc` had exactly
# the same shape (see post_dated_cheques.py). Twice in three functions
# is not a coincidence -- a status column is what a file about MONEY
# never looks at.
#
# THE EQUIVALENT is the ledger lookup's own `and b.org_id = v_c.org_id`,
# the same shape as create_deposit's and proven the same way: by the
# time that select runs, v_bid has been refused if null and refused if
# it belongs to another company, so the conjunct cannot exclude a row
# the id would not have missed. Belt-and-braces, and the function's own
# comment says why it is there.
#
# The third of the cheque trio, after record_pdc and bounce_pdc (see
# `post_dated_cheques.py`, 27 of 27). It is built like create_deposit --
# the DIRECTION decides the module right, the control account, which
# side each leg takes and the sign of the balance update -- so the same
# four families apply, and the one new rule is the STATUS LIST:
# `not in ('held', 'deposited')`. Two states clear, and a fixture that
# only ever holds cheques cannot tell the list from a single value.

m("anybody can clear a cheque",
  "clear_pdc",
  "  if not app.can_write_module(v_c.org_id,",
  "  if false and not app.can_write_module(v_c.org_id,"
  "  -- clear write guard dropped",
  "-- clear write guard dropped")

m("clearing an INCOMING cheque needs the purchases right, and vice versa",
  "clear_pdc",
  "        case when v_c.direction = 'incoming' then 'sales' else 'purchases' end) then",
  "        case when v_c.direction = 'incoming' then 'purchases' else 'sales' end) then"
  "  -- clear module derivation swapped",
  "-- clear module derivation swapped")

m("a cheque in any state at all can be cleared",
  "clear_pdc",
  "  if v_c.status not in ('held', 'deposited') then",
  "  if false then  -- clear status guard dropped",
  "-- clear status guard dropped")

m("a cheque already DEPOSITED cannot be cleared",
  "clear_pdc",
  "  if v_c.status not in ('held', 'deposited') then",
  "  if v_c.status not in ('held') then  -- deposited no longer clears",
  "-- deposited no longer clears")

m("the day it cleared is ignored for the day it was typed",
  "clear_pdc",
  "  v_on  := coalesce(p_on, app.today());",
  "  v_on  := app.today();  -- clearing date forced to today",
  "-- clearing date forced to today")

m("the cheque's own account is not used when none is named",
  "clear_pdc",
  "  v_bid := coalesce(p_bank, v_c.bank_account_id);",
  "  v_bid := p_bank;  -- cheque's own account not used",
  "-- cheque's own account not used")

m("the account NAMED is ignored for the cheque's own",
  "clear_pdc",
  "  v_bid := coalesce(p_bank, v_c.bank_account_id);",
  "  v_bid := v_c.bank_account_id;  -- named account ignored",
  "-- named account ignored")

m("a cheque can clear through ANOTHER COMPANY's account",
  "clear_pdc",
  "  if v_bid is not null and not exists (",
  "  if false and not exists (  -- foreign bank guard dropped",
  "-- foreign bank guard dropped")

m("a cheque can clear through no account at all",
  "clear_pdc",
  "  if v_bid is null then",
  "  if false then  -- bankless clearing accepted",
  "-- bankless clearing accepted")

m("the ledger account is resolved without regard to the company",
  "clear_pdc",
  "   where b.id = v_bid and b.org_id = v_c.org_id;\n"
  "  if v_bank is null then",
  "   where b.id = v_bid;  -- ledger lookup org scope dropped\n"
  "  if v_bank is null then",
  "-- ledger lookup org scope dropped")

m("an OUTGOING cheque is cleared out of the INCOMING holding account",
  "clear_pdc",
  "  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);",
  "  v_held := app.cheque_account(v_c.org_id, 'incoming');"
  "  -- holding account fixed",
  "-- holding account fixed")

m("an incoming cheque is journalled the way an outgoing one is",
  "clear_pdc",
  "  if v_c.direction = 'incoming' then\n    -- Now, and only now, it is money.",
  "  if v_c.direction <> 'incoming' then\n"
  "    -- Now, and only now, it is money.  -- direction inverted",
  "-- direction inverted")

m("a cleared cheque is money from nobody",
  "clear_pdc",
  "      jsonb_build_object('account_id', v_bank, 'contact_id', v_c.contact_id,\n"
  "        'description', 'Cheque ' || v_c.cheque_no || ' cleared',\n"
  "        'debit', v_c.amount, 'credit', 0),",
  "      jsonb_build_object('account_id', v_bank, 'contact_id', null,\n"
  "        'description', 'Cheque ' || v_c.cheque_no || ' cleared',\n"
  "        'debit', v_c.amount, 'credit', 0),  -- bank leg contact dropped",
  "-- bank leg contact dropped")

m("the holding account is emptied for nobody",
  "clear_pdc",
  "      jsonb_build_object('account_id', v_held, 'contact_id', v_c.contact_id,\n"
  "        'description', 'Cheque ' || v_c.cheque_no || ' cleared',\n"
  "        'debit', 0, 'credit', v_c.amount));",
  "      jsonb_build_object('account_id', v_held, 'contact_id', null,\n"
  "        'description', 'Cheque ' || v_c.cheque_no || ' cleared',\n"
  "        'debit', 0, 'credit', v_c.amount));  -- held leg contact dropped",
  "-- held leg contact dropped")

m("the journal line does not say which cheque cleared",
  "clear_pdc",
  "        'description', 'Cheque ' || v_c.cheque_no || ' cleared',\n"
  "        'debit', v_c.amount, 'credit', 0),",
  "        'description', 'Cheque cleared',\n"
  "        'debit', v_c.amount, 'credit', 0),  -- cheque number not on the line",
  "-- cheque number not on the line")

m("an OUTGOING cheque's lines read as an incoming one's",
  "clear_pdc",
  "        'description', 'Cheque ' || v_c.cheque_no || ' presented',\n"
  "        'debit', v_c.amount, 'credit', 0),",
  "        'description', 'Cheque ' || v_c.cheque_no || ' cleared',\n"
  "        'debit', v_c.amount, 'credit', 0),  -- presented reads as cleared",
  "-- presented reads as cleared")

m("the journal is dated the day it was typed, not the day it cleared",
  "clear_pdc",
  "    v_c.org_id, v_on, 'cheque', v_lines,",
  "    v_c.org_id, app.today(), 'cheque', v_lines,  -- journal date forced",
  "-- journal date forced")

m("the journal does not say which cheque it is for",
  "clear_pdc",
  "    'Cheque ' || v_c.pdc_no || ' cleared', 'post_dated_cheques', p_id);",
  "    'Cheque cleared', 'post_dated_cheques', p_id);  -- pdc_no not named",
  "-- pdc_no not named")

m("the journal does not point back at the cheque",
  "clear_pdc",
  "    'Cheque ' || v_c.pdc_no || ' cleared', 'post_dated_cheques', p_id);",
  "    'Cheque ' || v_c.pdc_no || ' cleared', 'post_dated_cheques', null);"
  "  -- source cheque forgotten",
  "-- source cheque forgotten")

m("an OUTGOING cheque clearing RAISES the bank balance",
  "clear_pdc",
  "           + case when v_c.direction = 'incoming' then v_c.amount\n"
  "                  else -v_c.amount end",
  "           + v_c.amount  -- bank balance always raised",
  "-- bank balance always raised")

m("the bank balance is not moved at all",
  "clear_pdc",
  "   where id = v_bid;\n"
  "\n"
  "  update public.post_dated_cheques",
  "   where id = null;  -- bank balance update hits nothing\n"
  "\n"
  "  update public.post_dated_cheques",
  "-- bank balance update hits nothing")

m("a cleared cheque is not marked cleared",
  "clear_pdc",
  "     set status = 'cleared', cleared_on = v_on, settle_entry_id = v_entry,",
  "     set status = 'held', cleared_on = v_on, settle_entry_id = v_entry,"
  "  -- status not advanced",
  "-- status not advanced")

m("WHEN it cleared is not recorded",
  "clear_pdc",
  "     set status = 'cleared', cleared_on = v_on, settle_entry_id = v_entry,",
  "     set status = 'cleared', cleared_on = null, settle_entry_id = v_entry,"
  "  -- cleared_on not recorded",
  "-- cleared_on not recorded")

m("the cheque does not remember the journal that settled it",
  "clear_pdc",
  "     set status = 'cleared', cleared_on = v_on, settle_entry_id = v_entry,",
  "     set status = 'cleared', cleared_on = v_on, settle_entry_id = null,"
  "  -- settle entry not kept",
  "-- settle entry not kept")

m("the cheque does not record WHICH account it cleared through",
  "clear_pdc",
  "         bank_account_id = v_bid\n   where id = p_id;",
  "         bank_account_id = null\n   where id = p_id;"
  "  -- clearing account not kept",
  "-- clearing account not kept")

m("CONTROL -- a comment beside the holding account",
  "clear_pdc",
  "  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);",
  "  v_held := app.cheque_account(v_c.org_id, v_c.direction::text);"
  "  -- CONTROL: this cannot change an account.",
  "-- CONTROL: this cannot change an account.")
