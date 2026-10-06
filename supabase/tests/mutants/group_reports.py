# Mutants for the group reports (0739): the combined trial balance, the
# consolidated one (combined plus eliminations), the elimination check,
# and the intercompany listing it is built from.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/group_consolidation.sql \
#       supabase/tests/mutants/group_reports.py
#
# then group_reporting.sql, group_shapes.sql, group_trial_balance_shapes.sql.
#
# RESULT, 6 October: 29 mutants, ALL 29 KILLED, control alive, across
# group_consolidation.sql, group_reporting.sql, group_shapes.sql and
# group_trial_balance_shapes.sql. Three of the four reports were already
# held from every side. `report_group_intercompany` was asked one
# question -- one invoice, dated today -- and lost 10 of its 11 until
# group_reporting.sql's "The inter-company listing, rule by rule" gave
# it a period with entries before, inside and after it, a draft, the
# other side's payable and expense, a company in the group the reader
# cannot see, a nil line, and a reader from outside.

# -- report_group_trial_balance -------------------------------------------

m("a stranger reads the group",
  "report_group_trial_balance",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- stranger",
  "-- stranger")

m("a company in no group gets an empty report, not a refusal",
  "report_group_trial_balance",
  "  if v_currencies is null then",
  "  if false then  -- no group",
  "-- no group")

m("companies in different currencies are added together",
  "report_group_trial_balance",
  "  if array_length(v_currencies, 1) > 1 then",
  "  if false then  -- any currencies",
  "-- any currencies")

m("the company count is one",
  "report_group_trial_balance",
  "         count(*)::integer,\n         round(sum(p.opening_balance), 2),",
  "         1,  -- one company\n         round(sum(p.opening_balance), 2),",
  "-- one company")

m("debits are not summed across the group",
  "report_group_trial_balance",
  "         round(sum(p.debit), 2),",
  "         round(max(p.debit), 2),  -- max debit",
  "-- max debit")

m("closing balances are not summed across the group",
  "report_group_trial_balance",
  "         round(sum(p.closing_balance), 2)\n    from per_company p",
  "         round(max(p.closing_balance), 2)  -- max closing\n    from per_company p",
  "-- max closing")

m("an account nobody used is listed",
  "report_group_trial_balance",
  "  having sum(abs(p.opening_balance)) + sum(p.debit) + sum(p.credit) <> 0",
  "  having true  -- empty accounts",
  "-- empty accounts")

m("an account with only an opening balance is left off",
  "report_group_trial_balance",
  "  having sum(abs(p.opening_balance)) + sum(p.debit) + sum(p.credit) <> 0",
  "  having sum(p.debit) + sum(p.credit) <> 0  -- no opening",
  "-- no opening")

# -- report_group_consolidated_trial_balance --------------------------------

m("a partly owned subsidiary is consolidated as if wholly owned",
  "report_group_consolidated_trial_balance",
  "  if v_partial is not null then",
  "  if false then  -- partial",
  "-- partial")

m("a subsidiary may run the consolidation",
  "report_group_consolidated_trial_balance",
  "  if v_parent is not null then",
  "  if false then  -- from a subsidiary",
  "-- from a subsidiary")

m("a company nobody has said owns is consolidated",
  "report_group_consolidated_trial_balance",
  "  if v_unowned is not null then",
  "  if false then  -- unowned",
  "-- unowned")

m("a wholly owned subsidiary is refused as partial",
  "report_group_consolidated_trial_balance",
  "     and o.owned_percent < 100;",
  "     and o.owned_percent <= 100;  -- le",
  "-- le")

m("eliminations are not applied",
  "report_group_consolidated_trial_balance",
  "         round(t.closing_balance + coalesce(e.adjustment, 0), 2)",
  "         round(t.closing_balance, 2)  -- no elimination",
  "-- no elimination")

