# Mutants for public.dispose_fixed_asset -- an asset sold, scrapped or
# written off: depreciation caught up to the day it left, the cost and
# the accumulated charge relieved, the proceeds banked, and the
# difference struck as a gain or a loss.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0729_the_two_the_audit_missed.sql \
#       supabase/tests/asset_disposal_shapes.sql \
#       supabase/tests/mutants/asset_disposal.py
#
# then again against `fixed_assets.sql`, `depreciation_schedule.sql` and
# `money_names_the_account.sql`.
#
# RESULT, 5 October: 38 mutants (37 plus a control). 19 killed on
# `asset_disposal_shapes.sql` and 18 survived; across its four files
# 36 of 37 die, with one proven EQUIVALENT. The control lived.
#
#   asset_disposal_shapes.sql    kills 19, then 33
#   fixed_assets.sql             kills 11, four of them new
#   depreciation_schedule.sql    kills 11, one of them new
#   money_names_the_account.sql  kills NOTHING -- see below
#
# TWO SURVIVORS WERE RULES `0729` ADDED AND NOTHING EVER TESTED, which
# is the result worth keeping. That migration closed two holes in this
# function and its own comment describes both:
#
#   * proceeds that named no account used to be debited to 1120 Bank
#     Accounts, the heading the real accounts hang under;
#   * `and b.org_id = a.org_id` on the bank lookup "is new and is a
#     cross-tenant fix, not tidying", because p_bank_account_id is an
#     ARGUMENT and none of 0160's composite foreign keys cover it.
#
# Both shipped unasserted. And `money_names_the_account.sql` -- the file
# whose whole subject is the 1120 heading, and which NAMES this function
# twice -- kills nothing, because it names it in a COMMENT and in a
# static sweep of function bodies. It never calls it. A file that checks
# the source text of a fix is not a file that checks the fix.
#
# The rest were the ordinary families: both guards at the top, both
# sides of the acquisition-date boundary, the cents, the chart-missing
# refusal, the link back to the asset, and the depreciation run's own
# figure (`v_catchup`, the months since the last run, against `v_accum`,
# everything the asset ever accumulated -- the same number until there
# IS a previous run).
#
# AND THREE `> 0` LEGS AT ONCE, measured on LAND. Land is never
# depreciated, so an asset carried at its residual value has no
# accumulated charge and no catch-up, and sold at cost it has no gain
# either: all three conditions absent together, and the journal is two
# lines. The first attempt used an asset bought and sold on the SAME DAY
# and expected two lines; it got six, because `app.months_held` counts
# the month of acquisition as a whole month. A fixture built to make
# three things zero made none of them.
#
# The longest journal in the sweep so far: up to six legs, four of them
# conditional, and the condition on every one is `> 0`. That makes the
# `>= 0` family -- a leg of two zeroes that balances and that only a
# line count can see -- the single most likely gap here, and this sweep
# has already found five of them (post_stock_adjustment, close_fiscal_
# year, run_recurring_journals_for among them).
#
# The second thing to look for, after the lesson clear_pdc and
# run_recurring_journals_for both gave: the SIX columns the final update
# writes. A disposal that posts a perfect journal and leaves the asset
# reading as in service is the defect a depreciation run would then
# charge for ever.

m("anybody can dispose of an asset",
  "dispose_fixed_asset",
  "  if not app.can_post(a.org_id) then",
  "  if false then  -- disposal post guard dropped",
  "-- disposal post guard dropped")

m("an asset already disposed of can be disposed of again",
  "dispose_fixed_asset",
  "  if a.status = 'disposed' then",
  "  if false then  -- already-disposed guard dropped",
  "-- already-disposed guard dropped")

m("an asset cannot be disposed of ON the day it was acquired",
  "dispose_fixed_asset",
  "  if p_date < a.acquisition_date then",
  "  if p_date <= a.acquisition_date then  -- same-day disposal refused",
  "-- same-day disposal refused")

