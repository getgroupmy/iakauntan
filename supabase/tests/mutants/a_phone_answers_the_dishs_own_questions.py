# Mutants for public.place_public_pos_order (0796) -- a phone's order
# from a QR menu takes answers only to the questions its dish asks (the
# active ones the phone is shown), and every question the dish requires
# answered, asked of the lines this order made.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0796_a_phone_answers_the_dishs_own_questions.sql \
#       supabase/tests/pos_public_menu.sql \
#       supabase/tests/mutants/a_phone_answers_the_dishs_own_questions.py
#
# RESULT: 10 mutants and a control, all 10 killed by
# `pos_public_menu.sql`, every order placed as `anon`.
#
# The grant by hand: `anon`'s EXECUTE revoked, the file fails on its
# first order ("permission denied"), and `function_grants.sql` fails
# naming the function; restored, both pass. Neither did before `0796`:
# this file placed every order as the superuser, and the allowlist asked
# only what was open, never whether what it listed still was -- and the
# first draft of `0796` left the grant off, as `0165`'s event trigger
# takes it on every replace.

F = "place_public_pos_order"

m("any answer on any dish", F,
  "           and pm.id = (v_mod ->> 'modifier')::uuid) then",
  "           and pm.id = (v_mod ->> 'modifier')::uuid) and false then  -- any answer",
  "-- any answer")
m("any of the shop's questions, not the dish's", F,
  "         where img.item_id = v_item\n           and pm.id = (v_mod ->> 'modifier')::uuid) then",
  "         where img.org_id = v_org  -- shop's questions\n           and pm.id = (v_mod ->> 'modifier')::uuid) then",
  "-- shop's questions")
m("a retired question still takes answers", F,
  "          join public.pos_modifier_groups g on g.id = img.group_id and g.is_active\n          join public.pos_modifiers pm",
  "          join public.pos_modifier_groups g on g.id = img.group_id  -- retired asked\n          join public.pos_modifiers pm",
  "-- retired asked")
m("the dish's name is not said", F,
  "    select i.name into v_name from public.items i where i.id = v_item;",
  "    v_name := null;  -- nameless",
  "-- nameless")

m("a required question need not be answered", F,
  "    if found then\n      raise exception '% needs % to \"%\".', v_name,",
  "    if false then  -- unrequired\n      raise exception '% needs % to \"%\".', v_name,",
  "-- unrequired")
m("a retired question is still required", F,
  "      join public.pos_modifier_groups g on g.id = img.group_id and g.is_active\n     where img.item_id = v_item\n       and g.min_select > 0",
  "      join public.pos_modifier_groups g on g.id = img.group_id  -- retired required\n     where img.item_id = v_item\n       and g.min_select > 0",
  "-- retired required")
m("the minimum itself is not enough", F,
  "           < g.min_select\n     order by img.sort_order, g.name",
  "           <= g.min_select  -- one more\n     order by img.sort_order, g.name",
  "-- one more")
m("one answer anywhere on the bill answers every plate", F,
  "                      where m.line_id = v_line and m.group_id = g.id), 0)\n           < g.min_select",
  "                      where m.line_id in (select l.id from public.pos_sale_lines l where l.sale_id = v_sale) and m.group_id = g.id), 0)  -- bill-wide\n           < g.min_select",
  "-- bill-wide")
m("one answer counts once however many were asked for", F,
  "       and coalesce((select sum(m.quantity)::integer\n                       from public.pos_sale_line_modifiers m\n                      where m.line_id = v_line",
  "       and coalesce((select count(*)::integer  -- counted once\n                       from public.pos_sale_line_modifiers m\n                      where m.line_id = v_line",
  "-- counted once")
m("every required question is said as one", F,
  "        case when v_gap.min_select = 1 then 'an answer'",
  "        case when true then 'an answer'  -- singular",
  "-- singular")

m("CONTROL", F,
  "  v_gap    record;\nbegin",
  "  v_gap    record;  -- control\nbegin",
  "-- control")
