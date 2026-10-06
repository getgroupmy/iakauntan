# Mutants for app.raise_notifications (0739) -- what the bell says each
# morning: e-Invoices LHDN refused, tickets past their SLA, claims
# waiting on an approver, and financial statements coming due.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/notifications.sql \
#       supabase/tests/mutants/raise_notifications.py
#
# RESULT: 20 mutants and a control. 20 killed in notifications.sql,
# by "raise_notifications, rule by rule" and the block above it.
#
#   The fixture above it had one of each source, each of which should
#   ring: no accepted e-Invoice, no ticket inside its SLA or resolved, no
#   draft claim or claim with no approver, no lodged filing or one months
#   off, nobody assigned to the ticket, and no filing past its date, on
#   it, or on the thirtieth day.

m("another company's refused e-Invoices ring this bell",
  "raise_notifications",
  "            where e.org_id = p_org\n              and e.status in ('invalid', 'rejected', 'failed')",
  "            where e.status in ('invalid', 'rejected', 'failed')  -- any org",
  "-- any org")

m("an accepted e-Invoice is reported refused",
  "raise_notifications",
  "              and e.status in ('invalid', 'rejected', 'failed')",
  "              and true  -- any status",
  "-- any status")

m("a failed submission is not reported",
  "raise_notifications",
  "              and e.status in ('invalid', 'rejected', 'failed')",
  "              and e.status in ('invalid', 'rejected')  -- not failed",
  "-- not failed")

m("the reason LHDN gave is not shown",
  "raise_notifications",
  "         coalesce(r.rejection_reason, r.error_message,",
  "         coalesce(r.error_message,  -- no reason",
  "-- no reason")

m("a refused e-Invoice is not urgent",
  "raise_notifications",
  "         'urgent', '/einvoice', 'einvoice_documents', r.id) then",
  "         'warning', '/einvoice', 'einvoice_documents', r.id) then  -- calm",
  "-- calm")

m("another company's tickets ring this bell",
  "raise_notifications",
  "            where t.org_id = p_org\n",
  "            where true  -- any org\n",
  "-- any org")

m("a ticket inside its SLA is overdue",
  "raise_notifications",
  "              and t.resolution_due_at < now()",
  "              and true  -- any time",
  "-- any time")

m("a resolved ticket is overdue",
  "raise_notifications",
  "              and t.status not in ('resolved', 'closed', 'cancelled')",
  "              and t.status not in ('closed', 'cancelled')  -- resolved too",
  "-- resolved too")

m("a late ticket goes to the company, not its assignee",
  "raise_notifications",
  "    if app.notify(p_org, r.assignee_id, 'ticket_overdue',",
  "    if app.notify(p_org, null, 'ticket_overdue',  -- to all",
  "-- to all")

m("another company's claims ring this bell",
  "raise_notifications",
  "            where c.org_id = p_org\n",
  "            where true  -- any org\n",
  "-- any org")

m("a draft claim waits for approval",
  "raise_notifications",
  "              and c.status = 'submitted'",
  "              and true  -- any status",
  "-- any status")

m("a claim with no approver is announced to nobody in particular",
  "raise_notifications",
  "              and c.approver_id is not null",
  "              and true  -- no approver",
  "-- no approver")

m("a claim goes to everybody, not its approver",
  "raise_notifications",
  "    if app.notify(p_org, r.approver_id, 'claim_to_approve',",
  "    if app.notify(p_org, null, 'claim_to_approve',  -- to all",
  "-- to all")

m("another company's filings ring this bell",
  "raise_notifications",
  "            where f.org_id = p_org\n              and f.lodged_on is null",
  "            where f.lodged_on is null  -- any org",
  "-- any org")

m("a lodged filing is still due",
  "raise_notifications",
  "              and f.lodged_on is null",
  "              and true  -- lodged too",
  "-- lodged too")

m("a filing is announced however far away",
  "raise_notifications",
  "    if r.lodge_by - p_on <= 30 then",
  "    if true then  -- any distance",
  "-- any distance")

m("thirty days out is not yet announced",
  "raise_notifications",
  "    if r.lodge_by - p_on <= 30 then",
  "    if r.lodge_by - p_on < 30 then  -- 29",
  "-- 29")

m("a filing past its date is only a warning",
  "raise_notifications",
  "           case when r.lodge_by < p_on then 'urgent' else 'warning' end,",
  "           'warning',  -- calm",
  "-- calm")

m("a filing due today is urgent",
  "raise_notifications",
  "           case when r.lodge_by < p_on then 'urgent' else 'warning' end,",
  "           case when r.lodge_by <= p_on then 'urgent' else 'warning' end,  -- today urgent",
  "-- today urgent")

m("nothing new is counted",
  "raise_notifications",
  "  return v_new;",
  "  return 0;  -- uncounted",
  "-- uncounted")

m("CONTROL: a comment inside the block",
  "raise_notifications",
  "  -- The statutory one. Thirty days out is when it stops being next",
  "  -- CONTROL\n  -- The statutory one. Thirty days out is when it stops being next",
  "-- CONTROL")
