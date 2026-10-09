# Mutants for public.allocate_credit_note (0629) -- a posted credit note
# knocked off a posted invoice or debit note of the same company: by
# somebody who may post, never a draft or a void on either side, never
# for nothing. The ceilings are `app.apply_allocation`'s.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0629_the_credit_note_nobody_could_knock_off.sql \
#       supabase/tests/credit_note_allocation.sql \
#       supabase/tests/mutants/allocate_credit_note.py
#
# RESULT: 13 mutants and a control, all killed by
# `credit_note_allocation.sql`. Eight only after its rule-by-rule block:
# a missing or deleted credit note, a void one, a missing, foreign or
# deleted invoice, a draft or void one, and a debit note taking one.
# `knock_off.sql` kills none of the eight. The customer is not checked
# here because `app.apply_allocation` refuses two different customers
# for every writer.

m("a credit note that does not exist is not said so",
  "allocate_credit_note",
  "  if v_cn.id is null or v_cn.deleted_at is not null then",
  "  if false then  -- no such note",
  "-- no such note")

m("a deleted credit note is allocated",
  "allocate_credit_note",
  "  if v_cn.id is null or v_cn.deleted_at is not null then",
  "  if v_cn.id is null then  -- deleted",
  "-- deleted")

m("anybody allocates a credit note",
  "allocate_credit_note",
  "  if not app.can_post(v_cn.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an invoice is allocated as if it were a credit note",
  "allocate_credit_note",
  "  if v_cn.doc_type <> 'credit_note' then",
  "  if false then  -- any type",
  "-- any type")

m("a draft credit note is allocated",
  "allocate_credit_note",
  "  if v_cn.gl_entry_id is null or v_cn.status = 'void' then",
  "  if v_cn.status = 'void' then  -- draft note",
  "-- draft note")

m("a void credit note is allocated",
  "allocate_credit_note",
  "  if v_cn.gl_entry_id is null or v_cn.status = 'void' then",
  "  if v_cn.gl_entry_id is null then  -- void note",
  "-- void note")

m("an invoice that does not exist is not said so",
  "allocate_credit_note",
  "  if v_inv.id is null or v_inv.org_id <> v_cn.org_id\n     or v_inv.deleted_at is not null then",
  "  if v_inv.id is null  -- no such invoice\n     or v_inv.deleted_at is not null then",
  "-- no such invoice")

m("a deleted invoice is allocated against",
  "allocate_credit_note",
  "     or v_inv.deleted_at is not null then\n    raise exception 'No such invoice.'",
  "     or false then  -- deleted inv\n    raise exception 'No such invoice.'",
  "-- deleted inv")

m("a credit note is set against a quotation",
  "allocate_credit_note",
  "  if v_inv.doc_type not in ('invoice', 'debit_note') then",
  "  if false then  -- any document",
  "-- any document")

m("a credit note is not set against a debit note",
  "allocate_credit_note",
  "  if v_inv.doc_type not in ('invoice', 'debit_note') then",
  "  if v_inv.doc_type not in ('invoice') then  -- no debit note",
  "-- no debit note")

m("a draft invoice is allocated against",
  "allocate_credit_note",
  "  if v_inv.gl_entry_id is null or v_inv.status = 'void' then",
  "  if v_inv.status = 'void' then  -- draft invoice",
  "-- draft invoice")

m("a void invoice is allocated against",
  "allocate_credit_note",
  "  if v_inv.gl_entry_id is null or v_inv.status = 'void' then",
  "  if v_inv.gl_entry_id is null then  -- void invoice",
  "-- void invoice")

m("an allocation of nothing is recorded",
  "allocate_credit_note",
  "  if coalesce(p_amount, 0) <= 0 then",
  "  if false then  -- nothing",
  "-- nothing")

m("CONTROL: a comment inside the block",
  "allocate_credit_note",
  "  if coalesce(p_amount, 0) <= 0 then",
  "  if coalesce(p_amount, 0) <= 0 then  -- (control)",
  "(control)")
