# Mutants for public.split_pos_sale (0255) -- some lines of a parked bill
# moved to a second bill at the same table: by somebody who may sell;
# only a parked bill, only lines that are on it, never all of them; the
# second bill the same in every way but its lines -- table, covers, note,
# customer, and a bill discount RATE but not a flat amount; the lines
# renumbered from one on the new bill; both bills re-added.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0255_a_price_the_manager_takes_off.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/split_pos_sale.py
#
# RESULT: 18 mutants and a control, all killed by `pos_fnb.sql`; four of
# the first fourteen before its rule-by-rule block. The split the file
# already made was of a walk-in bill with no covers, note or discount,
# whose one moved line was line 1 -- so dropping the customer, the
# covers, the rate or the renumbering left the second bill exactly as
# it should have been. Its only refusal was "the whole bill"; the other
# five guards could be removed without a sound.

m("a bill that does not exist is not said so",
  "split_pos_sale",
  "  if v_sale.id is null then\n    raise exception 'No such sale.'",
  "  if false then  -- no such sale\n    raise exception 'No such sale.'",
  "-- no such sale")

m("anybody splits a bill",
  "split_pos_sale",
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a paid bill is split",
  "split_pos_sale",
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("a split naming no lines goes ahead",
  "split_pos_sale",
  "  if p_lines is null or array_length(p_lines, 1) is null then",
  "  if false then  -- no lines named",
  "-- no lines named")

m("lines from another bill go ahead",
  "split_pos_sale",
  "  if v_moved = 0 then",
  "  if false then  -- none of ours",
  "-- none of ours")

m("the whole bill is split off",
  "split_pos_sale",
  "  if v_moved = v_total then",
  "  if false then  -- whole bill",
  "-- whole bill")

m("the second bill is at no table",
  "split_pos_sale",
  "     set table_id = v_sale.table_id,",
  "     set table_id = null,  -- no table",
  "-- no table")

m("the second bill forgets the covers",
  "split_pos_sale",
  "         covers = v_sale.covers,",
  "         covers = null,  -- no covers",
  "-- no covers")

m("the second bill is for nobody",
  "split_pos_sale",
  "  v_new := public.open_pos_sale(v_sale.register_id, v_sale.contact_id);",
  "  v_new := public.open_pos_sale(v_sale.register_id, null);  -- walk-in",
  "-- walk-in")

m("the discount rate does not follow the food",
  "split_pos_sale",
  "         bill_discount_percent = v_sale.bill_discount_percent,",
  "         bill_discount_percent = 0,  -- rate dropped",
  "-- rate dropped")

m("a flat-amount discount's reason follows too",
  "split_pos_sale",
  "           case when coalesce(v_sale.bill_discount_percent, 0) > 0\n                then v_sale.bill_discount_reason end,",
  "           v_sale.bill_discount_reason,  -- reason always\n",
  "-- reason always")

m("the moved lines keep their old numbers",
  "split_pos_sale",
  "       set sale_id = v_new, line_no = v_no",
  "       set sale_id = v_new  -- old numbers",
  "-- old numbers")

m("the first bill is not re-added",
  "split_pos_sale",
  "  perform app.recalc_pos_sale(p_sale);\n  perform app.recalc_pos_sale(v_new);",
  "  perform 1;  -- first stale\n  perform app.recalc_pos_sale(v_new);",
  "-- first stale")

m("the second bill is not added up",
  "split_pos_sale",
  "  perform app.recalc_pos_sale(p_sale);\n  perform app.recalc_pos_sale(v_new);",
  "  perform app.recalc_pos_sale(p_sale);\n  perform 1;  -- second stale",
  "-- second stale")

m("a flat-amount discount's giver follows too",
  "split_pos_sale",
  "         bill_discounted_by    =\n           case when coalesce(v_sale.bill_discount_percent, 0) > 0\n                then v_sale.bill_discounted_by end,",
  "         bill_discounted_by    =\n           v_sale.bill_discounted_by,  -- giver always\n",
  "-- giver always")

m("the second bill forgets the note",
  "split_pos_sale",
  "         note = v_sale.note,",
  "         note = null,  -- no note",
  "-- no note")

m("a rate's giver is forgotten",
  "split_pos_sale",
  "                then v_sale.bill_discounted_by end,",
  "                then null::uuid end,  -- giver forgotten",
  "-- giver forgotten")

m("the moved lines are numbered backwards",
  "split_pos_sale",
  "     order by l.line_no\n  loop",
  "     order by l.line_no desc  -- backwards\n  loop",
  "-- backwards")

m("CONTROL: a comment inside the block",
  "split_pos_sale",
  "  if v_sale.status <> 'parked' then",
  "  if v_sale.status <> 'parked' then  -- (control)",
  "(control)")
