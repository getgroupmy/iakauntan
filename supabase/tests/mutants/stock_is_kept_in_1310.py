# Mutants for 0915 -- an item's stock account, when it names one, is
# its company's 1310, for every writer.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0915_stock_is_kept_in_1310.sql \
#       supabase/tests/stock_is_kept_in_1310.sql \
#       supabase/tests/mutants/stock_is_kept_in_1310.py

F = 'stock_is_kept_in_1310'

m('only the app is asked',
  F,
  "  if new.inventory_account_id is null then\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if new.inventory_account_id is null then\n",
  '-- app only')

m('every write is asked, not only a change',
  F,
  "  if tg_op = 'UPDATE'\n"
  "     and new.inventory_account_id is not distinct from old.inventory_account_id then\n",
  "  if false then  -- every write\n",
  '-- every write')

m('an insert is not asked',
  F,
  "  if new.inventory_account_id is null then\n",
  "  if new.inventory_account_id is null or tg_op = 'INSERT' then  -- inserts free\n",
  '-- inserts free')

m('another company''s 1310 will do',
  F,
  "   where a.id = new.inventory_account_id\n"
  "     and a.org_id = new.org_id;\n",
  "   where a.id = new.inventory_account_id;  -- any company\n",
  '-- any company')

m('any stock account will do',
  F,
  "  if v_code is distinct from '1310' then\n",
  "  if v_code is null then  -- any account\n",
  '-- any account')

m('naming 1310 is refused too',
  F,
  "  if v_code is distinct from '1310' then\n",
  "  if true then  -- nothing named\n",
  '-- nothing named')

m('CONTROL: a comment inside the function',
  F,
  "  end if;\n  return new;\nend;",
  "  end if;\n  return new;  -- control\nend;",
  '-- control')
