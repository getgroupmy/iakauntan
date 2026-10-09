# Mutants for public.merge_pos_sales (0259) -- one parked bill folded
# into another and the emptied one DELETED: never into itself; both
# must exist, by somebody who may sell, both still parked, the same
# outlet; the moved lines numbered on after the receiving bill's last,
# in the order they stood; the count of lines moved returned; a
# redemption and a discount carried only when the receiving bill has
# none of its own -- a flat amount as well as a rate, with its reason,
# giver and time; two addresses refused, an address already out with a
# driver refused, a lone address carried; the dockets follow the food;
# the emptied bill gone and the receiving one re-added.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0259_an_address_a_fee_and_a_driver.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/merge_pos_sales.py
#
# Swept against three files, because the bill, the card and the address
# are three fixtures: `pos_fnb.sql`, then the survivors against
# `pos_loyalty.sql` (the redemption) and `pos_delivery.sql` (the
# address and the driver).
#
# RESULT: 25 mutants and a control, all killed; four before the
# rule-by-rule blocks -- the deleted bill, the re-add, and the two
# address mutants in `pos_delivery.sql`, one of them only because the
# unique index on `pos_deliveries.sale_id` threw something the test
# did not catch. The file's one merge folded a one-line bill with no
# discount, docket, redemption or address into another, so every
# carry-over rule and every one of the six refusals went unasked. A
# rate and a receiving bill's own rate each needed a bill rated while
# still EMPTY: once anything is rung up `bill_discount` holds the
# rate's amount too, and the two conditions cannot be told apart.

m("a bill is merged into itself",
  "merge_pos_sales",
  "  if p_into = p_from then",
  "  if false then  -- into itself",
  "-- into itself")

m("a bill that does not exist is merged from",
  "merge_pos_sales",
  "  if v_into.id is null or v_from.id is null then",
  "  if v_into.id is null then  -- from unchecked",
  "-- from unchecked")

m("a bill that does not exist is merged into",
  "merge_pos_sales",
  "  if v_into.id is null or v_from.id is null then",
  "  if v_from.id is null then  -- into unchecked",
  "-- into unchecked")

m("anybody merges bills",
  "merge_pos_sales",
  "  if not app.can_write_module(v_into.org_id, 'pos') then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a settled bill is merged from",
  "merge_pos_sales",
  "  if v_into.status <> 'parked' or v_from.status <> 'parked' then",
  "  if v_into.status <> 'parked' then  -- from any status",
  "-- from any status")

m("a settled bill is merged into",
  "merge_pos_sales",
  "  if v_into.status <> 'parked' or v_from.status <> 'parked' then",
  "  if v_from.status <> 'parked' then  -- into any status",
  "-- into any status")

m("bills in two outlets are merged",
  "merge_pos_sales",
  "  if v_into.outlet_id <> v_from.outlet_id then",
  "  if false then  -- any outlet",
  "-- any outlet")

m("the moved lines arrive backwards",
  "merge_pos_sales",
  "    select l.id from public.pos_sale_lines l where l.sale_id = p_from order by l.line_no",
  "    select l.id from public.pos_sale_lines l where l.sale_id = p_from order by l.line_no desc  -- backwards",
  "-- backwards")

m("the count is one, however many moved",
  "merge_pos_sales",
  "    v_n  := v_n + 1;",
  "    v_n  := 1;  -- count one",
  "-- count one")

m("a redemption is lost with the bill it was on",
  "merge_pos_sales",
  "  if coalesce(v_from.loyalty_points_redeemed, 0) > 0\n     and coalesce(v_into.loyalty_points_redeemed, 0) = 0 then",
  "  if false then  -- redemption lost\n",
  "-- redemption lost")

m("a redemption overwrites the receiving bill's own",
  "merge_pos_sales",
  "     and coalesce(v_into.loyalty_points_redeemed, 0) = 0 then",
  "     then  -- redemption overwrites",
  "-- redemption overwrites")

