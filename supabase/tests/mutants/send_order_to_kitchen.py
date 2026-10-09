# Mutants for public.send_order_to_kitchen (0220) -- the lines the
# kitchen has never seen, sent: the sale must exist; somebody who may
# sell; anything but a voided sale (paid is fine -- a kiosk cooks after
# the money); never with a required choice unanswered; only unsent
# lines; every line must route somewhere; ONE docket per station per
# send, carrying the table, the covers, and each line's quantity,
# modifiers and note; the lines stamped sent; only this send's dockets
# returned.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0220_a_customer_serving_themselves.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/send_order_to_kitchen.py
#
# then against `pos_void_permission.sql`, which adds none.
#
# RESULT: 14 mutants and a control, all killed by `pos_fnb.sql`; six
# before its rule-by-rule block. Every send was of a parked table bill
# by the owner, at an outlet where everything routes, with no note on
# any line, and only the docket's lines were ever read -- so the table,
# the covers, the note, a paid order (a kiosk cooks after the money), a
# voided one, a line with nowhere to go, a missing sale and a stranger
# were all unasked.

m("a sale that does not exist is not said so",
  "send_order_to_kitchen",
  "  if v_sale.id is null then\n    raise exception 'No such sale.'",
  "  if false then  -- no such sale\n    raise exception 'No such sale.'",
  "-- no such sale")

m("anybody sends an order",
  "send_order_to_kitchen",
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a voided order is sent",
  "send_order_to_kitchen",
  "  if v_sale.status = 'voided' then",
  "  if false then  -- voided too",
  "-- voided too")

m("a paid order is not sent",
  "send_order_to_kitchen",
  "  if v_sale.status = 'voided' then",
  "  if v_sale.status <> 'parked' then  -- parked only",
  "-- parked only")

m("a choice still to make is sent anyway",
  "send_order_to_kitchen",
  "  if v_gaps > 0 then",
  "  if false then  -- gaps ignored",
  "-- gaps ignored")

m("a line already sent is sent again",
  "send_order_to_kitchen",
  "       and l.sent_to_kitchen_at is null\n     order by l.line_no",
  "       and true  -- resend\n     order by l.line_no",
  "-- resend")

m("a line with nowhere to go is lost",
  "send_order_to_kitchen",
  "    if v_st is null then\n      raise exception\n        'Nothing tells the kitchen where",
  "    if false then  -- no route\n      raise exception\n        'Nothing tells the kitchen where",
  "-- no route")

m("each line gets its own docket",
  "send_order_to_kitchen",
  "    v_ticket := (v_made ->> v_st::text)::uuid;",
  "    v_ticket := null;  -- a docket a line",
  "-- a docket a line")

m("the docket does not say which table",
  "send_order_to_kitchen",
  "      values (v_sale.org_id, v_sale.outlet_id, v_st, p_sale, v_table,\n              v_sale.covers, v_now, auth.uid())",
  "      values (v_sale.org_id, v_sale.outlet_id, v_st, p_sale, null,  -- no table\n              v_sale.covers, v_now, auth.uid())",
  "-- no table")

m("the docket does not say how many covers",
  "send_order_to_kitchen",
  "              v_sale.covers, v_now, auth.uid())",
  "              null, v_now, auth.uid())  -- no covers",
  "-- no covers")

m("the docket line loses the quantity",
  "send_order_to_kitchen",
  "    values (v_sale.org_id, v_ticket, v_line.id, v_line.description, v_line.quantity,",
  "    values (v_sale.org_id, v_ticket, v_line.id, v_line.description, 1,  -- one of each",
  "-- one of each")

m("the docket line loses the note",
  "send_order_to_kitchen",
  "            app.pos_line_modifier_text(v_line.id), v_line.note);",
  "            app.pos_line_modifier_text(v_line.id), null);  -- no note",
  "-- no note")

m("the line is not stamped sent",
  "send_order_to_kitchen",
  "       set sent_to_kitchen_at = v_now where l.id = v_line.id;",
  "       set sent_to_kitchen_at = null where l.id = v_line.id;  -- never sent",
  "-- never sent")

m("every docket the sale ever had is returned",
  "send_order_to_kitchen",
  "     where k.id in (select (value #>> '{}')::uuid from jsonb_each(v_made))",
  "     where k.sale_id = p_sale  -- every docket",
  "-- every docket")

m("CONTROL: a comment inside the block",
  "send_order_to_kitchen",
  "  if v_gaps > 0 then",
  "  if v_gaps > 0 then  -- (control)",
  "(control)")
