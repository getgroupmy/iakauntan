# Mutants for public.report_ap_aging (0739) -- the aged payables: every
# posted bill, purchase debit note, purchase credit note and unapplied
# payment, less what was allocated by the as-at date -- by a payment, a
# credit note or a withholding certificate -- in its own currency and in
# ringgit, with days overdue and a bucket.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/aged_balances.sql \
#       supabase/tests/mutants/report_ap_aging.py
#
# RESULT: (pending)

# -- allocations: both ends in the ledger by the as-at date ------------

m("an allocation made after the as-at date already reduces the balance",
  "report_ap_aging",
  "       and coalesce(p.payment_date, cn.doc_date, w.cert_date) <= p_as_at",
  "       and true  -- any date",
  "-- any date")

m("an allocation from an unposted payment counts",
  "report_ap_aging",
  "      left join public.purchase_payments p on p.id = a.payment_id\n       and p.gl_entry_id is not null and p.deleted_at is null",
  "      left join public.purchase_payments p on p.id = a.payment_id\n       and p.deleted_at is null  -- unposted payment",
  "-- unposted payment")

m("an allocation from a deleted payment counts",
  "report_ap_aging",
  "      left join public.purchase_payments p on p.id = a.payment_id\n       and p.gl_entry_id is not null and p.deleted_at is null",
  "      left join public.purchase_payments p on p.id = a.payment_id\n       and p.gl_entry_id is not null  -- deleted payment",
  "-- deleted payment")

m("an allocation from a void payment counts",
  "report_ap_aging",
  "       and p.status <> 'void'\n      left join public.sales_documents cn",
  "       and true  -- void payment\n      left join public.sales_documents cn",
  "-- void payment")

m("an allocation from a void withholding certificate counts",
  "report_ap_aging",
  "       and w.gl_entry_id is not null and w.deleted_at is null\n       and w.status <> 'void'",
  "       and w.gl_entry_id is not null and w.deleted_at is null\n       and true  -- void cert",
  "-- void cert")

m("an allocation from an unposted withholding certificate counts",
  "report_ap_aging",
  "       and w.gl_entry_id is not null and w.deleted_at is null\n       and w.status <> 'void'",
  "       and w.deleted_at is null  -- unposted cert\n       and w.status <> 'void'",
  "-- unposted cert")

m("withholding certificates settle nothing",
  "report_ap_aging",
  "       and coalesce(p.payment_date, cn.doc_date, w.cert_date) <= p_as_at",
  "       and coalesce(p.payment_date, cn.doc_date) <= p_as_at  -- no cert",
  "-- no cert")

m("another company's allocations count",
  "report_ap_aging",
  "     where a.org_id = p_org_id\n       and coalesce(p.payment_date, cn.doc_date, w.cert_date) <= p_as_at",
  "     where true  -- any org\n       and coalesce(p.payment_date, cn.doc_date, w.cert_date) <= p_as_at",
  "-- any org")

# -- documents -----------------------------------------------------------

m("a purchase credit note ADDS to the payable",
  "report_ap_aging",
  "           case when d.doc_type = 'purchase_credit_note' then -1 else 1 end",
  "           case when false then -1 else 1 end  -- pcn adds",
  "-- pcn adds")

m("a bill's settlement discount is not taken off",
  "report_ap_aging",
  "                 coalesce((select sum(al.amount + al.discount_amount)\n                             from allocations al where al.bill_id = d.id), 0)",
  "                 coalesce((select sum(al.amount)  -- no discount\n                             from allocations al where al.bill_id = d.id), 0)",
  "-- no discount")

m("a purchase debit note's allocations are not taken off",
  "report_ap_aging",
  "               when d.doc_type in ('bill', 'purchase_debit_note') then",
  "               when d.doc_type in ('bill') then  -- pdn never paid",
  "-- pdn never paid")

m("nothing allocated against a bill is taken off",
  "report_ap_aging",
  "               when d.doc_type in ('bill', 'purchase_debit_note') then",
  "               when d.doc_type in ('purchase_debit_note') then  -- bill never paid",
  "-- bill never paid")

m("purchase debit notes are left off the listing",
  "report_ap_aging",
  "       and d.doc_type in ('bill', 'purchase_debit_note', 'purchase_credit_note')",
  "       and d.doc_type in ('bill', 'purchase_credit_note')  -- no pdn",
  "-- no pdn")

m("purchase credit notes are left off the listing",
  "report_ap_aging",
  "       and d.doc_type in ('bill', 'purchase_debit_note', 'purchase_credit_note')",
  "       and d.doc_type in ('bill', 'purchase_debit_note')  -- no pcn",
  "-- no pcn")

m("an unposted bill is listed",
  "report_ap_aging",
  "       and d.doc_type in ('bill', 'purchase_debit_note', 'purchase_credit_note')\n       and d.gl_entry_id is not null",
  "       and d.doc_type in ('bill', 'purchase_debit_note', 'purchase_credit_note')\n       and true  -- unposted doc",
  "-- unposted doc")

m("a void bill is listed",
  "report_ap_aging",
  "       and d.gl_entry_id is not null\n       and d.status <> 'void'\n       and d.deleted_at is null\n       and d.doc_date <= p_as_at",
  "       and d.gl_entry_id is not null\n       and true  -- void doc\n       and d.deleted_at is null\n       and d.doc_date <= p_as_at",
  "-- void doc")

