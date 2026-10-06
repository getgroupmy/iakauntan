# Mutants for app.queue_overdue_reminders (0750, after 0739) -- the dunning mail: an
# open invoice so many days past due, on a day the company chose.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0750_what_earns_when_it_renews_and_who_is_trading.sql \
#       supabase/tests/outbound_email.sql \
#       supabase/tests/mutants/queue_overdue_reminders.py
#
# then again against `recurring_documents.sql` and `scheduled_work.sql`.
#
# RESULT, against 0750: 15 mutants and a control. 13 killed, 2
# equivalent.
#
#   Against 0739 the first sweep killed 3 of 14 in outbound_email.sql and
#   none in scheduled_work.sql: one posted invoice in one company with
#   mail on, due the day it was issued -- so days overdue and days since
#   issue were one number, and nothing was part-paid, deleted, a draft,
#   a credit note, on the minimum, switched off, suspended or on trial.
#   "queue_overdue_reminders, rule by rule" kills the rest, including
#   0750's trial company and the dedupe key, which names the days
#   OVERDUE (the "counted from the invoice date" mutant changes only the
#   key, never which invoices are chased).
#
#   EQUIVALENT by the callee: "a company with mail switched off is chased
#   for". `app.queue_document_email` reads the same `email_settings` row
#   and returns null when `is_enabled` is false, so nothing is queued
#   either way.
#
#   EQUIVALENT by the code's shape: "a company with no reminder days is
#   asked about". `x = any('{}')` is false, so an empty list chases
#   nobody with or without the `array_length` guard.

m("a company with mail switched off is chased for",
  "queue_overdue_reminders",
  "     where s.is_enabled\n",
  "     where true  -- switched off too\n",
  "-- switched off too")

m("a company with no reminder days is asked about",
  "queue_overdue_reminders",
  "       and array_length(s.reminder_days, 1) is not null",
  "       and true  -- no days",
  "-- no days")

m("a suspended company's customers are chased",
  "queue_overdue_reminders",
  "       and app.org_status_is_live(o.status)  -- 0750: trial too",
  "       and true  -- suspended too",
  "-- suspended too")

m("a deleted invoice is chased",
  "queue_overdue_reminders",
  "       and d.deleted_at is null",
  "       and true  -- deleted too",
  "-- deleted too")

m("a credit note is chased",
  "queue_overdue_reminders",
  "       and d.doc_type = 'invoice'",
  "       and true  -- any type",
  "-- any type")

m("a draft is chased",
  "queue_overdue_reminders",
  "       and d.status in ('posted', 'partial')",
  "       and d.status <> 'void'  -- drafts too",
  "-- drafts too")

m("a part-paid invoice is not chased",
  "queue_overdue_reminders",
  "       and d.status in ('posted', 'partial')",
  "       and d.status in ('posted')  -- not partial",
  "-- not partial")

m("a paid invoice is chased",
  "queue_overdue_reminders",
  "       and d.balance_amount > 0\n",
  "       and true  -- paid too\n",
  "-- paid too")

m("a balance under the minimum is chased",
  "queue_overdue_reminders",
  "       and d.balance_amount >= s.reminder_min_amount",
  "       and true  -- any amount",
  "-- any amount")

m("a balance exactly at the minimum is not chased",
  "queue_overdue_reminders",
  "       and d.balance_amount >= s.reminder_min_amount",
  "       and d.balance_amount > s.reminder_min_amount  -- strictly",
  "-- strictly")

m("every overdue day is a reminder day",
  "queue_overdue_reminders",
  "       and (p_on - d.due_date) = any (s.reminder_days)",
  "       and (p_on - d.due_date) > 0  -- every day",
  "-- every day")

m("the days are counted from the invoice date",
  "queue_overdue_reminders",
  "    select d.id, d.org_id, (p_on - d.due_date) as days_over",
  "    select d.id, d.org_id, (p_on - d.doc_date) as days_over  -- from issue",
  "-- from issue")

m("the 7th and the 14th are the same mail",
  "queue_overdue_reminders",
  "         'reminder:' || r.id::text || ':' || r.days_over::text) is not null then",
  "         'reminder:' || r.id::text) is not null then  -- one key",
  "-- one key")

m("nothing queued is counted",
  "queue_overdue_reminders",
  "      v_n := v_n + 1;",
  "      v_n := v_n;  -- uncounted",
  "-- uncounted")

# 0750 -- a trial company's customers are chased.
m("a trial company's customers are not chased",
  "queue_overdue_reminders",
  "       and app.org_status_is_live(o.status)  -- 0750: trial too",
  "       and coalesce(o.status, 'active') = 'active'  -- active only",
  "-- active only")

m("CONTROL: a comment inside the block",
  "queue_overdue_reminders",
  "  return v_n;",
  "  -- CONTROL\n  return v_n;",
  "-- CONTROL")
