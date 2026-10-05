# Mutants for public.create_deposit -- money taken from a customer or
# paid to a supplier before there is a document to put it against, held
# in its own control account until it is applied, returned, forfeited or
# written off.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0728_the_rest_of_the_money_that_went_to_the_heading.sql \
#       supabase/tests/deposits.sql \
#       supabase/tests/mutants/deposits.py
#
# then again against `money_names_the_account.sql` and `idempotency.sql`.
#
# RESULT, 5 October: 26 mutants plus a control. 13 killed on
# `deposits.sql` and 12 survived; `money_names_the_account.sql` kills one
# more that it misses, `idempotency.sql` kills one already counted.
# 24 of 25 after the work, with one proven EQUIVALENT. The control lived.
#
#   deposits.sql                 kills 13, then 24
#   money_names_the_account.sql  kills "a deposit that names no account
#                                is accepted" -- the 1120 heading bug
#                                0728 closed, which is that file's whole
#                                subject
#   idempotency.sql              kills the zeroed balance, already counted
#
# SEVEN OF THE TWELVE WERE ONE FIXTURE PROBLEM. Every deposit in the
# file is a round hundred or thousand taken TODAY, with no mode and no
# reference. So:
#
#   round(p_amount, 2) had no cents to lose
#   coalesce(p_date, app.today()) had nothing to tell from today
#   p_mode, p_reference and p_notes were never read back
#   and the journal's contact_id on each leg was never looked at
#
# One deposit -- 1234.56, nine days ago, mode '02', reference 'CHQ
# 900241' -- closes seven mutants at once. The three arguments a deposit
# carries purely so a person can find the money later are exactly the
# three nothing asserted, and none of them can unbalance a journal.
#
# THE MODULE DERIVATION NEEDED TWO FIXTURES, which is the lesson
# `contra.sql` paid for first. `app.can_write_module(p_org, v_module)`
# with v_module derived from the kind is TWO claims in one call: that
# the guard exists at all, and that each direction asks for the right
# module. A stranger proves only the first -- they are refused whichever
# module is named. The second needs a company that holds one side and
# not the other, and only `purchases` can be switched off, because
# `sales` is a core module every company has. So: purchases off refuses
# a SUPPLIER deposit and must still allow a CUSTOMER one. Swap the
# derivation and the customer deposit asks for purchases and is
# refused.
#
# THE EQUIVALENT is the ledger lookup's own `and b.org_id = p_org`.
# Proven by shape: by the time that select runs, p_bank has already
# been refused if null and refused if it belongs to another company, so
# the conjunct cannot exclude a row the id would not have found anyway.
# Belt-and-braces, and right to keep -- the function's own comment
# records that the row written and the balance updated once used p_bank
# raw, which is the defect it guards against returning.
#
# Five definitions, the most-redefined money mover in the schema, and
# two live overloads (the keyed wrapper added by the write-idempotency
# programme). It is also the function whose DIRECTION decides
# everything: the module right required, the control account used, which
# side of the journal each leg lands on, and the sign of the bank
# balance update all follow from `p_kind`. A company holding both sales
# and purchases rights cannot tell a swapped derivation from a correct
# one.

m("anybody can take a deposit",
  "create_deposit",
  "  if not app.can_write_module(p_org, v_module) then",
  "  if false then  -- deposit write guard dropped",
  "-- deposit write guard dropped")

m("a customer deposit needs the PURCHASES right and the other way round",
  "create_deposit",
  "  v_module text := case when p_kind = 'customer' then 'sales'"
  " else 'purchases' end;",
  "  v_module text := case when p_kind = 'customer' then 'purchases'"
  " else 'sales' end;  -- module derivation swapped",
  "-- module derivation swapped")

m("a deposit can be of any kind at all",
  "create_deposit",
  "  if p_kind not in ('customer', 'supplier') then",
  "  if false then  -- kind guard dropped",
  "-- kind guard dropped")

m("a deposit for NOTHING is accepted",
  "create_deposit",
  "  if v_amount <= 0 then",
  "  if v_amount < 0 then  -- zero deposit accepted",
  "-- zero deposit accepted")

m("a deposit for a NEGATIVE amount is accepted",
  "create_deposit",
  "  if v_amount <= 0 then",
  "  if false then  -- amount guard dropped",
  "-- amount guard dropped")

m("the deposit's cents are rounded away",
  "create_deposit",
  "  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 2);",
  "  v_amount numeric(18, 2) := round(coalesce(p_amount, 0), 0);"
  "  -- cents rounded away",
  "-- cents rounded away")

m("a deposit can name a contact that does not exist",
  "create_deposit",
  "  if not exists (select 1 from public.contacts c\n"
  "                  where c.id = p_contact and c.org_id = p_org) then",
  "  if false then  -- contact guard dropped",
  "-- contact guard dropped")

m("a deposit can name ANOTHER COMPANY's contact",
  "create_deposit",
  "                  where c.id = p_contact and c.org_id = p_org) then",
  "                  where c.id = p_contact) then  -- contact org scope dropped",
  "-- contact org scope dropped")

m("a deposit can be banked in ANOTHER COMPANY's account",
  "create_deposit",
  "  if p_bank is not null and not exists (",
  "  if false and not exists (  -- foreign bank guard dropped",
  "-- foreign bank guard dropped")

