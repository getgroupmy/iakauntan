# Mutants for public.report_cash_flow (0100) -- the indirect cash flow
# statement: profit, the depreciation add-back, working capital,
# investing and financing, and a reconciliation that proves itself
# against the bank and cash accounts.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0100_cash_flow_and_equity.sql \
#       supabase/tests/financial_statements.sql \
#       supabase/tests/mutants/report_cash_flow.py
#
# RESULT, 6 October: 27 mutants, ALL 27 KILLED, control alive, on
# financial_statements.sql. 12 died before "The cash flow statement,
# rule by rule" was added -- one year with every journal inside it, no
# opening balances, no drafts, one company, a bank as the only cash.
# The first run stopped at a mutant that named `'none'` as an account
# subtype, which is not in the enum: a harness error, not a kill, and
# every mutant after it unrun. Rewritten to name `'reserves'`.

m("another company's lines move this company's cash",
  "report_cash_flow",
  "     where l.org_id = p_org_id\n       and e.status = 'posted'\n       and e.entry_date between p_from and p_to",
  "     where true  -- any org\n       and e.status = 'posted'\n       and e.entry_date between p_from and p_to",
  "-- any org")

m("a draft journal moves cash",
  "report_cash_flow",
  "     where l.org_id = p_org_id\n       and e.status = 'posted'\n       and e.entry_date between p_from and p_to",
  "     where l.org_id = p_org_id\n       and true  -- draft\n       and e.entry_date between p_from and p_to",
  "-- draft")

m("the period has no start",
  "report_cash_flow",
  "       and e.entry_date between p_from and p_to\n       and e.source <> 'year_end_close'",
  "       and e.entry_date <= p_to  -- no start\n       and e.source <> 'year_end_close'",
  "-- no start")

m("the period has no end",
  "report_cash_flow",
  "       and e.entry_date between p_from and p_to\n       and e.source <> 'year_end_close'",
  "       and e.entry_date >= p_from  -- no end\n       and e.source <> 'year_end_close'",
  "-- no end")

m("the year-end close is read as a movement",
  "report_cash_flow",
  "       and e.source <> 'year_end_close'",
  "       and true  -- close counted",
  "-- close counted")

m("contributions are the ledger's sign, not cash's",
  "report_cash_flow",
  "           round(-sum(l.debit - l.credit), 2) as contributed",
  "           round(sum(l.debit - l.credit), 2) as contributed  -- ledger sign",
  "-- ledger sign")

m("a cash account is read as working capital",
  "report_cash_flow",
  "             when m.account_subtype in ('bank', 'cash') then 'cash'",
  "             when m.account_subtype in ('bank') then 'cash'  -- cash box wc",
  "-- cash box wc")

m("revenue is left out of profit",
  "report_cash_flow",
  "             when m.account_type in ('revenue', 'expense') then 'profit'",
  "             when m.account_type in ('expense') then 'profit'  -- no revenue",
  "-- no revenue")

m("expenses are left out of profit",
  "report_cash_flow",
  "             when m.account_type in ('revenue', 'expense') then 'profit'",
  "             when m.account_type in ('revenue') then 'profit'  -- no expense",
  "-- no expense")

m("accumulated depreciation is investing",
  "report_cash_flow",
  "             when m.account_subtype = 'accumulated_depreciation' then 'noncash'",
  "             when m.account_subtype = 'accumulated_depreciation' then 'investing'  -- acc dep inv",
  "-- acc dep inv")

m("fixed assets are working capital",
  "report_cash_flow",
  "             when m.account_subtype in ('fixed_asset', 'other_asset')\n               then 'investing'",
  "             when m.account_subtype in ('other_asset')  -- fa wc\n               then 'investing'",
  "-- fa wc")

m("long-term loans are working capital",
  "report_cash_flow",
  "             when m.account_subtype in ('long_term_liability', 'share_capital',",
  "             when m.account_subtype in ('share_capital',  -- loan wc",
  "-- loan wc")

m("share capital is working capital",
  "report_cash_flow",
  "             when m.account_subtype in ('long_term_liability', 'share_capital',",
  "             when m.account_subtype in ('long_term_liability',  -- capital wc",
  "-- capital wc")