m("an asset can be disposed of BEFORE it was acquired",
  "dispose_fixed_asset",
  "  if p_date < a.acquisition_date then",
  "  if false then  -- acquisition-date guard dropped",
  "-- acquisition-date guard dropped")

m("the accumulated charge can go BACKWARDS at disposal",
  "dispose_fixed_asset",
  "  v_accum := greatest(app.accumulated_depreciation_at(a, p_date),\n"
  "                      a.accumulated_depreciation);",
  "  v_accum := app.accumulated_depreciation_at(a, p_date);"
  "  -- accumulated floor dropped",
  "-- accumulated floor dropped")

m("depreciation is NOT caught up to the day the asset left",
  "dispose_fixed_asset",
  "  v_accum := greatest(app.accumulated_depreciation_at(a, p_date),\n"
  "                      a.accumulated_depreciation);",
  "  v_accum := a.accumulated_depreciation;  -- catch-up never computed",
  "-- catch-up never computed")

# EQUIVALENT, and the proof is the line directly above it.
# `v_accum := greatest(app.accumulated_depreciation_at(a, p_date),
# a.accumulated_depreciation)` makes v_accum >= a.accumulated_depreciation
# unconditionally, so `v_accum - a.accumulated_depreciation` is never
# negative and the `greatest(..., 0)` around it cannot change anything.
# Two floors, one of them unreachable because the other fires first.
# Right to keep as belt-and-braces; impossible to distinguish by any
# fixture, because the state it guards against cannot be built.
m("a NEGATIVE catch-up is charged to the profit and loss",
  "dispose_fixed_asset",
  "  v_catchup := greatest(v_accum - a.accumulated_depreciation, 0);",
  "  v_catchup := v_accum - a.accumulated_depreciation;"
  "  -- catch-up floor dropped",
  "-- catch-up floor dropped")

m("the gain or loss is struck against COST rather than net book value",
  "dispose_fixed_asset",
  "  v_nbv := a.cost - v_accum;",
  "  v_nbv := a.cost;  -- accumulated charge ignored in the result",
  "-- accumulated charge ignored in the result")

m("the gain or loss loses its cents",
  "dispose_fixed_asset",
  "  v_result := round(coalesce(p_proceeds, 0) - v_nbv, 2);",
  "  v_result := round(coalesce(p_proceeds, 0) - v_nbv, 0);"
  "  -- result rounded to ringgit",
  "-- result rounded to ringgit")

m("the asset's OWN cost account is ignored for the chart's 1510",
  "dispose_fixed_asset",
  "  v_asset_ac := coalesce(a.asset_account_id,",
  "  v_asset_ac := coalesce(null::uuid,  -- asset's own account ignored",
  "-- asset's own account ignored")

m("the asset's OWN accumulated account is ignored for the chart's 1590",
  "dispose_fixed_asset",
  "  v_accum_ac := coalesce(a.accumulated_account_id,",
  "  v_accum_ac := coalesce(null::uuid,  -- asset's own accum account ignored",
  "-- asset's own accum account ignored")

m("an asset scrapped for NOTHING is made to name a bank account",
  "dispose_fixed_asset",
  "  if coalesce(p_proceeds, 0) > 0 then\n    if p_bank_account_id is null then",
  "  if coalesce(p_proceeds, 0) >= 0 then\n    if p_bank_account_id is null then"
  "  -- nil disposal made to name an account",
  "-- nil disposal made to name an account")

m("proceeds can be received into no account at all",
  "dispose_fixed_asset",
  "    if p_bank_account_id is null then",
  "    if false then  -- bankless proceeds accepted",
  "-- bankless proceeds accepted")

m("proceeds can be banked into ANOTHER COMPANY's account",
  "dispose_fixed_asset",
  "     where b.id = p_bank_account_id and b.org_id = a.org_id;",
  "     where b.id = p_bank_account_id;  -- proceeds bank org scope dropped",
  "-- proceeds bank org scope dropped")

