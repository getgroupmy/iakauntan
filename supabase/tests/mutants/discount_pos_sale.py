# Mutants for public.discount_pos_sale (0255) -- money taken off a whole
# parked bill: by somebody with the discount grant; a percentage OR an
# amount, the percentage 0..100, the amount not negative and not more
# than the bill; a reason whenever anything comes off; who and when
# recorded only then; the bill re-added, and the discount it came to
# answered.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0255_a_price_the_manager_takes_off.sql \
#       supabase/tests/pos.sql \
#       supabase/tests/mutants/discount_pos_sale.py
#
# RESULT: 17 mutants and a control, all killed by `pos.sql` -- and every
# one of them only after its rule-by-rule block. Before it, none of the
# four files that call this killed a single mutant: each discounts a
# bill and then adds a line, which re-adds the bill whatever the
# discount did; none tries a refusal; and none has tax on the bill, so a
# percentage of what the customer pays and of the subtotal were one
# figure.

m("a sale that does not exist is not said so",
  "discount_pos_sale",
  "  if v_sale.id is null then\n    raise exception 'No such sale.'",
  "  if false then  -- no such sale\n    raise exception 'No such sale.'",
  "-- no such sale")

m("anybody takes money off a bill",
  "discount_pos_sale",
  "  if not app.can_discount_pos(v_sale.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a paid bill is discounted",
  "discount_pos_sale",
  "  if v_sale.status <> 'parked' then",
  "  if false then  -- any status",
  "-- any status")

m("a percentage and an amount together are taken",
  "discount_pos_sale",
  "  if p_percent is not null and p_amount is not null then",
  "  if false then  -- both",
  "-- both")

m("a negative percentage is taken",
  "discount_pos_sale",
  "    if p_percent < 0 or p_percent > 100 then",
  "    if p_percent > 100 then  -- negative percent",
  "-- negative percent")

m("more than a hundred per cent is taken",
  "discount_pos_sale",
  "    if p_percent < 0 or p_percent > 100 then",
  "    if p_percent < 0 then  -- over a hundred",
  "-- over a hundred")

m("the percentage is of the subtotal, before tax",
  "discount_pos_sale",
  "  v_gross := round(coalesce(v_sale.subtotal, 0) + coalesce(v_sale.tax_amount, 0), 2);",
  "  v_gross := round(coalesce(v_sale.subtotal, 0), 2);  -- before tax",
  "-- before tax")

m("a negative amount is taken",
  "discount_pos_sale",
  "    if p_amount < 0 then",
  "    if false then  -- negative amount",
  "-- negative amount")

m("more than the bill is taken off",
  "discount_pos_sale",
  "    if p_amount > v_gross then",
  "    if false then  -- over the bill",
  "-- over the bill")

m("exactly the bill is too much",
  "discount_pos_sale",
  "    if p_amount > v_gross then",
  "    if p_amount >= v_gross then  -- exact refused",
  "-- exact refused")

m("money comes off with no reason",
  "discount_pos_sale",
  "  if v_amt > 0 and v_reason is null then",
  "  if false then  -- no reason",
  "-- no reason")

m("a reason of spaces is a reason",
  "discount_pos_sale",
  "  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');",
  "  v_reason text := nullif(coalesce(p_reason, ''), '');  -- spaces count",
  "-- spaces count")

m("the reason is not kept",
  "discount_pos_sale",
  "         bill_discount_reason  = case when v_amt > 0 then v_reason end,",
  "         bill_discount_reason  = null,  -- no reason kept",
  "-- no reason kept")

m("who took it off is not kept",
  "discount_pos_sale",
  "         bill_discounted_by    = case when v_amt > 0 then auth.uid() end,",
  "         bill_discounted_by    = null,  -- nobody",
  "-- nobody")

m("clearing a discount still names who",
  "discount_pos_sale",
  "         bill_discounted_by    = case when v_amt > 0 then auth.uid() end,",
  "         bill_discounted_by    = auth.uid(),  -- always named",
  "-- always named")

m("the bill is not re-added",
  "discount_pos_sale",
  "  perform app.recalc_pos_sale(p_sale);",
  "  perform 1;  -- stale",
  "-- stale")

m("the answer is not what came off",
  "discount_pos_sale",
  "  return v_amt;\nend;",
  "  return 0;  -- answers nothing\nend;",
  "-- answers nothing")

m("CONTROL: a comment inside the block",
  "discount_pos_sale",
  "  if v_sale.status <> 'parked' then",
  "  if v_sale.status <> 'parked' then  -- (control)",
  "(control)")