m("eliminations are applied the wrong way",
  "report_group_consolidated_trial_balance",
  "         round(t.closing_balance + coalesce(e.adjustment, 0), 2)",
  "         round(t.closing_balance - coalesce(e.adjustment, 0), 2)  -- flipped",
  "-- flipped")

# -- report_group_elimination_check ------------------------------------------

m("a stranger checks the group's eliminations",
  "report_group_elimination_check",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- stranger",
  "-- stranger")

m("a receivable is matched against the other side's receivable",
  "report_group_elimination_check",
  "       and p.category = 'payable'",
  "       and p.category = 'receivable'  -- wrong side",
  "-- wrong side")

m("revenue is matched against the other side's revenue",
  "report_group_elimination_check",
  "       and x.category = 'expense'",
  "       and x.category = 'revenue'  -- wrong side",
  "-- wrong side")

m("a balance the other side never recorded is not a difference",
  "report_group_elimination_check",
  "           coalesce(p.amount, 0) as b_side",
  "           coalesce(p.amount, r.amount) as b_side  -- assumed matched",
  "-- assumed matched")

m("everything is eliminated",
  "report_group_elimination_check",
  "         round(pairs.a_side - pairs.b_side, 2) = 0\n    from pairs",
  "         true  -- all eliminated\n    from pairs",
  "-- all eliminated")

m("trading is never checked",
  "report_group_elimination_check",
  "     where s.category = 'revenue')",
  "     where false)  -- no trading",
  "-- no trading")

# -- report_group_intercompany -------------------------------------------------

m("a stranger reads the intercompany listing",
  "report_group_intercompany",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- stranger",
  "-- stranger")

m("a contact that is no group company is intercompany",
  "report_group_intercompany",
  "       and c.linked_org_id in (select org_id from orgs)",
  "       and c.linked_org_id is not null  -- any linked",
  "-- any linked")

m("a draft journal is intercompany",
  "report_group_intercompany",
  "       and e.status = 'posted'\n       and e.entry_date <= p_to",
  "       and true  -- drafts\n       and e.entry_date <= p_to",
  "-- drafts")

m("the period has no end",
  "report_group_intercompany",
  "       and e.entry_date <= p_to\n       and (p_from is null or e.entry_date >= p_from))",
  "       and true  -- no end\n       and (p_from is null or e.entry_date >= p_from))",
  "-- no end")

m("the period has no start",
  "report_group_intercompany",
  "       and (p_from is null or e.entry_date >= p_from))",
  "       and true)  -- no start",
  "-- no start")

m("a receivable is read the wrong way round",
  "report_group_intercompany",
  "         round(sum(case when l.account_subtype = 'accounts_receivable'\n                        then l.debit - l.credit else 0 end), 2),",
  "         round(sum(case when l.account_subtype = 'accounts_receivable'\n                        then l.credit - l.debit else 0 end), 2),  -- ar flipped",
  "-- ar flipped")

m("a payable is read the wrong way round",
  "report_group_intercompany",
  "                        then l.credit - l.debit else 0 end), 2),\n         round(sum(case when l.account_type = 'revenue'",
  "                        then l.debit - l.credit else 0 end), 2),  -- ap flipped\n         round(sum(case when l.account_type = 'revenue'",
  "-- ap flipped")

m("expenses are not intercompany",
  "report_group_intercompany",
  "         round(sum(case when l.account_type = 'expense'\n                        then l.debit - l.credit else 0 end), 2)",
  "         0::numeric  -- no expense",
  "-- no expense")

m("a contact with nothing posted is listed",
  "report_group_intercompany",
  "  having sum(abs(l.debit)) + sum(abs(l.credit)) <> 0",
  "  having true  -- empty",
  "-- empty")

m("CONTROL: a comment inside the block",
  "report_group_intercompany",
  "  return query\n  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),\n  lines as (",
  "  return query\n  -- CONTROL\n  with orgs as (select g.org_id from app.group_orgs(p_org_id) g),\n  lines as (",
  "-- CONTROL")
