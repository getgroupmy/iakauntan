# Mutants for app.stock_figures_are_the_stocks (0813) -- on items, a
# client's own statement does not write average_cost or
# quantity_on_hand, nor creates an item with either set; the stock
# functions, and the movement trigger under them, pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0813_the_stock_figures_are_the_stocks.sql \
#       supabase/tests/stock_figures.sql \
#       supabase/tests/mutants/stock_figures_are_the_stocks.py
#
# RESULT: 9 mutants and a control, all 9 killed by `stock_figures.sql`,
# new in `0813`. "The functions are refused too" survived the first
# draft: every stock function writes the item one trigger down, so only
# the database's own statement at the top level tells `or` from `and`,
# and nothing made one. The file now sets an item's cost as the session.
#
# SECURITY DEFINER flipped by hand on the guard: the file fails on its
# first refusal ("an item's cost is not written by hand: it was not
# refused at all"); restored, it passes.

F = "stock_figures_are_the_stocks"

m("the client role is not asked", F,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")
m("a client's own statement passes at depth one", F,
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 0 then  -- depth one passes",
  "-- depth one passes")
m("the functions are refused too", F,
  "     or pg_trigger_depth() > 1 then",
  "     and pg_trigger_depth() > 1 then  -- owner asked",
  "-- owner asked")
m("an item is created with any cost", F,
  "    if new.average_cost <> 0 or new.quantity_on_hand <> 0 then",
  "    if new.quantity_on_hand <> 0 then  -- cost free",
  "-- cost free")
m("an item is created holding any stock", F,
  "    if new.average_cost <> 0 or new.quantity_on_hand <> 0 then",
  "    if new.average_cost <> 0 then  -- stock free",
  "-- stock free")
m("an insert goes on to the update's question", F,
  "        using errcode = '42501';\n    end if;\n    return new;\n  end if;",
  "        using errcode = '42501';\n    end if;\n    -- falls through\n  end if;",
  "-- falls through")
m("the cost is the client's", F,
  "  if new.average_cost is distinct from old.average_cost\n     or new.quantity_on_hand is distinct from old.quantity_on_hand then",
  "  if new.quantity_on_hand is distinct from old.quantity_on_hand then  -- cost free",
  "-- cost free")
m("what is on hand is the client's", F,
  "  if new.average_cost is distinct from old.average_cost\n     or new.quantity_on_hand is distinct from old.quantity_on_hand then",
  "  if new.average_cost is distinct from old.average_cost then  -- stock free",
  "-- stock free")
m("any edit to an item is refused", F,
  "  if new.average_cost is distinct from old.average_cost\n     or new.quantity_on_hand is distinct from old.quantity_on_hand then",
  "  if true then  -- frozen",
  "-- frozen")

m("CONTROL", F,
  "    return new;\n  end if;\n\n  if tg_op = 'INSERT' then",
  "    return new;\n  end if;\n  -- control\n  if tg_op = 'INSERT' then",
  "-- control")
