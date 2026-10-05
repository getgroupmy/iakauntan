# Mutants for public.run_depreciation -- the period's depreciation
# charge: a run row, one entry per asset, the asset's own book value
# moved on, and ONE journal grouped by the pair of accounts each asset
# posts to.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/depreciation_shapes.sql \
#       supabase/tests/mutants/run_depreciation.py
#
# then again against `depreciation_schedule.sql`, `fixed_assets.sql`,
# `asset_disposal_shapes.sql` and `idempotency.sql`.
#
# This function has FOUR separable claims, and a test file that proves
# one of them says nothing about the other three:
#
#   1. WHICH ASSETS. Four conjuncts -- this company's, not deleted,
#      active, and acquired by the run date -- and the last of them is
#      a boundary.
#   2. HOW MUCH. The charge is the DIFFERENCE between where the asset
#      should be and where it is, so a mutant that charges the whole
#      accumulated figure again is arithmetically plausible and doubles
#      the expense.
#   3. WHAT IT WRITES ON THE ASSET. `accumulated_depreciation`,
#      `depreciated_to`, and a `status` that flips to
#      `fully_depreciated` at `cost - residual_value` -- a boundary and
#      a term that a fixture with no residual value cannot see.
#   4. WHICH ACCOUNTS. Each asset may name its own expense and
#      accumulated accounts; the run falls back to 6400 and 1590, and
#      the journal is grouped so each pair posts its own total. BOTH
#      halves of both coalesces are behaviour.
#
# RESULT, 5 October: 43 mutants (42 plus a control).
#
#   depreciation_shapes.sql     kills 35, then 40
#   depreciation_schedule.sql   kills 16, two of them new
#   fixed_assets.sql            kills 20, none new
#   asset_disposal_shapes.sql   kills  9, none new
#   idempotency.sql             kills 11, none new
#
# 37 of 42 before the work; 41 of 41 killable after it. One is
# EQUIVALENT -- see "an asset not yet bought is depreciated" below --
# and the control lived on every file.
#
# 35 OF 42 ON ONE FILE IS THE STRONGEST OPENING FIGURE OF ANY FUNCTION
# IN THIS SWEEP, and the reason is that `depreciation_shapes.sql` was
# itself written out of an earlier mutation sweep. Its own header says
# that sweep "killed 19 of 42" across four functions -- and left NO
# mutants file, so that figure cannot be re-measured. This file makes
# `run_depreciation`'s share of it reproducible; `app.months_held`,
# `app.accumulated_depreciation_at` and `public.depreciation_preview`
# still have none.
#
# WHAT LIVED, and only one of the three is arithmetic:
#
#   * THE FIRST MONTH. `app.months_held(d, d)` is ONE, not zero -- its
#     `case when p_to >= p_from then 1` counts the month of acquisition
#     -- so a company that buys a van on the last day of May owes one
#     month of it in May. `acquisition_date <= p_as_at` could therefore
#     be narrowed to `<` with nothing to say, because no fixture in the
#     suite had an asset acquired exactly on the date being run.
#   * `opening_accumulated`. `depreciation_entries` records where the
#     asset stood before the charge and where it stands after.
#     `depreciation_schedule.sql` reads the CLOSING figure; nothing read
#     the opening one, so it could be written as zero on every run of
#     every asset for ever. Same finding as every other sweep here, on
#     the two columns a charge is reconstructed from.
#   * THE PROVENANCE. The journal's `source` and `source_id` were read
#     by nothing. A depreciation charge that calls itself a manual
#     journal is not findable from the run, and a run whose journal
#     names no source is not findable from the ledger -- either way the
#     one posting in the accounts that nobody enters by hand becomes
#     the one posting nobody can trace.
#
# NOTE, reported and NOT fixed: the 6400/1590 lookups have no
# `deleted_at is null`, so a RETIRED account is still posted to. That is
# the same finding `dispose_fixed_asset` and `post_client_transaction`
# gave, and it changes what a statutory posting resolves to, so it is
# the user's call and not a sweep's.

# -------------------------------------------------------- the guard

m("anybody can run the depreciation",
  "run_depreciation",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- depreciation post guard dropped",
  "-- depreciation post guard dropped")

# ------------------------------------------- the two default accounts