m("a redemption arrives without its discount",
  "merge_pos_sales",
  "           loyalty_discount = v_from.loyalty_discount\n     where s.id = p_into;",
  "           loyalty_discount = 0  -- no money\n     where s.id = p_into;",
  "-- no money")

m("a flat-amount discount is lost with the bill it was on",
  "merge_pos_sales",
  "  if (coalesce(v_from.bill_discount, 0) > 0\n      or coalesce(v_from.bill_discount_percent, 0) > 0)",
  "  if (coalesce(v_from.bill_discount_percent, 0) > 0)  -- rate only\n",
  "-- rate only")

m("a rate is lost with the bill it was on",
  "merge_pos_sales",
  "  if (coalesce(v_from.bill_discount, 0) > 0\n      or coalesce(v_from.bill_discount_percent, 0) > 0)",
  "  if (coalesce(v_from.bill_discount, 0) > 0)  -- amount only\n",
  "-- amount only")

m("a discount overwrites the receiving bill's flat amount",
  "merge_pos_sales",
  "     and coalesce(v_into.bill_discount, 0) = 0\n     and coalesce(v_into.bill_discount_percent, 0) = 0 then",
  "     and coalesce(v_into.bill_discount_percent, 0) = 0 then  -- over a flat amount",
  "-- over a flat amount")

m("a discount overwrites the receiving bill's rate",
  "merge_pos_sales",
  "     and coalesce(v_into.bill_discount, 0) = 0\n     and coalesce(v_into.bill_discount_percent, 0) = 0 then",
  "     and coalesce(v_into.bill_discount, 0) = 0 then  -- over a rate",
  "-- over a rate")

m("a carried discount loses its reason",
  "merge_pos_sales",
  "           bill_discount_reason  = v_from.bill_discount_reason,",
  "           bill_discount_reason  = null,  -- no reason",
  "-- no reason")

m("a carried discount loses its giver",
  "merge_pos_sales",
  "           bill_discounted_by    = v_from.bill_discounted_by,",
  "           bill_discounted_by    = null::uuid,  -- no giver",
  "-- no giver")

m("a carried discount loses its time",
  "merge_pos_sales",
  "           bill_discounted_at    = v_from.bill_discounted_at\n     where s.id = p_into;",
  "           bill_discounted_at    = null::timestamptz  -- no time\n     where s.id = p_into;",
  "-- no time")

m("two addresses are merged and one is lost",
  "merge_pos_sales",
  "    if exists (select 1 from public.pos_deliveries d where d.sale_id = p_into) then",
  "    if false then  -- both addresses kept",
  "-- both addresses kept")

m("a bill out with a driver is folded in",
  "merge_pos_sales",
  "                where d.sale_id = p_from and d.status <> 'pending') then",
  "                where false) then  -- out with a driver",
  "-- out with a driver")

m("a lone address is left on the bill that goes",
  "merge_pos_sales",
  "    update public.pos_deliveries d set sale_id = p_into, updated_at = now()\n     where d.sale_id = p_from;",
  "    update public.pos_deliveries d set sale_id = p_into, updated_at = now()\n     where false;  -- address left",
  "-- address left")

m("the dockets stay with the bill that goes",
  "merge_pos_sales",
  "  update public.pos_kitchen_tickets k set sale_id = p_into where k.sale_id = p_from;",
  "  update public.pos_kitchen_tickets k set sale_id = p_into where false;  -- dockets left",
  "-- dockets left")

m("the emptied bill is left on the floor",
  "merge_pos_sales",
  "  delete from public.pos_sales where id = p_from;",
  "  perform 1;  -- phantom",
  "-- phantom")

m("the receiving bill is not re-added",
  "merge_pos_sales",
  "  perform app.recalc_pos_sale(p_into);\n  return v_n;",
  "  perform 1;  -- stale\n  return v_n;",
  "-- stale")

m("CONTROL: a comment inside the block",
  "merge_pos_sales",
  "  if v_into.outlet_id <> v_from.outlet_id then",
  "  if v_into.outlet_id <> v_from.outlet_id then  -- (control)",
  "(control)")