m("a deleted bill is listed",
  "report_ap_aging",
  "       and d.gl_entry_id is not null\n       and d.status <> 'void'\n       and d.deleted_at is null\n       and d.doc_date <= p_as_at",
  "       and d.gl_entry_id is not null\n       and d.status <> 'void'\n       and true  -- deleted doc\n       and d.doc_date <= p_as_at",
  "-- deleted doc")

m("a bill dated after the as-at date is listed",
  "report_ap_aging",
  "       and d.deleted_at is null\n       and d.doc_date <= p_as_at\n    union all",
  "       and d.deleted_at is null\n       and true  -- future doc\n    union all",
  "-- future doc")

m("another company's bills are listed",
  "report_ap_aging",
  "     where d.org_id = p_org_id",
  "     where true  -- any org doc",
  "-- any org doc")

# -- unapplied payments ----------------------------------------------------

m("unapplied payments are left off",
  "report_ap_aging",
  "       and p.payment_date <= p_as_at\n  )",
  "       and p.payment_date <= p_as_at\n       and false  -- no payments\n  )",
  "-- no payments")

m("a payment shows its full amount, applied or not",
  "report_ap_aging",
  "           -(p.amount - coalesce((select sum(al.amount) from allocations al\n                                   where al.payment_id = p.id), 0))",
  "           -(p.amount)  -- never applied",
  "-- never applied")

m("a payment reduces the payable by a NEGATIVE amount",
  "report_ap_aging",
  "           -(p.amount - coalesce((select sum(al.amount) from allocations al\n                                   where al.payment_id = p.id), 0))",
  "           (p.amount - coalesce((select sum(al.amount) from allocations al  -- sign\n                                   where al.payment_id = p.id), 0))",
  "-- sign")

m("an unposted payment is listed",
  "report_ap_aging",
  "     where p.org_id = p_org_id\n       and p.gl_entry_id is not null",
  "     where p.org_id = p_org_id\n       and true  -- unposted payment row",
  "-- unposted payment row")

m("a void payment is listed",
  "report_ap_aging",
  "       and p.gl_entry_id is not null\n       and p.status <> 'void'\n       and p.deleted_at is null\n       and p.payment_date <= p_as_at",
  "       and p.gl_entry_id is not null\n       and true  -- void payment row\n       and p.deleted_at is null\n       and p.payment_date <= p_as_at",
  "-- void payment row")

m("a deleted payment is listed",
  "report_ap_aging",
  "       and p.status <> 'void'\n       and p.deleted_at is null\n       and p.payment_date <= p_as_at",
  "       and p.status <> 'void'\n       and true  -- deleted payment row\n       and p.payment_date <= p_as_at",
  "-- deleted payment row")

m("a payment made after the as-at date is listed",
  "report_ap_aging",
  "       and p.payment_date <= p_as_at\n  )",
  "       and true  -- future payment\n  )",
  "-- future payment")

m("another company's payments are listed",
  "report_ap_aging",
  "     where p.org_id = p_org_id",
  "     where true  -- any org payment",
  "-- any org payment")

# -- the columns -----------------------------------------------------------

m("the ringgit column ignores the exchange rate",
  "report_ap_aging",
  "         round(d.outstanding * d.rate, 2),",
  "         round(d.outstanding, 2),  -- no rate",
  "-- no rate")

m("a document with no rate is worth nothing in ringgit",
  "report_ap_aging",
  "           coalesce(d.exchange_rate, 1) as rate,",
  "           coalesce(d.exchange_rate, 0) as rate,  -- rate 0",
  "-- rate 0")

m("days overdue counted from the document date",
  "report_ap_aging",
  "         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,",
  "         greatest(0, p_as_at - d.doc_date)::integer,  -- from doc date",
  "-- from doc date")

m("days overdue goes negative before the due date",
  "report_ap_aging",
  "         greatest(0, p_as_at - coalesce(d.due_date, d.doc_date))::integer,",
  "         (p_as_at - coalesce(d.due_date, d.doc_date))::integer,  -- floor",
  "-- floor")

m("current stops the day BEFORE the due date",
  "report_ap_aging",
  "           when p_as_at <= coalesce(d.due_date, d.doc_date) then 'current'",
  "           when p_as_at < coalesce(d.due_date, d.doc_date) then 'current'  -- lt",
  "-- lt")

m("1-30 ends at 29",
  "report_ap_aging",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) <= 30 then '1_30'",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) < 30 then '1_30'  -- 29",
  "-- 29")

m("31-60 ends at 59",
  "report_ap_aging",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) <= 60 then '31_60'",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) < 60 then '31_60'  -- 59",
  "-- 59")

m("61-90 ends at 89",
  "report_ap_aging",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) <= 90 then '61_90'",
  "           when p_as_at - coalesce(d.due_date, d.doc_date) < 90 then '61_90'  -- 89",
  "-- 89")

m("a settled document is still listed, at nil",
  "report_ap_aging",
  "   where round(d.outstanding, 2) <> 0\n     and app.is_org_member(p_org_id)",
  "   where true  -- nil rows\n     and app.is_org_member(p_org_id)",
  "-- nil rows")

m("a stranger reads the listing",
  "report_ap_aging",
  "   where round(d.outstanding, 2) <> 0\n     and app.is_org_member(p_org_id)",
  "   where round(d.outstanding, 2) <> 0\n     and true  -- stranger",
  "-- stranger")

m("CONTROL: a comment inside the block",
  "report_ap_aging",
  "  documents as (\n    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,",
  "  -- CONTROL\n  documents as (\n    select d.contact_id, d.doc_type::text as doc_kind, d.id as document_id,",
  "-- CONTROL")
