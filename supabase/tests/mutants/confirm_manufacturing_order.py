# Mutants for public.confirm_manufacturing_order (0133) -- a draft order
# confirmed against its bill of materials: by somebody who may post, only
# a draft that has a BOM; components required at the recipe times how
# many recipes, GROSSED UP for scrap; operations planned at the recipe's
# minutes times the same; the order confirmed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0133_manufacturing.sql \
#       supabase/tests/manufacturing.sql \
#       supabase/tests/mutants/confirm_manufacturing_order.py
#
# RESULT: 11 mutants and a control, all killed by `manufacturing.sql`;
# two only after they were asserted -- the order that does not exist and
# one with no bill of materials. The scrap arithmetic was already pinned
# to 42.1053 (forty boards, five per cent wasted), which tells grossing
# up from deducting and from a straight percentage.

m("an order that does not exist is not said so",
  "confirm_manufacturing_order",
  "  if v_mo.id is null then\n    raise exception 'No such manufacturing order'",
  "  if false then  -- no such order\n    raise exception 'No such manufacturing order'",
  "-- no such order")

m("anybody confirms an order",
  "confirm_manufacturing_order",
  "  if not app.can_post(v_mo.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an order already confirmed is confirmed again",
  "confirm_manufacturing_order",
  "  if v_mo.status <> 'draft' then",
  "  if false then  -- any status",
  "-- any status")

m("an order with no bill of materials is confirmed",
  "confirm_manufacturing_order",
  "  if v_mo.bom_id is null then",
  "  if false then  -- no BOM",
  "-- no BOM")

m("the recipe's own output is ignored",
  "confirm_manufacturing_order",
  "  select v_mo.quantity / b.output_quantity into v_factor",
  "  select v_mo.quantity into v_factor  -- per one",
  "-- per one")

m("scrap is deducted rather than added",
  "confirm_manufacturing_order",
  "         round(l.quantity * v_factor / (1 - l.scrap_percent / 100), 4)",
  "         round(l.quantity * v_factor * (1 - l.scrap_percent / 100), 4)  -- deducted",
  "-- deducted")

m("scrap is added as a straight percentage",
  "confirm_manufacturing_order",
  "         round(l.quantity * v_factor / (1 - l.scrap_percent / 100), 4)",
  "         round(l.quantity * v_factor * (1 + l.scrap_percent / 100), 4)  -- simple percent",
  "-- simple percent")

m("scrap is ignored",
  "confirm_manufacturing_order",
  "         round(l.quantity * v_factor / (1 - l.scrap_percent / 100), 4)",
  "         round(l.quantity * v_factor, 4)  -- no scrap",
  "-- no scrap")

m("components are not written",
  "confirm_manufacturing_order",
  "   where l.bom_id = v_mo.bom_id\n   order by l.line_no;",
  "   where false  -- none\n   order by l.line_no;",
  "-- none")

m("planned minutes are the recipe's, whatever the quantity",
  "confirm_manufacturing_order",
  "         round(o.minutes * v_factor, 4)",
  "         round(o.minutes, 4)  -- minutes once",
  "-- minutes once")

m("the order is not marked confirmed",
  "confirm_manufacturing_order",
  "     set status = 'confirmed', updated_at = now()",
  "     set updated_at = now()  -- still draft",
  "-- still draft")

m("CONTROL: a comment inside the block",
  "confirm_manufacturing_order",
  "  if v_mo.bom_id is null then",
  "  if v_mo.bom_id is null then  -- (control)",
  "(control)")