# INVERTED rather than dropped. `select ... into` over two matching rows
# takes whichever the planner reaches first, so a mutant that merely
# DROPS `org_id = p_org_id` can pick this org's own 6400 and survive as a
# coin flip. `<>` always picks somebody else's, or nothing -- and nothing
# reaches the refusal, which is a kill either way.
m("ANOTHER company's depreciation expense account is used",
  "run_depreciation",
  "  select id into v_default_expense from public.accounts\n"
  "   where org_id = p_org_id and code = '6400';",
  "  select id into v_default_expense from public.accounts\n"
  "   where org_id <> p_org_id and code = '6400';  -- expense account from elsewhere",
  "-- expense account from elsewhere")

m("ANOTHER company's accumulated depreciation account is used",
  "run_depreciation",
  "  select id into v_default_accum from public.accounts\n"
  "   where org_id = p_org_id and code = '1590';",
  "  select id into v_default_accum from public.accounts\n"
  "   where org_id <> p_org_id and code = '1590';  -- accumulated account from elsewhere",
  "-- accumulated account from elsewhere")

m("the charge is posted to the wrong expense account",
  "run_depreciation",
  "   where org_id = p_org_id and code = '6400';",
  "   where org_id = p_org_id and code = '6100';  -- expense code changed",
  "-- expense code changed")

m("the credit is posted to the wrong accumulated account",
  "run_depreciation",
  "   where org_id = p_org_id and code = '1590';",
  "   where org_id = p_org_id and code = '1510';  -- accumulated code changed",
  "-- accumulated code changed")

# -------------------------------------------------- which assets run

m("ANOTHER company's assets are depreciated too",
  "run_depreciation",
  "     where org_id = p_org_id and deleted_at is null",
  "     where deleted_at is null  -- asset org scope dropped",
  "-- asset org scope dropped")

m("a DELETED asset is still depreciated",
  "run_depreciation",
  "     where org_id = p_org_id and deleted_at is null",
  "     where org_id = p_org_id  -- deleted assets included",
  "-- deleted assets included")

m("a disposed or fully depreciated asset is depreciated again",
  "run_depreciation",
  "       and status = 'active' and acquisition_date <= p_as_at",
  "       and acquisition_date <= p_as_at  -- status no longer checked",
  "-- status no longer checked")

m("an asset bought ON the run date gets no charge",
  "run_depreciation",
  "       and status = 'active' and acquisition_date <= p_as_at",
  "       and status = 'active' and acquisition_date < p_as_at"
  "  -- acquisition boundary narrowed",
  "-- acquisition boundary narrowed")

# EQUIVALENT, and a FOURTH kind of equivalence proof in this sweep:
# THE GUARD IS IN THE CALLEE. `app.accumulated_depreciation_at` opens
# with `if p_as_at < p_asset.acquisition_date then return 0`, so an
# asset bought in June enters a March run, is handed a target of zero,
# and is thrown straight back out by `if v_charge <= 0 then continue`.
# No fixture can distinguish the two forms of this line.
#
# The three kinds already proven were the code's own shape, a table
# constraint, and a trigger. This one is worth knowing because the
# proof is not in the function being mutated at all.
#
# `depreciation_shapes.sql` had a comment that was precise, confident
# and wrong about exactly this -- "Running March with an asset bought in
# June charges three months of an asset the company does not own yet".
# True of `depreciation_preview`, which the same fixture does catch;
# false of the run. Corrected in place, with the measurement beside it.
m("an asset not yet bought is depreciated",
  "run_depreciation",
  "       and status = 'active' and acquisition_date <= p_as_at",
  "       and status = 'active'  -- acquisition date no longer checked",
  "-- acquisition date no longer checked")

# ------------------------------------------------------- the charge

m("the whole accumulated figure is charged again every period",
  "run_depreciation",
  "    v_charge := round(v_target - a.accumulated_depreciation, 2);",
  "    v_charge := round(v_target, 2);  -- charge is not a difference",
  "-- charge is not a difference")

m("the charge is rounded to whole ringgit",
  "run_depreciation",
  "    v_charge := round(v_target - a.accumulated_depreciation, 2);",
  "    v_charge := round(v_target - a.accumulated_depreciation, 0);"
  "  -- charge rounded to the ringgit",
  "-- charge rounded to the ringgit")

m("an asset with nothing to charge gets an entry row anyway",
  "run_depreciation",
  "    if v_charge <= 0 then continue; end if;",
  "    if v_charge < 0 then continue; end if;  -- zero charge no longer skipped",
  "-- zero charge no longer skipped")