m("a deposit that names no account is accepted",
  "create_deposit",
  "  if p_bank is null then",
  "  if false then  -- bankless deposit accepted",
  "-- bankless deposit accepted")

m("the ledger account is resolved without regard to the company",
  "create_deposit",
  "   where b.id = p_bank and b.org_id = p_org;\n"
  "  if v_bank is null then",
  "   where b.id = p_bank;  -- ledger lookup org scope dropped\n"
  "  if v_bank is null then",
  "-- ledger lookup org scope dropped")

m("a SUPPLIER deposit is held in the CUSTOMER deposit account",
  "create_deposit",
  "  v_held := app.deposit_account(p_org, p_kind);",
  "  v_held := app.deposit_account(p_org, 'customer');  -- held account fixed",
  "-- held account fixed")

m("a customer deposit is journalled the way a supplier one is",
  "create_deposit",
  "  if p_kind = 'customer' then\n"
  "    -- Money in, and a liability for money the company would have to\n"
  "    -- give back.",
  "  if p_kind <> 'customer' then\n"
  "    -- Money in, and a liability for money the company would have to\n"
  "    -- give back.  -- direction inverted",
  "-- direction inverted")

m("the deposit is recorded against nobody on the bank's leg",
  "create_deposit",
  "      jsonb_build_object('account_id', v_bank, 'contact_id', p_contact,\n"
  "        'description', 'Deposit ' || v_no, 'debit', v_amount, 'credit', 0),",
  "      jsonb_build_object('account_id', v_bank, 'contact_id', null,\n"
  "        'description', 'Deposit ' || v_no, 'debit', v_amount, 'credit', 0),"
  "  -- bank leg contact dropped",
  "-- bank leg contact dropped")

m("the deposit is recorded against nobody on the HELD leg",
  "create_deposit",
  "      jsonb_build_object('account_id', v_held, 'contact_id', p_contact,\n"
  "        'description', 'Deposit ' || v_no, 'debit', 0, 'credit', v_amount));",
  "      jsonb_build_object('account_id', v_held, 'contact_id', null,\n"
  "        'description', 'Deposit ' || v_no, 'debit', 0, 'credit', v_amount));"
  "  -- held leg contact dropped",
  "-- held leg contact dropped")

m("the date the money moved is ignored on the NOTE",
  "create_deposit",
  "  values (p_org, v_no, coalesce(p_date, app.today()),"
  " p_kind::app.deposit_kind,",
  "  values (p_org, v_no, app.today(), p_kind::app.deposit_kind,"
  "  -- note date forced to today",
  "-- note date forced to today")

m("the date the money moved is ignored on the JOURNAL",
  "create_deposit",
  "    p_org, coalesce(p_date, app.today()), 'deposit', v_lines,",
  "    p_org, app.today(), 'deposit', v_lines,  -- journal date forced to today",
  "-- journal date forced to today")

m("none of the deposit is available to spend",
  "create_deposit",
  "          v_amount, p_notes, auth.uid())",
  "          0, p_notes, auth.uid())  -- balance starts at nothing",
  "-- balance starts at nothing")

m("how the money arrived is not recorded",
  "create_deposit",
  "          p_contact, v_cur, v_rate, v_amount, p_bank, p_mode, p_reference,",
  "          p_contact, v_cur, v_rate, v_amount, p_bank, null, p_reference,"
  "  -- payment mode dropped",
  "-- payment mode dropped")

m("the reference the money came with is not recorded",
  "create_deposit",
  "          p_contact, v_cur, v_rate, v_amount, p_bank, p_mode, p_reference,",
  "          p_contact, v_cur, v_rate, v_amount, p_bank, p_mode, null,"
  "  -- reference dropped",
  "-- reference dropped")

m("the deposit's currency is assumed rather than read",
  "create_deposit",
  "  v_cur  := app.base_currency(p_org);",
  "  v_cur  := 'MYR';  -- base currency assumed",
  "-- base currency assumed")

m("the note does not point at the journal it posted",
  "create_deposit",
  "  update public.deposit_notes set gl_entry_id = v_entry where id = v_id;",
  "  -- entry not linked: update public.deposit_notes set gl_entry_id ="
  " v_entry where id = v_id;",
  "-- entry not linked")

m("the journal does not point back at the note",
  "create_deposit",
  "    'Deposit ' || v_no, 'deposit_notes', v_id);",
  "    'Deposit ' || v_no, 'deposit_notes', null);  -- source note forgotten",
  "-- source note forgotten")

m("a deposit PAID to a supplier RAISES the bank balance",
  "create_deposit",
  "           + case when p_kind = 'customer' then v_amount else -v_amount end",
  "           + v_amount  -- bank balance always raised",
  "-- bank balance always raised")

m("the bank balance is not moved at all",
  "create_deposit",
  "   where id = p_bank;",
  "   where id = null;  -- bank balance update hits nothing",
  "-- bank balance update hits nothing")

m("CONTROL -- a comment beside the document number",
  "create_deposit",
  "  v_no   := app.next_document_number_internal(p_org, 'deposit');",
  "  v_no   := app.next_document_number_internal(p_org, 'deposit');"
  "  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
