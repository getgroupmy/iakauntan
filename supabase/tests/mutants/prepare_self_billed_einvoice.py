# Mutants for public.prepare_self_billed_einvoice (0636) -- the buyer's
# own e-Invoice for a supplier who does not issue one, queued for
# MyInvois: the document must exist and the caller write; e-Invoice on,
# the company's TIN set, the document posted and marked as owing one;
# bill / purchase credit note / purchase debit note are 11 / 12 / 13 and
# nothing else is one; the supplier's TIN must be a number (a general
# TIN like EI00000000020 is; N/A, NIL, a dash are not); one already
# queued, submitted or valid is not prepared again. The SUPPLIER block
# is the supplier, the BUYER block is us -- the e-Invoice TIN before the
# plain one; every charge no line carries is in total_charges; lines
# fall back to classification 022 and tax type 06; the document points
# at what was prepared.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0636_the_code_the_customs_officer_reads.sql \
#       supabase/tests/self_billed_einvoice.sql \
#       supabase/tests/mutants/prepare_self_billed_einvoice.py
#
# then the survivors against `tariff_code.sql`.
#
# RESULT: 25 mutants and a control, all killed -- 24 by
# `self_billed_einvoice.sql`, the tariff code by `tariff_code.sql`; ten
# before the rule-by-rule block. Every self-billed document had been a
# BILL, from a company whose e-Invoice TIN was its plain TIN, with no
# shipping, one item line, an item without a classification of its
# own, prepared once; so the 12 / 13 codes, a purchase order filed as a
# bill, the buyer TIN, the shipping, a heading line, a retry's totals
# and errors, and the four refusals before the type were all unasked.
# The '022' fallback needs a line with NO item: `items.classification_code`
# is NOT NULL and defaults to '022', so an item line never reaches it.

m("a document that does not exist is not said so",
  "prepare_self_billed_einvoice",
  "  if not found then\n    raise exception 'Purchase document % not found'",
  "  if false then  -- no such document\n    raise exception 'Purchase document % not found'",
  "-- no such document")

m("anybody prepares one",
  "prepare_self_billed_einvoice",
  "  if not app.can_write(v_doc.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a company without e-Invoice prepares one",
  "prepare_self_billed_einvoice",
  "  if not v_org.einvoice_enabled then",
  "  if false then  -- e-Invoice off",
  "-- e-Invoice off")

m("a company with no TIN prepares one",
  "prepare_self_billed_einvoice",
  "  if coalesce(v_org.einvoice_tin, v_org.tin) is null then",
  "  if false then  -- no TIN needed",
  "-- no TIN needed")

m("a draft is prepared",
  "prepare_self_billed_einvoice",
  "  if v_doc.status = 'draft' then",
  "  if false then  -- drafts too",
  "-- drafts too")

m("a document not owing one is prepared",
  "prepare_self_billed_einvoice",
  "  if not v_doc.requires_self_billed then",
  "  if false then  -- owed or not",
  "-- owed or not")

m("a purchase credit note is filed as a debit note",
  "prepare_self_billed_einvoice",
  "    when 'purchase_credit_note' then '12'",
  "    when 'purchase_credit_note' then '13'  -- credit as debit",
  "-- credit as debit")

m("a purchase debit note is filed as a credit note",
  "prepare_self_billed_einvoice",
  "    when 'purchase_debit_note'  then '13'",
  "    when 'purchase_debit_note'  then '12'  -- debit as credit",
  "-- debit as credit")

m("a kind of document that is not one is prepared as a bill",
  "prepare_self_billed_einvoice",
  "    else null\n  end;\n  if v_type is null then\n    raise exception 'A % is not a self-billed e-Invoice document'",
  "    else '11'  -- anything is a bill\n  end;\n  if v_type is null then\n    raise exception 'A % is not a self-billed e-Invoice document'",
  "-- anything is a bill")

m("a placeholder TIN is taken for a number",
  "prepare_self_billed_einvoice",
  "     or v_supplier.tin !~ '[1-9]' then",
  "     or false then  -- placeholders pass",
  "-- placeholders pass")

