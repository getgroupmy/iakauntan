# Mutants for public.post_manufacturing_order -- components issued,
# conversion absorbed, and a finished item carried at what it cost to
# make.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0422_what_day_the_work_was_done.sql \
#       supabase/tests/manufacturing.sql \
#       supabase/tests/mutants/manufacturing.py
#
# then again against the five other files that reach it.
#
# RESULT, 5 October: 38 mutants (37 plus a control). 30 killed on
# `manufacturing.sql` and 7 survived; the other five files that reach it
# kill nothing new. 36 of 37 after the work, with one proven
# EQUIVALENT. The control lived.
#
# THIRTY OF THIRTY-SEVEN ON THE FIRST RUN IS THE BEST SCORE OF THE
# SWEEP, and the reason is that `manufacturing.sql` already has the
# fixture the collapse needed: a short run, six chairs off an order of
# ten, so `v_ratio` is 0.6 and every `* v_ratio` in the body means
# something. The ratio is the function's own comment's subject --
# "costing the whole recipe against half an output is how a finished
# item ends up carried at twice what it is worth" -- and the file stood
# on it.
#
# WHAT IT DID NOT STAND ON was the difference between the order's
# TOTALS and what the short run WROTE. The three figures asserted are
# `component_cost`, `conversion_cost` and `quantity_done` on the order;
# the per-component line and the finished movement carry the ratio
# INDEPENDENTLY, and neither was read. The order could total 312 while
# each component line claimed the full recipe, and a shop reading
# `mo_components` for a variance report would see ten chairs' worth
# issued against six chairs' output -- with every total right.
#
# And `status not in ('confirmed', 'in_progress')` is two values in one
# list, with every order in the file posted straight from `confirmed`.
# Narrowing it refused a shop that had started the work, which is the
# ordinary case for anything taking more than a shift.
#
# The one function in the schema where VALUE CONSERVATION is the whole
# point and the arithmetic has a scale factor in it. A short run
# consumes proportionally less -- `v_ratio := v_done / v_mo.quantity` --
# and the function's own comment says what happens without it: "costing
# the whole recipe against half an output is how a finished item ends up
# carried at twice what it is worth".
#
# WHICH MAKES THE RATIO THE FIRST THING TO LOOK FOR, because a fixture
# that always produces the WHOLE ordered quantity has v_ratio = 1, and
# at 1 every `* v_ratio` in the body is the identity. Four separate
# rules collapse into nothing at once. That is the third-family collapse
# this sweep keeps finding, in its most expensive form: the figure the
# factory carries its stock at.
#
# `scripts/state_write_coverage.py` also flagged `total_cost` here.

m("anybody can post a manufacturing order",
  "post_manufacturing_order",
  "  if not app.can_post(v_mo.org_id) then",
  "  if false then  -- mo post guard dropped",
  "-- mo post guard dropped")

m("an order already posted is posted again",
  "post_manufacturing_order",
  "  if v_mo.posted_at is not null then",
  "  if false then  -- mo repost guard dropped",
  "-- mo repost guard dropped")

m("an order in any state at all can be posted",
  "post_manufacturing_order",
  "  if v_mo.status not in ('confirmed', 'in_progress') then",
  "  if false then  -- mo status guard dropped",
  "-- mo status guard dropped")

m("an order IN PROGRESS cannot be posted",
  "post_manufacturing_order",
  "  if v_mo.status not in ('confirmed', 'in_progress') then",
  "  if v_mo.status not in ('confirmed') then"
  "  -- in_progress no longer postable",
  "-- in_progress no longer postable")

m("an order posted with no quantity makes NOTHING rather than its order",
  "post_manufacturing_order",
  "  v_done := coalesce(p_quantity_done, v_mo.quantity);",
  "  v_done := coalesce(p_quantity_done, 0);  -- ordered quantity ignored",
  "-- ordered quantity ignored")

m("the quantity actually produced is ignored for the quantity ordered",
  "post_manufacturing_order",
  "  v_done := coalesce(p_quantity_done, v_mo.quantity);",
  "  v_done := v_mo.quantity;  -- short run ignored",
  "-- short run ignored")

m("producing NOTHING is accepted",
  "post_manufacturing_order",
  "  if v_done <= 0 then",
  "  if v_done < 0 then  -- nil production accepted",
  "-- nil production accepted")

m("a NEGATIVE production is accepted",
  "post_manufacturing_order",
  "  if v_done <= 0 then",
  "  if false then  -- production guard dropped",
  "-- production guard dropped")

m("a SHORT RUN consumes the whole recipe",
  "post_manufacturing_order",
  "  v_ratio := v_done / v_mo.quantity;",
  "  v_ratio := 1;  -- ratio forced to one",
  "-- ratio forced to one")

