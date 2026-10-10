# Mutants for public.open_customer_portal (0797, restated from 0493) --
# what one customer owes, for somebody holding their portal token: the
# link's state, the record of each opening, the open invoices of every
# record of this customer in this company, and what is owed currency by
# currency.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0797_a_ringgit_and_a_dollar_are_not_two_of_anything.sql \
#       supabase/tests/customer_portal_shapes.sql \
#       supabase/tests/mutants/a_ringgit_and_a_dollar_are_not_two_of_anything.py
#
# RESULT: 17 mutants and a control. 16 killed by
# `customer_portal_shapes.sql`, one after an assertion that an invoice
# for nothing (which posts as 'posted', owing nothing) is not listed.
#
# EQUIVALENT: "another company's record with our party id counts".
# The documents are held to the link's company, and a document's contact
# to the document's company by `sales_documents_contact_same_org`, so
# another company's contact owns no document of ours whatever its party
# id. The file asserts the constraint instead.
#
# The grant by hand: `anon`'s EXECUTE revoked, the file fails at its
# own grant assertion ("a customer may open their own account"), before
# the 0797 block reaches its anon call; restored, it passes.
#
# The page, in Dart, by `scripts/mutate.py` (mutants kept in scratch):
# `customer_portal_summary.dart` 12 of 12 by
# `customer_portal_summary_test.dart`, and `customer_portal_page.dart`
# 3 of 3 by the new `customer_portal_page_test.dart`, each with a
# no-op control that passed.

F = "open_customer_portal"

# The door.
m("a revoked link opens", F,
  "    when l.revoked_at is not null then 'revoked'",
  "    when false then 'revoked'  -- revoked opens",
  "-- revoked opens")
m("an expired link opens", F,
  "    when l.expires_at < now() then 'expired'",
  "    when false then 'expired'  -- expired opens",
  "-- expired opens")
m("a deleted customer's account opens", F,
  "    when c.id is null or c.deleted_at is not null then 'withdrawn'",
  "    when c.id is null then 'withdrawn'  -- deleted opens",
  "-- deleted opens")

# The record of each opening.
m("the first opening is overwritten", F,
  "     set opened_at = coalesce(opened_at, now()),",
  "     set opened_at = now(),  -- first overwritten",
  "-- first overwritten")
m("openings are not counted", F,
  "         open_count = open_count + 1,",
  "         open_count = open_count,  -- uncounted",
  "-- uncounted")

# Whose invoices.
m("another company's record with our party id counts", F,
  "          where c2.org_id = l.org_id\n            and (c2.id = c.id",
  "          where true  -- any company\n            and (c2.id = c.id",
  "-- any company")
m("the customer's other record does not count", F,
  "                 or (c.party_id is not null and c2.party_id = c.party_id)))",
  "                 or false))  -- one record",
  "-- one record")
m("a deleted invoice is owed", F,
  "       and d.deleted_at is null\n       and d.doc_type = 'invoice'",
  "       and true  -- deleted owed\n       and d.doc_type = 'invoice'",
  "-- deleted owed")
m("a draft is a demand", F,
  "       and d.status in ('posted', 'partial')",
  "       and d.status in ('posted', 'partial', 'draft')  -- drafts",
  "-- drafts")
m("a paid invoice is listed", F,
  "       and coalesce(d.balance_amount, 0) > 0\n  )",
  "       and coalesce(d.balance_amount, 0) >= 0  -- paid listed\n  )",
  "-- paid listed")

# Currency by currency.
m("every currency is one total", F,
  "       from (select d.currency, sum(d.balance_amount) as amount\n               from open_docs d group by d.currency) s),",
  "       from (select min(d.currency) as currency, sum(d.balance_amount) as amount\n               from open_docs d having count(*) > 0) s),  -- one total",
  "-- one total")
m("the company's own currency is not first", F,
  "              order by s.currency is distinct from coalesce(o.base_currency, 'MYR'),\n                       s.currency), '[]'::jsonb)",
  "              order by s.currency), '[]'::jsonb)  -- by name",
  "-- by name")
m("a customer billed only in dollars is owed ringgit", F,
  "    'currency', case when v_ccys = 1 then v_sums -> 0 ->> 'currency'",
  "    'currency', case when false then v_sums -> 0 ->> 'currency'  -- ringgit",
  "-- ringgit")
m("two currencies are added up again", F,
  "    'total_outstanding', case when v_ccys <= 1 then v_owed end,",
  "    'total_outstanding', v_owed,  -- added up",
  "-- added up")
m("owing nothing is no figure at all", F,
  "    'total_outstanding', case when v_ccys <= 1 then v_owed end,",
  "    'total_outstanding', case when v_ccys = 1 then v_owed end,  -- nothing is null",
  "-- nothing is null")
m("invoices are counted rather than currencies", F,
  "    (select count(distinct d.currency)::integer from open_docs d),",
  "    (select count(*)::integer from open_docs d),  -- invoices",
  "-- invoices")
m("an invoice does not say its currency", F,
  "              'currency', d.currency,\n              'total_amount', d.total_amount,",
  "              'total_amount', d.total_amount,  -- no currency",
  "-- no currency")

m("CONTROL", F,
  "  v_ccys  integer;\nbegin",
  "  v_ccys  integer;  -- control\nbegin",
  "-- control")
