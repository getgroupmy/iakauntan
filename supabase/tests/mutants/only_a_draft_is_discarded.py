# Mutants for app.a_draft_is_what_is_discarded (0802) -- on sales and
# purchase documents, a client's own statement discards (sets
# deleted_at on) only a draft; a discarded draft can be brought back;
# the database's own functions pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0802_only_a_draft_is_discarded.sql \
#       supabase/tests/document_discard.sql \
#       supabase/tests/mutants/only_a_draft_is_discarded.py
#
# RESULT: 6 mutants and a control, all 6 killed by
# `document_discard.sql`, new in `0802`, two only after its owner block:
# the database discarding a quotation past draft, and a client bringing
# it back. SECURITY DEFINER flipped by hand: the file fails on its first
# refusal ("it was not refused at all"); restored, it passes.

F = "a_draft_is_what_is_discarded"

m("the client role is not asked", F,
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  "  if true then  -- nobody asked",
  "-- nobody asked")
m("the functions are refused too", F,
  "     or pg_trigger_depth() > 1 then",
  "     and pg_trigger_depth() > 1 then  -- owner asked",
  "-- owner asked")
m("a draft is not discarded either", F,
  "     and old.status <> 'draft' then",
  "     and true then  -- nothing discarded",
  "-- nothing discarded")
m("a posted document is discarded", F,
  "     and old.status <> 'draft' then",
  "     and old.status not in ('draft', 'posted') then  -- posted discarded",
  "-- posted discarded")
m("a discarded draft cannot come back", F,
  "  if new.deleted_at is not null\n     and old.deleted_at is null\n",
  "  if new.deleted_at is distinct from old.deleted_at  -- no return\n",
  "-- no return")
m("the refusal does not name the document", F,
  "      'reverses what it posted.', old.doc_no, old.status",
  "      'reverses what it posted.', null, old.status  -- unnamed",
  "-- unnamed")

m("CONTROL", F,
  "  return new;\nend $$;",
  "  return new;  -- control\nend $$;",
  "-- control")
