# Mutants for app.due_date_from_terms, app.settlement_discount_of and
# app.document_due_date_guard (0385) -- what a payment term means: when
# the document falls due, and what paying early is worth by when.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0385_the_discount_that_cleared_an_invoice_and_no_ledger.sql \
#       supabase/tests/settlement_discount.sql \
#       supabase/tests/mutants/payment_terms.py
#
# RESULT: (pending)

m("cash on delivery is credit for the term's days",
  "due_date_from_terms",
  "    when 'cod'     then p_doc_date",
  "    when 'cod'     then p_doc_date + v_t.days  -- credit",
  "-- credit")

m("prepaid is credit for the term's days",
  "due_date_from_terms",
  "    when 'prepaid' then p_doc_date",
  "    when 'prepaid' then p_doc_date + v_t.days  -- credit",
  "-- credit")

m("end of month counts from the invoice date",
  "due_date_from_terms",
  "    when 'eom'     then (date_trunc('month', p_doc_date)\n                          + interval '1 month - 1 day')::date + v_t.days",
  "    when 'eom'     then p_doc_date + v_t.days  -- not month end",
  "-- not month end")

m("end of month is the first of the next",
  "due_date_from_terms",
  "                          + interval '1 month - 1 day')::date + v_t.days",
  "                          + interval '1 month')::date + v_t.days  -- the 1st",
  "-- the 1st")

m("end of month forgets the days",
  "due_date_from_terms",
  "                          + interval '1 month - 1 day')::date + v_t.days",
  "                          + interval '1 month - 1 day')::date  -- no days",
  "-- no days")

m("net terms ignore the days",
  "due_date_from_terms",
  "    else p_doc_date + v_t.days",
  "    else p_doc_date  -- on the day",
  "-- on the day")

m("a discount with no days named is offered",
  "settlement_discount_of",
  "     or coalesce(v_t.discount_days, 0) <= 0 then",
  "     or false then  -- no days fine",
  "-- no days fine")

m("a discount of nothing is offered",
  "settlement_discount_of",
  "  if coalesce(v_t.discount_percent, 0) <= 0\n",
  "  if false  -- nothing fine\n",
  "-- nothing fine")

m("the discount runs from the due date",
  "settlement_discount_of",
  "  deadline := p_doc_date + v_t.discount_days;",
  "  deadline := app.due_date_from_terms(p_term_id, p_doc_date) + v_t.discount_days;  -- from due",
  "-- from due")

m("the discount is not divided by a hundred",
  "settlement_discount_of",
  "  amount   := round(coalesce(p_amount, 0) * v_t.discount_percent / 100, 2);",
  "  amount   := round(coalesce(p_amount, 0) * v_t.discount_percent, 2);  -- percent",
  "-- percent")

m("a typed due date is overwritten by the terms",
  "document_due_date_guard",
  "  if new.due_date is null then",
  "  if true then  -- always",
  "-- always")

m("a document may fall due before it was raised",
  "document_due_date_guard",
  "     and new.due_date < new.doc_date then",
  "     and false then  -- any order",
  "-- any order")

m("falling due the day it is raised is refused",
  "document_due_date_guard",
  "     and new.due_date < new.doc_date then",
  "     and new.due_date <= new.doc_date then  -- same day refused",
  "-- same day refused")

m("CONTROL: a comment inside the block",
  "due_date_from_terms",
  "    -- End of month plus the days: the whole point of EOM terms is that",
  "    -- CONTROL\n    -- End of month plus the days: the whole point of EOM terms is that",
  "-- CONTROL")
