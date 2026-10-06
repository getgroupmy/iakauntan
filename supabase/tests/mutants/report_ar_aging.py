# Mutants for public.report_ar_aging (0747) -- the aged receivables:
# every posted invoice, debit note, credit note, refund note and
# unapplied receipt, less what was allocated by the as-at date, in its
# own currency and in ringgit, with days overdue and a bucket.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0747_the_three_ways_of_being_paid_the_listings_never_saw.sql \
#       supabase/tests/aged_balances.sql \
#       supabase/tests/mutants/report_ar_aging.py
#
# RESULT, 6 October, against 0747: 47 mutants and a control. 41
# KILLED, 6 equivalent, control alive -- across aged_balances.sql and
# aging_shapes.sql, which between them kill every one that can be.
#
# The sweep is what found the defect `0747` fixes. Against 0739 the
# nine files that reach the function left a debit note, a deleted
# invoice, and receipts and credit notes that never reached the ledger
# unasserted; asserting those ("The receivables listing, rule by
# rule") is when the question "what else writes an allocation?" was
# asked, and the answer -- contras, deposits, post-dated cheques -- was
# a listing at 7,000.00 against 1210's 2,200.00.
#
# Equivalent, with the reason:
#   * another company's allocations: `payment_allocations` has a
#     composite foreign key to the document's company (23503). A table
#     constraint.
#   * `coalesce(exchange_rate, 0)`: the column is NOT NULL. A table
#     constraint.
#   * a void contra, a bounced or cancelled cheque, a cheque with no
#     journal, a void deposit: `void_contra`, `bounce_pdc` and
#     `cancel_pdc` DELETE their allocations, `record_pdc` posts whenever
#     it allocates and posts nothing otherwise, and `void_deposit`
#     refuses a deposit that has been applied. The writer.

# -- allocations: both ends in the ledger by the as-at date ------------

m("an allocation made after the as-at date already reduces the balance",
  "report_ar_aging",
  "       and coalesce(r.receipt_date, cn.doc_date, k.contra_date,\n                    case when n.id is not null then a.applied_on end,\n                    q.received_on) <= p_as_at",
  "       and true  -- any date",
  "-- any date")

m("an allocation from an unposted receipt counts",
  "report_ar_aging",
  "      left join public.receipts r on r.id = a.receipt_id\n       and r.gl_entry_id is not null and r.deleted_at is null",
  "      left join public.receipts r on r.id = a.receipt_id\n       and r.deleted_at is null  -- unposted receipt",
  "-- unposted receipt")

m("an allocation from a deleted receipt counts",
  "report_ar_aging",
  "      left join public.receipts r on r.id = a.receipt_id\n       and r.gl_entry_id is not null and r.deleted_at is null",
  "      left join public.receipts r on r.id = a.receipt_id\n       and r.gl_entry_id is not null  -- deleted receipt",
  "-- deleted receipt")

m("an allocation from a void receipt counts",
  "report_ar_aging",
  "       and r.status <> 'void'\n      left join public.sales_documents cn",
  "       and true  -- void receipt\n      left join public.sales_documents cn",
  "-- void receipt")

m("an allocation from a void credit note counts",
  "report_ar_aging",
  "       and cn.gl_entry_id is not null and cn.deleted_at is null\n       and cn.status <> 'void'",
  "       and cn.gl_entry_id is not null and cn.deleted_at is null\n       and true  -- void credit note",
  "-- void credit note")

m("an allocation from an unposted credit note counts",
  "report_ar_aging",
  "       and cn.gl_entry_id is not null and cn.deleted_at is null\n       and cn.status <> 'void'",
  "       and cn.deleted_at is null  -- unposted cn\n       and cn.status <> 'void'",
  "-- unposted cn")

m("another company's allocations count",
  "report_ar_aging",
  "     where a.org_id = p_org_id\n       and coalesce(r.receipt_date, cn.doc_date, k.contra_date,",
  "     where true  -- any org\n       and coalesce(r.receipt_date, cn.doc_date, k.contra_date,",
  "-- any org")

# -- documents -----------------------------------------------------------

m("a credit note ADDS to the receivable",
  "report_ar_aging",
  "           case when d.doc_type in ('credit_note', 'refund_note')\n                then -1 else 1 end",
  "           case when d.doc_type in ('refund_note')  -- cn adds\n                then -1 else 1 end",
  "-- cn adds")

m("a refund note ADDS to the receivable",
  "report_ar_aging",
  "           case when d.doc_type in ('credit_note', 'refund_note')\n                then -1 else 1 end",
  "           case when d.doc_type in ('credit_note')  -- rn adds\n                then -1 else 1 end",
  "-- rn adds")

