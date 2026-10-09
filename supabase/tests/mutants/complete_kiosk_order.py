# Mutants for public.complete_kiosk_order (0220) -- paying at the
# machine: the order must exist and be the caller's to sell on; the
# tender must be this company's, in use, and not cash; the order takes
# its number before it completes, is paid with one tender for the
# amount given or the bill, goes straight to an active kitchen if the
# outlet has one, and says what it came to.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0220_a_customer_serving_themselves.sql \
#       supabase/tests/pos_kiosk.sql \
#       supabase/tests/mutants/complete_kiosk_order.py
#
# RESULT: 13 mutants and a control. 10 killed by `pos_kiosk.sql`; before
# its assertions, 6 -- cash, the number kept and said, the default
# amount, the reference, the kitchen told. Nothing had asked about a
# missing order, a kitchen switched off (the order then goes nowhere),
# or the invoice and total the machine is told to print.
#
# Three are EQUIVALENT, for one reason: the sale is completed by
# `complete_pos_sale` (0546), which asks the same two questions in the
# same words -- `can_write_module(..., 'pos')`, and a tender of this
# company that is in use. Remove the kiosk's own copy and the inner one
# refuses identically. The assertions stay (a stranger, another
# company's tender, a tender out of use): they hold whichever copy
# answers, and fail if both go.

F = "complete_kiosk_order"

m("an order that does not exist is not refused in words", F,
  "  if v_sale.id is null then\n    raise exception 'No such order.'",
  "  if false then  -- no such order\n    raise exception 'No such order.'",
  "-- no such order")

m("anybody may pay for an order", F,
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("another company's tender is accepted", F,
  "   where tt.id = p_tender and tt.org_id = v_sale.org_id and tt.is_active;",
  "   where tt.id = p_tender and tt.is_active;  -- any company",
  "-- any company")

m("a tender out of use is accepted", F,
  "   where tt.id = p_tender and tt.org_id = v_sale.org_id and tt.is_active;",
  "   where tt.id = p_tender and tt.org_id = v_sale.org_id;  -- retired taken",
  "-- retired taken")

m("cash is taken at a machine", F,
  "  if v_kind = 'cash' then",
  "  if false then  -- cash taken",
  "-- cash taken")

m("the order keeps no number", F,
  "  update public.pos_sales s set order_no = v_no where s.id = p_sale;",
  "  -- no number kept",
  "-- no number kept")

m("the bill is not the default amount", F,
  "      'amount', coalesce(p_amount, v_sale.total_amount),",
  "      'amount', p_amount,  -- no default",
  "-- no default")

m("the reference is dropped", F,
  "      'reference', p_reference))) r;",
  "      'reference', null))) r;  -- no reference",
  "-- no reference")

m("a kitchen switched off is sent to", F,
  "              where st.outlet_id = v_sale.outlet_id and st.is_active) then",
  "              where st.outlet_id = v_sale.outlet_id) then  -- any station",
  "-- any station")

m("the kitchen is not told", F,
  "    perform public.send_order_to_kitchen(p_sale);",
  "    null;  -- kitchen untold",
  "-- kitchen untold")

m("the number is not said", F,
  "  order_no   := v_no;",
  "  order_no   := null;  -- no number said",
  "-- no number said")

m("the invoice is not said", F,
  "  invoice_no := v_done.invoice_no;",
  "  invoice_no := null;  -- no invoice said",
  "-- no invoice said")

m("the total is not said", F,
  "  total      := v_done.total;",
  "  total      := null;  -- no total said",
  "-- no total said")

m("CONTROL", F,
  "  v_no := app.next_kiosk_order_no(v_sale.outlet_id);",
  "  v_no := app.next_kiosk_order_no(v_sale.outlet_id);  -- control",
  "-- control")
