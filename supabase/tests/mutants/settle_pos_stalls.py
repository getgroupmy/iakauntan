# Mutants for public.settle_pos_stalls (0268) -- each stall in a food
# court paid its takings less commission for a period that is over: by
# somebody who may write purchases, never for a period that ends before
# it starts or has not ended yet, never twice for the same days; one
# posted bill per stall that sold anything, to its operator, dated the
# last day, at the net, on the stall purchases account, and the
# settlement recorded against it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0268_the_food_court_and_what_each_stall_is_owed.sql \
#       supabase/tests/pos_food_court.sql \
#       supabase/tests/mutants/settle_pos_stalls.py
#
# RESULT: 20 mutants and a control, all killed by `pos_food_court.sql`.
# Nine only after its rule-by-rule section: the outlet that does not
# exist, who may settle (a member who may write POS and only read
# purchases), a period ending before it starts, the bill's date and due
# date -- invisible while every settlement was one day long, so the first
# and the last were the same -- the settlement's net, bill and settler,
# and the net answered. "The bill is to nobody" is killed by the NOT NULL
# on a bill's contact, which refuses the whole settlement.

m("an outlet that does not exist is not said so",
  "settle_pos_stalls",
  "  if v_org is null then\n    raise exception 'No such outlet.'",
  "  if false then  -- no such outlet\n    raise exception 'No such outlet.'",
  "-- no such outlet")

m("anybody settles the stalls",
  "settle_pos_stalls",
  "  if not app.can_write_module(v_org, 'purchases') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a period that ends before it starts is settled",
  "settle_pos_stalls",
  "  if p_to < p_from then",
  "  if false then  -- backwards",
  "-- backwards")

m("a period ending TODAY is settled",
  "settle_pos_stalls",
  "  if p_to >= (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if p_to > (now() at time zone 'Asia/Kuala_Lumpur')::date then  -- today allowed",
  "-- today allowed")

m("a period not over is settled at all",
  "settle_pos_stalls",
  "  if p_to >= (now() at time zone 'Asia/Kuala_Lumpur')::date then",
  "  if false then  -- any period",
  "-- any period")

m("a stall that sold nothing is billed",
  "settle_pos_stalls",
  "     where t.gross > 0",
  "     where t.gross >= 0  -- nothing sold billed",
  "-- nothing sold billed")

m("a stall settled for those days is settled again",
  "settle_pos_stalls",
  "    if v_row.settled then",
  "    if false then  -- twice",
  "-- twice")

m("the bill is dated the first day, not the last",
  "settle_pos_stalls",
  "      v_org, 'bill', v_no, p_to, p_to,",
  "      v_org, 'bill', v_no, p_from, p_to,  -- first day",
  "-- first day")

m("the bill falls due on the first day",
  "settle_pos_stalls",
  "      v_org, 'bill', v_no, p_to, p_to,",
  "      v_org, 'bill', v_no, p_to, p_from,  -- due first day",
  "-- due first day")

m("the bill is to nobody",
  "settle_pos_stalls",
  "      (select s.operator_contact_id from public.pos_stalls s\n        where s.id = v_row.stall_id),",
  "      null,  -- nobody",
  "-- nobody")

m("the stall is paid its gross, commission and all",
  "settle_pos_stalls",
  "      1, v_row.net, v_acct);",
  "      1, v_row.gross, v_acct);  -- gross",
  "-- gross")

m("the bill is left a draft",
  "settle_pos_stalls",
  "    perform public.post_purchase_document(v_bill);",
  "    perform 1;  -- left draft",
  "-- left draft")

m("the settlement records gross as net",
  "settle_pos_stalls",
  "      v_org, v_row.stall_id, p_from, p_to, v_row.gross, v_row.commission,\n      v_row.net, v_bill, auth.uid());",
  "      v_org, v_row.stall_id, p_from, p_to, v_row.gross, v_row.commission,\n      v_row.gross, v_bill, auth.uid());  -- net is gross",
  "-- net is gross")

m("the settlement records no commission",
  "settle_pos_stalls",
  "      v_org, v_row.stall_id, p_from, p_to, v_row.gross, v_row.commission,",
  "      v_org, v_row.stall_id, p_from, p_to, v_row.gross, 0,  -- no commission",
  "-- no commission")

m("the settlement does not point at its bill",
  "settle_pos_stalls",
  "      v_row.net, v_bill, auth.uid());",
  "      v_row.net, null, auth.uid());  -- no bill",
  "-- no bill")

m("who settled is not recorded",
  "settle_pos_stalls",
  "      v_row.net, v_bill, auth.uid());",
  "      v_row.net, v_bill, null);  -- nobody settled",
  "-- nobody settled")

m("the answer gives the gross as the net",
  "settle_pos_stalls",
  "    net        := v_row.net;",
  "    net        := v_row.gross;  -- answers gross",
  "-- answers gross")

m("the answer names no bill",
  "settle_pos_stalls",
  "    bill_no    := v_no;",
  "    bill_no    := null;  -- no bill number",
  "-- no bill number")

m("a period nobody sold in returns nothing quietly",
  "settle_pos_stalls",
  "  if not v_any then",
  "  if false then  -- quiet",
  "-- quiet")

m("CONTROL: a comment inside the block",
  "settle_pos_stalls",
  "  if p_to < p_from then",
  "  if p_to < p_from then  -- (control)",
  "(control)")
