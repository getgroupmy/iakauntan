# Mutants for the elimination engine under the consolidated trial
# balance (0739): app.group_intercompany_lines, which reads what one
# group company recorded against another, and app.group_eliminations,
# which takes out only the pairs whose two sides agree to the sen.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/group_consolidation.sql \
#       supabase/tests/mutants/group_eliminations.py
#
# then group_shapes.sql.
#
# RESULT, 6 October: 18 mutants, 17 KILLED, 1 equivalent, control
# alive, across group_consolidation.sql and group_shapes.sql -- with no
# new assertion. group_shapes.sql alone kills 17.
#
# Equivalent: "a bank or tax line is eliminated" (the account filter
# dropped). Such a line falls through every `case` arm -- there is no
# `else` -- so its category and its amount are both NULL, and `having
# round(...) <> 0` is NULL for it and drops the row anyway. The code's
# own shape.

# -- app.group_intercompany_lines -------------------------------------------

m("a contact linked outside the group is inter-company",
  "group_intercompany_lines",
  "     and c.linked_org_id in (select org_id from orgs)\n     and c.linked_org_id <> l.org_id",
  "     and c.linked_org_id is not null  -- any linked\n     and c.linked_org_id <> l.org_id",
  "-- any linked")

m("a company trading with itself is inter-company",
  "group_intercompany_lines",
  "     and c.linked_org_id <> l.org_id",
  "     and true  -- self",
  "-- self")

m("a draft journal is eliminated",
  "group_intercompany_lines",
  "     and e.status = 'posted'\n     and e.entry_date <= p_to",
  "     and true  -- drafts\n     and e.entry_date <= p_to",
  "-- drafts")

m("the period has no end",
  "group_intercompany_lines",
  "     and e.entry_date <= p_to\n     and (p_from is null",
  "     and true  -- no end\n     and (p_from is null",
  "-- no end")

m("the period has no start",
  "group_intercompany_lines",
  "     and (p_from is null or e.entry_date >= p_from)\n     and (a.account_subtype",
  "     and true  -- no start\n     and (a.account_subtype",
  "-- no start")

m("a bank or tax line is eliminated",
  "group_intercompany_lines",
  "     and (a.account_subtype in ('accounts_receivable', 'accounts_payable')\n          or a.account_type in ('revenue', 'expense'))",
  "     and true  -- any account",
  "-- any account")

m("a receivable's magnitude has the wrong sign",
  "group_intercompany_lines",
  "         round(sum(case\n           when a.account_subtype = 'accounts_receivable' then l.debit - l.credit",
  "         round(sum(case\n           when a.account_subtype = 'accounts_receivable' then l.credit - l.debit  -- ar sign",
  "-- ar sign")

m("an expense's magnitude has the wrong sign",
  "group_intercompany_lines",
  "           when a.account_type    = 'expense'             then l.debit - l.credit\n         end), 2)\n    from",
  "           when a.account_type    = 'expense'             then l.credit - l.debit  -- exp sign\n         end), 2)\n    from",
  "-- exp sign")

m("a nil total is a line",
  "group_intercompany_lines",
  "         end), 2) <> 0;",
  "         end), 2) is not null;  -- nil lines",
  "-- nil lines")

# -- app.group_eliminations ------------------------------------------------------

m("a pair is eliminated whether or not the sides agree",
  "group_eliminations",
  "     where round(t.amount - o.amount, 2) = 0)",
  "     where true)  -- unmatched eliminated",
  "-- unmatched eliminated")

m("a receivable is matched against a receivable",
  "group_eliminations",
  "             when 'receivable' then 'payable'\n             when 'payable'    then 'receivable'",
  "             when 'receivable' then 'receivable'  -- r to r\n             when 'payable'    then 'receivable'",
  "-- r to r")

m("revenue is matched against revenue",
  "group_eliminations",
  "             when 'revenue'    then 'expense'\n             else 'revenue' end",
  "             when 'revenue'    then 'revenue'  -- rev to rev\n             else 'revenue' end",
  "-- rev to rev")

m("a receivable is eliminated the wrong way",
  "group_eliminations",
  "           when 'receivable' then -1   -- an asset comes down",
  "           when 'receivable' then 1  -- ar up",
  "-- ar up")

m("a payable is eliminated the wrong way",
  "group_eliminations",
  "           when 'payable'    then  1   -- a liability comes up toward zero",
  "           when 'payable'    then -1  -- ap down",
  "-- ap down")

m("revenue is eliminated the wrong way",
  "group_eliminations",
  "           when 'revenue'    then  1   -- revenue comes up toward zero",
  "           when 'revenue'    then -1  -- rev down",
  "-- rev down")

m("a cost is eliminated the wrong way",
  "group_eliminations",
  "           else                   -1   -- a cost comes down",
  "           else                    1  -- cost up",
  "-- cost up")

m("a matched receivable takes the other company's lines with it",
  "group_eliminations",
  "      on m.org_id = l.org_id and m.counterparty = l.counterparty\n     and m.category = l.category",
  "      on m.counterparty = l.counterparty  -- any side\n     and m.category = l.category",
  "-- any side")

m("CONTROL: a comment inside the block",
  "group_eliminations",
  "  -- A pair reconciles when the two sides agree exactly. Only then is",
  "  -- CONTROL\n  -- A pair reconciles when the two sides agree exactly. Only then is",
  "-- CONTROL")
