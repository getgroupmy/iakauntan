# Mutants for public.report_collections (0749; first written against 0739) -- the credit controller's
# worklist: who owes what on invoices, how old, the last attempt to
# collect it, the live promise and whether it has been broken, and who
# has never been chased.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0749_what_counts_as_owed_and_as_paid.sql \
#       supabase/tests/collections.sql \
#       supabase/tests/mutants/report_collections.py
#
# RESULT AGAIN, against 0749: 19 mutants, 16 KILLED, 3 equivalent,
# control alive. The question below was answered -- "Chase debit notes"
# -- and 0749 reads invoices and debit notes; collections.sql's "A debit
# note is chased like an invoice" kills the new mutant that takes them
# off again. "Credit notes and receipts are chased as debts" is now
# EQUIVALENT by the code's own shape: every positive kind of row is on
# the list, and `> 0` keeps the negative ones off without the kind
# filter's help.
#
# RESULT, 6 October (against 0739): 18 mutants, 15 KILLED, 2 equivalent, 1 left as a
# question, control alive, on collections.sql. 7 died before "The
# worklist, rule by rule" was added.
#
# Equivalent, with the reason:
#   * another company's attempt: `collection_attempts` has a composite key
#     to its contact's company. A table constraint.
#   * a credit balance on the worklist (`<> 0` for `> 0`): the rows are
#     invoices and `app.apply_allocation` refuses to over-allocate one, so
#     none is negative. The writer.
#
# NOT asserted, deliberately: "credit notes and receipts are chased as
# debts" -- `where a.doc_kind = 'invoice'` dropped. Credit notes, refund
# notes and receipts are negative and the `> 0` filter drops them anyway;
# the only row the kind filter keeps off is a DEBIT NOTE, which is a debt.
# So the worklist never chases a customer whose only debt is a debit
# note. Asserting it either way would decide a question that is the
# user's (docs/handoff.md, item 13).

m("a stranger reads the worklist",
  "report_collections",
  "  if not app.is_org_member(p_org_id) then\n    raise exception 'Not your company'",
  "  if false then  -- stranger\n    raise exception 'Not your company'",
  "-- stranger")

m("a member without the ledger reads it",
  "report_collections",
  "  if not (app.can_read_ledger(p_org_id) or app.can_write(p_org_id)) then",
  "  if false then  -- any member",
  "-- any member")

m("credit notes and receipts are chased as debts -- in fact: debit notes are",
  "report_collections",
  "     where a.doc_kind in ('invoice', 'debit_note')\n       and a.base_outstanding > 0",
  "     where true  -- any kind\n       and a.base_outstanding > 0",
  "-- any kind")

m("a credit balance is on the worklist",
  "report_collections",
  "     where a.doc_kind in ('invoice', 'debit_note')\n       and a.base_outstanding > 0",
  "     where a.doc_kind in ('invoice', 'debit_note')\n       and a.base_outstanding <> 0  -- credits",
  "-- credits")

m("the oldest debt is the youngest",
  "report_collections",
  "           max(a.days_overdue) as oldest_days,",
  "           min(a.days_overdue) as oldest_days,  -- youngest",
  "-- youngest")

m("the latest attempt is the first one",
  "report_collections",
  "     where c.org_id = p_org_id and c.attempted_on <= p_as_at\n     order by c.contact_id, c.attempted_on desc, c.created_at desc",
  "     where c.org_id = p_org_id and c.attempted_on <= p_as_at\n     order by c.contact_id, c.attempted_on asc, c.created_at desc  -- first",
  "-- first")

m("an attempt after the as-at date is the latest",
  "report_collections",
  "     where c.org_id = p_org_id and c.attempted_on <= p_as_at\n     order by",
  "     where c.org_id = p_org_id  -- future attempt\n     order by",
  "-- future attempt")

m("another company's attempt is the latest",
  "report_collections",
  "     where c.org_id = p_org_id and c.attempted_on <= p_as_at\n     order by",
  "     where c.attempted_on <= p_as_at  -- any org attempt\n     order by",
  "-- any org attempt")

m("the live promise is the first one ever made",
  "report_collections",
  "       and c.attempted_on <= p_as_at\n     order by c.contact_id, c.attempted_on desc, c.created_at desc\n  )\n  select",
  "       and c.attempted_on <= p_as_at\n     order by c.contact_id, c.attempted_on asc, c.created_at desc  -- first promise\n  )\n  select",
  "-- first promise")

m("an attempt with no promise is a promise",
  "report_collections",
  "       and c.promise_date is not null",
  "       and true  -- no promise",
  "-- no promise")

m("a promise made after the as-at date is live",
  "report_collections",
  "       and c.promise_date is not null\n       and c.attempted_on <= p_as_at",
  "       and c.promise_date is not null\n       and true  -- future promise",
  "-- future promise")

m("a promise is broken on its own day",
  "report_collections",
  "         (p.promise_date is not null and p.promise_date < p_as_at),\n         l.assigned_to,",
  "         (p.promise_date is not null and p.promise_date <= p_as_at),  -- le\n         l.assigned_to,",
  "-- le")

m("no promise is ever broken",
  "report_collections",
  "         (p.promise_date is not null and p.promise_date < p_as_at),\n         l.assigned_to,",
  "         false,  -- never broken\n         l.assigned_to,",
  "-- never broken")

m("nobody is ever never-chased",
  "report_collections",
  "         (l.contact_id is null)\n    from owed o",
  "         false  -- all chased\n    from owed o",
  "-- all chased")

m("the person assigned is not named",
  "report_collections",
  "         (select coalesce(pr.full_name, pr.email)\n            from public.profiles pr where pr.id = l.assigned_to),",
  "         null::text,  -- unnamed",
  "-- unnamed")

m("broken promises are not first",
  "report_collections",
  "     (p.promise_date is not null and p.promise_date < p_as_at) desc,\n     (l.contact_id is null) desc,",
  "     (l.contact_id is null) desc,  -- broken not first",
  "-- broken not first")

m("the never-chased are not before the rest",
  "report_collections",
  "     (l.contact_id is null) desc,\n     o.oldest_days desc;",
  "     o.oldest_days desc;  -- never-chased not first",
  "-- never-chased not first")

m("the oldest debt is last",
  "report_collections",
  "     o.oldest_days desc;",
  "     o.oldest_days asc;  -- oldest last",
  "-- oldest last")

m("debit notes are not chased (0749)",
  "report_collections",
  "     where a.doc_kind in ('invoice', 'debit_note')",
  "     where a.doc_kind in ('invoice')  -- no dn",
  "-- no dn")

m("CONTROL: a comment inside the block",
  "report_collections",
  "  return query\n  with owed as (",
  "  return query\n  -- CONTROL\n  with owed as (",
  "-- CONTROL")
