# Mutants for public.add_line_free_modifier (0251) -- an answer typed at
# the till: the line must exist and be the caller's to sell on, its
# bill still open, the quantity positive; the question must be this
# company's, being asked, and open to typed answers; the answer must
# say something, fit on a docket, and never take money off; the menu
# price is snapshotted and the line repriced.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0251_an_answer_that_is_not_on_the_list.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/add_line_free_modifier.py
#
# RESULT: 16 mutants and a control, all 16 killed by `pos_fnb.sql`;
# before its assertions, 7 -- the closed question, the blank and the
# untrimmed answer, sixty-one characters, money off, the snapshot, the
# repricing. Nothing had asked about a missing line, a stranger, a
# settled bill, no quantity, a missing question, another company's
# question, a question no longer asked, exactly sixty characters, or a
# typed quantity of two.
#
# Noted, not raised: unlike a listed answer, a typed one is not checked
# against the questions the ITEM asks -- any active question of the
# company that takes typed answers can be put on any plate. It can only
# add to the price, so it is a docket-tidiness question, not a money one.

F = "add_line_free_modifier"

m("a line that does not exist is not refused in words", F,
  "  if v_line.id is null then\n    raise exception 'No such line.'",
  "  if false then  -- no such line\n    raise exception 'No such line.'",
  "-- no such line")

m("anybody may type onto a plate", F,
  "  if not app.can_write_module(v_line.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a settled bill takes a typed answer", F,
  "  if v_stat <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("no quantity is a quantity", F,
  "  if coalesce(p_quantity, 0) <= 0 then",
  "  if false then  -- any quantity",
  "-- any quantity")

m("another company's question is taken", F,
  "  if v_group.id is null or v_group.org_id <> v_line.org_id then",
  "  if v_group.id is null then  -- any company",
  "-- any company")

m("a question that does not exist is not refused in words", F,
  "  if v_group.id is null or v_group.org_id <> v_line.org_id then",
  "  if v_group.org_id <> v_line.org_id then  -- missing passes",
  "-- missing passes")

m("a question not being asked takes an answer", F,
  "  if not v_group.is_active then",
  "  if false then  -- inactive asked",
  "-- inactive asked")

m("a closed question takes a typed answer", F,
  "  if not v_group.allows_free_text then",
  "  if false then  -- always open",
  "-- always open")

m("the answer is not trimmed", F,
  "  v_name := btrim(coalesce(p_name, ''));",
  "  v_name := coalesce(p_name, '');  -- untrimmed",
  "-- untrimmed")

m("an empty answer is taken", F,
  "  if v_name = '' then",
  "  if false then  -- empty taken",
  "-- empty taken")

m("sixty characters is too long", F,
  "  if length(v_name) > 60 then",
  "  if length(v_name) >= 60 then  -- fifty-nine",
  "-- fifty-nine")

m("sixty-one characters fit", F,
  "  if length(v_name) > 60 then",
  "  if length(v_name) > 61 then  -- sixty-one",
  "-- sixty-one")

m("money comes off", F,
  "  if coalesce(p_price_delta, 0) < 0 then",
  "  if false then  -- discount",
  "-- discount")

m("the menu price is not snapshotted", F,
  "  if v_line.base_unit_price is null then\n    update public.pos_sale_lines l\n       set base_unit_price = l.unit_price where l.id = p_line;\n  end if;",
  "  -- no snapshot",
  "-- no snapshot")

m("the quantity typed is ignored", F,
  "          coalesce(p_price_delta, 0), p_quantity)",
  "          coalesce(p_price_delta, 0), 1)  -- one only",
  "-- one only")

m("the line is not repriced", F,
  "  perform app.reprice_pos_line(p_line);\n  return v_id;",
  "  -- no reprice\n  return v_id;",
  "-- no reprice")

m("CONTROL", F,
  "  select * into v_group from public.pos_modifier_groups where id = p_group;",
  "  select * into v_group from public.pos_modifier_groups where id = p_group;  -- control",
  "-- control")
