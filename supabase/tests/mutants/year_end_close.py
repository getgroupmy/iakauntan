# Mutants for public.close_fiscal_year and public.reopen_fiscal_year --
# the year-end sweep that empties every profit and loss account into
# Current Year Earnings, and the reversal that puts it back.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0648_the_close_the_schema_was_waiting_for.sql \
#       supabase/tests/year_end_close.sql \
#       supabase/tests/mutants/year_end_close.py
#
# then again against `idempotency.sql`.
#
# RESULT, 5 October: 32 mutants plus a control. 15 killed on
# `year_end_close.sql` and 16 survived; `idempotency.sql` kills one more
# that this file misses.
#
# CORRECTED the same evening, and the correction is the interesting
# part. The figure was recorded as 30 of 31 with one equivalent. The
# harness's new pre-flight then found that the mutant "a profit and loss
# account with NO movement gets a line of nothing" had been swallowing
# `order by p.code` -- so it was a DOUBLE mutant, and its kill was the
# ordering's. Re-measured with the marker terminated properly, it
# survives, and it survives because `report_profit_loss` already ends
# with `having sum(l.debit - l.credit) <> 0` and never returns a nil
# account at all.
#
# So: 29 of 30 killable, with TWO proven equivalent. One fewer killable
# mutant and one more equivalence than the first measurement said, and
# the same 29 real kills. The control lived throughout.
#
#   year_end_close.sql  kills 15, then 28
#   idempotency.sql     kills "a year that is not closed can be
#                       reopened", via refuses_a_repeat
#
# ONE CAUSE ACCOUNTED FOR MOST OF THE SIXTEEN: **every block in the
# file closed exactly one year.** Both ordering rules have three
# conjuncts -- the company, the status, and the date comparison -- and
# only the date comparison can be stood on by a fixture that never
# closes a second year. Dropping `status = 'open'` from the close's
# earlier-year rule means a company can never close its SECOND year,
# because the first one being properly shut still blocks; and the
# reopen's later-year rule was not asserted at all, in any of its three
# parts. Two years, closed in order and reopened in the other order, is
# the fixture; and a stranger's 2024 (open) and 2027 (closed) are what
# make the two org scopes observable, since every other company in the
# file has a year starting on the same day as ours and `<` is strict.
#
# The rest were stamps and shapes that balance: the closing journal's
# DATE and description, `closed_at`, `closed_by`, the three fields a
# reopen has to CLEAR, and the reversal's date. Every one of them is
# invisible to a balance check, and five of them are invisible to any
# figure at all.
#
# AND A BREAK-EVEN YEAR, which nothing had ever closed. `if v_profit
# <> 0` is the whole of "no result line when there is no result", and a
# fixture that always trades at a profit or a loss cannot see it: the
# widened test posts a line of two zeroes to equity, the journal still
# balances, and every figure asserted elsewhere is unchanged. Only the
# LINE COUNT sees it.
#
# This pair is the largest single journal the application posts -- one
# line per P&L account with movement, plus the result -- and the one
# whose defects are hardest to see, because EVERY mutation of the sign
# or the sides still balances. The revenue debits and the expense
# credits net to exactly the result, so a journal that sweeps the wrong
# way balances as neatly as one that sweeps the right way and reads as
# a profitable year on the face of the balance sheet. The file already
# knows this; its loss block exists for it.
#
# What a sweep can still find here is the ORDERING rules, which are two
# guards of the same shape in opposite directions:
#
#   close:  no EARLIER year may still be open
#   reopen: no LATER year may still be closed
#
# Each has three conjuncts -- the company, the status, and the date
# comparison -- and a fixture that closes exactly one year cannot stand
# on any of them.

m("anybody may close the year",
  "close_fiscal_year",
  "  if not app.can_admin(f.org_id) then\n"
  "    raise exception 'Only an owner or an administrator may close a year'",
  "  if false then\n"
  "    raise exception 'Only an owner or an administrator may close a year'"
  "  -- close admin guard dropped",
  "-- close admin guard dropped")

m("a year already closed can be closed again",
  "close_fiscal_year",
  "  if f.status <> 'open' then",
  "  if false then  -- close status guard dropped",
  "-- close status guard dropped")

m("ANOTHER COMPANY's open year blocks this one's close",
  "close_fiscal_year",
  "   where y.org_id = f.org_id and y.status = 'open'\n"
  "     and y.start_date < f.start_date;",
  "   where y.status = 'open'\n"
  "     and y.start_date < f.start_date;  -- earlier-year org scope dropped",
  "-- earlier-year org scope dropped")

m("an earlier year already CLOSED still blocks this one",
  "close_fiscal_year",
  "   where y.org_id = f.org_id and y.status = 'open'\n"
  "     and y.start_date < f.start_date;",
  "   where y.org_id = f.org_id\n"
  "     and y.start_date < f.start_date;  -- earlier-year status dropped",
  "-- earlier-year status dropped")

