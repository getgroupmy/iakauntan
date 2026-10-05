# Mutants for public.remit_withholding -- paying over to LHDN the tax
# withheld from a non-resident payment, which closes the certificate.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/withholding_shapes.sql \
#       supabase/tests/mutants/remit_withholding.py
#
# then again against `withholding.sql`.
#
# RESULT, 5 October: 23 mutants (22 plus a control). 10 killed on
# `withholding_shapes.sql` and 13 survived; `withholding.sql` kills
# three more. 19 of 22 across both, with THREE proven EQUIVALENT. The
# control lived.
#
# THE HEADLINE IS WHY THIS FUNCTION WAS SWEPT AT ALL. It is not high in
# `mutation_targets.py`'s ranking; it was swept because
# dispose_fixed_asset's sweep found that two of `0729`'s own fixes had
# no behavioural test, and this is the other of the two functions that
# migration touched. The same fix was missing here too: a grep of all
# 384 assertion files for the refusal 0729 added -- "nothing for a
# reconciliation to match" -- found it in ONE file, written an hour
# earlier for the disposal.
#
# AND THE BLOCK THAT TESTS THIS FUNCTION'S BANK ACCOUNT IS THOROUGH.
# `withholding_shapes.sql` has four assertions on the cross-tenant
# guard, each naming the mutant it kills ("MUTANT: the
# cross-organization guard removed", and so on). The fallback six lines
# below it was never touched. A sweep that measured one guard carefully
# left the one beside it at zero -- which is the same failure the
# function's own header describes about `0506`: "its header's 'neither
# needed changing' was about that guard and said nothing about the
# fallback; it was read as a verdict on the whole function."
#
# THE OTHER REAL GAP WAS THE FOREIGN CURRENCY, which for a withholding
# certificate is the ORDINARY case -- the tax exists because the payee
# is a non-resident. Every certificate in the file is MYR at rate 1,
# where `tax_amount * coalesce(rate, 1)`, `tax_amount` and
# `round(x, 0)` are all the same number: three mutants in one collapse.
# USD 7,333.33 at 4.2135 is 30,898.99, which is none of the three.
#
# THE THREE EQUIVALENTS are each proven, and one of them in a new way:
# by the table's constraints rather than the code's shape. See the
# notes above each.
#
# Swept because of what dispose_fixed_asset's sweep found, not because
# the ranking put it high. `0729` closed the 1120 fallback in exactly
# TWO live posting paths and this is the other one -- and a grep of all
# 384 assertion files for the refusal it added
# ("nothing for a reconciliation to match") found it in ONE file: the
# one written an hour ago for the disposal. So the same fix shipped
# untested twice, and the function's own header says why it survived:
#
#   "`0506` read this function and left it alone, correctly, for the
#    cross-tenant guard above. Its header's 'neither needed changing'
#    was about that guard and said nothing about the fallback; it was
#    read as a verdict on the whole function."
#
# A verdict on part of a function read as a verdict on the function is
# the same failure as a comment naming a gap being read as the
# assertion that closes it -- which is what recurring_shapes.sql had.

m("anybody can remit the tax",
  "remit_withholding",
  "  if not app.can_post(c.org_id) then",
  "  if false then  -- remit post guard dropped",
  "-- remit post guard dropped")

m("an UNPOSTED certificate can be remitted",
  "remit_withholding",
  "  if c.gl_entry_id is null then",
  "  if false then  -- unposted certificate accepted",
  "-- unposted certificate accepted")

m("a certificate already remitted is remitted again",
  "remit_withholding",
  "  if c.remitted_on is not null then",
  "  if false then  -- repeat remittance accepted",
  "-- repeat remittance accepted")

m("the tax can be paid from ANOTHER COMPANY's bank account",
  "remit_withholding",
  "  if p_bank_account_id is not null\n"
  "     and not exists (select 1 from public.bank_accounts b\n"
  "                      where b.id = p_bank_account_id and b.org_id = c.org_id)",
  "  if false\n"
  "     and not exists (select 1 from public.bank_accounts b\n"
  "                      where b.id = p_bank_account_id and b.org_id = c.org_id)"
  "  -- remit foreign bank guard dropped",
  "-- remit foreign bank guard dropped")

m("the tax can be paid from NO account at all -- 0729's fix",
  "remit_withholding",
  "  if p_bank_account_id is null then\n"
  "    raise exception\n"
  "      'Say which account the remittance was paid from.",
  "  if false then\n"
  "    raise exception\n"
  "      'Say which account the remittance was paid from.  -- bankless remittance accepted",
  "-- bankless remittance accepted")

# EQUIVALENT, with the one below it, and proven by shape. The
# cross-tenant guard thirty lines above has already refused any
# p_bank_account_id outside this company, and the null guard has
# refused a missing one, so neither this conjunct nor the balance
# update's can exclude a row the id would not have missed anyway. The
# guard above is what makes them redundant, which is also why they are
# right to keep: an edit to it makes them load-bearing again.
m("the ledger account is resolved without regard to the company",
  "remit_withholding",
  "   where b.id = p_bank_account_id and b.org_id = c.org_id;\n"
  "  if v_bank is null then",
  "   where b.id = p_bank_account_id;  -- remit ledger org scope dropped\n"
  "  if v_bank is null then",
  "-- remit ledger org scope dropped")

