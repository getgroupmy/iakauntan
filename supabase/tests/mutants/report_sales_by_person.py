# Mutants for public.report_sales_by_person (0750, after 0739) -- what each
# salesperson sold, what was credited back, and the commission on the
# difference, plus the line of sales nobody was credited with.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0750_what_earns_when_it_renews_and_who_is_trading.sql \
#       supabase/tests/salespeople.sql \
#       supabase/tests/mutants/report_sales_by_person.py
#
# RESULT, against 0750: 19 mutants and a control. 18 killed, 1
# equivalent.
#
#   Against 0739 the first sweep killed 7 of 17: every fixture was in
#   ringgit at rate one, with no refund note, nothing before the period,
#   one company, and salespeople whose alphabetical order was also their
#   sales order. "report_sales_by_person, rule by rule" killed nine more.
#
#   The seventeenth, "a quotation is counted as a document", survived
#   because the only posted document the type filter turned away was a
#   DEBIT NOTE -- which posts revenue. Asked (docs/handoff.md item 15),
#   answered "count them", built in 0750, and "A debit note is a sale"
#   asserts it, including that the report foots to the ledger's revenue.
#   Both 0750 mutants -- the debit note left out of `invoiced`, and
#   0739's type list put back -- are killed by it.
#
#   EQUIVALENT by the writer, now: "a quotation is counted as a
#   document". `post_sales_document_internal` posts four types --
#   invoice, debit note, credit note, refund note -- and refuses the
#   rest ("does not post to the ledger"), and all four are in the list,
#   so `status = 'posted'` has already turned away everything the type
#   filter could.

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
  "       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')\n     group by",
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

# 0750 -- a debit note is invoiced.
m("a debit note is not invoiced",
  "report_sales_by_person",
  "           sum(case when d.doc_type in ('invoice', 'debit_note')",
  "           sum(case when d.doc_type in ('invoice')  -- no debit note",
  "-- no debit note")

m("a debit note is not read at all",
  "report_sales_by_person",
  "       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')",
  "       and d.doc_type in ('invoice', 'credit_note', 'refund_note')  -- 0739's list",
  "-- 0739's list")

m("CONTROL: a comment inside the block",
  "report_sales_by_person",
  "  -- see the sales nobody was credited with, because that is the number",
  "  -- CONTROL\n  -- see the sales nobody was credited with, because that is the number",
  "-- CONTROL")
