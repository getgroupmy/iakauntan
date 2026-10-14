# Mutants for 0904 -- the transfer counters on document lines and
# fulfilment_status on the header are the database's to write.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0904_what_was_taken_forward_is_the_databases.sql \
#       supabase/tests/what_was_taken_forward.sql \
#       supabase/tests/mutants/what_was_taken_forward.py

m('nobody is asked',
  'what_was_taken_forward_is_the_databases',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then\n",
  "  if true then  -- nobody asked\n",
  '-- nobody asked')

m('the owner is refused too',
  'what_was_taken_forward_is_the_databases',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then\n",
  "  if pg_trigger_depth() > 1 then  -- everyone\n",
  '-- everyone')

m('an update is measured from zero, not from what it was',
  'what_was_taken_forward_is_the_databases',
  "(v_new -> v_col) is distinct from (v_old -> v_col)) then\n",
  "(v_new -> v_col) is distinct from v_start) then  -- from zero\n",
  '-- from zero')

m('an insert is not asked',
  'what_was_taken_forward_is_the_databases',
  "    if (tg_op = 'INSERT' and (v_new -> v_col) is distinct from v_start)\n",
  "    if (false)  -- inserts free\n",
  '-- inserts free')

m('only the first column is asked',
  'what_was_taken_forward_is_the_databases',
  "  foreach v_arg in array tg_argv loop\n",
  "  foreach v_arg in array tg_argv[1:1] loop  -- first only\n",
  '-- first only')

m('CONTROL: a comment inside the function',
  'what_was_taken_forward_is_the_databases',
  "  foreach v_arg in array tg_argv loop\n",
  "  -- control\n  foreach v_arg in array tg_argv loop\n",
  '-- control')
