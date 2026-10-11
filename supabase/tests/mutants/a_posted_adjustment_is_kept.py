# Mutants for app.a_posted_adjustment_is_kept (0814) -- a client's own
# statement does not change or delete a stock adjustment past draft, nor
# a line under one, nor create one other than as a draft, nor mark a
# draft posted without posting it. Drafts are as before; the functions
# pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0814_a_stocktake_is_kept_as_it_was_posted.sql \
#       supabase/tests/stock_figures.sql \
#       supabase/tests/mutants/a_posted_adjustment_is_kept.py
#
# RESULT: 11 mutants and a control, all 11 killed by `stock_figures.sql`'s
# `0814` block. "The functions are refused too" is killed by
# `post_stock_adjustment` itself, which marks the adjustment posted at
# the top trigger depth as its owner.
#
# SECURITY DEFINER flipped by hand: the file fails on its first refusal
# ("its line is not rewritten: it was not refused at all"); restored, it
# passes.

F = "a_posted_adjustment_is_kept"

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
m("an adjustment is created in any state", F,
  "      if new.status <> 'draft' or new.gl_entry_id is not null\n         or new.posted_at is not null then",
  "      if false then  -- any state",
  "-- any state")
m("a posted adjustment is the client's", F,
  "    if old.status <> 'draft' then\n      raise exception\n        '% is %, and a stock adjustment is kept",
  "    if false then  -- posted free\n      raise exception\n        '% is %, and a stock adjustment is kept",
  "-- posted free")
m("a draft is frozen too", F,
  "    if old.status <> 'draft' then\n      raise exception\n        '% is %, and a stock adjustment is kept",
  "    if true then  -- drafts frozen\n      raise exception\n        '% is %, and a stock adjustment is kept",
  "-- drafts frozen")
m("a draft is marked posted by hand", F,
  "            or new.gl_entry_id is distinct from old.gl_entry_id\n            or new.posted_at is distinct from old.posted_at) then",
  "            and false) then  -- marked posted",
  "-- marked posted")
m("a line asks only where it was", F,
  "     where a.id in (old.adjustment_id, new.adjustment_id)",
  "     where a.id = old.adjustment_id  -- only the old",
  "-- only the old")
m("a line asks only where it goes", F,
  "     where a.id in (old.adjustment_id, new.adjustment_id)",
  "     where a.id = new.adjustment_id  -- only the new",
  "-- only the new")
m("a line under a posted adjustment is the client's", F,
  "       and a.status <> 'draft'\n  loop",
  "       and false\n  loop  -- lines free",
  "-- lines free")
m("a line under a draft is frozen", F,
  "       and a.status <> 'draft'\n  loop",
  "       and true\n  loop  -- lines frozen",
  "-- lines frozen")

m("CONTROL", F,
  "  v_adj public.stock_adjustments;\nbegin",
  "  v_adj public.stock_adjustments;  -- control\nbegin",
  "-- control")
