# Mutants for public.remove_pos_sale_promotion (0256) -- one promotion
# taken off an open bill: a row that exists, for somebody who may sell
# there, on a bill still parked; the row deleted, the bill re-added, the
# bill's id handed back.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0256_a_price_the_shop_decided_in_advance.sql \
#       supabase/tests/pos_promotion_admin.sql \
#       supabase/tests/mutants/remove_pos_sale_promotion.py
#
# RESULT: 7 mutants and a control, all 7 killed by
# `pos_promotion_admin.sql`, from 5: a stranger, and that one row goes
# and not every promotion on the bill (a bill carrying two promotions,
# since one promotion is one row however many lines it covers).

F = "remove_pos_sale_promotion"

m("a promotion that is not there is removed", F,
  "  if v_sale is null then\n    raise exception 'No such promotion on this bill.'",
  "  if false then  -- ghost\n    raise exception 'No such promotion on this bill.'",
  "-- ghost")
m("anybody may remove a promotion", F,
  "  if not app.can_write_module(v_org, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")
m("a settled bill loses its promotion", F,
  "  if v_status <> 'parked' then",
  "  if false then  -- settled changed",
  "-- settled changed")
m("the promotion stays", F,
  "  delete from public.pos_sale_promotions where id = p_row;",
  "  perform 1;  -- stays",
  "-- stays")
m("every promotion on the bill goes", F,
  "  delete from public.pos_sale_promotions where id = p_row;",
  "  delete from public.pos_sale_promotions where sale_id = v_sale;  -- all go",
  "-- all go")
m("the bill is not re-added", F,
  "  perform app.recalc_pos_sale(v_sale);\n  return v_sale;",
  "  perform 1;  -- unrecalculated\n  return v_sale;",
  "-- unrecalculated")
m("the bill's id is not handed back", F,
  "  return v_sale;\nend;",
  "  return null;  -- nothing back\nend;",
  "-- nothing back")

m("CONTROL", F,
  "  v_status app.pos_sale_status;\nbegin",
  "  v_status app.pos_sale_status;  -- control\nbegin",
  "-- control")