m("a credit note's used part is not taken off",
  "report_ar_aging",
  "                 coalesce((select sum(al.amount) from allocations al\n                            where al.credit_note_id = d.id), 0)",
  "                 0  -- cn never used",
  "-- cn never used")

m("an invoice's settlement discount is not taken off",
  "report_ar_aging",
  "                 coalesce((select sum(al.amount + al.discount_amount)\n                             from allocations al\n                            where al.invoice_id = d.id), 0)",
  "                 coalesce((select sum(al.amount)  -- no discount\n                             from allocations al\n                            where al.invoice_id = d.id), 0)",
  "-- no discount")

m("a debit note's allocations are not taken off",
  "report_ar_aging",
  "               when d.doc_type in ('invoice', 'debit_note') then",
  "               when d.doc_type in ('invoice') then  -- dn never paid",
  "-- dn never paid")

m("debit notes are left off the listing",
  "report_ar_aging",
  "       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')",
  "       and d.doc_type in ('invoice', 'credit_note', 'refund_note')  -- no dn",
  "-- no dn")

m("refund notes are left off the listing",
  "report_ar_aging",
  "       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')",
  "       and d.doc_type in ('invoice', 'debit_note', 'credit_note')  -- no rn",
  "-- no rn")

m("an unposted invoice is listed",
  "report_ar_aging",
  "       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')\n       and d.gl_entry_id is not null",
  "       and d.doc_type in ('invoice', 'debit_note', 'credit_note', 'refund_note')\n       and true  -- unposted doc",
  "-- unposted doc")

m("a void invoice is listed",
  "report_ar_aging",
  "       and d.gl_entry_id is not null\n       and d.status <> 'void'\n       and d.deleted_at is null\n       and d.doc_date <= p_as_at",
  "       and d.gl_entry_id is not null\n       and true  -- void doc\n       and d.deleted_at is null\n       and d.doc_date <= p_as_at",
  "-- void doc")

m("a deleted invoice is listed",
  "report_ar_aging",
  "       and d.gl_entry_id is not null\n       and d.status <> 'void'\n       and d.deleted_at is null\n       and d.doc_date <= p_as_at",
  "       and d.gl_entry_id is not null\n       and d.status <> 'void'\n       and true  -- deleted doc\n       and d.doc_date <= p_as_at",
  "-- deleted doc")

m("an invoice dated after the as-at date is listed",
  "report_ar_aging",
  "       and d.deleted_at is null\n       and d.doc_date <= p_as_at\n    union all",
  "       and d.deleted_at is null\n       and true  -- future doc\n    union all",
  "-- future doc")

m("another company's documents are listed",
  "report_ar_aging",
  "     where d.org_id = p_org_id",
  "     where true  -- any org doc",
  "-- any org doc")

# -- unapplied receipts --------------------------------------------------

m("unapplied receipts are left off",
  "report_ar_aging",
  "       and r.receipt_date <= p_as_at\n  )",
  "       and r.receipt_date <= p_as_at\n       and false  -- no receipts\n  )",
  "-- no receipts")

m("a receipt shows its full amount, applied or not",
  "report_ar_aging",
  "           -(r.amount - coalesce((select sum(al.amount) from allocations al\n                                   where al.receipt_id = r.id), 0))",
  "           -(r.amount)  -- never applied",
  "-- never applied")

m("a receipt reduces the receivable by a NEGATIVE amount",
  "report_ar_aging",
  "           -(r.amount - coalesce((select sum(al.amount) from allocations al\n                                   where al.receipt_id = r.id), 0))",
  "           (r.amount - coalesce((select sum(al.amount) from allocations al  -- sign\n                                   where al.receipt_id = r.id), 0))",
  "-- sign")

m("an unposted receipt is listed",
  "report_ar_aging",
  "     where r.org_id = p_org_id\n       and r.gl_entry_id is not null",
  "     where r.org_id = p_org_id\n       and true  -- unposted receipt row",
  "-- unposted receipt row")

m("a void receipt is listed",
  "report_ar_aging",
  "       and r.gl_entry_id is not null\n       and r.status <> 'void'\n       and r.deleted_at is null\n       and r.receipt_date <= p_as_at",
  "       and r.gl_entry_id is not null\n       and true  -- void receipt row\n       and r.deleted_at is null\n       and r.receipt_date <= p_as_at",
  "-- void receipt row")

m("a deleted receipt is listed",
  "report_ar_aging",
  "       and r.status <> 'void'\n       and r.deleted_at is null\n       and r.receipt_date <= p_as_at",
  "       and r.status <> 'void'\n       and true  -- deleted receipt row\n       and r.receipt_date <= p_as_at",
  "-- deleted receipt row")

m("a receipt banked after the as-at date is listed",
  "report_ar_aging",
  "       and r.receipt_date <= p_as_at\n  )",
  "       and true  -- future receipt\n  )",
  "-- future receipt")

