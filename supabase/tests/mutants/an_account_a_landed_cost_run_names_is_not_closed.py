# Mutants for 0927 -- an account a draft landed cost run names is not
# closed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0927_an_account_a_landed_cost_run_names_is_not_closed.sql \
#       supabase/tests/an_account_a_landed_cost_run_names_is_not_closed.sql \
#       supabase/tests/mutants/an_account_a_landed_cost_run_names_is_not_closed.py
#
# Not mutated: the clause's `r.org_id = v_a.org_id`. A charge naming
# this account is this company's by the charge's tenant key, so a run
# of another company can never match, and removing the filter is an
# equivalent mutant.

R = 'retire_account'

m('a draft run is not asked',
  R,
  "             and r.status = 'draft'\n",
  "             and false  -- not asked\n",
  '-- not asked')

m('a posted run still holds its accounts',
  R,
  "             and r.status = 'draft'\n",
  "             and r.status in ('draft', 'posted')  -- posted counts\n",
  '-- posted counts')

m('a cancelled run still holds its accounts',
  R,
  "             and r.status = 'draft'\n",
  "             and r.status in ('draft', 'cancelled')  -- cancelled counts\n",
  '-- cancelled counts')

m('a draft run holds every account, named or not',
  R,
  "                          where c.run_id = r.id and c.account_id = p_id)\n",
  "                          where c.run_id = r.id)  -- any account\n",
  '-- any account')

m('only the first charge is asked',
  R,
  "                          where c.run_id = r.id and c.account_id = p_id)\n",
  "                          where c.run_id = r.id and c.account_id = p_id and c.line_no = 1)  -- first only\n",
  '-- first only')

m('the run is not named',
  R,
  "          select 13, 'unposted landed cost run ' || r.run_no\n",
  "          select 13, 'unposted landed cost run'  -- no number\n",
  '-- no number')

m('CONTROL: a comment in the clause',
  R,
  "          -- 0927: and a landed cost run not yet posted. Each charge\n",
  "          -- 0927: and a landed cost run not yet posted. Each charge (control)\n",
  '(control)')
