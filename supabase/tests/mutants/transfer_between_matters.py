# Mutants for public.transfer_between_matters -- moving a client's money
# from one of their matters to another.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0743_which_client_account_when_there_are_two.sql \
#       supabase/tests/matter_transfer.sql \
#       supabase/tests/mutants/transfer_between_matters.py
#
# Chosen as the riskiest target left: client money is regulated, the
# function has been redefined FIVE times (0358, 0690, 0696, 0698, 0739)
# and exactly ONE test file calls it. A function rewritten five times
# under a single file's worth of assertions is where a gap survives.
#
# RESULT, 5 October: 19 mutants, 10 killed on the first run and EIGHT
# SURVIVED -- the worst score of any function measured in this session,
# and the only one where survivors outnumbered a third of the set. Five
# were missing assertions; three were the one-bank-account fixture
# collapse; and chasing the last of those found a real defect, fixed in
# `0743`. After the work: 19 of 19 accounted for.
#
# `0739` writes `CREATE OR REPLACE FUNCTION` in UPPER CASE -- it is a
# bulk re-emission of 39 functions whose `p_date` defaults were on the
# wrong clock -- so a case-sensitive grep for the latest definition finds
# `0358` and is wrong by five migrations. `latest_defining()` in
# scripts/mutate_sql.py is `re.I` for exactly this, and refuses to run
# against anything but the latest.
#
# Three of these are regulatory rather than arithmetic, and are the ones
# worth the most:
#
#   * the client_id check -- money held for one client applied for
#     another is the breach the Legal Profession Act exists to prevent;
#   * `is_client_account` when choosing the bank -- paying client money
#     out of the office account is the same breach by another route;
#   * the two legs' signs -- a transfer whose out-leg is positive CREATES
#     client money. That one is asymmetric, so a journal-balance
#     assertion catches it; the sign SWAP is symmetric and does not.

m("a deleted matter can still be moved from",
  "transfer_between_matters",
  "   where id = p_from and deleted_at is null;",
  "   where id = p_from;  -- deleted_at dropped",
  "-- deleted_at dropped")

m("money crosses from one COMPANY's matter to another's",
  "transfer_between_matters",
  "   where id = p_to and deleted_at is null and org_id = v_from.org_id;",
  "   where id = p_to and deleted_at is null;  -- org check dropped",
  "-- org check dropped")

m("a company without the legal module can move client money",
  "transfer_between_matters",
  "  if not app.has_module(v_from.org_id, 'legal') then",
  "  if not app.has_module(v_from.org_id, 'legal') and false then"
  "  -- module check dropped",
  "-- module check dropped")

m("anybody may move client money",
  "transfer_between_matters",
  "  if not app.can_post(v_from.org_id) then",
  "  if not app.can_post(v_from.org_id) and false then  -- can_post dropped",
  "-- can_post dropped")

m("a matter may transfer to itself, and only to itself",
  "transfer_between_matters",
  "  if p_from = p_to then",
  "  if p_from <> p_to then  -- self-transfer check inverted",
  "-- self-transfer check inverted")

m("a transfer of nothing is allowed",
  "transfer_between_matters",
  "  if p_amount is null or p_amount <= 0 then",
  "  if p_amount is null or p_amount < 0 then  -- zero allowed",
  "-- zero allowed")

m("THE STATUTORY ONE: money held for one client is applied for another",
  "transfer_between_matters",
  "  if v_from.client_id <> v_to.client_id then",
  "  if v_from.client_id = v_to.client_id then  -- client check inverted",
  "-- client check inverted")

m("VOID transactions count towards what the matter holds",
  "transfer_between_matters",
  "   where t.matter_id = p_from and t.status <> 'void';",
  "   where t.matter_id = p_from;  -- void included",
  "-- void included")

m("a matter may be overdrawn",
  "transfer_between_matters",
  "  if v_held < p_amount then",
  "  if v_held < 0 then  -- sufficiency check gutted",
  "-- sufficiency check gutted")

m("moving exactly what the matter holds is refused",
  "transfer_between_matters",
  "  if v_held < p_amount then",
  "  if v_held <= p_amount then  -- exact balance refused",
  "-- exact balance refused")

m("THE OTHER STATUTORY ONE: the firm's OFFICE account is used",
  "transfer_between_matters",
  "   where org_id = v_from.org_id and is_client_account and is_active",
  "   where org_id = v_from.org_id and is_active  -- client-account dropped",
  "-- client-account dropped")

m("a closed client account is used",
  "transfer_between_matters",
  "   where org_id = v_from.org_id and is_client_account and is_active",
  "   where org_id = v_from.org_id and is_client_account"
  "  -- is_active dropped",
  "-- is_active dropped")

m("the NON-default client account is preferred",
  "transfer_between_matters",
  "   order by is_default desc, created_at, id limit 1;",
  "   order by is_default asc, created_at, id limit 1;"
  "  -- default preference reversed",
  "-- default preference reversed")

# 0743's own line. Dropping the tiebreak returns the function to what
# this run found: with no default client account the choice is made by
# physical row order. Firm B's fixture is built so the correct row and
# the first row are different ones, which is the only way this can be
# killed -- a fixture where the right account is also the first account
# cannot tell a total ordering from no ordering at all.
m("the tiebreak 0743 added is removed, so the choice is arbitrary again",
  "transfer_between_matters",
  "   order by is_default desc, created_at, id limit 1;",
  "   order by is_default desc limit 1;  -- tiebreak removed",
  "-- tiebreak removed")

m("the out-leg is positive, so the transfer CREATES client money",
  "transfer_between_matters",
  "     p_date, 'transfer_out', v_bank, -p_amount,",
  "     p_date, 'transfer_out', v_bank, p_amount,  -- out-leg sign flipped",
  "-- out-leg sign flipped")

m("both legs land on the matter the money came FROM",
  "transfer_between_matters",
  "    (v_from.org_id, p_to,",
  "    (v_from.org_id, p_from,  -- destination matter dropped",
  "-- destination matter dropped")

m("the two legs are labelled the wrong way round",
  "transfer_between_matters",
  "     p_date, 'transfer_in', v_bank, p_amount,",
  "     p_date, 'transfer_out', v_bank, p_amount,  -- in-leg relabelled",
  "-- in-leg relabelled")

m("the out-leg is never posted to the ledger",
  "transfer_between_matters",
  "  perform public.post_client_transaction(v_out);",
  "  -- post dropped: perform public.post_client_transaction(v_out);",
  "-- post dropped")

m("CONTROL -- a comment inside the function block",
  "transfer_between_matters",
  "  v_note := coalesce(nullif(btrim(p_description), ''),"
  " 'Transfer between matters');",
  "  v_note := coalesce(nullif(btrim(p_description), ''),"
  " 'Transfer between matters');  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
