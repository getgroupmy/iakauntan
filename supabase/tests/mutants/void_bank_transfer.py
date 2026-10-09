# Mutants for public.void_bank_transfer (0504) -- a transfer undone: it
# must exist and not be deleted, the caller must be able to post, and a
# transfer already void says so; a POSTED one has its journal reversed
# on the transfer's own date and both running balances put back --
# the sender by what was sent (fee included) at its rate, the receiver
# by what arrived at its rate; then marked void with the reason added
# under any notes already there, and the reversal handed back.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0504_a_bank_fee_is_inside_the_amount_sent.sql \
#       supabase/tests/bank_transfers.sql \
#       supabase/tests/mutants/void_bank_transfer.py
#
# RESULT: 14 mutants and a control, all killed by `bank_transfers.sql`;
# thirteen by the "Undo Baki" block an earlier, unrecorded sweep left.
# The one survivor was the note: no transfer the file voided had one,
# so a void that wrote its reason OVER the note looked the same as one
# that wrote it underneath.

m("a transfer that does not exist is not said so",
  "void_bank_transfer",
  "  if not found then\n    raise exception 'Transfer % not found'",
  "  if false then  -- no such transfer\n    raise exception 'Transfer % not found'",
  "-- no such transfer")

m("a deleted transfer is voided",
  "void_bank_transfer",
  "  select * into r from public.bank_transfers where id = p_id and deleted_at is null;",
  "  select * into r from public.bank_transfers where id = p_id;  -- deleted too",
  "-- deleted too")

m("anybody voids",
  "void_bank_transfer",
  "  if not app.can_post(r.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a void transfer is voided again",
  "void_bank_transfer",
  "  if r.status = 'void' then",
  "  if false then  -- twice",
  "-- twice")

m("a posted transfer is not reversed",
  "void_bank_transfer",
  "  if r.gl_entry_id is not null then",
  "  if false then  -- ledger left",
  "-- ledger left")

m("the reversal is dated today",
  "void_bank_transfer",
  "    v_reversal := public.reverse_gl_entry(r.gl_entry_id, r.transfer_date);",
  "    v_reversal := public.reverse_gl_entry(r.gl_entry_id, app.today());  -- dated today",
  "-- dated today")

m("what was sent is put back at no rate",
  "void_bank_transfer",
  "    v_sent := round(r.amount_sent * r.from_rate, 2);",
  "    v_sent := round(r.amount_sent, 2);  -- sent unrated",
  "-- sent unrated")

m("what arrived is taken back at no rate",
  "void_bank_transfer",
  "    v_received := round(r.amount_received * r.to_rate, 2);",
  "    v_received := round(r.amount_received, 2);  -- received unrated",
  "-- received unrated")

m("the sending account is left short",
  "void_bank_transfer",
  "       set current_balance = current_balance + v_sent",
  "       set current_balance = current_balance  -- sender short",
  "-- sender short")

m("the receiving account keeps the money",
  "void_bank_transfer",
  "       set current_balance = current_balance - v_received",
  "       set current_balance = current_balance  -- receiver keeps it",
  "-- receiver keeps it")

m("the transfer is not marked void",
  "void_bank_transfer",
  "     set status = 'void',",
  "     set status = status,  -- not void",
  "-- not void")

m("the reason is not kept",
  "void_bank_transfer",
  "                      'Voided: ' || coalesce(p_reason, 'no reason given'))",
  "                      'Voided: ' || 'no reason given')  -- reason lost",
  "-- reason lost")

m("the notes already there are lost",
  "void_bank_transfer",
  "                      coalesce(notes, '') || E'\\n' ||",
  "                      E'\\n' ||  -- old notes lost",
  "-- old notes lost")

m("the reversal is not handed back",
  "void_bank_transfer",
  "  return v_reversal;",
  "  return null;  -- nothing back",
  "-- nothing back")

m("CONTROL: a comment inside the block",
  "void_bank_transfer",
  "  if r.status = 'void' then",
  "  if r.status = 'void' then  -- (control)",
  "(control)")
