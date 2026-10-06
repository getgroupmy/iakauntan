# Mutants for public.report_general_ledger (0458) -- the ledger itself:
# for each account, a line brought forward and then every posted line in
# the period, with a running balance that has to follow from the lines
# above it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0458_the_ledger_itself.sql \
#       supabase/tests/general_ledger.sql \
#       supabase/tests/mutants/report_general_ledger.py
#
# RESULT, 6 October: 28 mutants, 27 KILLED, 1 equivalent, control
# alive, on general_ledger.sql alone. 15 died before "The ledger, rule
# by rule" was added: the fixture had one company, one period start
# that fell between entries, opening balances only on an asset, no
# drafts before the period, no contact, and every journal posted in
# date order -- so a running balance ordered by entry number agreed
# with one ordered by date.
#
# Equivalent: the brought-forward sum reading another company's lines.
# It already filters to this company's account, and
# `gl_lines_account_same_org` ties a line's company to its account's.
# A table constraint.

m("with no end date the ledger stops a year ago",
  "report_general_ledger",
  "    select coalesce(p_to, app.today()) as upto",
  "    select coalesce(p_to, app.today() - 365) as upto  -- year ago",
  "-- year ago")

m("another company's accounts are listed",
  "report_general_ledger",
  "     where a.org_id = p_org_id\n       and a.deleted_at is null",
  "     where true  -- any org account\n       and a.deleted_at is null",
  "-- any org account")

m("a deleted account is listed",
  "report_general_ledger",
  "     where a.org_id = p_org_id\n       and a.deleted_at is null",
  "     where a.org_id = p_org_id\n       and true  -- deleted account",
  "-- deleted account")

m("group headings are listed as accounts",
  "report_general_ledger",
  "       and not a.is_group",
  "       and true  -- groups",
  "-- groups")

m("asking for one account gives every account",
  "report_general_ledger",
  "       and (p_account_id is null or a.id = p_account_id)",
  "       and true  -- every account",
  "-- every account")

m("the brought-forward balance leaves out unposted entries' absence: drafts count",
  "report_general_ledger",
  "                and e.status = 'posted'\n                and p_from is not null",
  "                and true  -- draft opening\n                and p_from is not null",
  "-- draft opening")

m("the brought-forward balance includes the first day of the period",
  "report_general_ledger",
  "                and e.entry_date < p_from), 0)",
  "                and e.entry_date <= p_from), 0)  -- le",
  "-- le")

m("nothing is brought forward from earlier entries",
  "report_general_ledger",
  "                and e.entry_date < p_from), 0)",
  "                and false), 0)  -- no prior",
  "-- no prior")

m("the account's own opening balance is left out",
  "report_general_ledger",
  "           + case when w.account_type in ('asset', 'expense')\n                  then w.opening_balance else -w.opening_balance end",
  "           + 0  -- no opening",
  "-- no opening")

m("a liability's opening balance is signed as a debit",
  "report_general_ledger",
  "           + case when w.account_type in ('asset', 'expense')\n                  then w.opening_balance else -w.opening_balance end",
  "           + w.opening_balance  -- unsigned",
  "-- unsigned")

m("an expense's opening balance is signed as a credit",
  "report_general_ledger",
  "           + case when w.account_type in ('asset', 'expense')",
  "           + case when w.account_type in ('asset')  -- expense credit",
  "-- expense credit")

m("the brought-forward sum reads another company's lines",
  "report_general_ledger",
  "              where l.account_id = w.id\n                and l.org_id = p_org_id",
  "              where l.account_id = w.id\n                and true  -- any org opening",
  "-- any org opening")

m("draft entries are listed",
  "report_general_ledger",
  "     where l.org_id = p_org_id\n       and e.status = 'posted'\n       and e.entry_date <= b.upto",
  "     where l.org_id = p_org_id\n       and true  -- draft lines\n       and e.entry_date <= b.upto",
  "-- draft lines")

m("entries after the end date are listed",
  "report_general_ledger",
  "       and e.entry_date <= b.upto",
  "       and true  -- after end",
  "-- after end")

m("entries before the start date are listed",
  "report_general_ledger",
  "       and (p_from is null or e.entry_date >= p_from)",
  "       and true  -- before start",
  "-- before start")

m("the period excludes its own first day",
  "report_general_ledger",
  "       and (p_from is null or e.entry_date >= p_from)",
  "       and (p_from is null or e.entry_date > p_from)  -- gt",
  "-- gt")

m("the running balance is credits minus debits",
  "report_general_ledger",
  "           o.amount + sum(l.debit - l.credit) over (",
  "           o.amount + sum(l.credit - l.debit) over (  -- flipped",
  "-- flipped")

m("the running balance starts from nothing",
  "report_general_ledger",
  "           o.amount + sum(l.debit - l.credit) over (",
  "           0 + sum(l.debit - l.credit) over (  -- no bf",
  "-- no bf")

m("the running balance runs across accounts",
  "report_general_ledger",
  "             partition by l.account_id\n             order by l.entry_date",
  "             partition by true  -- across\n             order by l.entry_date",
  "-- across")

m("the running balance is the account's total on every line",
  "report_general_ledger",
  "             rows between unbounded preceding and current row) as balance",
  "             rows between unbounded preceding and unbounded following) as balance  -- total",
  "-- total")

m("the running balance runs in entry-number order before date",
  "report_general_ledger",
  "             order by l.entry_date, l.entry_no, l.line_no, l.created_at",
  "             order by l.entry_no, l.entry_date, l.line_no, l.created_at  -- no first",
  "-- no first")

m("an empty account is listed with a nil line brought forward",
  "report_general_ledger",
  "     and (o.amount <> 0\n          or exists (select 1 from lines l where l.account_id = w.id))",
  "     and (true  -- empty\n          or exists (select 1 from lines l where l.account_id = w.id))",
  "-- empty")

m("an account with only a balance brought forward is left off",
  "report_general_ledger",
  "     and (o.amount <> 0\n          or exists (select 1 from lines l where l.account_id = w.id))",
  "     and (false  -- bf only\n          or exists (select 1 from lines l where l.account_id = w.id))",
  "-- bf only")

m("an account with lines but nothing brought forward has no first line",
  "report_general_ledger",
  "     and (o.amount <> 0\n          or exists (select 1 from lines l where l.account_id = w.id))",
  "     and (o.amount <> 0  -- lines only\n          )",
  "-- lines only")

m("a stranger reads the lines brought forward",
  "report_general_ledger",
  "    join opening o on o.account_id = w.id\n   where app.is_org_member(p_org_id)",
  "    join opening o on o.account_id = w.id\n   where true  -- stranger bf",
  "-- stranger bf")

m("a stranger reads the movements",
  "report_general_ledger",
  "    from running r\n   where app.is_org_member(p_org_id)",
  "    from running r\n   where true  -- stranger lines",
  "-- stranger lines")

m("the line brought forward is printed after the movements",
  "report_general_ledger",
  "   order by 2, 15 desc, 5, 6, 7;",
  "   order by 2, 15, 5, 6, 7;  -- bf last",
  "-- bf last")

m("the contact is not named",
  "report_general_ledger",
  "      left join public.contacts c on c.id = l.contact_id",
  "      left join public.contacts c on false  -- no contact",
  "-- no contact")

m("CONTROL: a comment inside the block",
  "report_general_ledger",
  "  running as (",
  "  -- CONTROL\n  running as (",
  "-- CONTROL")
