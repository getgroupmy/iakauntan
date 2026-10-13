# Mutants for 0867 -- a customer's credit is tightened by anybody who
# writes, and loosened only by a member who may post.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0867_credit_is_loosened_by_whoever_answers_for_it.sql \
#       supabase/tests/credit_terms_loosened.sql \
#       supabase/tests/mutants/credit_terms.py

m('any writer loosens',
  'credit_is_loosened_by_a_poster',
  '    if not app.can_post(new.org_id) then\n',
  '    if not app.can_write(new.org_id) then  -- writers\n',
  '-- writers')

m('any reader of the ledger loosens',
  'credit_is_loosened_by_a_poster',
  '    if not app.can_post(new.org_id) then\n',
  '    if not app.can_read_ledger(new.org_id) then  -- readers\n',
  '-- readers')

m('a hold comes off for anybody',
  'credit_is_loosened_by_a_poster',
  '  if (old.credit_hold and not new.credit_hold)\n',
  '  if (false)  -- holds\n',
  '-- holds')

m('a hold left off counts as one taken off',
  'credit_is_loosened_by_a_poster',
  '  if (old.credit_hold and not new.credit_hold)\n',
  '  if (not new.credit_hold)  -- left off\n',
  '-- left off')

m('a limit goes up for anybody',
  'credit_is_loosened_by_a_poster',
  '              or new.credit_limit > old.credit_limit)) then\n',
  '              or false)) then  -- raises\n',
  '-- raises')

m('an unchanged limit counts as raised',
  'credit_is_loosened_by_a_poster',
  '              or new.credit_limit > old.credit_limit)) then\n',
  '              or new.credit_limit >= old.credit_limit)) then  -- unchanged\n',
  '-- unchanged')

m('a limit is taken away by anybody',
  'credit_is_loosened_by_a_poster',
  '         and (new.credit_limit <= 0\n',
  '         and (false  -- removals\n',
  '-- removals')

m('setting a limit where there was none counts as loosening',
  'credit_is_loosened_by_a_poster',
  '     or (old.credit_limit > 0\n',
  '     or (true  -- from none\n',
  '-- from none')

m('a client is never asked',
  'credit_is_loosened_by_a_poster',
  "  if current_user not in ('authenticated', 'anon')\n",
  "  if true  -- nobody\n",
  '-- nobody')

m('the top statement is let through as if nested',
  'credit_is_loosened_by_a_poster',
  '     or pg_trigger_depth() > 1 then\n',
  '     or pg_trigger_depth() > 0 then  -- depth\n',
  '-- depth')

m('CONTROL: the trigger, as it is',
  'credit_is_loosened_by_a_poster',
  '    if not app.can_post(new.org_id) then\n',
  '    if not app.can_post(new.org_id) then  -- control\n',
  '-- control')