m("another company's receipts are listed",
  "report_ar_aging",
  "     where r.org_id = p_org_id",
  "     where true  -- any org receipt",
  "-- any org receipt")

# -- the columns -----------------------------------------------------------

m("the ringgit column ignores the exchange rate",
  "report_ar_aging",
  "         round(d.outstanding * d.rate, 2),",
  "         round(d.outstanding, 2),  -- no rate",
  "-- no rate")

m("a document with no rate is worth nothing in ringgit",
  "report_ar_aging",
  "           coalesce(d.exchange_rate, 1) as rate,",
  "           coalesce(d.exchange_rate, 0) as rate,  -- rate 0",
  "-- rate 0")

m("days overdue counted from the document date",
  "report_ar_aging",
  "         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,",
  "         greatest(0, p_as_at - d.doc_date)::integer,  -- from doc date",
  "-- from doc date")

m("days overdue goes negative before the due date",
  "report_ar_aging",
  "         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,",
  "         (p_as_at - coalesce(d.due_date, d.doc_date))::integer,  -- floor",
  "-- floor")

m("current stops the day BEFORE the due date",
  "report_ar_aging",
  "           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'",
  "           when p_as_at < coalesce(d.due_date, d.doc_date) then 'current'  -- lt",
  "-- lt")

m("current is measured from the document date",
  "report_ar_aging",
  "           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'",
  "           when p_as_at <= d.doc_date then 'current'  -- cur doc date",
  "-- cur doc date")

m("1-30 ends at 29",
  "report_ar_aging",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) < 30 then '1_30'  -- 29",
  "-- 29")

m("31-60 ends at 59",
  "report_ar_aging",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) < 60 then '31_60'  -- 59",
  "-- 59")

m("61-90 ends at 89",
  "report_ar_aging",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) < 90 then '61_90'  -- 89",
  "-- 89")

m("a settled document is still listed, at nil",
  "report_ar_aging",
  "   where round(d.outstanding, 2) <> 0\n     and app.is_org_member(p_org_id)",
  "   where true  -- nil rows\n     and app.is_org_member(p_org_id)",
  "-- nil rows")

m("a stranger reads the listing",
  "report_ar_aging",
  "   where round(d.outstanding, 2) <> 0\n     and app.is_org_member(p_org_id)",
  "   where round(d.outstanding, 2) <> 0\n     and true  -- stranger",
  "-- stranger")

# -- 0747: the three ways of being paid ---------------------------------

m("a contra settles nothing",
  "report_ar_aging",
  "coalesce(r.receipt_date, cn.doc_date, k.contra_date,",
  "coalesce(r.receipt_date, cn.doc_date,  -- no contra",
  "-- no contra")

m("an applied deposit settles nothing",
  "report_ar_aging",
  "                    case when n.id is not null then a.applied_on end,",
  "                    null::date,  -- no deposit",
  "-- no deposit")

m("an applied deposit counts from the day the button was pressed",
  "report_ar_aging",
  "                    case when n.id is not null then a.applied_on end,",
  "                    case when n.id is not null then app.malaysian_day(a.allocated_at) end,  -- pressed",
  "-- pressed")

m("a post-dated cheque settles nothing",
  "report_ar_aging",
  "                    q.received_on) <= p_as_at",
  "                    null::date) <= p_as_at  -- no cheque",
  "-- no cheque")

m("a cheque counts from the day it can be banked, not the day it came",
  "report_ar_aging",
  "                    q.received_on) <= p_as_at",
  "                    q.cheque_date) <= p_as_at  -- cheque date",
  "-- cheque date")

m("a void contra still settles",
  "report_ar_aging",
  "       and k.gl_entry_id is not null and k.status <> 'void'",
  "       and k.gl_entry_id is not null  -- void contra",
  "-- void contra")

m("a bounced or cancelled cheque still settles",
  "report_ar_aging",
  "       and q.status in ('held', 'deposited', 'cleared')",
  "       and true  -- bounced cheque",
  "-- bounced cheque")

m("a cheque with no journal settles",
  "report_ar_aging",
  "       and q.gl_entry_id is not null\n       and q.status in ('held', 'deposited', 'cleared')",
  "       and true  -- unposted cheque\n       and q.status in ('held', 'deposited', 'cleared')",
  "-- unposted cheque")

m("a void deposit still settles",
  "report_ar_aging",
  "       and n.gl_entry_id is not null and n.status <> 'void'",
  "       and n.gl_entry_id is not null  -- void deposit",
  "-- void deposit")

m("CONTROL: a comment inside the block",
  "report_ar_aging",
  "  -- Documents that moved the receivable: invoices and debit notes add",
  "  -- CONTROL\n  -- Documents that moved the receivable: invoices and debit notes add",
  "-- CONTROL")