m("a chart with no 1510 or 1590 posts the disposal anyway",
  "dispose_fixed_asset",
  "  if v_asset_ac is null or v_accum_ac is null then",
  "  if false then  -- missing-account guard dropped",
  "-- missing-account guard dropped")

m("an asset already depreciated to the day gets a catch-up of NOTHING",
  "dispose_fixed_asset",
  "  if v_catchup > 0 then\n"
  "    v_expense_ac := coalesce(a.expense_account_id,",
  "  if v_catchup >= 0 then  -- nil catch-up lines posted\n"
  "    v_expense_ac := coalesce(a.expense_account_id,",
  "-- nil catch-up lines posted")

m("the asset's own depreciation expense account is ignored",
  "dispose_fixed_asset",
  "    v_expense_ac := coalesce(a.expense_account_id,",
  "    v_expense_ac := coalesce(null::uuid,  -- own expense account ignored",
  "-- own expense account ignored")

m("the catch-up CREDITS the expense and DEBITS the accumulated charge",
  "dispose_fixed_asset",
  "           'debit', v_catchup, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0)\n"
  "      || jsonb_build_object(",
  "           'debit', 0, 'credit', v_catchup, 'fc_debit', 0, 'fc_credit', 0)\n"
  "      || jsonb_build_object(  -- catch-up expense side swapped",
  "-- catch-up expense side swapped")

m("an asset with NO accumulated charge gets a line of nothing",
  "dispose_fixed_asset",
  "  if v_accum > 0 then",
  "  if v_accum >= 0 then  -- nil accumulated line posted",
  "-- nil accumulated line posted")

m("the accumulated charge is CREDITED rather than relieved",
  "dispose_fixed_asset",
  "      'debit', v_accum, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);",
  "      'debit', 0, 'credit', v_accum, 'fc_debit', 0, 'fc_credit', 0);"
  "  -- accumulated relief side swapped",
  "-- accumulated relief side swapped")

m("a disposal for nothing still adds a cash leg of nothing",
  "dispose_fixed_asset",
  "  if coalesce(p_proceeds, 0) > 0 then\n    v_entries := v_entries || jsonb_build_object(\n"
  "      'account_id', v_cash_ac,",
  "  if coalesce(p_proceeds, 0) >= 0 then  -- nil proceeds line posted\n"
  "    v_entries := v_entries || jsonb_build_object(\n"
  "      'account_id', v_cash_ac,",
  "-- nil proceeds line posted")

m("the asset is relieved at its NET BOOK VALUE rather than at cost",
  "dispose_fixed_asset",
  "    'account_id', v_asset_ac, 'description', 'Disposal of ' || a.asset_no,\n"
  "    'debit', 0, 'credit', a.cost, 'fc_debit', 0, 'fc_credit', 0);",
  "    'account_id', v_asset_ac, 'description', 'Disposal of ' || a.asset_no,\n"
  "    'debit', 0, 'credit', v_nbv, 'fc_debit', 0, 'fc_credit', 0);"
  "  -- asset relieved at NBV",
  "-- asset relieved at NBV")

m("a disposal at exactly net book value posts a gain of nothing",
  "dispose_fixed_asset",
  "  if v_result > 0 then",
  "  if v_result >= 0 then  -- nil gain line posted",
  "-- nil gain line posted")

m("a GAIN is posted to the LOSS account and the loss to the gain",
  "dispose_fixed_asset",
  "      'account_id', app.disposal_account(a.org_id, true),\n"
  "      'description', 'Gain on disposal of ' || a.asset_no,",
  "      'account_id', app.disposal_account(a.org_id, false),\n"
  "      'description', 'Gain on disposal of ' || a.asset_no,"
  "  -- gain posted to the loss account",
  "-- gain posted to the loss account")

m("a gain is DEBITED, which reads as a loss and still balances",
  "dispose_fixed_asset",
  "      'debit', 0, 'credit', v_result, 'fc_debit', 0, 'fc_credit', 0);",
  "      'debit', v_result, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);"
  "  -- gain side swapped",
  "-- gain side swapped")

