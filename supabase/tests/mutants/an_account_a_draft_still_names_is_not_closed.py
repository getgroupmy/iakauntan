# Mutants for 0922 -- retire_account refuses an account that a document
# not yet posted still names. Only the lines 0922 added are mutated;
# 0921's are swept by an_account_still_named_is_not_closed.py.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0922_an_account_a_draft_still_names_is_not_closed.sql \
#       supabase/tests/an_account_a_draft_still_names_is_not_closed.sql \
#       supabase/tests/mutants/an_account_a_draft_still_names_is_not_closed.py

F = 'retire_account'

SALES_HEAD = ("            from public.sales_documents d\n"
              "           where d.org_id = v_a.org_id\n"
              "             and d.deleted_at is null\n")
PURCH_HEAD = ("            from public.purchase_documents d\n"
              "           where d.org_id = v_a.org_id\n"
              "             and d.deleted_at is null\n")
STATUS = "             and d.status in ('draft', 'pending', 'approved')\n"
NOT_CX = "             and d.fulfilment_status <> 'cancelled'\n"
SALES_POSTS = "             and (d.doc_type in ('invoice', 'credit_note', 'debit_note', 'refund_note')\n"
PURCH_POSTS = "             and (d.doc_type in ('bill', 'purchase_credit_note', 'purchase_debit_note')\n"
NOT_DONE = "                  or d.fulfilment_status <> 'fulfilled')\n"

for side, head, posts in [('sales', SALES_HEAD, SALES_POSTS), ('purchase', PURCH_HEAD, PURCH_POSTS)]:
    m('%s documents are not asked' % side,
      F, head + STATUS,
      head + "             and false /* no %s */\n" % side,
      '/* no %s */' % side)

    m('a removed %s document still holds its accounts open' % side,
      F, head,
      head.replace("             and d.deleted_at is null\n",
                   "             /* removed %s too */\n" % side),
      '/* removed %s too */' % side)

    m('only a %s document still a draft is asked' % side,
      F, head + STATUS,
      head + "             and d.status in ('draft' /* %s drafts only */)\n" % side,
      '/* %s drafts only */' % side)

    m('a %s document voided or rejected still holds its accounts open' % side,
      F, head + STATUS,
      head + "             /* any %s status */\n" % side,
      '/* any %s status */' % side)

    m('a cancelled %s order still holds its accounts open' % side,
      F, head + STATUS + NOT_CX,
      head + STATUS + "             /* cancelled %s too */\n" % side,
      '/* cancelled %s too */' % side)

    m('a %s order all carried on still holds its accounts open' % side,
      F, posts + NOT_DONE,
      posts + "                  or true /* %s done too */)\n" % side,
      '/* %s done too */' % side)

    m('a %s document that posts is let go once its goods have moved' % side,
      F, posts + NOT_DONE,
      "             and (false /* %s posts */\n" % side + NOT_DONE,
      '/* %s posts */' % side)

m('a sales document is asked for any line in the company, not its own',
  F,
  "             and exists (select 1 from public.sales_document_lines l\n"
  "                          where l.document_id = d.id and l.account_id = p_id)\n",
  "             and exists (select 1 from public.sales_document_lines l\n"
  "                          where l.account_id = p_id /* any sales line */)\n",
  '/* any sales line */')

m('a purchase document is asked for any line in the company, not its own',
  F,
  "             and exists (select 1 from public.purchase_document_lines l\n"
  "                          where l.document_id = d.id and l.account_id = p_id)\n",
  "             and exists (select 1 from public.purchase_document_lines l\n"
  "                          where l.account_id = p_id /* any purchase line */)\n",
  '/* any purchase line */')

m('an invoice not yet posted is called open, and an order unposted',
  F,
  "          select 10, case when d.doc_type in ('invoice', 'credit_note', 'debit_note', 'refund_note')\n"
  "                          then 'unposted ' else 'open ' end\n",
  "          select 10, case when d.doc_type in ('invoice', 'credit_note', 'debit_note', 'refund_note')\n"
  "                          then 'open ' else 'unposted ' /* swapped */ end\n",
  '/* swapped */')

# --- expenses ----------------------------------------------------------
EXP_HEAD = ("            from public.expenses e\n"
            "           where e.org_id = v_a.org_id\n")

m('expenses are not asked',
  F, EXP_HEAD,
  EXP_HEAD + "             and false /* no expenses */\n",
  '/* no expenses */')

m('a removed expense still holds its account open',
  F, EXP_HEAD + "             and e.deleted_at is null\n",
  EXP_HEAD + "             /* removed expense too */\n",
  '/* removed expense too */')

m('a voided expense still holds its account open',
  F,
  "             and e.status in ('draft', 'pending', 'approved')\n",
  "             /* any expense status */\n",
  '/* any expense status */')

m("an expense's own account is not asked, only its split",
  F,
  "             and (e.account_id = p_id\n",
  "             and (false /* header free */\n",
  '/* header free */')

m("an expense's split is not asked, only its own account",
  F,
  "                  or exists (select 1 from public.expense_lines l\n"
  "                              where l.expense_id = e.id and l.account_id = p_id))\n",
  "                  or false /* split free */)\n",
  '/* split free */')

# --- stock adjustments -------------------------------------------------
m('stock adjustments are not asked',
  F,
  "             and s.account_id = p_id\n"
  "             and s.status in ('draft', 'pending', 'approved')\n",
  "             and s.account_id = p_id and false /* no adjustments */\n"
  "             and s.status in ('draft', 'pending', 'approved')\n",
  '/* no adjustments */')

m('a voided stock adjustment still holds its account open',
  F,
  "             and s.account_id = p_id\n"
  "             and s.status in ('draft', 'pending', 'approved')\n",
  "             and s.account_id = p_id\n"
  "             /* any adjustment status */\n",
  '/* any adjustment status */')

m('CONTROL: a comment inside the function',
  F,
  "          -- 0922: and what is written and has yet to post. A line's\n",
  "          -- 0922: and what is written and has yet to post. A line's (control)\n",
  '(control)')
