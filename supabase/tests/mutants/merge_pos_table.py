# Mutants for public.merge_pos_table (0245) -- a split table put back
# together: a table that exists, for somebody who may sell, that is
# split; never with two parties' bills open on its halves; the whole
# table back in service, the one open bill moved onto it, the halves
# retired, not deleted.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0245_a_long_table_is_two_tables.sql \
#       supabase/tests/pos_fnb.sql \
#       supabase/tests/mutants/merge_pos_table.py
#
# RESULT: 11 mutants and a control, all 11 killed by `pos_fnb.sql`, from
# 6: a table that is not there, a stranger, a table merged twice (its
# retired halves counted as parts), a voided bill on one half counted as
# a party, and another split table's halves retired with it -- each only
# after the rule-by-rule lines beside the merge assertions.

F = "merge_pos_table"

m("a table that is not there is merged", F,
  "  if v_table.id is null then\n    raise exception 'No such table.'",
  "  if false then  -- ghost\n    raise exception 'No such table.'",
  "-- ghost")
m("anybody may merge", F,
  "  if not app.can_write_module(v_table.org_id, 'pos') then\n    raise exception 'not permitted to sell for this organization'",
  "  if false then  -- anybody\n    raise exception 'not permitted to sell for this organization'",
  "-- anybody")
m("a half merges only itself", F,
  "  v_parent := coalesce(v_table.parent_table_id, v_table.id);",
  "  v_parent := v_table.id;  -- half only",
  "-- half only")
m("a table never split is merged", F,
  "  if v_parts = 0 then",
  "  if false then  -- unsplit merges",
  "-- unsplit merges")
m("retired halves count as parts", F,
  "   where t.parent_table_id = v_parent and t.is_active;\n  if v_parts = 0 then",
  "   where t.parent_table_id = v_parent;  -- retired count\n  if v_parts = 0 then",
  "-- retired count")
m("two parties are merged onto one table", F,
  "  if v_open > 1 then",
  "  if v_open > 2 then  -- two parties",
  "-- two parties")
m("a settled bill counts as a party", F,
  "   where t.parent_table_id = v_parent and t.is_active\n     and s.status = 'parked';\n\n  if v_open > 1 then",
  "   where t.parent_table_id = v_parent and t.is_active;  -- settled count\n\n  if v_open > 1 then",
  "-- settled count")
m("the whole table stays out of service", F,
  "  update public.pos_tables t set is_active = true where t.id = v_parent;",
  "  perform 1;  -- parent stays out",
  "-- parent stays out")
m("the party stays at the half", F,
  "    update public.pos_sales s set table_id = v_parent where s.id = v_sale;",
  "    perform 1;  -- party left behind",
  "-- party left behind")
m("the halves stay in service", F,
  "     set is_active = false\n   where t.parent_table_id = v_parent;",
  "     set is_active = true  -- halves stay\n   where t.parent_table_id = v_parent;",
  "-- halves stay")
m("the halves are retired from every table", F,
  "     set is_active = false\n   where t.parent_table_id = v_parent;",
  "     set is_active = false\n   where t.parent_table_id is not null;  -- every half",
  "-- every half")

m("CONTROL", F,
  "  v_codes  text;\nbegin",
  "  v_codes  text;  -- control\nbegin",
  "-- control")