m("the remittance is not converted at the certificate's rate",
  "remit_withholding",
  "  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);",
  "  v_base := round(c.tax_amount, 2);  -- rate ignored",
  "-- rate ignored")

# EQUIVALENT, and proven by the TABLE rather than by the code -- a kind
# of proof this sweep had not used before.
# `withholding_certificates.exchange_rate` is NOT NULL, defaults to 1,
# and carries `check (exchange_rate > 0)`. So `coalesce(c.exchange_rate,
# 1)` can never see a null: no fixture can build the state, because the
# column refuses it. Right to keep -- a later migration that made the
# column nullable would make the coalesce load-bearing the same day --
# but nothing can distinguish it today.
m("a certificate with NO rate is converted at nothing",
  "remit_withholding",
  "  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);",
  "  v_base := round(c.tax_amount * c.exchange_rate, 2);  -- rate fallback dropped",
  "-- rate fallback dropped")

m("the remittance loses its sen",
  "remit_withholding",
  "  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 2);",
  "  v_base := round(c.tax_amount * coalesce(c.exchange_rate, 1), 0);"
  "  -- remittance rounded to ringgit",
  "-- remittance rounded to ringgit")

m("the withholding liability is CREDITED rather than cleared",
  "remit_withholding",
  "        'debit', v_base, 'credit', 0),",
  "        'debit', 0, 'credit', v_base),  -- liability side swapped",
  "-- liability side swapped")

m("the money does not leave the bank in the ledger",
  "remit_withholding",
  "        'debit', 0, 'credit', v_base)),",
  "        'debit', v_base, 'credit', 0)),  -- bank side swapped",
  "-- bank side swapped")

m("the remittance is dated the day it was typed",
  "remit_withholding",
  "    c.org_id, p_paid_on, 'withholding'::app.journal_source,",
  "    c.org_id, app.today(), 'withholding'::app.journal_source,"
  "  -- remittance date forced to today",
  "-- remittance date forced to today")

m("the journal does not point back at the certificate",
  "remit_withholding",
  "    'withholding_certificates', c.id,",
  "    'withholding_certificates', null,  -- source certificate forgotten",
  "-- source certificate forgotten")

m("the form code is not carried when no reference is given",
  "remit_withholding",
  "    coalesce(p_reference, c.form_code));",
  "    p_reference);  -- form code fallback dropped",
  "-- form code fallback dropped")

m("the reference given is ignored for the form code",
  "remit_withholding",
  "    coalesce(p_reference, c.form_code));",
  "    c.form_code);  -- given reference ignored",
  "-- given reference ignored")

m("the bank balance is not reduced",
  "remit_withholding",
  "     set current_balance = current_balance - v_base",
  "     set current_balance = current_balance  -- bank balance not reduced",
  "-- bank balance not reduced")

m("the bank balance is RAISED by the remittance",
  "remit_withholding",
  "     set current_balance = current_balance - v_base",
  "     set current_balance = current_balance + v_base"
  "  -- bank balance raised",
  "-- bank balance raised")

m("the remittance balance update reaches ANOTHER COMPANY's account",
  "remit_withholding",
  "   where id = p_bank_account_id\n     and org_id = c.org_id;",
  "   where id = p_bank_account_id;  -- balance update org scope dropped",
  "-- balance update org scope dropped")

m("WHEN the tax was remitted is not recorded",
  "remit_withholding",
  "     set remitted_on = p_paid_on, remittance_ref = p_reference,",
  "     set remitted_on = app.today(), remittance_ref = p_reference,"
  "  -- remitted_on forced to today",
  "-- remitted_on forced to today")

m("the remittance reference is not kept on the certificate",
  "remit_withholding",
  "     set remitted_on = p_paid_on, remittance_ref = p_reference,",
  "     set remitted_on = p_paid_on, remittance_ref = null,"
  "  -- remittance ref not kept",
  "-- remittance ref not kept")

m("the certificate does not remember the remittance journal",
  "remit_withholding",
  "         remittance_gl_entry_id = v_entry, status = 'completed'",
  "         remittance_gl_entry_id = null, status = 'completed'"
  "  -- remittance entry not kept",
  "-- remittance entry not kept")

m("a remitted certificate is not marked completed",
  "remit_withholding",
  "         remittance_gl_entry_id = v_entry, status = 'completed'",
  "         remittance_gl_entry_id = v_entry  -- status not advanced",
  "-- status not advanced")

m("CONTROL -- a comment beside the withholding account",
  "remit_withholding",
  "  v_wht := app.withholding_account(c.org_id);",
  "  v_wht := app.withholding_account(c.org_id);"
  "  -- CONTROL: this cannot change an account.",
  "-- CONTROL: this cannot change an account.")
