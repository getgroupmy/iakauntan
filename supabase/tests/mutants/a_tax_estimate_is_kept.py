# Mutants for app.a_tax_estimate_is_kept() (0827) -- a client may not
# change an estimate a revision replaced, nor what opening and revising
# decide on any estimate; the dialog's own fields stay the client's and
# the owner at the top is let through.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0827_a_revision_leaves_the_estimate_it_replaced.sql \
#       supabase/tests/tax_estimate_chain.sql \
#       supabase/tests/mutants/a_tax_estimate_is_kept.py
#
# RESULT: 16 of 17 mutants killed by `tax_estimate_chain.sql`, the
# control surviving. The survivor, `a nested statement is a client's
# too`, is equivalent -- `open_tax_estimate` and `revise_tax_estimate`
# are definers -- and the file says so. `org_id`, `fiscal_year_id` and
# `created_by` die for the wrong reason, by a policy or a foreign key
# answering a random value; the file asks for the guard's own sentence,
# so a value either of those would let through still dies here.
#
# The revoked insert and delete are not in the function, so they were
# restored by hand: each grant with its policy, and each grant alone,
# fails the file (4 of 4), each policy alone fails its last assertion
# (2 of 2), and a no-op control passes.

m('the guard is never asked',
  'a_tax_estimate_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- never asked',
  '-- never asked')

m('the owner at the top is refused too',
  'a_tax_estimate_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if pg_trigger_depth() > 1 then  -- owner refused',
  '-- owner refused')

m("a nested statement is a client's too",
  'a_tax_estimate_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if current_user not in ('authenticated', 'anon') then  -- depth unasked",
  '-- depth unasked')

m('a replaced estimate is not asked',
  'a_tax_estimate_is_kept',
  "  if old.status = 'superseded' then",
  '  if false then  -- superseded unasked',
  '-- superseded unasked')

m('the live one is taken for the replaced one',
  'a_tax_estimate_is_kept',
  "  if old.status = 'superseded' then",
  "  if old.status <> 'superseded' then  -- the wrong one",
  '-- the wrong one')

m('a replaced estimate is refused as some other kind',
  'a_tax_estimate_is_kept',
  "      old.form, old.year_of_assessment\n      using errcode = '42501';",
  "      old.form, old.year_of_assessment\n      using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('the chain is never asked',
  'a_tax_estimate_is_kept',
  '  foreach v_col in array c_chain loop',
  '  foreach v_col in array array[]::text[] loop  -- chain unasked',
  '-- chain unasked')

for col in ['org_id', 'fiscal_year_id', 'year_of_assessment', 'form',
            'revises_id', 'revision_month', 'status', 'created_by']:
    m(f'{col} is not asked',
      'a_tax_estimate_is_kept',
      f"'{col}'",
      "'updated_at'",
      "'updated_at'")

m('a typed column is refused as some other kind',
  'a_tax_estimate_is_kept',
  "        v_col, old.form, old.year_of_assessment\n        using errcode = '42501';",
  "        v_col, old.form, old.year_of_assessment\n        using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside the block',
  'a_tax_estimate_is_kept',
  '  v_old := to_jsonb(old);',
  '  v_old := to_jsonb(old);  -- (control)',
  '(control)')
