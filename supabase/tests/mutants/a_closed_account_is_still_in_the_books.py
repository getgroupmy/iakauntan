# Mutants for 0828 -- the six reports show a closed account that carries
# posted lines or an opening balance, and `retire_account` refuses an
# account with a balance or one an active bank account posts to.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0828_a_closed_account_is_still_in_the_books.sql \
#       supabase/tests/closed_account_in_books.sql \
#       supabase/tests/mutants/a_closed_account_is_still_in_the_books.py
#
# RESULT: see docs/handoff.md, item 95.

# -- report_trial_balance ---------------------------------------------
m('the trial balance leaves closed accounts out again',
  'report_trial_balance',
  '     and (a.deleted_at is null or m.account_id is not null)',
  '     and (a.deleted_at is null)  -- closed left out',
  '-- closed left out')

m('the trial balance shows every closed account',
  'report_trial_balance',
  '     and (a.deleted_at is null or m.account_id is not null)',
  '     and (true)  -- every closed account',
  '-- every closed account')

# -- report_balance_sheet ---------------------------------------------
m('the balance sheet leaves closed accounts out again',
  'report_balance_sheet',
  '  having a.deleted_at is null or count(e.id) > 0',
  '  having a.deleted_at is null  -- closed left out',
  '-- closed left out')

m('the balance sheet shows every closed account',
  'report_balance_sheet',
  '  having a.deleted_at is null or count(e.id) > 0',
  '  having true  -- every closed account',
  '-- every closed account')

# -- report_general_ledger --------------------------------------------
m('the general ledger leaves closed accounts out again',
  'report_general_ledger',
  "            or exists (select 1 from public.gl_lines pl\n"
  "                          join public.gl_entries pe on pe.id = pl.entry_id\n"
  "                         where pl.account_id = a.id and pe.status = 'posted'))",
  "            or false)  -- closed left out",
  '-- closed left out')

m('the general ledger shows every closed account',
  'report_general_ledger',
  "            or exists (select 1 from public.gl_lines pl\n"
  "                          join public.gl_entries pe on pe.id = pl.entry_id\n"
  "                         where pl.account_id = a.id and pe.status = 'posted'))",
  "            or true)  -- every closed account",
  '-- every closed account')

m("the general ledger counts a closed account's draft lines",
  'report_general_ledger',
  "                         where pl.account_id = a.id and pe.status = 'posted'))",
  "                         where pl.account_id = a.id))  -- drafts count",
  '-- drafts count')

# -- report_changes_in_equity -----------------------------------------
m('changes in equity leaves closed accounts out again',
  'report_changes_in_equity',
  "            or exists (select 1 from public.gl_lines pl\n"
  "                           join public.gl_entries pe on pe.id = pl.entry_id\n"
  "                          where pl.account_id = a.id and pe.status = 'posted'))",
  "            or false)  -- closed left out",
  '-- closed left out')

m('changes in equity shows every closed account',
  'report_changes_in_equity',
  "            or exists (select 1 from public.gl_lines pl\n"
  "                           join public.gl_entries pe on pe.id = pl.entry_id\n"
  "                          where pl.account_id = a.id and pe.status = 'posted'))",
  "            or true)  -- every closed account",
  '-- every closed account')

# -- report_matter_trial_balance --------------------------------------
m("the matter's trial balance leaves closed accounts out again",
  'report_matter_trial_balance',
  '   where a.org_id = p_org_id\n   order by a.code;',
  '   where a.org_id = p_org_id and a.deleted_at is null  -- closed left out\n   order by a.code;',
  '-- closed left out')

# -- report_cash_flow -------------------------------------------------
m("the cash brought forward leaves a closed account's opening balance out again",
  'report_cash_flow',
  "                        or exists (select 1 from public.gl_lines ol\n"
  "                                    join public.gl_entries oe on oe.id = ol.entry_id\n"
  "                                   where ol.account_id = a.id and oe.status = 'posted'))",
  "                        or false)  -- closed left out",
  '-- closed left out')

