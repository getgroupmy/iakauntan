# Mutants for 0913 -- a client's document line carries forward a line
# of the document its header was raised from, and nothing else.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0913_a_line_carries_forward_its_parents_line.sql \
#       supabase/tests/a_line_carries_its_parents_line.sql \
#       supabase/tests/mutants/a_line_carries_its_parents_line.py

F = 'a_line_carries_its_parents_line'

m('nobody is asked',
  F,
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if true then  -- nobody\n",
  '-- nobody')

m('the owner is asked too',
  F,
  "  if current_user not in ('authenticated', 'anon') then\n",
  "  if false then  -- everyone\n",
  '-- everyone')

m('a line linked to nothing is asked',
  F,
  "  if new.source_line_id is null then\n",
  "  if false then  -- nulls asked\n",
  '-- nulls asked')

m('an update is not asked',
  F,
  "  if tg_op = 'UPDATE'\n"
  "     and new.source_line_id is not distinct from old.source_line_id\n"
  "     and new.document_id is not distinct from old.document_id then\n",
  "  if tg_op = 'UPDATE' then  -- updates free\n",
  '-- updates free')

m('a line moved to another document is not asked',
  F,
  "     and new.source_line_id is not distinct from old.source_line_id\n"
  "     and new.document_id is not distinct from old.document_id then\n",
  "     and new.source_line_id is not distinct from old.source_line_id then  -- moves free\n",
  '-- moves free')

m('a typed document may carry a line forward',
  F,
  "  if v_parent is null then\n",
  "  if false then  -- typed fine\n",
  '-- typed fine')

m('any line will do on a raised document',
  F,
  "  if v_source_doc is distinct from v_parent then\n",
  "  if false then  -- anywhere\n",
  '-- anywhere')

m('a sales line is looked for among purchases',
  F,
  "  if tg_table_name = 'sales_document_lines' then\n",
  "  if false then  -- one side\n",
  '-- one side')

m('CONTROL: a comment inside the function',
  F,
  "  end if;\n  return new;\nend;",
  "  end if;\n  return new;  -- control\nend;",
  '-- control')
