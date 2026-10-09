# Mutants for 0770's two functions: `void_sales_document` (an invoice
# voided, its journal reversed, and since 0770 its e-Invoice withdrawn
# or the void refused while LHDN decides) and the guard 0770 added to
# `prepare_einvoice`.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0770_a_voided_sale_is_not_sent_to_lhdn.sql \
#       supabase/tests/einvoice_statutory.sql \
#       supabase/tests/mutants/void_and_einvoice.py
#
# RESULT: 14 mutants and a control. `einvoice_statutory.sql`'s 0770
# block kills ten -- two of them (a deleted invoice, a bystander's
# e-Invoice) only after the first sweep left them alive.
# `void_an_invoice.sql` kills the other four: anybody voiding, a paid
# invoice, one LHDN validated, and the journal not reversed (`reversal.sql`
# also kills that one).

m("a void invoice is prepared for MyInvois",
  "prepare_einvoice",
  "  if v_doc.status = 'void' or v_doc.deleted_at is not null then",
  "  if false then  -- void sent",
  "-- void sent")

m("a deleted invoice is prepared for MyInvois",
  "prepare_einvoice",
  "  if v_doc.status = 'void' or v_doc.deleted_at is not null then",
  "  if v_doc.status = 'void' then  -- deleted sent",
  "-- deleted sent")

m("anybody voids an invoice",
  "void_sales_document",
  "  if not app.can_post(v_doc.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a paid invoice is voided",
  "void_sales_document",
  "  if v_doc.paid_amount > 0 then",
  "  if false then  -- paid",
  "-- paid")

m("an invoice LHDN validated is voided",
  "void_sales_document",
  "  if v_doc.einvoice_status = 'valid' then",
  "  if false then  -- valid",
  "-- valid")

m("an invoice LHDN is deciding is voided",
  "void_sales_document",
  "                and e.status = 'submitted') then",
  "                and false) then  -- deciding",
  "-- deciding")

m("the journal is not reversed",
  "void_sales_document",
  "    perform public.reverse_gl_entry(v_doc.gl_entry_id, app.today());",
  "    perform 1;  -- unreversed",
  "-- unreversed")

m("a queued e-Invoice is left to be sent",
  "void_sales_document",
  "     and e.status in ('draft', 'queued', 'failed', 'invalid');",
  "     and e.status in ('draft', 'failed', 'invalid');  -- queued left",
  "-- queued left")

m("a failed e-Invoice is left to be sent again",
  "void_sales_document",
  "     and e.status in ('draft', 'queued', 'failed', 'invalid');",
  "     and e.status in ('draft', 'queued', 'invalid');  -- failed left",
  "-- failed left")

m("an invalid e-Invoice is left to be sent again",
  "void_sales_document",
  "     and e.status in ('draft', 'queued', 'failed', 'invalid');",
  "     and e.status in ('draft', 'queued', 'failed');  -- invalid left",
  "-- invalid left")

m("the withdrawal does not say why",
  "void_sales_document",
  "           || coalesce(' (' || nullif(btrim(p_reason), '') || ')', '')",
  "           || ''  -- no reason",
  "-- no reason")

m("the withdrawal is not dated",
  "void_sales_document",
  "         cancelled_at = now(),",
  "         cancelled_at = null,  -- undated",
  "-- undated")

m("another invoice's e-Invoice is withdrawn",
  "void_sales_document",
  "     and e.source_id = v_doc.id\n     and e.status in",
  "     and true  -- any invoice\n     and e.status in",
  "-- any invoice")

m("CONTROL: a comment inside the block",
  "void_sales_document",
  "  if v_doc.paid_amount > 0 then",
  "  if v_doc.paid_amount > 0 then  -- (control)",
  "(control)")
