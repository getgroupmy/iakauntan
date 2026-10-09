# Mutants for public.request_einvoice_for_sale (0402) -- a counter sale's
# own e-Invoice, raised in a named buyer's name: only for a completed
# sale not already consolidated, only to a customer of this company with
# a TIN, moving the receivable's contact and nothing else.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0402_the_invoice_that_could_be_posted_twice.sql \
#       supabase/tests/pos.sql \
#       supabase/tests/mutants/request_einvoice_for_sale.py
#
# RESULT: 8 of 9 killed by `pos.sql`, control surviving, and the ninth
# EQUIVALENT for every invoice the product posts: "every line of the
# journal is given the buyer" changes nothing, because
# `post_sales_document_internal` stamps the document's contact on the
# receivable AND the revenue lines, so "the lines that carried the old
# contact" is every line. Five were killed only after the rule-by-rule
# lines added to `pos.sql`: a missing sale, an open one, another
# company's customer, somebody outside the company, and the sale itself
# naming the buyer. NOT a viewer for the permission: `0501` keeps naming
# the buyer on the module bar on purpose, and `module_access` gives a
# member with no access type 'write' whatever their role -- a viewer
# passes this guard by design and is then stopped by `prepare_einvoice`
# asking `can_write`. That leaves 0501's stated intent ("naming the
# buyer is part of the sale", for a cashier who is not a writer)
# unreachable in practice; recorded in the handoff, not raised.

m("a sale that does not exist is not said so",
  "request_einvoice_for_sale",
  "  if v_sale.id is null then",
  "  if false then  -- no such sale",
  "-- no such sale")

m("anybody names the buyer",
  "request_einvoice_for_sale",
  "  if not app.can_write_module(v_sale.org_id, 'pos') then",
  "  if false then  -- anybody",
  "-- anybody")

m("a sale still open is given an e-Invoice",
  "request_einvoice_for_sale",
  "  if v_sale.status <> 'completed' or v_sale.invoice_id is null then",
  "  if false then  -- open sale",
  "-- open sale")

m("a sale already consolidated is given its own as well",
  "request_einvoice_for_sale",
  "  if exists (select 1 from public.einvoice_consolidation_items ci",
  "  if false and exists (select 1 from public.einvoice_consolidation_items ci  -- twice",
  "-- twice")

m("another company's customer is named",
  "request_einvoice_for_sale",
  "   where c.id = p_contact and c.org_id = v_sale.org_id;",
  "   where c.id = p_contact;  -- any company",
  "-- any company")

m("a buyer with no TIN is named",
  "request_einvoice_for_sale",
  "  if v_tin is null then",
  "  if false then  -- no tin",
  "-- no tin")

m("the receivable stays filed under the walk-in",
  "request_einvoice_for_sale",
  "       set contact_id = p_contact\n     where l.entry_id = v_gl",
  "       set contact_id = l.contact_id  -- receivable unmoved\n     where l.entry_id = v_gl",
  "-- receivable unmoved")

m("every line of the journal is given the buyer",
  "request_einvoice_for_sale",
  "       and l.contact_id is not distinct from v_old;",
  "       ;  -- every line",
  "-- every line")

m("the sale itself does not name the buyer",
  "request_einvoice_for_sale",
  "  update public.pos_sales\n     set contact_id = p_contact",
  "  update public.pos_sales\n     set contact_id = contact_id  -- sale unnamed",
  "-- sale unnamed")

m("CONTROL: a comment inside the block",
  "request_einvoice_for_sale",
  "  if v_tin is null then",
  "  if v_tin is null then  -- (control)",
  "(control)")