m("an over-depreciated asset is CREDITED back",
  "run_depreciation",
  "    if v_charge <= 0 then continue; end if;",
  "    if false then continue; end if;  -- negative charge posted",
  "-- negative charge posted")

# ---------------------------------------------- the per-asset entry

m("the entry records the whole accumulated figure as this period's charge",
  "run_depreciation",
  "    values (p_org_id, v_run_id, a.id, v_charge, a.accumulated_depreciation, v_target);",
  "    values (p_org_id, v_run_id, a.id, v_target, a.accumulated_depreciation, v_target);"
  "  -- entry amount is the target",
  "-- entry amount is the target")

m("the entry says the asset opened at nothing",
  "run_depreciation",
  "    values (p_org_id, v_run_id, a.id, v_charge, a.accumulated_depreciation, v_target);",
  "    values (p_org_id, v_run_id, a.id, v_charge, 0, v_target);"
  "  -- opening accumulated zeroed",
  "-- opening accumulated zeroed")

m("the entry closes where it opened",
  "run_depreciation",
  "    values (p_org_id, v_run_id, a.id, v_charge, a.accumulated_depreciation, v_target);",
  "    values (p_org_id, v_run_id, a.id, v_charge, a.accumulated_depreciation,\n"
  "            a.accumulated_depreciation);  -- closing accumulated not moved",
  "-- closing accumulated not moved")

# ------------------------------------------- what it writes on the asset

m("the asset's book value is never moved on, so the charge repeats",
  "run_depreciation",
  "       set accumulated_depreciation = v_target,",
  "       set accumulated_depreciation = a.accumulated_depreciation,"
  "  -- asset not moved on",
  "-- asset not moved on")

m("the asset does not record how far it has been depreciated",
  "run_depreciation",
  "           depreciated_to = p_as_at,",
  "           depreciated_to = null,  -- depreciated_to not recorded",
  "-- depreciated_to not recorded")

m("it records the real clock rather than the date depreciated to",
  "run_depreciation",
  "           depreciated_to = p_as_at,",
  "           depreciated_to = app.today(),  -- depreciated_to off the clock",
  "-- depreciated_to off the clock")

m("an asset depreciated to the last cent stays active for ever",
  "run_depreciation",
  "           status = case when v_target >= a.cost - a.residual_value",
  "           status = case when v_target > a.cost - a.residual_value"
  "  -- fully-depreciated boundary narrowed",
  "-- fully-depreciated boundary narrowed")

m("the residual value is depreciated away before the asset is retired",
  "run_depreciation",
  "           status = case when v_target >= a.cost - a.residual_value",
  "           status = case when v_target >= a.cost"
  "  -- residual value ignored at the flip",
  "-- residual value ignored at the flip")

m("an asset is never marked fully depreciated",
  "run_depreciation",
  "           status = case when v_target >= a.cost - a.residual_value\n"
  "                         then 'fully_depreciated' else 'active' end,",
  "           status = 'active',  -- status never flips",
  "-- status never flips")

# ---------------------------------------------------- the empty run

m("a run with nothing to charge leaves a run row and posts a journal",
  "run_depreciation",
  "  if v_total = 0 then",
  "  if false then  -- empty run no longer short-circuited",
  "-- empty run no longer short-circuited")

m("a run with nothing to charge leaves its row behind",
  "run_depreciation",
  "    delete from public.depreciation_runs where id = v_run_id;",
  "    -- empty run row kept",
  "-- empty run row kept")

# --------------------------------------------- which accounts, grouped

m("an asset that names its OWN expense account is ignored",
  "run_depreciation",
  "    select coalesce(fa.expense_account_id, v_default_expense) as expense_id,",
  "    select v_default_expense as expense_id,  -- asset expense account ignored",
  "-- asset expense account ignored")

m("an asset with no expense account of its own gets none",
  "run_depreciation",
  "    select coalesce(fa.expense_account_id, v_default_expense) as expense_id,",
  "    select fa.expense_account_id as expense_id,  -- 6400 fallback dropped",
  "-- 6400 fallback dropped")

m("an asset that names its OWN accumulated account is ignored",
  "run_depreciation",
  "           coalesce(fa.accumulated_account_id, v_default_accum) as accum_id,",
  "           v_default_accum as accum_id,  -- asset accumulated account ignored",
  "-- asset accumulated account ignored")

