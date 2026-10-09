# Mutants for public.void_pos_sale_line (0244) -- one line taken off a
# parked bill as a loss: by somebody who may sell AND has the void grant,
# never "other" without a word; the line copied to the void record with
# its reason, note, figures and who, then removed and the bill re-added.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0244_voiding_is_its_own_grant.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/void_pos_sale_line.py
#
# RESULT: 12 mutants and a control, all killed across two files, the
# control surviving: `pos_fnb.sql` kills what the loss is worth, when it
# went to the kitchen, the reason, the line removed and the bill re-added;
# `pos_void_permission.sql` the grant and who -- and, only after its
# rule-by-rule assertions, the line that does not exist, somebody who
# may not sell, a bill no longer parked, "other" without a word, and the
# note trimmed.

m("a line that does not exist is not said so",
  "void_pos_sale_line",
  "  if v_line.id is null then\n    raise exception 'No such line.'",
  "  if false then  -- no such line\n    raise exception 'No such line.'",
  "-- no such line")

m("anybody voids a line",
  "void_pos_sale_line",
  "  if not app.can_write_module(v_line.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a seller without the void grant voids a line",
  "void_pos_sale_line",
  "  if not app.can_void_pos(v_line.org_id) then",
  "  if false then  -- no grant needed",
  "-- no grant needed")

m("a line on a paid bill is voided",
  "void_pos_sale_line",
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("'other' needs no word",
  "void_pos_sale_line",
  "  if p_reason = 'other' and coalesce(btrim(p_note), '') = '' then",
  "  if false then  -- other unexplained",
  "-- other unexplained")

m("the void record forgets the reason",
  "void_pos_sale_line",
  "    v_line.line_total, v_line.sent_to_kitchen_at, p_reason,",
  "    v_line.line_total, v_line.sent_to_kitchen_at, 'other',  -- reason lost",
  "-- reason lost")

m("the void record keeps the note's spaces",
  "void_pos_sale_line",
  "    nullif(btrim(p_note), ''), auth.uid())\n  returning id into v_void;",
  "    p_note, auth.uid())  -- untrimmed\n  returning id into v_void;",
  "-- untrimmed")

m("the void record does not say who",
  "void_pos_sale_line",
  "    nullif(btrim(p_note), ''), auth.uid())\n  returning id into v_void;",
  "    nullif(btrim(p_note), ''), null)  -- nobody\n  returning id into v_void;",
  "-- nobody")

m("the void record loses what it was worth",
  "void_pos_sale_line",
  "    v_line.line_total, v_line.sent_to_kitchen_at, p_reason,",
  "    0, v_line.sent_to_kitchen_at, p_reason,  -- worth nothing",
  "-- worth nothing")

m("the void record forgets when it went to the kitchen",
  "void_pos_sale_line",
  "    v_line.line_total, v_line.sent_to_kitchen_at, p_reason,",
  "    v_line.line_total, null, p_reason,  -- never sent",
  "-- never sent")

m("the line stays on the bill",
  "void_pos_sale_line",
  "  delete from public.pos_sale_lines where id = p_line;",
  "  perform 1;  -- line stays",
  "-- line stays")

m("the bill is not added up again",
  "void_pos_sale_line",
  "  perform app.recalc_pos_sale(v_line.sale_id);",
  "  perform 1;  -- stale total",
  "-- stale total")

m("CONTROL: a comment inside the block",
  "void_pos_sale_line",
  "  if v_sale.status <> 'parked' then",
  "  if v_sale.status <> 'parked' then  -- (control)",
  "(control)")