m("a year counts as earlier than ITSELF, so nothing can ever close",
  "close_fiscal_year",
  "     and y.start_date < f.start_date;",
  "     and y.start_date <= f.start_date;  -- earlier-year boundary widened",
  "-- earlier-year boundary widened")

m("the earlier-year rule is dropped altogether",
  "close_fiscal_year",
  "  if v_earlier is not null then",
  "  if false then  -- earlier-year rule dropped",
  "-- earlier-year rule dropped")

# EQUIVALENT, proven by shape and by reading the other function rather
# than reasoned. `report_profit_loss` ends in
# `having sum(l.debit - l.credit) <> 0`, and its `amount` column is that
# same sum with the sign flipped for revenue -- a flip that cannot
# change whether a value is zero. So `where p.amount <> 0` can never
# exclude a row the report returned, and widening it to `is not null`
# excludes nothing either. No fixture can distinguish them.
#
# The finding is a COUPLING, not a gap: the filter is belt-and-braces
# resting on a property of a different function. Remove the `having`
# from report_profit_loss and this filter starts mattering the same day.
# `year_end_close.sql` now asserts the closing journal's LINE COUNT
# against the report's own row count, which is what would notice.
# EQUIVALENT, and this entry is a correction to the kill sheet below.
#
# The replacement used to omit its trailing newline, so the marker ran
# into `order by p.code` and commented it out. The mutant therefore did
# TWO things -- included nil accounts AND dropped the ordering -- and it
# was recorded as KILLED. The harness's pre-flight found the swallow on
# 5 October; with the newline restored the mutant was re-measured and
# **it SURVIVES**. The kill had been the ordering's all along.
#
# And it survives because it cannot be killed. `report_profit_loss`
# ends with
#
#     having sum(l.debit - l.credit) <> 0
#
# so it never returns an account with no movement, and `where
# p.amount <> 0` in the loop above can never be false. No fixture can
# distinguish the two forms.
#
# That is the FOURTH kind of equivalence proof this sweep has found --
# the guard is in the CALLEE -- and the second instance of it, after
# `run_depreciation`'s acquisition-date filter standing behind
# `accumulated_depreciation_at`'s own first line. Both were reached by
# asking what the called function already refuses.
#
# A double mutant masked a real question for a whole day: the one that
# mattered was not "is this condition asserted" but "can it ever fire".
m("a profit and loss account with NO movement gets a line of nothing",
  "close_fiscal_year",
  "     where p.amount <> 0\n",
  "     where p.amount is not null  -- nil accounts included\n",
  "-- nil accounts included")

m("revenue is swept the WRONG WAY, which still balances",
  "close_fiscal_year",
  "      'debit',  case when r.account_type = 'revenue' then r.amount else 0 end,\n"
  "      'credit', case when r.account_type = 'revenue' then 0 else r.amount end);",
  "      'debit',  case when r.account_type = 'revenue' then 0 else r.amount end,\n"
  "      'credit', case when r.account_type = 'revenue' then r.amount else 0 end);"
  "  -- sweep sides swapped",
  "-- sweep sides swapped")

m("a loss is added to the result instead of taken off it",
  "close_fiscal_year",
  "      + case when r.account_type = 'revenue' then r.amount else -r.amount end;",
  "      + r.amount;  -- expense no longer subtracted",
  "-- expense no longer subtracted")

m("a BREAK-EVEN year still gets a result line of nothing",
  "close_fiscal_year",
  "    if v_profit <> 0 then",
  "    if v_profit is not null then  -- nil result line kept",
  "-- nil result line kept")

m("a LOSS gets no result line at all, so the journal cannot balance",
  "close_fiscal_year",
  "    if v_profit <> 0 then",
  "    if v_profit > 0 then  -- loss gets no result line",
  "-- loss gets no result line")

m("the result is credited to equity whichever way the year went",
  "close_fiscal_year",
  "        'debit',  case when v_profit < 0 then -v_profit else 0 end,\n"
  "        'credit', case when v_profit > 0 then v_profit else 0 end);",
  "        'debit',  0,\n"
  "        'credit', abs(v_profit));  -- result always a credit",
  "-- result always a credit")

m("the result goes to RETAINED earnings rather than CURRENT year's",
  "close_fiscal_year",
  "  v_equity := app.current_year_earnings_account(f.org_id);",
  "  select id into v_equity from public.accounts\n"
  "   where org_id = f.org_id and code = '3200';  -- wrong equity account",
  "-- wrong equity account")

m("a year with nothing in it posts an EMPTY journal",
  "close_fiscal_year",
  "  if jsonb_array_length(v_lines) > 0 then",
  "  if jsonb_array_length(v_lines) >= 0 then  -- empty journal posted",
  "-- empty journal posted")

