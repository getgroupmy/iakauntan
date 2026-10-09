# Mutants for public.remove_pos_sale_line (0225) -- a keystroke taken
# back: the line must exist; somebody who may sell; only on a parked
# bill; never once it has gone to the kitchen (that is a void, with a
# reason); the line gone and the bill re-added.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0225_taking_something_off_the_bill.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/remove_pos_sale_line.py
#
# then against `pos.sql` and `pos_void_permission.sql`, which add none.
#
# RESULT: 6 mutants and a control, all killed by `pos_fnb.sql`; three
# before three refusals were added. Three files took a line off a bill
# and none ever asked for a missing line, a closed bill or a stranger.

m("a line that does not exist is not said so",
  "remove_pos_sale_line",
  "  if v_line.id is null then\n    raise exception 'No such line.'",
  "  if false then  -- no such line\n    raise exception 'No such line.'",
  "-- no such line")

m("anybody takes a line off",
  "remove_pos_sale_line",
  "  if not app.can_write_module(v_line.org_id, 'pos') then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a line comes off a paid bill",
  "remove_pos_sale_line",
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any bill",
  "-- any bill")

m("a line that went to the kitchen comes off without a word",
  "remove_pos_sale_line",
  "  if v_line.sent_to_kitchen_at is not null then",
  "  if false then  -- cooked too",
  "-- cooked too")

m("the line stays",
  "remove_pos_sale_line",
  "  delete from public.pos_sale_lines where id = p_line;",
  "  perform 1;  -- kept",
  "-- kept")

m("the bill is not re-added",
  "remove_pos_sale_line",
  "  perform app.recalc_pos_sale(v_line.sale_id);\nend;",
  "  perform 1;  -- stale\nend;",
  "-- stale")

m("CONTROL: a comment inside the block",
  "remove_pos_sale_line",
  "  if v_sale.status <> 'parked' then",
  "  if v_sale.status <> 'parked' then  -- (control)",
  "(control)")
