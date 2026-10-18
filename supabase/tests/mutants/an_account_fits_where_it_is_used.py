# Mutants for 0912 -- a contact's control account is an active one of
# its own kind, and a line's or an item's account is not a heading, a
# bank, a till, a receivable or a payable.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0912_an_account_fits_where_it_is_used.sql \
#       supabase/tests/an_account_fits_where_it_is_used.sql \
#       supabase/tests/mutants/an_account_fits_where_it_is_used.py

F = 'an_account_fits_where_it_is_used'

m('only the app is asked',
  F,
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n  end if;\n",
  "  if current_user not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if tg_op = 'UPDATE' then\n    v_old := to_jsonb(old);\n  end if;\n",
  '-- app only')

m('every write is asked, not only a change',
  F,
  "    continue when tg_op = 'UPDATE'\n"
  "                  and (v_new -> v_col) is not distinct from (v_old -> v_col);\n",
  "    -- every write\n",
  '-- every write')

m('an insert is not asked',
  F,
  "    continue when v_id is null;\n",
  "    continue when v_id is null or tg_op = 'INSERT';  -- inserts free\n",
  '-- inserts free')

m('a heading of receivables will do for a customer',
  F,
  "      if v_acct.is_group or not v_acct.is_active\n",
  "      if not v_acct.is_active  -- headings fine\n",
  '-- headings fine')

m('a retired receivables account will do',
  F,
  "      if v_acct.is_group or not v_acct.is_active\n",
  "      if v_acct.is_group  -- retired fine\n",
  '-- retired fine')

m('any account will do for a contact',
  F,
  "         or v_acct.account_subtype::text is distinct from v_want then\n",
  "         then  -- any kind\n",
  '-- any kind')

m('a supplier wants a receivables account',
  F,
  "      v_want := case v_rule when 'receivable' then 'accounts_receivable'\n"
  "                            else 'accounts_payable' end;\n",
  "      v_want := 'accounts_receivable';  -- one kind\n",
  '-- one kind')

m('a supplier is asked as a line is',
  F,
  "    if v_rule in ('receivable', 'payable') then\n",
  "    if v_rule = 'receivable' then  -- customers only\n",
  '-- customers only')

m('a line may sit on a heading',
  F,
  "    elsif v_acct.is_group then\n",
  "    elsif false then  -- headings fine\n",
  '-- headings fine')

m('a line may move the till',
  F,
  "    elsif v_acct.account_subtype in ('bank', 'cash') then\n",
  "    elsif v_acct.account_subtype in ('bank') then  -- till fine\n",
  '-- till fine')

m('a line may move the bank',
  F,
  "    elsif v_acct.account_subtype in ('bank', 'cash') then\n",
  "    elsif v_acct.account_subtype in ('cash') then  -- bank fine\n",
  '-- bank fine')

m('a line may move the payables',
  F,
  "    elsif v_acct.account_subtype in ('accounts_receivable', 'accounts_payable') then\n",
  "    elsif v_acct.account_subtype in ('accounts_receivable') then  -- payables fine\n",
  '-- payables fine')

m('a line may move the receivables',
  F,
  "    elsif v_acct.account_subtype in ('accounts_receivable', 'accounts_payable') then\n",
  "    elsif v_acct.account_subtype in ('accounts_payable') then  -- receivables fine\n",
  '-- receivables fine')

m('only the first account named is asked',
  F,
  "    v_id    := (v_new ->> v_col)::uuid;\n",
  "    v_id    := (v_new ->> v_col)::uuid;\n"
  "    exit when v_arg is distinct from tg_argv[0];  -- first only\n",
  '-- first only')

m('CONTROL: a comment inside the function',
  F,
  "  end loop;\n  return new;\nend;",
  "  end loop;\n  return new;  -- control\nend;",
  '-- control')