m("the cash brought forward counts every closed account's opening balance",
  'report_cash_flow',
  "                        or exists (select 1 from public.gl_lines ol\n"
  "                                    join public.gl_entries oe on oe.id = ol.entry_id\n"
  "                                   where ol.account_id = a.id and oe.status = 'posted'))",
  "                        or true)  -- every closed account",
  '-- every closed account')

m("the cash carried forward leaves a closed account's opening balance out again",
  'report_cash_flow',
  "                        or exists (select 1 from public.gl_lines cl\n"
  "                                    join public.gl_entries ce2 on ce2.id = cl.entry_id\n"
  "                                   where cl.account_id = a.id and ce2.status = 'posted'))",
  "                        or false)  -- closed left out",
  '-- closed left out')

m("the cash carried forward counts every closed account's opening balance",
  'report_cash_flow',
  "                        or exists (select 1 from public.gl_lines cl\n"
  "                                    join public.gl_entries ce2 on ce2.id = cl.entry_id\n"
  "                                   where cl.account_id = a.id and ce2.status = 'posted'))",
  "                        or true)  -- every closed account",
  '-- every closed account')

# -- retire_account ---------------------------------------------------
m('a balance is never asked',
  'retire_account',
  '  if v_balance <> 0 then',
  '  if false then  -- balance unasked',
  '-- balance unasked')

m('an opening balance is not counted',
  'retire_account',
  '  v_balance := v_balance\n    + case',
  '  v_balance := v_balance\n    + 0 * /* opening uncounted */ case',
  '/* opening uncounted */')

m('an opening balance is signed the other way',
  'retire_account',
  '           then v_a.opening_balance else -v_a.opening_balance end;',
  '           then -v_a.opening_balance else v_a.opening_balance end;  -- sign flipped',
  '-- sign flipped')

m('a draft journal counts',
  'retire_account',
  "   where l.account_id = p_id and e.status = 'posted';",
  "   where l.account_id = p_id;  -- drafts counted",
  '-- drafts counted')

m('debit and credit are named the wrong way round',
  'retire_account',
  "case when v_balance > 0 then ' debit' else ' credit' end",
  "case when v_balance > 0 then ' credit' else ' debit' end  -- swapped",
  '-- swapped')

m('a credit balance is printed negative',
  'retire_account',
  "to_char(abs(v_balance), 'FM999,999,999,990.00')",
  "to_char(v_balance, 'FM999,999,999,990.00')  /* signed */",
  '/* signed */')

m('a balance is refused as some other kind',
  'retire_account',
  "      v_a.code, to_char(abs(v_balance), 'FM999,999,999,990.00')\n"
  "        || case when v_balance > 0 then ' debit' else ' credit' end\n"
  "      using errcode = '23514';",
  "      v_a.code, to_char(abs(v_balance), 'FM999,999,999,990.00')\n"
  "        || case when v_balance > 0 then ' debit' else ' credit' end\n"
  "      using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('a live bank account is never asked',
  'retire_account',
  '  if v_bank is not null then',
  '  if false then  -- bank unasked',
  '-- bank unasked')

m('a bank account out of use counts',
  'retire_account',
  '   where b.account_id = p_id and b.is_active\n',
  '   where b.account_id = p_id  -- any bank\n',
  '-- any bank')

m('a live bank account is refused as some other kind',
  'retire_account',
  "      'still posts to it.', v_a.code, v_bank\n      using errcode = '23514';",
  "      'still posts to it.', v_a.code, v_bank\n      using errcode = 'P0001';  -- other kind",
  '-- other kind')

m('CONTROL: a comment inside retire_account',
  'retire_account',
  '  if v_balance <> 0 then',
  '  if v_balance <> 0 then  -- (control)',
  '(control)')