m("drawings are working capital",
  "report_cash_flow",
  "                                        'drawings') then 'financing'",
  "                                        'reserves') then 'financing'  -- drawings wc",
  "-- drawings wc")

m("cash brought forward includes the first day of the period",
  "report_cash_flow",
  "                   and e.entry_date < p_from), 0)",
  "                   and e.entry_date <= p_from), 0)  -- le",
  "-- le")

m("cash brought forward forgets the opening balances",
  "report_cash_flow",
  "                   and e.entry_date < p_from), 0)\n    + coalesce((select sum(a.opening_balance) from public.accounts a",
  "                   and e.entry_date < p_from), 0)\n    + 0 * coalesce((select sum(a.opening_balance) from public.accounts a  -- no ob",
  "-- no ob")

m("cash carried forward forgets the opening balances",
  "report_cash_flow",
  "                   and e.entry_date <= p_to), 0)\n    + coalesce((select sum(a.opening_balance) from public.accounts a",
  "                   and e.entry_date <= p_to), 0)\n    + 0 * coalesce((select sum(a.opening_balance) from public.accounts a  -- no cb ob",
  "-- no cb ob")

m("cash carried forward stops the day before the end",
  "report_cash_flow",
  "                   and e.entry_date <= p_to), 0)",
  "                   and e.entry_date < p_to), 0)  -- lt",
  "-- lt")

m("cash brought forward counts drafts",
  "report_cash_flow",
  "                 where l.org_id = p_org_id and e.status = 'posted'\n                   and a.account_subtype in ('bank', 'cash')\n                   and e.entry_date < p_from), 0)",
  "                 where l.org_id = p_org_id  -- bf drafts\n                   and a.account_subtype in ('bank', 'cash')\n                   and e.entry_date < p_from), 0)",
  "-- bf drafts")

m("cash brought forward reads another company",
  "report_cash_flow",
  "                 where l.org_id = p_org_id and e.status = 'posted'\n                   and a.account_subtype in ('bank', 'cash')\n                   and e.entry_date < p_from), 0)",
  "                 where e.status = 'posted'  -- bf any org\n                   and a.account_subtype in ('bank', 'cash')\n                   and e.entry_date < p_from), 0)",
  "-- bf any org")

m("a deleted bank account's opening balance is cash",
  "report_cash_flow",
  "                 where a.org_id = p_org_id and a.deleted_at is null\n                   and not a.is_group\n                   and a.account_subtype in ('bank', 'cash')), 0) as opening,",
  "                 where a.org_id = p_org_id\n                   and not a.is_group  -- deleted ob\n                   and a.account_subtype in ('bank', 'cash')), 0) as opening,",
  "-- deleted ob")

m("the depreciation line shows at nil",
  "report_cash_flow",
  "      having coalesce(sum(c.contributed), 0) <> 0",
  "      having true  -- nil dep",
  "-- nil dep")

m("working capital lines that did not move are listed",
  "report_cash_flow",
  "     where c.bucket = 'working_capital' and c.contributed <> 0",
  "     where c.bucket = 'working_capital'  -- nil wc",
  "-- nil wc")

m("investing is left off",
  "report_cash_flow",
  "     where c.bucket = 'investing' and c.contributed <> 0",
  "     where false  -- no investing",
  "-- no investing")

m("financing is left off",
  "report_cash_flow",
  "     where c.bucket = 'financing' and c.contributed <> 0",
  "     where false  -- no financing",
  "-- no financing")

m("the net movement includes the cash accounts themselves",
  "report_cash_flow",
  "                      where c.bucket <> 'cash'), 0), 10",
  "                      where true), 0), 10  -- nets to nil",
  "-- nets to nil")

m("a stranger reads the statement",
  "report_cash_flow",
  "   where app.is_org_member(p_org_id)",
  "   where true  -- stranger",
  "-- stranger")

m("CONTROL: a comment inside the block",
  "report_cash_flow",
  "  cash_now as (",
  "  -- CONTROL\n  cash_now as (",
  "-- CONTROL")
