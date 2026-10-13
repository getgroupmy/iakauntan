# Mutants for 0849 -- app.a_billed_document_stays keeps a received
# e-invoice while a bill built from it still exists.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0849_what_a_supplier_sent_stays_whole.sql \
#       supabase/tests/received_einvoice_kept.sql \
#       supabase/tests/mutants/a_billed_document_stays.py
#
# RESULT: 6 of 7 killed, the control surviving. The survivor, "a
# statement one trigger down is a client too", is equivalent: what
# deletes a document from inside a trigger is a foreign key's cascade,
# which runs as the table's owner -- the test says so beside its owner
# assertion.
#
# The migration's other half -- a client's delete on the LINES revoked,
# and their delete policy dropped -- is not a function and has no
# mutant here. It was swept by hand: delete granted back and the policy
# restored, "a line of what a supplier sent is not deleted on its own"
# fails; with neither restored, the file passes.

m('nobody is asked',
  'a_billed_document_stays',
  "  if current_user not in ('authenticated', 'anon')\n     or pg_trigger_depth() > 1 then",
  '  if true then  -- nobody asked',
  '-- nobody asked')

m('a statement one trigger down is a client too',
  'a_billed_document_stays',
  '     or pg_trigger_depth() > 1 then',
  '     or false then  -- any depth',
  '-- any depth')

m('a billed document goes like any other',
  'a_billed_document_stays',
  '  if old.bill_id is not null then',
  '  if false then  -- billed free',
  '-- billed free')

m('every document stays',
  'a_billed_document_stays',
  '  if old.bill_id is not null then',
  '  if true then  -- all kept',
  '-- all kept')

m('billed once is billed for good',
  'a_billed_document_stays',
  '  if old.bill_id is not null then',
  "  if old.status = 'billed' then  -- status not bill",
  '-- status not bill')

m('a document the guard lets go is kept anyway',
  'a_billed_document_stays',
  '  return old;\nend $$;',
  '  return null;  -- delete skipped\nend $$;',
  '-- delete skipped')

m('a statement the guard does not ask about is skipped',
  'a_billed_document_stays',
  '     or pg_trigger_depth() > 1 then\n    return old;',
  '     or pg_trigger_depth() > 1 then\n    return null;  -- unasked skipped',
  '-- unasked skipped')

m('CONTROL: a comment inside a_billed_document_stays',
  'a_billed_document_stays',
  '  return old;\nend $$;',
  '  return old;  -- (control)\nend $$;',
  '(control)')
