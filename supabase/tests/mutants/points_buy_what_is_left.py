# Mutants for app.recalc_pos_sale's trim and public.redeem_loyalty_points
# (0787) -- points buy what is left to pay after the bill discount and
# the promotions; a redemption a later change outgrew is trimmed to the
# whole points that fit; the redemption replaces, and reports what the
# sale finally carries; and the guard is the loyalty module's, not the
# till's.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0787_points_buy_what_is_left_to_pay.sql \
#       supabase/tests/pos_loyalty.sql \
#       supabase/tests/mutants/points_buy_what_is_left.py
#
# RESULT: 11 mutants and a control. 8 killed by `pos_loyalty.sql`, all
# by `0787`'s own block -- including the guard, which no file had ever
# asked with the till on and the scheme off, and which `0787` itself
# nearly regressed: `0212`'s file text says 'pos', and production runs
# `0231`'s runtime rewrite of it to 'loyalty'.
#
# Three are EQUIVALENT, for one reason: the recalculation's trim. Every
# redemption ends in `app.recalc_pos_sale`, which cuts any redemption
# to what is left after the discounts, and the function then reads back
# what the sale carries. So pricing the request against the raw lines,
# counting the delivery fee as payable by points, and reporting the
# points ASKED for each produce a figure the trim corrects before
# anything sees it. The redemption's own pricing is kept so it says
# what it does, and so the trim is a guard rather than the rule.

R = "recalc_pos_sale"
P = "redeem_loyalty_points"

m("the trim never happens", R,
  "  if v_loy > v_room then",
  "  if false then  -- never trimmed",
  "-- never trimmed")

m("the room ignores the bill discount", R,
  "  v_room := greatest(round(v_gross - v_bill - v_promo, 2), 0);",
  "  v_room := greatest(round(v_gross - v_promo, 2), 0);  -- bill ignored",
  "-- bill ignored")

m("the room ignores the promotions", R,
  "  v_room := greatest(round(v_gross - v_bill - v_promo, 2), 0);",
  "  v_room := greatest(round(v_gross - v_bill, 2), 0);  -- promo ignored",
  "-- promo ignored")

m("a trimmed redemption rounds the points up", R,
  "      floor(v_room / nullif(v_per_point, 0))::integer, 0);",
  "      ceil(v_room / nullif(v_per_point, 0))::integer, 0);  -- rounded up",
  "-- rounded up")

m("the trim keeps the old points", R,
  "       set loyalty_points_redeemed = least(s.loyalty_points_redeemed, v_points),",
  "       set loyalty_points_redeemed = s.loyalty_points_redeemed,  -- points kept",
  "-- points kept")

m("the trim keeps the old discount", R,
  "           loyalty_discount = v_loy\n     where s.id = p_sale;\n  end if;",
  "           loyalty_discount = loyalty_discount  -- discount kept\n     where s.id = p_sale;\n  end if;",
  "-- discount kept")

m("the redemption is priced against the lines (as before 0787)", P,
  "  select greatest(s.total_amount - coalesce(s.delivery_fee, 0), 0)\n    into v_basket from public.pos_sales s where s.id = p_sale;",
  "  select coalesce(sum(l.line_subtotal), 0) + coalesce(sum(l.tax_amount), 0)  -- lines\n    into v_basket from public.pos_sale_lines l where l.sale_id = p_sale;",
  "-- lines")

m("an earlier redemption stacks", P,
  "  update public.pos_sales s\n     set loyalty_points_redeemed = 0, loyalty_discount = 0\n   where s.id = p_sale;\n  perform app.recalc_pos_sale(p_sale);\n  select greatest",
  "  perform app.recalc_pos_sale(p_sale);  -- stacks\n  select greatest",
  "-- stacks")

m("the delivery fee is spent on points", P,
  "  select greatest(s.total_amount - coalesce(s.delivery_fee, 0), 0)",
  "  select greatest(s.total_amount, 0)  -- fee included",
  "-- fee included")

m("it reports the points asked for, not the points carried", P,
  "  points_after := v_balance - points_applied;",
  "  points_applied := v_points; points_after := v_balance - v_points;  -- asked",
  "-- asked")

m("the guard is the till's (as before 0231)", P,
  "  if not app.can_write_module(v_sale.org_id, 'loyalty') then",
  "  if not app.can_write_module(v_sale.org_id, 'pos') then  -- till guard",
  "-- till guard")

m("CONTROL: a comment inside the block", R,
  "  if v_loy > v_room then",
  "  if v_loy > v_room then  -- (control)",
  "(control)")
