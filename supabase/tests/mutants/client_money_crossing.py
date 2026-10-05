# Mutants for the three client-money movers in `0549`: money in, money
# out, and the crossing from client account to office.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0549_the_transfer_that_has_to_arrive_somewhere.sql \
#       supabase/tests/client_money_crossing.sql \
#       supabase/tests/mutants/client_money_crossing.py
#
# Then again against `supabase/tests/client_account.sql`, which is the
# only other file that reaches any of them: a per-file score understates
# the suite, and running one file nearly produced three false alarms
# earlier in this session.
#
# Picked by `scripts/mutation_targets.py`, which ranks money movers by
# how many test files reach them and how many times they have been
# redefined. `public.pay_from_client_account` came top: one file, and
# the same family as `transfer_between_matters`, which scored worst of
# anything measured (19 mutants, 8 survived, one a real defect).
#
# RESULT, 5 October: 21 mutants, 13 killed on the first run and EIGHT
# SURVIVED. 21 of 21 killed after the work; nothing was equivalent.
#
#   client_money_crossing.sql  kills 13, then all 21
#   client_account.sql         kills NONE of the 21 -- it names
#                              receive_client_money but asserts other
#                              things, so the union is one file
#
# The eight were the same three families found in matter_transfer.sql
# the same day, which is the finding worth more than the eight:
#
#   * THREE unasserted `can_post` guards, one per function. A stranger
#     could pay money onto a matter, pay it out, and cross it to office.
#   * `status <> 'void'` in the payout check, so a bounced receipt
#     funded a disbursement.
#   * FOUR bank-selection rules on receive_client_money collapsed into
#     one account, because the fixture's ordering landed on the client
#     account whichever rule was doing the work.
#
# Three kinds of claim, as with the other money functions:
#
#   * the REFUSALS -- and there are many, several sharing a SQLSTATE and
#     most of a sentence, which is exactly where a `%fragment%`
#     assertion passes against the wrong guard. That trap cost a
#     survivor on transfer_between_matters an hour ago.
#   * WHICH ACCOUNT -- client money must sit in a client account and
#     must leave to an office one. Getting either backwards is the
#     regulatory failure, not an arithmetic one.
#   * the SIGNS -- a payment out recorded as money in is asymmetric, so
#     a balance assertion catches it; swapping refund for payment is
#     symmetric and only a type assertion can.

# ----------------------------------------------------------------- in
m("money may be received for a company with no legal module",
  "receive_client_money",
  "  if not app.has_module(v_org, 'legal') then\n"
  "    raise exception 'Client accounting is part of the legal module'",
  "  if not app.has_module(v_org, 'legal') and false then  -- module dropped\n"
  "    raise exception 'Client accounting is part of the legal module'",
  "-- module dropped")

m("a stranger may pay money onto a matter",
  "receive_client_money",
  "  if not app.can_post(v_org) then\n"
  "    raise exception 'Insufficient privileges to move client money'\n"
  "      using errcode = '42501';\n  end if;\n  if p_amount is null"
  " or p_amount <= 0 then\n    raise exception 'Money received on account",
  "  if not app.can_post(v_org) and false then  -- can_post dropped\n"
  "    raise exception 'Insufficient privileges to move client money'\n"
  "      using errcode = '42501';\n  end if;\n  if p_amount is null"
  " or p_amount <= 0 then\n    raise exception 'Money received on account",
  "-- can_post dropped")

m("a receipt of nothing is allowed",
  "receive_client_money",
  "  if p_amount is null or p_amount <= 0 then\n"
  "    raise exception 'Money received on account",
  "  if p_amount is null or p_amount < 0 then  -- zero allowed\n"
  "    raise exception 'Money received on account",
  "-- zero allowed")

