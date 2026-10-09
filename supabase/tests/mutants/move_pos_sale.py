# Mutants for public.move_pos_sale (0213) -- a party changes tables and
# the bill goes with them: the bill must exist, be the caller's to sell
# on and still be parked; a null table is takeaway; the table must
# exist and be in the bill's own outlet.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0213_the_room_and_the_bill_on_it.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/move_pos_sale.py
#
# RESULT: 8 mutants and a control, all 8 killed by `pos_fnb.sql`;
# before its assertions, 3 -- takeaway, another outlet, and the move
# itself. Nothing had asked about a missing bill, a missing table, a
# stranger, a settled bill, or which module's permission it is (asked
# by switching the stock module off around one move; the mutant's
# refusal stops that move, which is the kill).
#
# Noted, not raised: a table out of service is not refused. The floor
# plan shows only tables in service, so a bill moved onto one leaves
# the plan -- it stays on the list of every open bill (0226), and the
# same state is reachable by taking an occupied table out of service
# directly, which the table policy allows.

F = "move_pos_sale"

m("a bill that does not exist is not refused", F,
  "  if v_sale.id is null then\n    raise exception 'No such sale.'",
  "  if false then  -- no such sale\n    raise exception 'No such sale.'",
  "-- no such sale")

m("anybody may move a bill", F,
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("the guard asks another module", F,
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if not app.can_write_module(v_sale.org_id, 'inventory') then  -- other module",
  "-- other module")

m("a settled bill is moved", F,
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("takeaway is not a move", F,
  "  if p_table is null then\n    update public.pos_sales s set table_id = null where s.id = p_sale;\n    return;\n  end if;",
  "  if p_table is null then\n    return;  -- takeaway ignored\n  end if;",
  "-- takeaway ignored")

m("a table that does not exist is not refused in words", F,
  "  if v_table.id is null then\n    raise exception 'No such table.'",
  "  if false then  -- no such table\n    raise exception 'No such table.'",
  "-- no such table")

m("a table in another outlet is taken", F,
  "  if v_table.outlet_id <> v_sale.outlet_id then",
  "  if false then  -- any outlet",
  "-- any outlet")

m("the bill stays where it was", F,
  "  update public.pos_sales s set table_id = p_table where s.id = p_sale;\nend;",
  "  update public.pos_sales s set table_id = v_sale.table_id where s.id = p_sale;  -- stays\nend;",
  "-- stays")

m("CONTROL", F,
  "  select * into v_table from public.pos_tables where id = p_table;",
  "  select * into v_table from public.pos_tables where id = p_table;  -- control",
  "-- control")