m("the closing journal is dated the START of the year",
  "close_fiscal_year",
  "      f.org_id, f.end_date, 'year_end_close', v_lines,\n"
  "      'Year-end close: ' || f.name);",
  "      f.org_id, f.start_date, 'year_end_close', v_lines,\n"
  "      'Year-end close: ' || f.name);  -- closed on the wrong day",
  "-- closed on the wrong day")

m("the closing journal does not say which year it closed",
  "close_fiscal_year",
  "      'Year-end close: ' || f.name);",
  "      'Year-end close');  -- year not named",
  "-- year not named")

m("a closed year is not marked closed",
  "close_fiscal_year",
  "     set status = 'closed', closed_at = now(), closed_by = auth.uid(),",
  "     set status = 'open', closed_at = now(), closed_by = auth.uid(),"
  "  -- status not advanced",
  "-- status not advanced")

m("WHEN the year was closed is not recorded",
  "close_fiscal_year",
  "     set status = 'closed', closed_at = now(), closed_by = auth.uid(),",
  "     set status = 'closed', closed_at = null, closed_by = auth.uid(),"
  "  -- closed_at not recorded",
  "-- closed_at not recorded")

m("WHO closed the year is not recorded",
  "close_fiscal_year",
  "     set status = 'closed', closed_at = now(), closed_by = auth.uid(),",
  "     set status = 'closed', closed_at = now(), closed_by = null,"
  "  -- closed_by not recorded",
  "-- closed_by not recorded")

m("the year does not record which journal closed it",
  "close_fiscal_year",
  "         closing_entry_id = v_entry, updated_at = now()\n"
  "   where id = f.id;",
  "         closing_entry_id = null, updated_at = now()\n"
  "   where id = f.id;  -- closing entry not kept",
  "-- closing entry not kept")

m("anybody may REOPEN the year",
  "reopen_fiscal_year",
  "  if not app.can_admin(f.org_id) then",
  "  if false then  -- reopen admin guard dropped",
  "-- reopen admin guard dropped")

m("a year that is not closed can be reopened",
  "reopen_fiscal_year",
  "  if f.status <> 'closed' then",
  "  if false then  -- reopen status guard dropped",
  "-- reopen status guard dropped")

m("a LATER year still closed does not block this one's reopening",
  "reopen_fiscal_year",
  "  if v_later is not null then",
  "  if false then  -- later-year rule dropped",
  "-- later-year rule dropped")

m("ANOTHER COMPANY's closed year blocks this one's reopening",
  "reopen_fiscal_year",
  "   where y.org_id = f.org_id and y.status = 'closed'\n"
  "     and y.start_date > f.start_date;",
  "   where y.status = 'closed'\n"
  "     and y.start_date > f.start_date;  -- later-year org scope dropped",
  "-- later-year org scope dropped")

m("a year counts as later than ITSELF, so nothing can ever reopen",
  "reopen_fiscal_year",
  "     and y.start_date > f.start_date;",
  "     and y.start_date >= f.start_date;  -- later-year boundary widened",
  "-- later-year boundary widened")

m("the closing journal is not reversed, merely forgotten",
  "reopen_fiscal_year",
  "  if f.closing_entry_id is not null then",
  "  if f.closing_entry_id is null then  -- reversal skipped",
  "-- reversal skipped")

m("the reversal copies the closing journal instead of reversing it",
  "reopen_fiscal_year",
  "        'debit', r.credit, 'credit', r.debit);",
  "        'debit', r.debit, 'credit', r.credit);  -- reversal not reversed",
  "-- reversal not reversed")

m("the reversal is dated the START of the year",
  "reopen_fiscal_year",
  "      f.org_id, f.end_date, 'year_end_close', v_lines,\n"
  "      'Year-end close reversed: ' || f.name);",
  "      f.org_id, f.start_date, 'year_end_close', v_lines,\n"
  "      'Year-end close reversed: ' || f.name);  -- reopened on the wrong day",
  "-- reopened on the wrong day")

m("a reopened year still says when it was closed",
  "reopen_fiscal_year",
  "     set status = 'open', closed_at = null, closed_by = null,",
  "     set status = 'open', closed_by = null,  -- closed_at not cleared",
  "-- closed_at not cleared")

m("a reopened year still says who closed it",
  "reopen_fiscal_year",
  "     set status = 'open', closed_at = null, closed_by = null,",
  "     set status = 'open', closed_at = null,  -- closed_by not cleared",
  "-- closed_by not cleared")

m("a reopened year still points at the journal that closed it",
  "reopen_fiscal_year",
  "         closing_entry_id = null, updated_at = now()",
  "         updated_at = now()  -- closing entry not cleared",
  "-- closing entry not cleared")

m("CONTROL -- a comment beside the sweep loop",
  "close_fiscal_year",
  "  v_equity := app.current_year_earnings_account(f.org_id);",
  "  v_equity := app.current_year_earnings_account(f.org_id);"
  "  -- CONTROL: this cannot change an account.",
  "-- CONTROL: this cannot change an account.")
