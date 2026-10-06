# Mutants for public.report_sales_by_person (0739) -- what each
# salesperson sold, what was credited back, and the commission on the
# difference, plus the line of sales nobody was credited with.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/salespeople.sql \
#       supabase/tests/mutants/report_sales_by_person.py
#
# RESULT: 17 mutants and a control. 16 killed; 1 is a QUESTION, not an
# equivalent.
#
#   The first sweep killed 7. Every fixture in the file was in ringgit at
#   rate one, with no refund note, nothing before the period, one
#   company, and salespeople whose alphabetical order was also their
#   sales order -- so currency, refunds, the period's start, deletion,
#   the company boundary, the ordering and the stranger were rules no row
#   could tell from their absence. "report_sales_by_person, rule by
#   rule" in salespeople.sql kills nine more.
#
#   SURVIVES, AND IS FOR THE USER: "a quotation is counted as a
#   document". Only four document types can be posted at all
#   (`post_sales_document_internal`: invoice, credit note, debit note,
#   refund note), so the only posted document this filter turns away is
#   a DEBIT NOTE -- and a debit note posts revenue. The file's own
#   assertion says the lines "foot to everything sold ... checkable
#   against the profit and loss"; with a debit note in the period they
#   do not, and nobody is credited with it. Whether a debit note earns
#   commission is a business decision, so it is asked rather than
#   asserted either way. See docs/handoff.md.

m("a stranger reads the commission",
  "report_sales_by_person",
  "  if not app.can_read_ledger(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a foreign invoice is counted in its own currency",
  "report_sales_by_person",
  "                    then d.total_amount * d.exchange_rate else 0 end) as inv,",
  "                    then d.total_amount else 0 end) as inv,  -- own ccy",
  "-- own ccy")

m("a foreign credit note is counted in its own currency",
  "report_sales_by_person",
  "                    then d.total_amount * d.exchange_rate else 0 end) as crd,",
  "                    then d.total_amount else 0 end) as crd,  -- own ccy",
  "-- own ccy")

m("a refund note is not taken off",
  "report_sales_by_person",
  "           sum(case when d.doc_type in ('credit_note', 'refund_note')",
  "           sum(case when d.doc_type in ('credit_note')  -- no refund",
  "-- no refund")

m("a sale before the period is counted",
  "report_sales_by_person",
  "       and d.doc_date between p_from and p_to",
  "       and d.doc_date <= p_to  -- no start",
  "-- no start")

m("a sale after the period is counted",
  "report_sales_by_person",
  "       and d.doc_date between p_from and p_to",
  "       and d.doc_date >= p_from  -- no end",
  "-- no end")

m("a draft is commissioned",
  "report_sales_by_person",
  "       and d.status = 'posted'",
  "       and true  -- any status",
  "-- any status")

m("a deleted invoice is commissioned",
  "report_sales_by_person",
  "       and d.deleted_at is null\n       and d.doc_type in",
  "       and true  -- deleted too\n       and d.doc_type in",
  "-- deleted too")

m("a quotation is counted as a document",
  "report_sales_by_person",
  "       and d.doc_type in ('invoice', 'credit_note', 'refund_note')\n     group by",
  "       and true  -- every type\n     group by",
  "-- every type")

m("credits are added to sales, not taken off",
  "report_sales_by_person",
  "         coalesce(sold.inv, 0) - coalesce(sold.crd, 0),\n         coalesce(sold.docs, 0),\n         s.commission_rate,",
  "         coalesce(sold.inv, 0) + coalesce(sold.crd, 0),  -- plus\n         coalesce(sold.docs, 0),\n         s.commission_rate,",
  "-- plus")

m("commission is paid on gross sales",
  "report_sales_by_person",
  "              else round((coalesce(sold.inv, 0) - coalesce(sold.crd, 0))",
  "              else round((coalesce(sold.inv, 0))  -- gross",
  "-- gross")

m("commission is not divided by a hundred",
  "report_sales_by_person",
  "                         * s.commission_rate / 100, 2) end",
  "                         * s.commission_rate, 2) end  -- percent",
  "-- percent")

m("no rate is commission of nothing",
  "report_sales_by_person",
  "         case when s.commission_rate is null then null",
  "         case when s.commission_rate is null then 0  -- zero",
  "-- zero")

m("another company's salespeople are listed",
  "report_sales_by_person",
  "   where s.org_id = p_org_id\n",
  "   where true  -- every company\n",
  "-- every company")

m("the unattributed sales are dropped",
  "report_sales_by_person",
  "   where sold.person is null",
  "   where false  -- dropped",
  "-- dropped")

m("the unattributed line nets nothing off",
  "report_sales_by_person",
  "         coalesce(sold.inv, 0) - coalesce(sold.crd, 0),\n         coalesce(sold.docs, 0),\n         null::numeric, null::numeric",
  "         coalesce(sold.inv, 0),  -- gross\n         coalesce(sold.docs, 0),\n         null::numeric, null::numeric",
  "-- gross")

m("the biggest seller is not first",
  "report_sales_by_person",
  "   order by 7 desc nulls last, 3;",
  "   order by 3;  -- by name",
  "-- by name")

m("CONTROL: a comment inside the block",
  "report_sales_by_person",
  "  -- see the sales nobody was credited with, because that is the number",
  "  -- CONTROL\n  -- see the sales nobody was credited with, because that is the number",
  "-- CONTROL")
