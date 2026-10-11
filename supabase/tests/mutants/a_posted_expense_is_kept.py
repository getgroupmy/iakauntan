# Mutants for app.a_posted_expense_is_kept() (0824) -- a client may not
# rewrite a posted expense's journalled columns, state or deletion mark,
# delete it, create one other than as a draft, or move a draft's state;
# the description, reference and receipt stay editable and the owner at
# the top is let through. Every element of the frozen list is a mutant
# of its own.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0824_an_expense_is_kept_as_it_was_posted.sql \
#       supabase/tests/posted_expense_kept.sql \
#       supabase/tests/mutants/a_posted_expense_is_kept.py
#
# RESULT: 33 of 34 mutants killed by `posted_expense_kept.sql`, the control
# surviving, the first time. The survivor, `a nested statement is a
# client's too`, is equivalent -- the table's only writers are two
# definers -- and the file says so beside the owner's assertion. Eight of
# the column mutants were killed by something else answering instead of
# the guard -- a foreign key, the row's policy, the branch check,
# `refuse_reposting` -- which is a kill because each assertion asks for
# the guard's own sentence: with a value those would take, the change
# would have gone through.

m('the guard is never asked',
  'a_posted_expense_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- never asked',
  '-- never asked')

m('the owner at the top is refused too',
  'a_posted_expense_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if pg_trigger_depth() > 1 then  -- owner refused',
  '-- owner refused')

m("a nested statement is a client's too",
  'a_posted_expense_is_kept',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if current_user not in ('authenticated', 'anon') then  -- depth unasked",
  '-- depth unasked')

m("an insert's state is not asked",
  'a_posted_expense_is_kept',
  "    if new.status <> 'draft' or new.gl_entry_id is not null",
  '    if false or new.gl_entry_id is not null  -- insert state unasked',
  '-- insert state unasked')

m("an insert's journal is not asked",
  'a_posted_expense_is_kept',
  "    if new.status <> 'draft' or new.gl_entry_id is not null\n",
  "    if new.status <> 'draft' or false  -- insert journal unasked\n",
  '-- insert journal unasked')

m("an insert's posting time is not asked",
  'a_posted_expense_is_kept',
  "       or new.posted_at is not null then\n      raise exception\n        'An expense",
  "       or false then  -- insert time unasked\n      raise exception\n        'An expense",
  '-- insert time unasked')

m('a posted expense may be deleted',
  'a_posted_expense_is_kept',
  "    if tg_op = 'DELETE' then",
  '    if false then  -- delete allowed',
  '-- delete allowed')

m("a posted expense's columns are not asked",
  'a_posted_expense_is_kept',
  '    foreach v_col in array c_frozen loop',
  '    foreach v_col in array array[]::text[] loop  -- nothing frozen',
  '-- nothing frozen')

m('posted is asked by the wrong column',
  'a_posted_expense_is_kept',
  '  if old.gl_entry_id is not null then',
  '  if old.posted_at is null and old.gl_entry_id is not null then  -- wrong column',
  '-- wrong column')

m('org_id is not frozen',
  'a_posted_expense_is_kept',
  "'org_id',",
  "'created_at',",
  "'created_at'")

m('expense_no is not frozen',
  'a_posted_expense_is_kept',
  "'expense_no',",
  "'created_at',",
  "'created_at'")

m('expense_date is not frozen',
  'a_posted_expense_is_kept',
  "'expense_date',",
  "'created_at',",
  "'created_at'")

m('contact_id is not frozen',
  'a_posted_expense_is_kept',
  "'contact_id',",
  "'created_at',",
  "'created_at'")

m('account_id is not frozen',
  'a_posted_expense_is_kept',
  "'account_id',",
  "'created_at',",
  "'created_at'")

m('bank_account_id is not frozen',
  'a_posted_expense_is_kept',
  "'bank_account_id',",
  "'created_at',",
  "'created_at'")

m('payment_mode_code is not frozen',
  'a_posted_expense_is_kept',
  "'payment_mode_code',",
  "'created_at',",
  "'created_at'")

m('currency is not frozen',
  'a_posted_expense_is_kept',
  "'currency',",
  "'created_at',",
  "'created_at'")

m('exchange_rate is not frozen',
  'a_posted_expense_is_kept',
  "'exchange_rate',",
  "'created_at',",
  "'created_at'")

m('amount is not frozen',
  'a_posted_expense_is_kept',
  "'amount',",
  "'created_at',",
  "'created_at'")

m('tax_code_id is not frozen',
  'a_posted_expense_is_kept',
  "'tax_code_id',",
  "'created_at',",
  "'created_at'")

m('tax_amount is not frozen',
  'a_posted_expense_is_kept',
  "'tax_amount',",
  "'created_at',",
  "'created_at'")

m('total_amount is not frozen',
  'a_posted_expense_is_kept',
  "'total_amount',",
  "'created_at',",
  "'created_at'")

m('branch_id is not frozen',
  'a_posted_expense_is_kept',
  "'branch_id',",
  "'created_at',",
  "'created_at'")

m('department_code is not frozen',
  'a_posted_expense_is_kept',
  "'department_code',",
  "'created_at',",
  "'created_at'")

m('project_code is not frozen',
  'a_posted_expense_is_kept',
  "'project_code',",
  "'created_at',",
  "'created_at'")

m('matter_id is not frozen',
  'a_posted_expense_is_kept',
  "'matter_id',",
  "'created_at',",
  "'created_at'")

m('status is not frozen',
  'a_posted_expense_is_kept',
  "'status',",
  "'created_at',",
  "'created_at'")

m('gl_entry_id is not frozen',
  'a_posted_expense_is_kept',
  "'gl_entry_id',",
  "'created_at',",
  "'created_at'")

m('posted_at is not frozen',
  'a_posted_expense_is_kept',
  "'posted_at',",
  "'created_at',",
  "'created_at'")

m('deleted_at is not frozen',
  'a_posted_expense_is_kept',
  "'deleted_at']",
  "'created_at']",
  "'created_at'")

m("a draft's state is not asked",
  'a_posted_expense_is_kept',
  '     and (new.status is distinct from old.status\n',
  '     and (false  -- draft state unasked\n',
  '-- draft state unasked')

m("a draft's journal is not asked",
  'a_posted_expense_is_kept',
  '          or new.gl_entry_id is distinct from old.gl_entry_id\n',
  '          or false  -- draft journal unasked\n',
  '-- draft journal unasked')

m("a draft's posting time is not asked",
  'a_posted_expense_is_kept',
  '          or new.posted_at is distinct from old.posted_at) then',
  '          or false) then  -- draft time unasked',
  '-- draft time unasked')

m('the refusal is a different kind',
  'a_posted_expense_is_kept',
  "          old.expense_no, v_col\n          using errcode = '42501';",
  "          old.expense_no, v_col\n          using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside the block',
  'a_posted_expense_is_kept',
  "  if tg_op = 'INSERT' then",
  "  if tg_op = 'INSERT' then  -- (control)",
  '(control)')
