# Mutants for public.report_statement_of_account (0747; first written
# against 0624) -- the statement a customer is sent: what was brought
# forward, then every invoice, note, receipt, contra, applied deposit
# and post-dated cheque in the period, with a running balance.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0747_the_three_ways_of_being_paid_the_listings_never_saw.sql \
#       supabase/tests/statement_of_account.sql \
#       supabase/tests/mutants/report_statement_of_account.py
#
# RESULT, 6 October, against 0747: 9 mutants, 8 KILLED, 1 equivalent,
# control alive, on statement_of_account.sql. "Another customer's
# settlements" lived until the block gained a second customer whose
# cheque must stay off this one's statement.
#
# Equivalent: "every allocation is read as one of the three". A receipt's
# allocation then joins none of contra_notes, deposit_notes and
# post_dated_cheques, so its date is coalesce(null, null, null) -- and a
# null date is neither before the period (opening) nor inside it, so the
# row is never shown and never summed. The code's own shape.

m("a contra is not on the statement",
  "report_statement_of_account",
  "       and (k.id is not null or n.id is not null or q.id is not null)",
  "       and (n.id is not null or q.id is not null)  -- no contra",
  "-- no contra")

m("an applied deposit is not on the statement",
  "report_statement_of_account",
  "       and (k.id is not null or n.id is not null or q.id is not null)",
  "       and (k.id is not null or q.id is not null)  -- no deposit",
  "-- no deposit")

m("a post-dated cheque is not on the statement",
  "report_statement_of_account",
  "       and (k.id is not null or n.id is not null or q.id is not null)",
  "       and (k.id is not null or n.id is not null)  -- no cheque",
  "-- no cheque")

m("a deposit is dated the day the button was pressed",
  "report_statement_of_account",
  "    select coalesce(k.contra_date, a.applied_on, q.received_on),",
  "    select coalesce(k.contra_date, app.malaysian_day(max(a.allocated_at)), q.received_on),  -- pressed",
  "-- pressed")

m("a cheque is dated the day it can be banked",
  "report_statement_of_account",
  "    select coalesce(k.contra_date, a.applied_on, q.received_on),",
  "    select coalesce(k.contra_date, a.applied_on, q.cheque_date),  -- cheque date",
  "-- cheque date")

m("the three are debits, not credits",
  "report_statement_of_account",
  "           0, sum(a.amount), coalesce(d.exchange_rate, 1)",
  "           sum(a.amount), 0, coalesce(d.exchange_rate, 1)  -- debit",
  "-- debit")

m("every allocation is read as one of the three, receipts included",
  "report_statement_of_account",
  "       and (k.id is not null or n.id is not null or q.id is not null)",
  "       and true  -- everything",
  "-- everything")

m("another customer's settlements are on this statement",
  "report_statement_of_account",
  "       and d.contact_id = p_contact_id and d.org_id = v_org",
  "       and d.org_id = v_org  -- any customer",
  "-- any customer")

m("the three are named as each other",
  "report_statement_of_account",
  "           case when k.id is not null then 'contra'",
  "           case when k.id is not null then 'deposit'  -- misnamed",
  "-- misnamed")

m("CONTROL: a comment inside the block",
  "report_statement_of_account",
  "  -- Everything before the period, as one number. Not listed: a",
  "  -- CONTROL\n  -- Everything before the period, as one number. Not listed: a",
  "-- CONTROL")
