# Mutants for 0868 -- the drawer's tolerance is tightened by anybody the
# till admits, and loosened only by a manager.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0868_the_drawers_tolerance_is_the_managers.sql \
#       supabase/tests/drawer_tolerance.sql \
#       supabase/tests/mutants/drawer_tolerance.py

m('anybody at the till loosens it',
  'drawer_tolerance_is_the_managers',
  '  if v_loosened and not app.can_admin(old.org_id) then\n',
  "  if v_loosened and not app.can_write_module(old.org_id, 'pos') then  -- till\n",
  '-- till')

m('a poster loosens it',
  'drawer_tolerance_is_the_managers',
  '  if v_loosened and not app.can_admin(old.org_id) then\n',
  '  if v_loosened and not app.can_post(old.org_id) then  -- posters\n',
  '-- posters')

m('a delete is not a loosening',
  'drawer_tolerance_is_the_managers',
  '    v_loosened := old.variance_tolerance is not null;\n',
  '    v_loosened := false;  -- deletes\n',
  '-- deletes')

m('a delete of a row with no tolerance is one',
  'drawer_tolerance_is_the_managers',
  '    v_loosened := old.variance_tolerance is not null;\n',
  '    v_loosened := true;  -- any delete\n',
  '-- any delete')

m('clearing it is not a loosening',
  'drawer_tolerance_is_the_managers',
  '                  and (new.variance_tolerance is null\n',
  '                  and (false  -- clears\n',
  '-- clears')

m('raising it is not a loosening',
  'drawer_tolerance_is_the_managers',
  '                       or new.variance_tolerance > old.variance_tolerance);\n',
  '                       or false);  -- raises\n',
  '-- raises')

m('leaving it as it was is a loosening',
  'drawer_tolerance_is_the_managers',
  '                       or new.variance_tolerance > old.variance_tolerance);\n',
  '                       or new.variance_tolerance >= old.variance_tolerance);  -- unchanged\n',
  '-- unchanged')

m('setting one where there was none is a loosening',
  'drawer_tolerance_is_the_managers',
  '    v_loosened := old.variance_tolerance is not null\n                  and',
  '    v_loosened := true  -- from none\n                  and',
  '-- from none')

m('a client is never asked',
  'drawer_tolerance_is_the_managers',
  "  if current_user not in ('authenticated', 'anon')\n",
  "  if true  -- nobody\n",
  '-- nobody')

m('the top statement is let through as if nested',
  'drawer_tolerance_is_the_managers',
  '     or pg_trigger_depth() > 1 then\n',
  '     or pg_trigger_depth() > 0 then  -- depth\n',
  '-- depth')

m('CONTROL: the trigger, as it is',
  'drawer_tolerance_is_the_managers',
  '  if v_loosened and not app.can_admin(old.org_id) then\n',
  '  if v_loosened and not app.can_admin(old.org_id) then  -- control\n',
  '-- control')