m("an asset with no accumulated account of its own gets none",
  "run_depreciation",
  "           coalesce(fa.accumulated_account_id, v_default_accum) as accum_id,",
  "           fa.accumulated_account_id as accum_id,  -- 1590 fallback dropped",
  "-- 1590 fallback dropped")

m("two assets on one account post only the larger charge",
  "run_depreciation",
  "           sum(e.amount) as amount",
  "           max(e.amount) as amount  -- charges not totalled",
  "-- charges not totalled")

m("EVERY run's entries are posted again by this one",
  "run_depreciation",
  "     where e.run_id = v_run_id\n"
  "     group by 1, 2",
  "     group by 1, 2  -- run scope dropped from the grouping",
  "-- run scope dropped from the grouping")

# NOT WRITTEN: `group by 1, 2` -> `group by 1`. The accumulated account
# would then be neither grouped nor aggregated, so the query fails at
# runtime and every file "kills" it. A mutant that cannot run measures
# nothing; the grouping's real behaviour is covered by the four coalesce
# mutants above and by `sum` -> `max`.

# -------------------------------------------------- the two refusals

m("a missing expense account posts a line with no account at all",
  "run_depreciation",
  "    if r.expense_id is null or r.accum_id is null then",
  "    if false then  -- null account refusal dropped",
  "-- null account refusal dropped")

m("only the expense half of the pair is checked",
  "run_depreciation",
  "    if r.expense_id is null or r.accum_id is null then",
  "    if r.expense_id is null then  -- accumulated half unchecked",
  "-- accumulated half unchecked")

# ------------------------------------------------------- the journal

m("depreciation is posted as a CREDIT to the expense account",
  "run_depreciation",
  "           'debit', r.amount, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0)",
  "           'debit', 0, 'credit', r.amount, 'fc_debit', 0, 'fc_credit', 0)"
  "  -- expense side flipped",
  "-- expense side flipped")

m("accumulated depreciation is DEBITED rather than credited",
  "run_depreciation",
  "           'debit', 0, 'credit', r.amount, 'fc_debit', 0, 'fc_credit', 0);",
  "           'debit', r.amount, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);"
  "  -- accumulated side flipped",
  "-- accumulated side flipped")

m("the journal is not marked as a depreciation posting",
  "run_depreciation",
  "    p_org_id, p_as_at, 'depreciation'::app.journal_source, v_entries,",
  "    p_org_id, p_as_at, 'manual'::app.journal_source, v_entries,"
  "  -- journal source lied about",
  "-- journal source lied about")

m("the journal is dated the day the job ran, not the date depreciated to",
  "run_depreciation",
  "    p_org_id, p_as_at, 'depreciation'::app.journal_source, v_entries,",
  "    p_org_id, app.today(), 'depreciation'::app.journal_source, v_entries,"
  "  -- journal dated today",
  "-- journal dated today")

m("the journal does not say which run made it",
  "run_depreciation",
  "    'Depreciation to ' || p_as_at, 'depreciation_runs', v_run_id, null,",
  "    'Depreciation to ' || p_as_at, 'depreciation_runs', null, null,"
  "  -- source run forgotten",
  "-- source run forgotten")

# -------------------------------------------------------- the run row

m("the run does not record the journal it posted",
  "run_depreciation",
  "     set gl_entry_id = v_entry_id, total_amount = v_total",
  "     set gl_entry_id = null, total_amount = v_total"
  "  -- run's journal not recorded",
  "-- run's journal not recorded")

m("the run records no total",
  "run_depreciation",
  "     set gl_entry_id = v_entry_id, total_amount = v_total",
  "     set gl_entry_id = v_entry_id, total_amount = 0"
  "  -- run total not recorded",
  "-- run total not recorded")

m("EVERY run in the company is stamped with this journal",
  "run_depreciation",
  "     set gl_entry_id = v_entry_id, total_amount = v_total\n"
  "   where id = v_run_id;",
  "     set gl_entry_id = v_entry_id, total_amount = v_total\n"
  "   where org_id = p_org_id;  -- every run stamped",
  "-- every run stamped")

m("the caller is not told which run was made",
  "run_depreciation",
  "  return v_run_id;\nend;",
  "  return null;  -- run id not returned\nend;",
  "-- run id not returned")

m("CONTROL -- a comment beside the total",
  "run_depreciation",
  "  v_total     numeric(18, 2) := 0;",
  "  v_total     numeric(18, 2) := 0;  -- CONTROL: this cannot change a sum.",
  "-- CONTROL: this cannot change a sum.")
