# Mutants for public.report_stock_card (0739) -- one item's movements,
# with a brought-forward line and a running balance in quantity and value.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/stock_card.sql \
#       supabase/tests/mutants/report_stock_card.py
#
# RESULT: 21 mutants and a control. 21 killed, all in stock_card.sql.
#
#   The first sweep killed 11 there and NONE in utc_is_not_today.sql,
#   which asks the card only about its clock. The fixture was in date
#   order and number order at once, so the running balance's ordering
#   was unasked; no movement fell on a range's first day, so `<` and
#   `<=` agreed; it had one item; the warehouse filter was never used
#   with a range; and only an adjustment had a document to name. "report_stock_card,
#   rule by rule" adds a second item, a back-dated movement, a sale and a
#   purchase as sources, a range beginning on a movement's day, a shed's
#   own opening, and a landed cost on an empty shelf.
#
#   Noted, not asserted: that landed cost leaves the card's value at
#   50.00 where `app.apply_stock_movement` stores 0 -- the trigger zeroes
#   the value whenever the quantity is zero. The card is right by its own
#   arithmetic; which of the two the ledger agrees with depends on what
#   `post_landed_cost_run` posts for a shelf with nothing on it.

m("a stranger reads the shelf",
  "report_stock_card",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("the opening includes the first day of the range",
  "report_stock_card",
  "       and m.movement_date < p_from\n",
  "       and m.movement_date <= p_from  -- first day too\n",
  "-- first day too")

m("the opening ignores the warehouse",
  "report_stock_card",
  "       and (p_warehouse_id is null or m.warehouse_id = p_warehouse_id);",
  "       and true;  -- every warehouse",
  "-- every warehouse")

m("the opening value is left out",
  "report_stock_card",
  "    select coalesce(sum(m.quantity), 0), coalesce(sum(m.total_cost), 0)",
  "    select coalesce(sum(m.quantity), 0), 0  -- no value",
  "-- no value")

m("the opening counts another item",
  "report_stock_card",
  "     where m.org_id = p_org_id and m.item_id = p_item_id\n       and m.movement_date < p_from",
  "     where m.org_id = p_org_id  -- any item\n       and m.movement_date < p_from",
  "-- any item")

m("the card shows another item",
  "report_stock_card",
  "     where m.org_id = p_org_id and m.item_id = p_item_id\n       and m.movement_date <= p_to",
  "     where m.org_id = p_org_id  -- any item\n       and m.movement_date <= p_to",
  "-- any item")

m("a movement after the date is shown",
  "report_stock_card",
  "       and m.movement_date <= p_to\n",
  "       and true  -- no end\n",
  "-- no end")

m("a movement before the range is shown",
  "report_stock_card",
  "       and (p_from is null or m.movement_date >= p_from)",
  "       and true  -- no start",
  "-- no start")

m("the card ignores the warehouse",
  "report_stock_card",
  "       and (p_warehouse_id is null or m.warehouse_id = p_warehouse_id))",
  "       and true)  -- every warehouse",
  "-- every warehouse")

m("a sale's number is not the reference",
  "report_stock_card",
  "               where m.source_table = 'sales_documents' and d.id = m.source_id),",
  "               where false),  -- no sale",
  "-- no sale")

m("a purchase's number is not the reference",
  "report_stock_card",
  "               where m.source_table = 'purchase_documents' and d.id = m.source_id),",
  "               where false),  -- no purchase",
  "-- no purchase")

m("an adjustment's number is not the reference",
  "report_stock_card",
  "               where m.source_table = 'stock_adjustments' and a.id = m.source_id),",
  "               where false),  -- no adjustment",
  "-- no adjustment")

m("the note is never the reference",
  "report_stock_card",
  "             m.notes) as reference,",
  "             null) as reference,  -- no note",
  "-- no note")

m("a brought-forward of nil is shown",
  "report_stock_card",
  "     where p_from is not null and (v_open_qty <> 0 or v_open_value <> 0)",
  "     where p_from is not null  -- always",
  "-- always")

m("a value-only opening is hidden",
  "report_stock_card",
  "     where p_from is not null and (v_open_qty <> 0 or v_open_value <> 0)",
  "     where p_from is not null and v_open_qty <> 0  -- qty only",
  "-- qty only")

m("the running quantity starts at nothing",
  "report_stock_card",
  "           round(v_open_qty + sum(d.quantity) over w, 4),",
  "           round(sum(d.quantity) over w, 4),  -- no opening",
  "-- no opening")

m("the running value starts at nothing",
  "report_stock_card",
  "           round(v_open_value + sum(d.total_cost) over w, 2),",
  "           round(sum(d.total_cost) over w, 2),  -- no opening",
  "-- no opening")

m("the running balance runs in number order, not date order",
  "report_stock_card",
  "    window w as (order by d.movement_date, d.movement_no, d.id",
  "    window w as (order by d.movement_no, d.id  -- by number",
  "-- by number")

m("the running balance is the whole card's total on every line",
  "report_stock_card",
  "                 rows between unbounded preceding and current row)",
  "                 rows between unbounded preceding and unbounded following)  -- total",
  "-- total")

m("the brought-forward line is not first",
  "report_stock_card",
  "   order by x.ord, x.movement_date, x.movement_no, x.id;",
  "   order by x.movement_date nulls last, x.movement_no, x.id;  -- bf anywhere",
  "-- bf anywhere")

m("the lines come out in number order",
  "report_stock_card",
  "   order by x.ord, x.movement_date, x.movement_no, x.id;",
  "   order by x.ord, x.movement_no, x.id;  -- by number",
  "-- by number")

m("CONTROL: a comment inside the block",
  "report_stock_card",
  "    -- The line the range starts from. Omitted when there is no range and",
  "    -- CONTROL\n    -- The line the range starts from. Omitted when there is no range and",
  "-- CONTROL")