m("a loss is posted as a negative debit rather than a positive one",
  "dispose_fixed_asset",
  "      'debit', -v_result, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0);",
  "      'debit', 0, 'credit', -v_result, 'fc_debit', 0, 'fc_credit', 0);"
  "  -- loss side swapped",
  "-- loss side swapped")

m("the disposal journal is dated the day it was typed",
  "dispose_fixed_asset",
  "    a.org_id, p_date, 'depreciation'::app.journal_source, v_entries,",
  "    a.org_id, app.today(), 'depreciation'::app.journal_source, v_entries,"
  "  -- disposal date forced to today",
  "-- disposal date forced to today")

m("the journal does not point back at the asset",
  "dispose_fixed_asset",
  "    'fixed_assets', a.id, null, app.base_currency(a.org_id), 1);",
  "    'fixed_assets', null, null, app.base_currency(a.org_id), 1);"
  "  -- source asset forgotten",
  "-- source asset forgotten")

m("the catch-up is not recorded in the depreciation history",
  "dispose_fixed_asset",
  "  if v_catchup > 0 then\n    insert into public.depreciation_runs",
  "  if false then  -- catch-up run not recorded\n"
  "    insert into public.depreciation_runs",
  "-- catch-up run not recorded")

m("the catch-up run records the whole accumulated charge as the period's",
  "dispose_fixed_asset",
  "    values (a.org_id, p_date, v_entry_id, v_catchup, auth.uid())",
  "    values (a.org_id, p_date, v_entry_id, v_accum, auth.uid())"
  "  -- run total is the whole charge",
  "-- run total is the whole charge")

m("the catch-up's opening and closing balances are the wrong way round",
  "dispose_fixed_asset",
  "    values (a.org_id, v_run_id, a.id, v_catchup,\n"
  "            a.accumulated_depreciation, v_accum);",
  "    values (a.org_id, v_run_id, a.id, v_catchup,\n"
  "            v_accum, a.accumulated_depreciation);  -- opening/closing swapped",
  "-- opening/closing swapped")

m("a disposed asset still reads as in service",
  "dispose_fixed_asset",
  "     set status = 'disposed', disposal_date = p_date,",
  "     set disposal_date = p_date,  -- status not advanced",
  "-- status not advanced")

m("the asset records the day it was typed as the day it left",
  "dispose_fixed_asset",
  "     set status = 'disposed', disposal_date = p_date,",
  "     set status = 'disposed', disposal_date = app.today(),"
  "  -- disposal date not kept",
  "-- disposal date not kept")

m("what the asset was sold for is not recorded on it",
  "dispose_fixed_asset",
  "         disposal_proceeds = coalesce(p_proceeds, 0),",
  "         disposal_proceeds = 0,  -- proceeds not recorded",
  "-- proceeds not recorded")

m("the asset does not remember the journal that disposed of it",
  "dispose_fixed_asset",
  "         disposal_entry_id = v_entry_id,",
  "         disposal_entry_id = null,  -- disposal entry not kept",
  "-- disposal entry not kept")

m("the caught-up charge is not written onto the asset",
  "dispose_fixed_asset",
  "         accumulated_depreciation = v_accum,",
  "         accumulated_depreciation = a.accumulated_depreciation,"
  "  -- caught-up charge not stored",
  "-- caught-up charge not stored")

m("the asset does not record how far it was depreciated",
  "dispose_fixed_asset",
  "         depreciated_to = p_date,",
  "         depreciated_to = null,  -- depreciated_to not kept",
  "-- depreciated_to not kept")

m("CONTROL -- a comment beside the net book value",
  "dispose_fixed_asset",
  "  v_nbv := a.cost - v_accum;",
  "  v_nbv := a.cost - v_accum;  -- CONTROL: this cannot change a figure.",
  "-- CONTROL: this cannot change a figure.")
