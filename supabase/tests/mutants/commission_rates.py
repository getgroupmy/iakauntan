# Mutants for 0866 -- a commission rate is the ledger's: read through a
# function that answers only a reader of the ledger, and set only by a
# member who may post.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0866_a_commission_rate_is_the_ledgers.sql \
#       supabase/tests/commission_rates_withheld.sql \
#       supabase/tests/mutants/commission_rates.py
#
# The column grant is no function and has no mutant here; it was swept
# by hand, commission_rate granted back to authenticated.

m('the rates go to any member',
  'salesperson_commission_rates',
  '     and app.can_read_ledger(p_org_id)\n',
  '     and true  -- any member\n',
  '-- any member')

m('the rates go only to a poster',
  'salesperson_commission_rates',
  '     and app.can_read_ledger(p_org_id)\n',
  '     and app.can_post(p_org_id)  -- posters\n',
  '-- posters')

m('the rates of every company',
  'salesperson_commission_rates',
  '   where s.org_id = p_org_id\n',
  '   where true  -- every company\n',
  '-- every company')

m('any writer sets a rate',
  'commission_rate_is_the_ledgers',
  '    if not app.can_post(new.org_id) then\n',
  '    if not app.can_write(new.org_id) then  -- writers\n',
  '-- writers')

m('any reader of the ledger sets a rate',
  'commission_rate_is_the_ledgers',
  '    if not app.can_post(new.org_id) then\n',
  '    if not app.can_read_ledger(new.org_id) then  -- readers\n',
  '-- readers')

m('a new salesperson comes in on any rate',
  'commission_rate_is_the_ledgers',
  "  if (tg_op = 'INSERT' and new.commission_rate is not null)\n",
  "  if (false)  -- inserts\n",
  '-- inserts')

m("an old salesperson's rate changes freely",
  'commission_rate_is_the_ledgers',
  "     or (tg_op = 'UPDATE'\n         and new.commission_rate is distinct from old.commission_rate) then\n",
  "     or (false) then  -- updates\n",
  '-- updates')

m('a client is never asked',
  'commission_rate_is_the_ledgers',
  "  if current_user not in ('authenticated', 'anon')\n",
  "  if true  -- nobody\n",
  '-- nobody')

m('the top statement is let through as if nested',
  'commission_rate_is_the_ledgers',
  '     or pg_trigger_depth() > 1 then\n',
  '     or pg_trigger_depth() > 0 then  -- depth\n',
  '-- depth')

m('CONTROL: the rates, as they are',
  'salesperson_commission_rates',
  '     and app.can_read_ledger(p_org_id)\n',
  '     and app.can_read_ledger(p_org_id)  -- control\n',
  '-- control')
