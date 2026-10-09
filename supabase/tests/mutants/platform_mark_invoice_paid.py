# Mutants for public.platform_mark_invoice_paid (0491) -- a platform
# invoice marked paid by hand: by a platform administrator, only from
# `issued`, with when and the note, and the customer told.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0491_the_rest_of_the_conversation_about_money.sql \
#       supabase/tests/platform_console.sql \
#       supabase/tests/mutants/platform_mark_invoice_paid.py
#
# RESULT: 6 mutants and a control, all killed: five by
# `platform_console.sql`, and "the customer is not told" by
# `module_subscription.sql`, which counts the mail. Nothing added.

m("anybody marks an invoice paid",
  "platform_mark_invoice_paid",
  "  if not app.is_platform_admin() then",
  "  if false then  -- anybody",
  "-- anybody")

m("a void or paid invoice is marked paid",
  "platform_mark_invoice_paid",
  "   where id = p_invoice_id and status = 'issued';",
  "   where id = p_invoice_id;  -- any status",
  "-- any status")

m("the invoice is not marked paid",
  "platform_mark_invoice_paid",
  "     set status = 'paid', paid_at = now(), paid_note = p_note",
  "     set paid_at = now(), paid_note = p_note  -- still issued",
  "-- still issued")

m("when it was paid is not recorded",
  "platform_mark_invoice_paid",
  "     set status = 'paid', paid_at = now(), paid_note = p_note",
  "     set status = 'paid', paid_at = null, paid_note = p_note  -- no when",
  "-- no when")

m("the note is not kept",
  "platform_mark_invoice_paid",
  "     set status = 'paid', paid_at = now(), paid_note = p_note",
  "     set status = 'paid', paid_at = now(), paid_note = null  -- no note",
  "-- no note")

m("the customer is not told",
  "platform_mark_invoice_paid",
  "    perform app.queue_platform_payment_received(p_invoice_id);",
  "    perform 1;  -- not told",
  "-- not told")

m("CONTROL: a comment inside the block",
  "platform_mark_invoice_paid",
  "  if not app.is_platform_admin() then",
  "  if not app.is_platform_admin() then  -- (control)",
  "(control)")
