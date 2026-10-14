# Mutants for 0891 -- a matter's client ledger is read day by day, and
# no day may close in debit.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0891_client_money_is_never_short_on_any_day.sql \
#       supabase/tests/client_money_any_day.sql \
#       supabase/tests/mutants/client_money_any_day.py

m('the total is read on every day again',
  'assert_client_funds',
  "                   sum(sum(t.amount)) over (order by t.transaction_date)\n",
  "                   sum(sum(t.amount)) over ()  -- the total\n",
  '-- the total')

m('the balance is carried backwards from the last day',
  'assert_client_funds',
  "                   sum(sum(t.amount)) over (order by t.transaction_date)\n",
  "                   sum(sum(t.amount)) over (order by t.transaction_date desc)  -- backwards\n",
  '-- backwards')

m('a day closing on nought is refused too',
  'assert_client_funds',
  "     where d.running < 0\n",
  "     where d.running <= 0  -- nought short\n",
  '-- nought short')

m('a voided row still counts',
  'assert_client_funds',
  "             where t.matter_id = v_matter\n               and t.status <> 'void'\n",
  "             where t.matter_id = v_matter  -- voids count\n",
  '-- voids count')

m('only the matter a row joins is checked',
  'assert_client_funds',
  "      from unnest(array[new.matter_id, old.matter_id]) as m\n",
  "      from unnest(array[coalesce(new.matter_id, old.matter_id)]) as m  -- joined only\n",
  '-- joined only')

m('the last short day is named, not the first',
  'assert_client_funds',
  "     order by d.transaction_date\n     limit 1;\n",
  "     order by d.transaction_date desc  -- last day\n     limit 1;\n",
  '-- last day')

m('the deepest short day is named, not the first',
  'assert_client_funds',
  "     order by d.transaction_date\n     limit 1;\n",
  "     order by d.running  -- deepest day\n     limit 1;\n",
  '-- deepest day')

m('nothing is refused',
  'assert_client_funds',
  "    if found then\n",
  "    if false then  -- never\n",
  '-- never')

m('CONTROL: a comment inside the function',
  'assert_client_funds',
  "    -- The first day the matter's client ledger closes in debit, if any.\n",
  "    -- The first day the matter's client ledger closes in debit, if any.\n    -- control\n",
  '-- control')
