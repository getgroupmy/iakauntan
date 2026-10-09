# Mutants for public.rollback_import_batch (0610) -- a failed or
# rehearsed import taken back out: the batch must exist; only an
# administrator; never one posted to the ledger (that is reversed with
# a journal), never one already rolled back; its rows deleted from the
# target tables in REVERSE order, so what depends on a row goes before
# it; ONLY this batch's rows; each table reported with what went and
# what stayed; the staging rows cleared and the batch marked rolled
# back; a row something newer points at refused in words.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0610_where_every_imported_row_came_from.sql \
#       supabase/tests/import_provenance.sql \
#       supabase/tests/mutants/rollback_import_batch.py
#
# RESULT: 10 mutants and a control. 9 killed by `import_provenance.sql`,
# four before its rule-by-rule block: the file rolled back one batch of
# a customer and an item, in a company with no other batch, as its
# owner -- so deleting every import's rows, deleting parents before
# their children, letting anybody do it or mis-answering a batch that
# does not exist all passed, and the refusal for a row something newer
# points at was never reached.
#
# One is EQUIVALENT: "a table with rows kept is not reported". Nothing
# in the schema skips a delete silently -- every guard raises -- so once
# the delete has run no row of the batch is left, `v_left` is always 0,
# and `v_gone > 0 or v_left > 0` is `v_gone > 0`.

m("a batch that does not exist is not said so",
  "rollback_import_batch",
  "  if v_batch.id is null then\n    raise exception 'No such import batch'",
  "  if false then  -- no such batch\n    raise exception 'No such import batch'",
  "-- no such batch")

m("anybody rolls an import back",
  "rollback_import_batch",
  "  if not app.can_admin(v_batch.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a posted import is deleted",
  "rollback_import_batch",
  "  if v_batch.status = 'posted' then",
  "  if false then  -- posted too",
  "-- posted too")

m("an import is rolled back twice",
  "rollback_import_batch",
  "  if v_batch.status = 'rolled_back' then",
  "  if false then  -- twice",
  "-- twice")

m("parents go before what depends on them",
  "rollback_import_batch",
  "  for v_i in reverse array_length(v_tables, 1) .. 1 loop",
  "  for v_i in 1 .. array_length(v_tables, 1) loop  -- forwards",
  "-- forwards")

m("every import's rows go, not just this one's",
  "rollback_import_batch",
  "      'delete from public.%I d where d.import_batch_id = $1",
  "      'delete from public.%I d where d.import_batch_id is not null and $1 is not null  -- every batch",
  "-- every batch")

m("a table with rows kept is not reported",
  "rollback_import_batch",
  "    if v_gone > 0 or v_left > 0 then",
  "    if v_gone > 0 then  -- kept unreported",
  "-- kept unreported")

m("the staging rows are left",
  "rollback_import_batch",
  "  delete from public.import_rows where batch_id = p_batch_id;",
  "  perform 1;  -- staging left",
  "-- staging left")

m("the batch is not marked rolled back",
  "rollback_import_batch",
  "     set status = 'rolled_back', finished_at = now()",
  "     set finished_at = now()  -- status kept",
  "-- status kept")

m("a row something newer points at fails in the database's words",
  "rollback_import_batch",
  "  when foreign_key_violation then\n    raise exception 'Part of this import cannot be removed",
  "  when sqlstate 'XX999' then  -- raw message\n    raise exception 'Part of this import cannot be removed",
  "-- raw message")

m("CONTROL: a comment inside the block",
  "rollback_import_batch",
  "  if v_batch.status = 'rolled_back' then",
  "  if v_batch.status = 'rolled_back' then  -- (control)",
  "(control)")
