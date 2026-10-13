# Mutants for 0865 -- the fixed asset register is the ledger's: the
# preview and the capital allowance schedule refuse a member who does
# not read it, the uncapitalised purchases give that member nothing, and
# only a writer who reads the ledger capitalises a bill line.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0865_the_fixed_asset_register_is_the_ledgers.sql \
#       supabase/tests/fixed_assets_withheld.sql \
#       supabase/tests/mutants/fixed_assets.py
#
# The five policies are no function and have no mutant here; they were
# swept by hand, 11 / 11 with a control: each select policy put back to
# is_org_member and to can_post, the insert check to either half of
# can_write and can_read_ledger, the update's USING to can_write alone
# and to can_post, and its WITH CHECK to can_write alone. Two things that
# sweep taught, both written into the test:
#
#   * The update's USING put back to can_write is killed by its WITH
#     CHECK, as an error rather than an assertion: the purchaser's
#     unqualified update then reaches the row and is refused writing it.
#   * Its WITH CHECK put back to can_write survived a move with a WHERE,
#     because an UPDATE that reads its rows holds the new row to the
#     select policy as well. The move is written without one.

m('a writer who does not read the ledger capitalises',
  'capitalise_bill_line',
  '  if not (app.can_write(v_line.org_id)\n          and app.can_read_ledger(v_line.org_id)) then\n',
  '  if not (app.can_write(v_line.org_id)) then  -- any writer\n',
  '-- any writer')

m('a reader who does not write capitalises',
  'capitalise_bill_line',
  '  if not (app.can_write(v_line.org_id)\n          and app.can_read_ledger(v_line.org_id)) then\n',
  '  if not (app.can_read_ledger(v_line.org_id)) then  -- any reader\n',
  '-- any reader')

m('only a poster capitalises',
  'capitalise_bill_line',
  '  if not (app.can_write(v_line.org_id)\n          and app.can_read_ledger(v_line.org_id)) then\n',
  '  if not (app.can_post(v_line.org_id)) then  -- posters\n',
  '-- posters')

m('the preview answers any member',
  'depreciation_preview',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- any member\n',
  '-- any member')

m('the preview answers only a poster',
  'depreciation_preview',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if not app.can_post(p_org_id) then  -- posters\n',
  '-- posters')

m('the uncapitalised purchases answer any member',
  'report_uncapitalised_purchases',
  '     and app.can_read_ledger(p_org)\n',
  '     and true  -- any member\n',
  '-- any member')

m('the uncapitalised purchases answer only a poster',
  'report_uncapitalised_purchases',
  '     and app.can_read_ledger(p_org)\n',
  '     and app.can_post(p_org)  -- posters\n',
  '-- posters')

m('the capital allowance schedule answers any member',
  'capital_allowance_schedule',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if false then  -- any member\n',
  '-- any member')

m('the capital allowance schedule answers only a poster',
  'capital_allowance_schedule',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if not app.can_post(p_org_id) then  -- posters\n',
  '-- posters')

m('CONTROL: the preview, as it is',
  'depreciation_preview',
  '  if not app.can_read_ledger(p_org_id) then\n',
  '  if not app.can_read_ledger(p_org_id) then  -- control\n',
  '-- control')
