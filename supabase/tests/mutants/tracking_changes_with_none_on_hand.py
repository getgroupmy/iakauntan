# Mutants for 0916 -- how an item is tracked (none, batch, serial)
# changes only with nothing on hand and no batch holding a balance.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0916_how_an_item_is_tracked_changes_with_none_on_hand.sql \
#       supabase/tests/tracking_changes_with_none_on_hand.sql \
#       supabase/tests/mutants/tracking_changes_with_none_on_hand.py

F = 'tracking_changes_with_none_on_hand'

m('only the app is asked',
  F,
  "  if new.tracking is not distinct from old.tracking then\n",
  "  if current_setting('role') not in ('authenticated', 'anon') then return new; end if;  -- app only\n"
  "  if new.tracking is not distinct from old.tracking then\n",
  '-- app only')

m('every write is asked, not only a change',
  F,
  "  if new.tracking is not distinct from old.tracking then\n",
  "  if false then  -- every write\n",
  '-- every write')

m('turning tracking on is not asked',
  F,
  "  if new.tracking is not distinct from old.tracking then\n",
  "  if new.tracking is not distinct from old.tracking or old.tracking = 'none' then  -- on is free\n",
  '-- on is free')

m('turning tracking off is not asked',
  F,
  "  if new.tracking is not distinct from old.tracking then\n",
  "  if new.tracking is not distinct from old.tracking or new.tracking = 'none' then  -- off is free\n",
  '-- off is free')

m('batch to serial is not asked',
  F,
  "  if new.tracking is not distinct from old.tracking then\n",
  "  if new.tracking is not distinct from old.tracking\n"
  "     or (old.tracking <> 'none' and new.tracking <> 'none') then  -- kinds free\n",
  '-- kinds free')

m('stock on hand does not matter',
  F,
  "  if v_held is not null then\n",
  "  if false then  -- stock free\n",
  '-- stock free')

m('a batch with a balance does not matter',
  F,
  "  if v_lots is not null then\n",
  "  if false then  -- batches free\n",
  '-- batches free')

m('stock is counted across warehouses, not in each',
  F,
  "          having sum(m.quantity) <> 0) s\n",
  "          having (select sum(quantity) from public.stock_movements\n"
  "                   where item_id = old.id) <> 0) s  -- every warehouse\n",
  '-- every warehouse')

m('CONTROL: a comment inside the function',
  F,
  "  end if;\n  return new;\nend;",
  "  end if;\n  return new;  -- control\nend;",
  '-- control')
