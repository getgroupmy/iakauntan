# Mutants for the three core statements (all last defined in 0739):
# public.report_trial_balance, public.report_profit_loss and
# public.report_balance_sheet. Every other report, the tax computation
# and the year-end close read one of these.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/financial_statements.sql \
#       supabase/tests/mutants/core_statements.py
#
# NOT A MUTANT: dropping the trial balance's `l.org_id = p_org_id`.
# Movements are only ever joined to accounts already filtered to the
# company, so another company's lines cannot reach a row. Equivalent by
# the join; left out rather than measured.

#
# RESULT, 6 October: 21 mutants, ALL 21 KILLED, control alive. Across the
# nineteen files that read these statements, only NINE died -- for the
# three functions every other report, the tax computation and the
# year-end close stand on. Twelve rules were unasserted: drafts counted
# (all three statements), an entry ON the from-date counted in both the
# opening and the period, journals after the as-at date, an account's
# own opening balance (left off the balance sheet; the wrong sign on a
# credit account's closing), group and deleted accounts listed, and --
# on all three -- the membership test that is the whole tenant boundary
# of a SECURITY DEFINER report. An existing "a stranger cannot read
# either statement" covered two OTHER statements, which is how it read
# as coverage. financial_statements.sql's "three core statements, rule
# by rule" block kills all twelve, with dates chosen so each rule moves
# a number: before the period, on its first day, a draft inside it, and
# after the as-at.

m("an entry ON the from-date is counted in the opening AND the period",
  "report_trial_balance",
  "           sum(case when p_from is not null and e.entry_date < p_from",
  "           sum(case when p_from is not null and e.entry_date <= p_from  -- boundary doubled",
  "-- boundary doubled")

m("debits from before the period are counted in it",
  "report_trial_balance",
  "           sum(case when p_from is null or e.entry_date >= p_from\n"
  "                    then l.debit else 0 end) as dr,",
  "           sum(l.debit) as dr,  -- period start ignored for debits",
  "-- period start ignored for debits")

m("an unposted journal is on the trial balance",
  "report_trial_balance",
  "       and e.status = 'posted'\n       and e.entry_date <= p_to",
  "       and e.entry_date <= p_to  -- unposted counted",
  "-- unposted counted")

m("journals after the to-date are on the trial balance",
  "report_trial_balance",
  "       and e.status = 'posted'\n       and e.entry_date <= p_to",
  "       and e.status = 'posted'  -- to-date ignored",
  "-- to-date ignored")

m("an account's opening balance is the wrong way round on a credit account",
  "report_trial_balance",
  "               + case when a.account_type in ('asset','expense')\n"
  "                      then a.opening_balance else -a.opening_balance end, 2)\n    from",
  "               + a.opening_balance, 2)  -- ob sign dropped\n    from",
  "-- ob sign dropped")

m("an account's opening balance is left out of the closing balance",
  "report_trial_balance",
  "               + case when a.account_type in ('asset','expense')\n"
  "                      then a.opening_balance else -a.opening_balance end, 2)\n    from",
  "               + 0, 2)  -- ob dropped from closing\n    from",
  "-- ob dropped from closing")

m("group accounts appear on the trial balance",
  "report_trial_balance",
  "     and not a.is_group\n     and app.is_org_member(p_org_id)\n   order by a.code;",
  "     and app.is_org_member(p_org_id)  -- groups listed\n   order by a.code;",
  "-- groups listed")

m("a deleted account appears on the trial balance",
  "report_trial_balance",
  "     and a.deleted_at is null\n     and not a.is_group",
  "     and not a.is_group  -- deleted listed",
  "-- deleted listed")

m("a non-member reads the trial balance",
  "report_trial_balance",
  "     and app.is_org_member(p_org_id)\n   order by a.code;",
  "   order by a.code;  -- membership dropped",
  "-- membership dropped")

m("revenue is reported as a negative",
  "report_profit_loss",
  "                        then l.credit - l.debit",
  "                        then l.debit - l.credit  -- revenue sign flipped",
  "-- revenue sign flipped")

m("the profit and loss runs from the beginning of time",
  "report_profit_loss",
  "     and e.entry_date between p_from and p_to",
  "     and e.entry_date <= p_to  -- from ignored",
  "-- from ignored")

m("an unposted journal is in the profit and loss",
  "report_profit_loss",
  "     and e.status = 'posted'\n     and e.entry_date between p_from and p_to",
  "     and e.entry_date between p_from and p_to  -- unposted counted",
  "-- unposted counted")

m("balance sheet accounts are in the profit and loss",
  "report_profit_loss",
  "     and a.account_type in ('revenue', 'expense')\n",
  "     -- any account type\n",
  "-- any account type")

m("accounts that net to nothing are listed",
  "report_profit_loss",
  "  having sum(l.debit - l.credit) <> 0\n",
  "  -- zero rows kept\n",
  "-- zero rows kept")

m("a non-member reads the profit and loss",
  "report_profit_loss",
  "     and app.is_org_member(p_org_id)\n   group by a.id, a.code, a.name, a.account_type, a.account_subtype\n  having",
  "     -- membership dropped\n   group by a.id, a.code, a.name, a.account_type, a.account_subtype\n  having",
  "-- membership dropped\n   group by a.id, a.code, a.name, a.account_type, a.account_subtype\n  having")

m("liabilities and equity are shown as debit balances",
  "report_balance_sheet",
  "                else l.credit - l.debit end), 0) + a.opening_balance, 2) as balance",
  "                else l.debit - l.credit end), 0) + a.opening_balance, 2) as balance  -- one sign",
  "-- one sign")

m("an account's opening balance is left off the balance sheet",
  "report_balance_sheet",
  "                else l.credit - l.debit end), 0) + a.opening_balance, 2) as balance",
  "                else l.credit - l.debit end), 0), 2) as balance  -- ob dropped",
  "-- ob dropped")

m("journals after the as-at date are on the balance sheet",
  "report_balance_sheet",
  "         and e.status = 'posted' and e.entry_date <= p_as_at",
  "         and e.status = 'posted'  -- as-at ignored",
  "-- as-at ignored")

m("an unposted journal is on the balance sheet",
  "report_balance_sheet",
  "         and e.status = 'posted' and e.entry_date <= p_as_at",
  "         and e.entry_date <= p_as_at  -- unposted counted",
  "-- unposted counted")

m("profit and loss accounts are on the balance sheet",
  "report_balance_sheet",
  "     and a.account_type in ('asset', 'liability', 'equity')\n",
  "     -- any account type\n",
  "-- any account type")

m("a non-member reads the balance sheet",
  "report_balance_sheet",
  "     and app.is_org_member(p_org_id)\n   group by a.id, a.code, a.name, a.account_type, a.account_subtype, a.opening_balance",
  "     -- BS membership dropped\n   group by a.id, a.code, a.name, a.account_type, a.account_subtype, a.opening_balance",
  "-- BS membership dropped")

m("CONTROL -- a comment inside the function block",
  "report_balance_sheet",
  "   order by a.code;",
  "   order by a.code;  -- CONTROL: this cannot change a figure.",
  "-- CONTROL: this cannot change a figure.")
