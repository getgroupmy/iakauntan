# Mutants for public.report_sst_summary (0748; first written against
# 0418) -- the SST summary by tax type, output and input, in ringgit:
# sales lines, the service charge read from the header, and purchase
# lines, with credit notes the other way.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0748_the_return_is_made_in_ringgit.sql \
#       supabase/tests/sst_summary.sql \
#       supabase/tests/mutants/report_sst_summary.py
#
# RESULT, 6 October, against 0748: 12 mutants, ALL 12 KILLED, control
# alive, on sst_summary.sql alone. The six currency mutants are what
# `0748` fixed and are killed by its "The return is made in ringgit"
# block -- each amount at a different rate (4.20, 3.40, 4.50) so that
# the wrong one is a different number. The rest -- credit note signs,
# drafts, the period, the membership tests -- the file already had.

m("a foreign sale's tax is declared in its own currency",
  "report_sst_summary",
  "           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)\n             as tax_amount\n      from public.sales_document_lines l",
  "           round(l.tax_amount, 2)  -- no rate\n             as tax_amount\n      from public.sales_document_lines l",
  "-- no rate")

m("a foreign sale's value is declared in its own currency",
  "report_sst_summary",
  "           round(l.line_subtotal * coalesce(d.exchange_rate, 1), 2)\n             as line_subtotal,\n           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)\n             as tax_amount\n      from public.sales_document_lines l",
  "           round(l.line_subtotal, 2)  -- no rate net\n             as line_subtotal,\n           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)\n             as tax_amount\n      from public.sales_document_lines l",
  "-- no rate net")

m("a foreign service charge is declared in its own currency",
  "report_sst_summary",
  "           round(d.service_charge_amount * coalesce(d.exchange_rate, 1), 2)",
  "           round(d.service_charge_amount, 2)  -- no rate sc",
  "-- no rate sc")

m("a foreign service charge's tax is declared in its own currency",
  "report_sst_summary",
  "           round(d.service_charge_tax * coalesce(d.exchange_rate, 1), 2)",
  "           round(d.service_charge_tax, 2)  -- no rate sc tax",
  "-- no rate sc tax")

m("a foreign bill's tax is claimed in its own currency",
  "report_sst_summary",
  "           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)\n             as tax_amount\n      from public.purchase_document_lines l",
  "           round(l.tax_amount, 2)  -- no rate in\n             as tax_amount\n      from public.purchase_document_lines l",
  "-- no rate in")

m("a foreign bill's value is in its own currency",
  "report_sst_summary",
  "           round(l.line_subtotal * coalesce(d.exchange_rate, 1), 2)\n             as line_subtotal,\n           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)\n             as tax_amount\n      from public.purchase_document_lines l",
  "           round(l.line_subtotal, 2)  -- no rate in net\n             as line_subtotal,\n           round(l.tax_amount * coalesce(d.exchange_rate, 1), 2)\n             as tax_amount\n      from public.purchase_document_lines l",
  "-- no rate in net")

m("a credit note adds to the output tax",
  "report_sst_summary",
  "           case when d.doc_type in ('credit_note', 'refund_note')\n                then -1 else 1 end as sign,\n           -- 0748. In ringgit, which is what the return is made in and",
  "           1 as sign,  -- cn adds\n           -- 0748. In ringgit, which is what the return is made in and",
  "-- cn adds")

m("a purchase credit note adds to the input tax",
  "report_sst_summary",
  "           case when d.doc_type = 'purchase_credit_note'\n                then -1 else 1 end as sign,",
  "           1 as sign,  -- pcn adds",
  "-- pcn adds")

m("a draft invoice is declared",
  "report_sst_summary",
  "     where d.org_id = p_org_id\n       and d.doc_type in ('invoice', 'credit_note', 'debit_note',\n                          'refund_note')\n       and d.status not in ('draft', 'void')\n       and d.doc_date between p_from and p_to\n  ),",
  "     where d.org_id = p_org_id\n       and d.doc_type in ('invoice', 'credit_note', 'debit_note',\n                          'refund_note')\n       and true  -- drafts\n       and d.doc_date between p_from and p_to\n  ),",
  "-- drafts")

m("the period has no end",
  "report_sst_summary",
  "       and d.doc_date between p_from and p_to\n  ),\n  -- The tax a Malaysian restaurant charges on the ten per cent is",
  "       and d.doc_date >= p_from  -- no end\n  ),\n  -- The tax a Malaysian restaurant charges on the ten per cent is",
  "-- no end")

m("a stranger reads the output tax",
  "report_sst_summary",
  "          select * from service_charge) o\n   where app.is_org_member(p_org_id)",
  "          select * from service_charge) o\n   where true  -- stranger out",
  "-- stranger out")

m("a stranger reads the input tax",
  "report_sst_summary",
  "    from purchases p\n   where app.is_org_member(p_org_id)",
  "    from purchases p\n   where true  -- stranger in",
  "-- stranger in")

m("CONTROL: a comment inside the block",
  "report_sst_summary",
  "  purchases as (",
  "  -- CONTROL\n  purchases as (",
  "-- CONTROL")
