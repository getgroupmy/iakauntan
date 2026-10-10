# Mutants for public.check_in_booking (0790) -- the customer arrives:
# the booking must exist, be the caller's to sell on, and not be
# cancelled or a no-show; a second check-in returns the linked bill
# unless it was voided (0790); the register must exist in the booking's
# outlet; the bill is the customer's, carries the service at the QUOTED
# price, and the diary says they arrived.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0790_a_voided_bill_does_not_keep_the_customer_waiting.sql \
#       supabase/tests/pos_service.sql \
#       supabase/tests/mutants/a_voided_bill_does_not_keep_the_customer_waiting.py
#
# RESULT: 12 mutants and a control, all 12 killed by `pos_service.sql`;
# before its assertions, 2 -- a second check-in opening a second bill,
# and the diary told. Nothing had asked about a missing booking, a
# cancelled or no-show appointment, a missing register or one in
# another outlet, whose bill it is, the quoted price against a price
# that moved since, a SETTLED appointment (which must not be reopened
# the way a voided one now is), or a stranger.
#
# The stranger first survived: `open_pos_sale` refuses one in the same
# words, so removing this function's guard changed nothing -- on the
# road the test took. On an appointment already checked in, the
# function returns the open bill without reaching `open_pos_sale`, and
# there its own guard is the only one. That is asked now.

F = "check_in_booking"

m("a booking that does not exist is not refused in words", F,
  "  if v_b.id is null then\n    raise exception 'No such booking.'",
  "  if false then  -- no such booking\n    raise exception 'No such booking.'",
  "-- no such booking")

m("anybody may check a customer in", F,
  "  if not app.can_write_module(v_b.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a cancelled appointment is checked in", F,
  "  if v_b.status in ('cancelled', 'no_show') then",
  "  if v_b.status in ('no_show') then  -- cancelled taken",
  "-- cancelled taken")

m("a no-show is checked in", F,
  "  if v_b.status in ('cancelled', 'no_show') then",
  "  if v_b.status in ('cancelled') then  -- no-show taken",
  "-- no-show taken")

m("0790 undone: a voided bill is returned", F,
  "  if v_b.sale_id is not null\n     and exists (select 1 from public.pos_sales s\n                  where s.id = v_b.sale_id and s.status <> 'voided') then",
  "  if v_b.sale_id is not null then  -- voided returned",
  "-- voided returned")

m("only a parked bill is returned", F,
  "                  where s.id = v_b.sale_id and s.status <> 'voided') then",
  "                  where s.id = v_b.sale_id and s.status = 'parked') then  -- parked only",
  "-- parked only")

m("a second check-in opens a second bill", F,
  "  if v_b.sale_id is not null\n     and exists (select 1 from public.pos_sales s\n                  where s.id = v_b.sale_id and s.status <> 'voided') then",
  "  if false then  -- always new",
  "-- always new")

m("a register that does not exist is not refused in words", F,
  "  if v_out is null then\n    raise exception 'No such register.'",
  "  if false then  -- no such register\n    raise exception 'No such register.'",
  "-- no such register")

m("a register in another outlet takes the appointment", F,
  "  if v_out <> v_b.outlet_id then",
  "  if false then  -- any outlet",
  "-- any outlet")

m("the bill is nobody's", F,
  "  v_sale := public.open_pos_sale(p_register, v_b.contact_id);",
  "  v_sale := public.open_pos_sale(p_register, null);  -- nobody's",
  "-- nobody's")

m("the service is rung at today's price, not the quote", F,
  "    perform public.add_pos_sale_line(v_sale, v_b.item_id, 1, v_b.price);",
  "    perform public.add_pos_sale_line(v_sale, v_b.item_id, 1, null);  -- today's price",
  "-- today's price")

m("the diary is not told they arrived", F,
  "     set status = 'arrived', sale_id = v_sale where b.id = p_booking;",
  "     set sale_id = v_sale where b.id = p_booking;  -- not arrived",
  "-- not arrived")

m("CONTROL", F,
  "  select r.outlet_id into v_out from public.pos_registers r where r.id = p_register;",
  "  select r.outlet_id into v_out from public.pos_registers r where r.id = p_register;  -- control",
  "-- control")