m("client money IN lands in the office account",
  "receive_client_money",
  "   where b.org_id = v_org and b.is_client_account and b.is_active\n"
  "   order by b.is_default desc, b.created_at\n   limit 1;\n"
  "  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "   where b.org_id = v_org and b.is_active  -- client-account dropped\n"
  "   order by b.is_default desc, b.created_at\n   limit 1;\n"
  "  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "-- client-account dropped")

m("money IN may land in a CLOSED client account",
  "receive_client_money",
  "   where b.org_id = v_org and b.is_client_account and b.is_active\n"
  "   order by b.is_default desc, b.created_at\n   limit 1;\n"
  "  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "   where b.org_id = v_org and b.is_client_account  -- is_active dropped\n"
  "   order by b.is_default desc, b.created_at\n   limit 1;\n"
  "  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "-- is_active dropped")

m("money IN prefers the NON-default client account",
  "receive_client_money",
  "   order by b.is_default desc, b.created_at\n   limit 1;\n"
  "  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "   order by b.is_default asc, b.created_at  -- default reversed\n"
  "   limit 1;\n  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "-- default reversed")

m("money IN drops the created_at tiebreak",
  "receive_client_money",
  "   order by b.is_default desc, b.created_at\n   limit 1;\n"
  "  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "   order by b.is_default desc  -- tiebreak dropped\n"
  "   limit 1;\n  if v_bank is null then\n"
  "    raise exception 'No client account is configured. Run the legal setup '",
  "-- tiebreak dropped")

# ---------------------------------------------------------------- out
m("a stranger may pay OUT of the client account",
  "pay_from_client_account",
  "  if not app.can_post(v_org) then",
  "  if not app.can_post(v_org) and false then  -- can_post dropped",
  "-- can_post dropped")

m("VOID transactions count towards what the matter can pay out",
  "pay_from_client_account",
  "   where t.matter_id = p_matter and t.status <> 'void';\n"
  "  if p_amount > v_held then",
  "   where t.matter_id = p_matter;  -- void included\n"
  "  if p_amount > v_held then",
  "-- void included")

m("a matter may pay out more than it holds",
  "pay_from_client_account",
  "  if p_amount > v_held then\n    raise exception\n"
  "      'Matter % holds % and cannot pay out %. Money held for one matter '",
  "  if false then  -- overdraft guard dropped\n    raise exception\n"
  "      'Matter % holds % and cannot pay out %. Money held for one matter '",
  "-- overdraft guard dropped")

m("paying out exactly what it holds is refused",
  "pay_from_client_account",
  "  if p_amount > v_held then\n    raise exception\n"
  "      'Matter % holds % and cannot pay out %. Money held for one matter '",
  "  if p_amount >= v_held then  -- exact payout refused\n    raise exception\n"
  "      'Matter % holds % and cannot pay out %. Money held for one matter '",
  "-- exact payout refused")

m("a payment OUT is recorded as money IN",
  "pay_from_client_account",
  "          v_bank, -p_amount,",
  "          v_bank, p_amount,  -- sign flipped",
  "-- sign flipped")

m("a payment is recorded as a refund and a refund as a payment",
  "pay_from_client_account",
  "          (case when p_refund then 'refund' else 'payment' end)",
  "          (case when p_refund then 'payment' else 'refund' end)"
  "  -- types swapped",
  "-- types swapped")

# ----------------------------------------------------------- crossing
m("a stranger may cross client money to office",
  "settle_from_client_account",
  "  if not app.can_post(v_org) then",
  "  if not app.can_post(v_org) and false then  -- can_post dropped",
  "-- can_post dropped")

m("ANOTHER MATTER'S invoice may be settled from this matter's money",
  "settle_from_client_account",
  "    if v_inv.matter_id <> p_matter then",
  "    if v_inv.matter_id = p_matter then  -- matter check inverted",
  "-- matter check inverted")

m("an unattributed invoice for ANOTHER CLIENT may be settled",
  "settle_from_client_account",
  "  elsif v_inv.contact_id is distinct from v_client then",
  "  elsif v_inv.contact_id is not distinct from v_client then"
  "  -- client check inverted",
  "-- client check inverted")

m("more may be crossed than the matter holds",
  "settle_from_client_account",
  "  if p_amount > v_held then\n    raise exception\n"
  "      'Matter % holds % and cannot transfer %. Money held for one matter '",
  "  if false then  -- held guard dropped\n    raise exception\n"
  "      'Matter % holds % and cannot transfer %. Money held for one matter '",
  "-- held guard dropped")

m("more may be crossed than the INVOICE owes",
  "settle_from_client_account",
  "  if p_amount > v_owing then",
  "  if false then  -- owing guard dropped",
  "-- owing guard dropped")

m("a NAMED client account is accepted as the destination",
  "settle_from_client_account",
  "    if v_is_client then\n      raise exception\n"
  "        'The money has to leave the client account.",
  "    if v_is_client and false then  -- client destination allowed\n"
  "      raise exception\n"
  "        'The money has to leave the client account.",
  "-- client destination allowed")

m("the crossing lands back in the CLIENT account, moving nothing",
  "settle_from_client_account",
  "     where b.org_id = v_org and not b.is_client_account and b.is_active",
  "     where b.org_id = v_org and b.is_client_account and b.is_active"
  "  -- office destination inverted",
  "-- office destination inverted")

m("CONTROL -- a comment inside the function block",
  "pay_from_client_account",
  "  perform public.post_client_transaction(v_id);\n  return v_id;",
  "  perform public.post_client_transaction(v_id);"
  "  -- CONTROL: this cannot change a number.\n  return v_id;",
  "-- CONTROL: this cannot change a number.")