m("a supplier with no TIN is filed",
  "prepare_self_billed_einvoice",
  "  if coalesce(nullif(btrim(v_supplier.tin), ''), '') = ''\n     or v_supplier.tin !~ '[1-9]' then",
  "  if v_supplier.tin !~ '[1-9]' then  -- blank passes\n",
  "-- blank passes")

m("one already queued is prepared again",
  "prepare_self_billed_einvoice",
  "  if found and v_existing.status in ('valid', 'submitted', 'queued') then",
  "  if found and v_existing.status in ('valid', 'submitted') then  -- queued again",
  "-- queued again")

m("one already valid is prepared again",
  "prepare_self_billed_einvoice",
  "  if found and v_existing.status in ('valid', 'submitted', 'queued') then",
  "  if false then  -- valid again",
  "-- valid again")

m("the supplier's trading name is filed over its legal name",
  "prepare_self_billed_einvoice",
  "    coalesce(v_supplier.legal_name, v_supplier.name),",
  "    v_supplier.name,  -- trading name",
  "-- trading name")

m("the buyer is filed under its plain TIN over its e-Invoice one",
  "prepare_self_billed_einvoice",
  "    coalesce(v_org.einvoice_tin, v_org.tin),\n    coalesce(v_org.einvoice_id_type, 'BRN'),",
  "    coalesce(v_org.tin, v_org.einvoice_tin),  -- plain TIN first\n    coalesce(v_org.einvoice_id_type, 'BRN'),",
  "-- plain TIN first")

m("the buyer block is filed with the supplier's TIN",
  "prepare_self_billed_einvoice",
  "    coalesce(v_org.einvoice_tin, v_org.tin),\n    coalesce(v_org.einvoice_id_type, 'BRN'),",
  "    v_supplier.tin,  -- supplier as buyer\n    coalesce(v_org.einvoice_id_type, 'BRN'),",
  "-- supplier as buyer")

m("shipping is left out of the charges",
  "prepare_self_billed_einvoice",
  "    coalesce(v_doc.shipping_amount, 0),\n    v_doc.rounding_amount, v_doc.total_amount,",
  "    0,  -- no charges\n    v_doc.rounding_amount, v_doc.total_amount,",
  "-- no charges")

m("a retry keeps the old totals",
  "prepare_self_billed_einvoice",
  "        payable_amount = excluded.payable_amount,",
  "        payable_amount = einvoice_documents.payable_amount,  -- old total",
  "-- old total")

m("a retry keeps the old errors",
  "prepare_self_billed_einvoice",
  "        validation_errors = '[]'::jsonb,",
  "        validation_errors = einvoice_documents.validation_errors,  -- old errors",
  "-- old errors")

m("a line with no classification has none",
  "prepare_self_billed_einvoice",
  "         coalesce(l.classification_code, i.classification_code, '022'),",
  "         coalesce(l.classification_code, i.classification_code),  -- no fallback",
  "-- no fallback")

m("an item's own classification is ignored",
  "prepare_self_billed_einvoice",
  "         coalesce(l.classification_code, i.classification_code, '022'),",
  "         coalesce(l.classification_code, '022'),  -- item ignored",
  "-- item ignored")

m("a line with no tax code has no tax type",
  "prepare_self_billed_einvoice",
  "         coalesce(t.tax_type_code, '06'), l.tax_rate, l.tax_amount,",
  "         t.tax_type_code, l.tax_rate, l.tax_amount,  -- no tax type",
  "-- no tax type")

m("the tariff code is left off the line",
  "prepare_self_billed_einvoice",
  "         i.tariff_code, i.country_of_origin",
  "         null, i.country_of_origin  -- no tariff",
  "-- no tariff")

m("a heading line is filed as an item",
  "prepare_self_billed_einvoice",
  "     and l.line_type = 'item'",
  "     and true  -- every line",
  "-- every line")

m("the bill does not point at what was prepared",
  "prepare_self_billed_einvoice",
  "     set einvoice_id = v_ei_id, einvoice_status = 'pending'",
  "     set einvoice_status = 'pending'  -- no link",
  "-- no link")

m("CONTROL: a comment inside the block",
  "prepare_self_billed_einvoice",
  "  if v_doc.status = 'draft' then",
  "  if v_doc.status = 'draft' then  -- (control)",
  "(control)")