m("the ratio is inverted, so a short run consumes MORE",
  "post_manufacturing_order",
  "  v_ratio := v_done / v_mo.quantity;",
  "  v_ratio := v_mo.quantity / v_done;  -- ratio inverted",
  "-- ratio inverted")

m("the stock arrives on the 1310 HEADING rather than a real account",
  "post_manufacturing_order",
  "   where org_id = v_mo.org_id and code = '1310' and not is_group limit 1;",
  "   where org_id = v_mo.org_id and code = '1310' limit 1;"
  "  -- 1310 heading allowed",
  "-- 1310 heading allowed")

m("ANOTHER COMPANY's inventory account is used",
  "post_manufacturing_order",
  "   where org_id = v_mo.org_id and code = '1310' and not is_group limit 1;",
  "   where org_id <> v_mo.org_id and code = '1310' and not is_group limit 1;"
  "  -- inventory org scope inverted",
  "-- inventory org scope inverted")

m("a chart with no inventory account posts anyway",
  "post_manufacturing_order",
  "  if v_inventory is null then",
  "  if false then  -- missing inventory account no longer refused",
  "-- missing inventory account no longer refused")

m("the components are taken IN rather than issued out",
  "post_manufacturing_order",
  "            -round(v_row.quantity_required * v_ratio, 4),",
  "            round(v_row.quantity_required * v_ratio, 4),"
  "  -- component sign dropped",
  "-- component sign dropped")

m("a short run still issues the whole required quantity",
  "post_manufacturing_order",
  "            -round(v_row.quantity_required * v_ratio, 4),",
  "            -round(v_row.quantity_required, 4),"
  "  -- component ratio dropped",
  "-- component ratio dropped")

m("the components leave a different warehouse from the one that makes it",
  "post_manufacturing_order",
  "            app.today(), 'assembly_out', v_row.item_id, v_mo.warehouse_id,",
  "            app.today(), 'assembly_out', v_row.item_id, null,"
  "  -- component warehouse dropped",
  "-- component warehouse dropped")

# The comment goes on the line it belongs to and not after `returning
# total_cost`, where it commented out the ` into v_movement_cost` that
# followed on the same line and turned the next `:=` into a syntax
# error. The harness reported that as a HARNESS ERROR and put the
# function back, which is what its landed check is for -- a mutant that
# will not parse is never a survivor.
m("the component movement does not say which order consumed it",
  "post_manufacturing_order",
  "            'manufacturing_orders', p_mo_id)\n    returning total_cost",
  "            'manufacturing_orders', null)  -- component source forgotten"
  "\n    returning total_cost",
  "-- component source forgotten")

m("what the order consumed is recorded as a negative amount of money",
  "post_manufacturing_order",
  "    v_component_cost := v_component_cost + abs(v_movement_cost);",
  "    v_component_cost := v_component_cost + v_movement_cost;"
  "  -- component cost left negative",
  "-- component cost left negative")

m("the component line does not record what was issued",
  "post_manufacturing_order",
  "       set quantity_issued = round(v_row.quantity_required * v_ratio, 4),",
  "       set quantity_issued = v_row.quantity_required,"
  "  -- issued quantity ignores the ratio",
  "-- issued quantity ignores the ratio")

m("the component line does not record what it cost",
  "post_manufacturing_order",
  "           total_cost = abs(v_movement_cost),",
  "           total_cost = 0,  -- component total cost not recorded",
  "-- component total cost not recorded")

# EQUIVALENT, and the TABLE proves it rather than the code --
# `mo_components_quantity_required_check` is `quantity_required > 0`, so
# a recipe line needing none of something cannot exist. The first
# version of the fixture inserted one and the constraint refused it. The
# guard is belt-and-braces against a row the schema will not hold: right
# to keep, and unobservable. Second time in this sweep a constraint has
# settled the question, after remit_withholding's
# `coalesce(exchange_rate, 1)`.
m("a component required in nil quantity divides by nothing",
  "post_manufacturing_order",
  "           unit_cost = case when v_row.quantity_required = 0 then 0",
  "           unit_cost = case when false then 0  -- nil-quantity guard dropped",
  "-- nil-quantity guard dropped")

m("conversion takes the PLANNED minutes where actual were booked",
  "post_manufacturing_order",
  "           (case when o.actual_minutes > 0 then o.actual_minutes\n"
  "                 else o.planned_minutes * v_ratio end) / 60.0",
  "           (o.planned_minutes * v_ratio) / 60.0  -- actual minutes ignored",
  "-- actual minutes ignored")

m("conversion takes the ACTUAL minutes where none were booked",
  "post_manufacturing_order",
  "           (case when o.actual_minutes > 0 then o.actual_minutes\n"
  "                 else o.planned_minutes * v_ratio end) / 60.0",
  "           (o.actual_minutes) / 60.0  -- planned minutes ignored",
  "-- planned minutes ignored")

