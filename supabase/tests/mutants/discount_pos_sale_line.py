# Mutants for public.discount_pos_sale_line (0255) -- money taken off one
# line of a parked bill: by somebody with the discount grant; a
# percentage OR an amount, measured against the line at FULL price so a
# second discount replaces rather than compounds; never negative, never
# more than the line; a reason whenever anything comes off; the line's
# net and tax re-split the way it was added (tax inside the price or on
# top of it); who, why and when kept only then; the bill re-added.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0255_a_price_the_manager_takes_off.sql \
#       supabase/tests/pos.sql \
#       supabase/tests/mutants/discount_pos_sale_line.py
#
# RESULT: 17 mutants and a control, all killed by `pos.sql`; fourteen
# only after its rule-by-rule block. "More than the line" survived a test
# that asserted exactly that refusal, because it caught `check_violation`
# and the negative line trips a different check on the way out -- the
# block asserts each refusal by its own sentence. The tax split needed a
# taxed line, on top of the price and inside it.

m("a line that does not exist is not said so",
  "discount_pos_sale_line",
  "  if v_line.id is null then\n    raise exception 'No such line.'",
  "  if false then  -- no such line\n    raise exception 'No such line.'",
  "-- no such line")

m("anybody takes money off a line",
  "discount_pos_sale_line",
  "  if not app.can_discount_pos(v_line.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a line on a paid bill is discounted",
  "discount_pos_sale_line",
  "  if v_status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("a percentage and an amount together are taken",
  "discount_pos_sale_line",
  "  if p_percent is not null and p_amount is not null then",
  "  if false then  -- both",
  "-- both")

m("a discount compounds on what is left",
  "discount_pos_sale_line",
  "  v_full := round(v_line.unit_price * v_line.quantity, 2);",
  "  v_full := round(v_line.line_subtotal, 2);  -- what is left",
  "-- what is left")

m("a percentage out of range is taken",
  "discount_pos_sale_line",
  "    if p_percent < 0 or p_percent > 100 then",
  "    if false then  -- any percent",
  "-- any percent")

m("a negative amount is taken",
  "discount_pos_sale_line",
  "    if p_amount < 0 then",
  "    if false then  -- negative amount",
  "-- negative amount")

m("more than the line is taken off",
  "discount_pos_sale_line",
  "    if p_amount > v_full then",
  "    if false then  -- over the line",
  "-- over the line")

m("exactly the line is too much",
  "discount_pos_sale_line",
  "    if p_amount > v_full then",
  "    if p_amount >= v_full then  -- exact refused",
  "-- exact refused")

m("money comes off with no reason",
  "discount_pos_sale_line",
  "  if v_amt > 0 and v_reason is null then",
  "  if false then  -- no reason",
  "-- no reason")

m("tax inside the price is added on top",
  "discount_pos_sale_line",
  "  if v_line.is_tax_inclusive and v_line.tax_rate > 0 then",
  "  if false then  -- always on top",
  "-- always on top")

m("tax on top is left off",
  "discount_pos_sale_line",
  "    v_tax := round(v_net * v_line.tax_rate / 100.0, 2);",
  "    v_tax := 0;  -- untaxed",
  "-- untaxed")

m("the line total leaves out the tax",
  "discount_pos_sale_line",
  "         line_total       = v_net + v_tax,",
  "         line_total       = v_net,  -- no tax in total",
  "-- no tax in total")

m("the reason is not kept",
  "discount_pos_sale_line",
  "         discount_reason  = case when v_amt > 0 then v_reason end,",
  "         discount_reason  = null,  -- no reason kept",
  "-- no reason kept")

m("who gave it is not kept",
  "discount_pos_sale_line",
  "         discounted_by    = case when v_amt > 0 then auth.uid() end,",
  "         discounted_by    = null,  -- nobody",
  "-- nobody")

m("clearing it still names who",
  "discount_pos_sale_line",
  "         discounted_by    = case when v_amt > 0 then auth.uid() end,",
  "         discounted_by    = auth.uid(),  -- always named",
  "-- always named")

m("the bill is not re-added",
  "discount_pos_sale_line",
  "  perform app.recalc_pos_sale(v_line.sale_id);\n  return p_line;",
  "  perform 1;  -- stale\n  return p_line;",
  "-- stale")

m("CONTROL: a comment inside the block",
  "discount_pos_sale_line",
  "  if v_status <> 'parked' then",
  "  if v_status <> 'parked' then  -- (control)",
  "(control)")
