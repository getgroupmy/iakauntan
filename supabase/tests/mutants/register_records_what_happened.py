# Mutants for 0896 -- a register's dates are not after today.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0896_a_register_records_what_has_happened.sql \
#       supabase/tests/register_records_what_happened.sql \
#       supabase/tests/mutants/register_records_what_happened.py
#
# The columns each table hands the function are trigger arguments, not
# function source, so this harness cannot reach them. They were swept by
# hand: each of the twelve dropped from its trigger in turn, the file
# run, the trigger restored -- twelve of twelve failed the file.

m('today itself is refused too',
  'corp_not_after_today',
  "    if v_day > app.today() then\n",
  "    if v_day >= app.today() then  -- not today\n",
  '-- not today')

m('tomorrow is let in',
  'corp_not_after_today',
  "    if v_day > app.today() then\n",
  "    if v_day > app.today() + 1 then  -- tomorrow too\n",
  '-- tomorrow too')

m('no column is read',
  'corp_not_after_today',
  "    v_day := (v_row ->> split_part(v_arg, '=', 1))::date;\n",
  "    v_day := null;  -- nothing read\n",
  '-- nothing read')

m('the column is named instead of its label',
  'corp_not_after_today',
  "        split_part(v_arg, '=', 2), to_char(v_day, 'DD Mon YYYY')\n",
  "        split_part(v_arg, '=', 1), to_char(v_day, 'DD Mon YYYY')  -- column name\n",
  '-- column name')

m('CONTROL: a comment inside the function',
  'corp_not_after_today',
  "  foreach v_arg in array tg_argv loop\n",
  "  -- control\n  foreach v_arg in array tg_argv loop\n",
  '-- control')
