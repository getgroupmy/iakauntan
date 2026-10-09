# Mutants for app.document_state_is_the_databases (0781) -- a client's
# own statement (role authenticated or anon, top trigger depth) may not
# write a sales or purchase document's status, paid amount or balance,
# nor insert anything but a draft with nothing paid; definer functions
# and writes from inside another trigger (`app.apply_allocation`, the
# line recalculation) pass.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0781_a_documents_state_is_the_databases.sql \
#       supabase/tests/posted_document_is_frozen.sql \
#       supabase/tests/mutants/document_state_is_the_databases.py
#
# RESULT: 10 mutants and a control, all killed by
# `posted_document_is_frozen.sql`. The two depth mutants are killed by
# the payment control: a receipt allocated by the client reaches the
# invoice through `app.apply_allocation` one trigger down, and a guard
# that asked nothing about depth refused it.

m("a signed-in client passes",
  "document_state_is_the_databases",
  "  if current_user not in ('authenticated', 'anon')",
  "  if current_user not in ('anon')  -- clients pass",
  "-- clients pass")

m("a write from inside another trigger is refused",
  "document_state_is_the_databases",
  "     or pg_trigger_depth() > 1 then",
  "     or false then  -- depth ignored",
  "-- depth ignored")

m("only a write two triggers deep passes",
  "document_state_is_the_databases",
  "     or pg_trigger_depth() > 1 then",
  "     or pg_trigger_depth() > 2 then  -- deeper",
  "-- deeper")

m("a client makes a document in any status",
  "document_state_is_the_databases",
  "    if new.status is distinct from 'draft'\n",
  "    if false  -- any status\n",
  "-- any status")

m("a client makes a document already paid",
  "document_state_is_the_databases",
  "       or coalesce(new.paid_amount, 0) <> 0 then",
  "       then  -- paid allowed",
  "-- paid allowed")

m("an insert is asked the update's question",
  "document_state_is_the_databases",
  "  if tg_op = 'INSERT' then",
  "  if false then  -- no insert rule",
  "-- no insert rule")

m("the status is the client's to write",
  "document_state_is_the_databases",
  "  foreach v_col in array array['status', 'paid_amount', 'balance_amount'] loop",
  "  foreach v_col in array array['paid_amount', 'balance_amount'] loop  -- status open",
  "-- status open")

m("what was paid is the client's to write",
  "document_state_is_the_databases",
  "  foreach v_col in array array['status', 'paid_amount', 'balance_amount'] loop",
  "  foreach v_col in array array['status', 'balance_amount'] loop  -- paid open",
  "-- paid open")

m("the balance is the client's to write",
  "document_state_is_the_databases",
  "  foreach v_col in array array['status', 'paid_amount', 'balance_amount'] loop",
  "  foreach v_col in array array['status', 'paid_amount'] loop  -- balance open",
  "-- balance open")

m("refused for want of a privilege nobody named",
  "document_state_is_the_databases",
  "        using errcode = '42501';\n    end if;\n  end loop;",
  "        using errcode = '23514';  -- another code\n    end if;\n  end loop;",
  "-- another code")

m("CONTROL: a comment inside the block",
  "document_state_is_the_databases",
  "  if tg_op = 'INSERT' then",
  "  if tg_op = 'INSERT' then  -- (control)",
  "(control)")
