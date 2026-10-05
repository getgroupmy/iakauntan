# Mutants for public.post_landed_cost_run -- putting freight, duty and
# handling onto the cost of the goods still on the shelf.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0271_the_freight_is_part_of_what_it_cost.sql \
#       supabase/tests/landed_cost.sql \
#       supabase/tests/mutants/post_landed_cost_run.py
#
# Ranked top by scripts/mutation_targets.py among the money movers with
# no mutants file: one test file reaches it.
#
# RESULT, 5 October: 15 mutants, 14 killed on the first run, ONE
# survivor, 15 of 15 after the work. The best first-run score of any
# function measured this session -- `landed_cost.sql` already asserted
# the ratio, the sen, both sides of the journal, the movement link and
# the status, and the balance check caught every sign mutation.
#
# The one survivor was `not is_group` on the 1310 lookup, and it
# survived for the reason `0727`/`0728` went unnoticed for a year: the
# seeded 1310 is postable, so "the inventory account" and "any account
# coded 1310" were the same row. Closed with a company whose 1310 is a
# HEADING, which must get the refusal rather than a posting onto the
# parent.
#
# Worth noting what killed the sign mutations: `Journal does not
# balance: debits 800.00, credits 0.00`. A balance check is a cheap kill
# for an ASYMMETRIC mutation and useless against a symmetric one -- the
# rounding-order mutant, which moves one sen between two charge
# accounts, balances perfectly and was caught by the assertion naming
# the account and the figure.
#
# Four things here are the shapes that have already cost this project
# real defects, so they get mutants of their own:
#
#   * `not is_group` on the 1310 lookup. `0727` and `0728` found six
#     posting functions crediting account 1120, the postable HEADING
#     above the real bank accounts -- an entry that balances and
#     reconciles against nothing. This is the same guard on the
#     inventory side.
#   * the ratio `v_cap / v_charged`, which decides how much of each
#     charge account is relieved. Inverting it is asymmetric and a
#     balance assertion catches it; getting the PROPORTION wrong between
#     two charge accounts is symmetric and only an assertion naming an
#     account does.
#   * the rounding absorber -- the last charge line takes `v_left` so
#     the entry balances to the sen. Removing it leaves a one-sen
#     imbalance that only shows up on a specific split.
#   * which line is "last". `order by c.line_no` decides who absorbs the
#     rounding; reversing it moves a sen between two accounts and
#     balances perfectly either way.

m("anybody may post a landed cost run",
  "post_landed_cost_run",
  "  if not app.can_write_module(v_run.org_id, 'inventory') then",
  "  if not app.can_write_module(v_run.org_id, 'inventory') and false then"
  "  -- can_write dropped",
  "-- can_write dropped")

m("an already-posted run can be posted again",
  "post_landed_cost_run",
  "  if v_run.status <> 'draft' then",
  "  if v_run.status = 'draft' and false then  -- repost guard inverted",
  "-- repost guard inverted")

m("a run with no charges is spread anyway",
  "post_landed_cost_run",
  "  if v_charged <= 0 then",
  "  if v_charged < 0 then  -- zero charges allowed",
  "-- zero charges allowed")

m("the charges are capitalised onto the inventory HEADING",
  "post_landed_cost_run",
  "   where org_id = v_run.org_id and code = '1310' and not is_group;",
  "   where org_id = v_run.org_id and code = '1310';  -- is_group dropped",
  "-- is_group dropped")

m("a movement is written for the lines that capitalise NOTHING",
  "post_landed_cost_run",
  "    if v_row.capitalised <> 0 then",
  "    if v_row.capitalised = 0 then  -- capitalised test inverted",
  "-- capitalised test inverted")

m("the whole charge is capitalised, not the share still on the shelf",
  "post_landed_cost_run",
  "              0, 0, v_row.capitalised,",
  "              0, 0, v_row.amount,  -- full charge capitalised",
  "-- full charge capitalised")

m("a run where everything has been sold posts anyway",
  "post_landed_cost_run",
  "  if v_cap = 0 then\n    raise exception\n"
  "      'Every one of those goods has already been sold",
  "  if false then  -- all-sold guard dropped\n    raise exception\n"
  "      'Every one of those goods has already been sold",
  "-- all-sold guard dropped")

m("the ratio is inverted, so the charge accounts are over-relieved",
  "post_landed_cost_run",
  "  v_ratio := v_cap / v_charged;",
  "  v_ratio := v_charged / v_cap;  -- ratio inverted",
  "-- ratio inverted")

m("the ratio is ignored, so every charge is relieved in full",
  "post_landed_cost_run",
  "  v_ratio := v_cap / v_charged;",
  "  v_ratio := 1;  -- ratio dropped",
  "-- ratio dropped")

m("the last line does not absorb the rounding",
  "post_landed_cost_run",
  "      v_credit := v_left;\n    end if;",
  "      v_credit := round(v_charge.amount * v_ratio, 2);"
  "  -- absorber dropped\n    end if;",
  "-- absorber dropped")

m("the FIRST charge line absorbs the rounding instead of the last",
  "post_landed_cost_run",
  "     where c.run_id = p_run order by c.line_no\n  loop",
  "     where c.run_id = p_run order by c.line_no desc  -- order reversed\n"
  "  loop",
  "-- order reversed")

m("the charge accounts are DEBITED and inventory credited",
  "post_landed_cost_run",
  "        'debit', greatest(-v_credit, 0), 'credit', greatest(v_credit, 0));",
  "        'debit', greatest(v_credit, 0), 'credit', greatest(-v_credit, 0));"
  "  -- charge sides swapped",
  "-- charge sides swapped")

m("inventory is CREDITED and the charges debited",
  "post_landed_cost_run",
  "    'debit', greatest(v_cap, 0), 'credit', greatest(-v_cap, 0));",
  "    'debit', greatest(-v_cap, 0), 'credit', greatest(v_cap, 0));"
  "  -- inventory sides swapped",
  "-- inventory sides swapped")

m("the movements are never linked to the journal",
  "post_landed_cost_run",
  "  update public.stock_movements\n     set gl_entry_id = v_entry",
  "  update public.stock_movements\n     set gl_entry_id = null  -- link dropped",
  "-- link dropped")

m("the run is left in draft after posting",
  "post_landed_cost_run",
  "     set status = 'posted', gl_entry_id = v_entry,",
  "     set status = 'draft', gl_entry_id = v_entry,  -- status not advanced",
  "-- status not advanced")

m("CONTROL -- a comment inside the function block",
  "post_landed_cost_run",
  "  v_ratio := v_cap / v_charged;",
  "  v_ratio := v_cap / v_charged;  -- CONTROL: this cannot change a number.",
  "-- CONTROL: this cannot change a number.")