m("a short run is costed at the whole planned time",
  "post_manufacturing_order",
  "                 else o.planned_minutes * v_ratio end) / 60.0",
  "                 else o.planned_minutes end) / 60.0"
  "  -- planned minutes ignore the ratio",
  "-- planned minutes ignore the ratio")

m("minutes are costed as if they were hours",
  "post_manufacturing_order",
  "                 else o.planned_minutes * v_ratio end) / 60.0\n"
  "           * w.cost_per_hour, 2)), 0)",
  "                 else o.planned_minutes * v_ratio end)\n"
  "           * w.cost_per_hour, 2)), 0)  -- minutes not converted to hours",
  "-- minutes not converted to hours")

m("the finished item is carried at the components alone",
  "post_manufacturing_order",
  "  v_finished := v_component_cost + v_conversion;",
  "  v_finished := v_component_cost;  -- conversion not absorbed",
  "-- conversion not absorbed")

m("the finished quantity is the quantity ORDERED, not the quantity made",
  "post_manufacturing_order",
  "          v_mo.item_id, v_mo.warehouse_id, v_done,\n"
  "          round(v_finished / v_done, 6), 'manufacturing_orders', p_mo_id);",
  "          v_mo.item_id, v_mo.warehouse_id, v_mo.quantity,\n"
  "          round(v_finished / v_done, 6), 'manufacturing_orders', p_mo_id);"
  "  -- finished quantity is the order",
  "-- finished quantity is the order")

m("the finished item is carried at its TOTAL cost per unit",
  "post_manufacturing_order",
  "          round(v_finished / v_done, 6), 'manufacturing_orders', p_mo_id);",
  "          round(v_finished, 6), 'manufacturing_orders', p_mo_id);"
  "  -- unit cost not divided",
  "-- unit cost not divided")

m("the finished value is CREDITED to inventory",
  "post_manufacturing_order",
  "    jsonb_build_object('account_id', v_inventory, 'debit', v_finished,\n"
  "                       'credit', 0,",
  "    jsonb_build_object('account_id', v_inventory, 'debit', 0,\n"
  "                       'credit', v_finished,  -- finished side swapped",
  "-- finished side swapped")

m("the components are DEBITED to inventory, so stock rises twice",
  "post_manufacturing_order",
  "    jsonb_build_object('account_id', v_inventory, 'debit', 0,\n"
  "                       'credit', v_component_cost,",
  "    jsonb_build_object('account_id', v_inventory, 'debit', v_component_cost,\n"
  "                       'credit', 0,  -- component side swapped",
  "-- component side swapped")

m("the conversion is taken to INVENTORY rather than out of the P&L",
  "post_manufacturing_order",
  "    jsonb_build_object('account_id', v_absorbed, 'debit', 0,",
  "    jsonb_build_object('account_id', v_inventory, 'debit', 0,"
  "  -- absorption account changed",
  "-- absorption account changed")

m("the journal does not point back at the order",
  "post_manufacturing_order",
  "    'Manufacturing order ' || v_mo.order_no,\n"
  "    'manufacturing_orders', p_mo_id);",
  "    'Manufacturing order ' || v_mo.order_no,\n"
  "    'manufacturing_orders', null);  -- source order forgotten",
  "-- source order forgotten")

m("a posted order still reads as confirmed",
  "post_manufacturing_order",
  "     set status = 'done',",
  "     set status = v_mo.status,  -- mo status not advanced",
  "-- mo status not advanced")

m("the order does not record how much was made",
  "post_manufacturing_order",
  "         quantity_done = v_done,",
  "         quantity_done = v_mo.quantity,  -- quantity_done is the order",
  "-- quantity_done is the order")

m("the order does not record what it consumed",
  "post_manufacturing_order",
  "         component_cost = v_component_cost,",
  "         component_cost = 0,  -- component cost not kept",
  "-- component cost not kept")

m("the order does not record what the conversion cost",
  "post_manufacturing_order",
  "         conversion_cost = v_conversion,",
  "         conversion_cost = 0,  -- conversion cost not kept",
  "-- conversion cost not kept")

m("the order does not remember the journal it posted",
  "post_manufacturing_order",
  "         gl_entry_id = v_entry,",
  "         gl_entry_id = null,  -- mo entry not kept",
  "-- mo entry not kept")

m("CONTROL -- a comment beside the ratio",
  "post_manufacturing_order",
  "  v_ratio := v_done / v_mo.quantity;",
  "  v_ratio := v_done / v_mo.quantity;  -- CONTROL: this cannot change a ratio.",
  "-- CONTROL: this cannot change a ratio.")
