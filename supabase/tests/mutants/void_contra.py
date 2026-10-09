# Mutants for public.void_contra (0421) -- a contra note reversed: by
# somebody with write on BOTH sales and purchases, never twice, never
# without a reason, its allocations taken off the invoices and bills it
# settled, its journal reversed today, and the note marked void with
# who, when, why and which entry undid it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0421_what_day_the_money_moved.sql \
#       supabase/tests/contra.sql \
#       supabase/tests/mutants/void_contra.py
#
# RESULT: 14 of 15 killed by `contra.sql`, the control surviving. Six only
# after its rule-by-rule block: the contra that does not exist, the SALES
# half of the permission (lost through an access type, not the module --
# the file had said it could not be asserted), the reason trimmed, the
# reversal dated today rather than on the contra's day (every contra
# before the block was dated today), and who and when.
#
# EQUIVALENT: "dated by reverse_gl_entry's default" -- that default is
# `coalesce(p_date, app.today())`, the same day this passes.

m("a contra that does not exist is not said so",
  "void_contra",
  "  if v_note.id is null then\n    raise exception 'No such contra.'",
  "  if false then  -- no such contra\n    raise exception 'No such contra.'",
  "-- no such contra")

m("anybody reverses a contra",
  "void_contra",
  "  if not app.can_write_module(v_note.org_id, 'sales')\n     or not app.can_write_module(v_note.org_id, 'purchases') then",
  "  if false then  -- anybody",
  "-- anybody")

m("write on sales alone is enough",
  "void_contra",
  "     or not app.can_write_module(v_note.org_id, 'purchases') then",
  "     or false then  -- sales alone",
  "-- sales alone")

m("write on purchases alone is enough",
  "void_contra",
  "  if not app.can_write_module(v_note.org_id, 'sales')\n",
  "  if false  -- purchases alone\n",
  "-- purchases alone")

m("a contra already void is reversed again",
  "void_contra",
  "  if v_note.status = 'void' then",
  "  if false then  -- void twice",
  "-- void twice")

m("a contra is reversed without a reason",
  "void_contra",
  "  if coalesce(trim(p_reason), '') = '' then",
  "  if false then  -- no reason",
  "-- no reason")

m("the reason is kept as typed, spaces and all",
  "void_contra",
  "     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),",
  "     set status = 'void', void_entry_id = v_rev, void_reason = p_reason,  -- untrimmed",
  "-- untrimmed")

m("the invoices and bills it settled keep the settlement",
  "void_contra",
  "  delete from public.payment_allocations where contra_id = p_id;",
  "  perform 1;  -- allocations kept",
  "-- allocations kept")

m("the journal is not reversed",
  "void_contra",
  "    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, app.today());",
  "    v_rev := null;  -- not reversed",
  "-- not reversed")

m("the reversal is dated by reverse_gl_entry's default, not today",
  "void_contra",
  "    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, app.today());",
  "    v_rev := public.reverse_gl_entry(v_note.gl_entry_id);  -- default date",
  "-- default date")

m("the reversal is dated on the contra's own day",
  "void_contra",
  "    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, app.today());",
  "    v_rev := public.reverse_gl_entry(v_note.gl_entry_id, v_note.contra_date);  -- contra date",
  "-- contra date")

m("the note is not marked void",
  "void_contra",
  "     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),",
  "     set void_entry_id = v_rev, void_reason = trim(p_reason),  -- still posted",
  "-- still posted")

m("the reversing entry is not recorded on the note",
  "void_contra",
  "     set status = 'void', void_entry_id = v_rev, void_reason = trim(p_reason),",
  "     set status = 'void', void_entry_id = null, void_reason = trim(p_reason),  -- no entry",
  "-- no entry")

m("who reversed it is not recorded",
  "void_contra",
  "         voided_at = now(), voided_by = auth.uid()",
  "         voided_at = now(), voided_by = null  -- nobody",
  "-- nobody")

m("when it was reversed is not recorded",
  "void_contra",
  "         voided_at = now(), voided_by = auth.uid()",
  "         voided_at = null, voided_by = auth.uid()  -- never",
  "-- never")

m("CONTROL: a comment inside the block",
  "void_contra",
  "  if v_note.status = 'void' then",
  "  if v_note.status = 'void' then  -- (control)",
  "(control)")
