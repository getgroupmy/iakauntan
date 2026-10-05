# Mutants for public.import_opening_balances -- a predecessor's trial
# balance brought onto the ledger on changeover day.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0525_reversing_it_has_to_be_enough.sql \
#       supabase/tests/opening_import_shapes.sql \
#       supabase/tests/mutants/opening_balances.py
#
# then again against `opening_trial_balance.sql`,
# `chart_of_accounts.sql`, `migration_progress.sql` and
# `opening_stock.sql`.
#
# RESULT, 5 October: 40 mutants (39 plus a control). 13 killed on
# `opening_import_shapes.sql` and 26 survived; 29 across all five files.
# 39 of 39 after the work -- nothing equivalent, and the control lived.
#
#   opening_import_shapes.sql  kills 13, then 26
#   opening_trial_balance.sql  kills 17, thirteen of them the rest
#   chart_of_accounts.sql      kills 6
#   migration_progress.sql     kills 6
#   opening_stock.sql          kills 2
#
# THE ELEVEN REAL GAPS WERE MOSTLY ROWS NOBODY HAD PUT IN A FILE: no
# account code at all, a heading, something that is not an amount, both
# columns on one line, 3900 itself. A changeover file arrives from
# somebody else's system with exactly those in it -- a stray blank row,
# a footnote in a money column, a subtotal line -- which is why the
# chain has nine links and why each needs a row that trips exactly one.
#
# AND THE CHAIN'S ORDER IS LOAD-BEARING, which the function's own
# comment says about the 3900 case: in a company that has imported
# nothing, 3900 does not exist yet, so the existence check below would
# answer "3900 is not an account in this company's chart" -- true,
# unhelpful, and not the reason. The new block asserts the WORDS, which
# is the whole of what the ordering buys, and first asserts that the
# company really has no 3900 -- otherwise the two branches agree and
# the assertion proves nothing.
#
# AND A COMMENT IN THE FILE HAD THE DIRECTION BACKWARDS. The duplicate
# check is `lower(v_code) = any (v_seen)` with `v_seen` holding lowered
# codes, and the file tested 'FX-1' then 'fx-1' under a comment saying
# "the order here is the assertion". It is not: with the upper spelling
# seen FIRST, the second row is already lower case and matches whether
# or not the comparison lowers it. Dropping the `lower()` from the
# comparison passed that assertion. Lower-then-upper is the order that
# distinguishes them, and the comment is corrected.
#
# THE CONTROL-ACCOUNT COMPARISON had neither of its two halves. A
# receivable or payable row is never posted -- the open items already
# did -- so it is COMPARED, and the verdict is `ok` when it agrees and a
# `warning` naming both figures when it does not. Neither was asserted,
# and the SIGN of the comparison depends on the account TYPE, so an
# asset and a liability read the two columns opposite ways. Three
# mutants lived in those two sentences.
#
# The most VALIDATION-heavy function swept. Nine conditions in one
# ordered `elsif` chain decide what a row's problem is, and the order
# is load-bearing -- the function's own comment says so about the 3900
# case: "Before the existence check, not after: 3900 is created on
# demand, so in a company that has imported nothing yet it does not
# exist, and the wrong branch answers '3900 is not an account in this
# company's chart' -- true, unhelpful, and not the reason it is being
# refused."
#
# An elsif chain is the one shape where MOVING a condition is a
# mutation worth writing, and where a fixture meeting two conditions at
# once cannot tell which one answered.

m("a row with no account code at all is accepted",
  "import_opening_balances",
  "    if v_code is null then\n      v_problem := 'No account code.';",
  "    if false then\n      v_problem := 'No account code.';"
  "  -- missing code accepted",
  "-- missing code accepted")

m("the same account twice in one file is accepted",
  "import_opening_balances",
  "    elsif lower(v_code) = any (v_seen) then",
  "    elsif false then  -- duplicate code accepted",
  "-- duplicate code accepted")

m("a duplicate is matched case-sensitively",
  "import_opening_balances",
  "    elsif lower(v_code) = any (v_seen) then",
  "    elsif v_code = any (v_seen) then  -- duplicate case no longer folded",
  "-- duplicate case no longer folded")

m("Opening Balance Equity can be brought in as a line of the file",
  "import_opening_balances",
  "    elsif v_code = '3900' then",
  "    elsif false then  -- 3900 accepted as a file line",
  "-- 3900 accepted as a file line")

m("an account that is not in the chart is accepted",
  "import_opening_balances",
  "    elsif v_acct_id is null then\n      v_problem := format(\n"
  "        '%s is not an account in this company''s chart.",
  "    elsif false then\n      v_problem := format(\n"
  "        '%s is not an account in this company''s chart."
  "  -- unknown account accepted",
  "-- unknown account accepted")

m("a HEADING can take an opening balance",
  "import_opening_balances",
  "    elsif v_acct_group then",
  "    elsif false then  -- heading accepted",
  "-- heading accepted")

# The anchor runs to the END of its line. `v_acct_id := null;` shares a
# line with `v_acct_type := null;`, so a marker placed after the first
# of them commented out the second -- and the mutant then did TWO
# things: it read unparseable amounts as zero AND stopped resetting the
# account type between rows, leaking the previous row's. Its kill could
# have come from either. Found by the harness's pre-flight on 5 October,
# after the kill sheet below had already been recorded; re-measured, and
# the figure held.
m("something that is not an amount is read as nothing",
  "import_opening_balances",
  "    v_debit  := app.import_number(app.import_text(r, 'debit'), 0);\n"
  "    v_credit := app.import_number(app.import_text(r, 'credit'), 0);\n"
  "\n"
  "    v_acct_id := null; v_acct_type := null;",
  "    v_debit  := coalesce(app.import_number(app.import_text(r, 'debit'), 0), 0);\n"
  "    v_credit := coalesce(app.import_number(app.import_text(r, 'credit'), 0), 0);\n"
  "\n"
  "    v_acct_id := null; v_acct_type := null;"
  "  -- unparseable amounts read as zero",
  "-- unparseable amounts read as zero")

m("a NEGATIVE amount is accepted in either column",
  "import_opening_balances",
  "    elsif v_debit < 0 or v_credit < 0 then",
  "    elsif false then  -- negative amounts accepted",
  "-- negative amounts accepted")

m("a negative CREDIT is accepted while a negative debit is not",
  "import_opening_balances",
  "    elsif v_debit < 0 or v_credit < 0 then",
  "    elsif v_debit < 0 then  -- negative credit accepted",
  "-- negative credit accepted")

m("a line with an amount in BOTH columns is accepted",
  "import_opening_balances",
  "    elsif v_debit <> 0 and v_credit <> 0 then",
  "    elsif false then  -- both columns accepted",
  "-- both columns accepted")

m("a receivable row is POSTED rather than compared",
  "import_opening_balances",
  "      if v_acct_subtype in ('accounts_receivable', 'accounts_payable') then",
  "      if false then  -- control accounts posted rather than compared",
  "-- control accounts posted rather than compared")

m("only RECEIVABLES are compared and payables are posted",
  "import_opening_balances",
  "      if v_acct_subtype in ('accounts_receivable', 'accounts_payable') then",
  "      if v_acct_subtype in ('accounts_receivable') then"
  "  -- payables no longer compared",
  "-- payables no longer compared")

m("a control account that AGREES is reported as out",
  "import_opening_balances",
  "        if round(v_ledger, 2)\n"
  "           = round(case when v_acct_type = 'asset'",
  "        if round(v_ledger, 2)\n"
  "           <> round(case when v_acct_type = 'asset'"
  "  -- agreement test inverted",
  "-- agreement test inverted")

m("a PAYABLE is compared with the sign of a receivable",
  "import_opening_balances",
  "           = round(case when v_acct_type = 'asset'\n"
  "                        then v_debit - v_credit\n"
  "                        else v_credit - v_debit end, 2)",
  "           = round(v_debit - v_credit, 2)"
  "  -- control sign no longer by type",
  "-- control sign no longer by type")

m("a line with nothing on it is accepted as a posting",
  "import_opening_balances",
  "      elsif v_debit = 0 and v_credit = 0 then\n"
  "        v_problem := 'Nothing on this line.';",
  "      elsif false then\n        v_problem := 'Nothing on this line.';"
  "  -- nil line accepted",
  "-- nil line accepted")

m("an inventory balance is brought in with no warning at all",
  "import_opening_balances",
  "        if v_acct_subtype = 'inventory' and not v_stock then",
  "        if false then  -- inventory warnings dropped",
  "-- inventory warnings dropped")

m("a company that DOES track stock gets the no-stock warning",
  "import_opening_balances",
  "        if v_acct_subtype = 'inventory' and not v_stock then",
  "        if v_acct_subtype = 'inventory' then"
  "  -- stock-tracked check dropped",
  "-- stock-tracked check dropped")

m("whether anything is stock-tracked ignores DELETED items",
  "import_opening_balances",
  "                  where it.org_id = p_org_id and it.track_inventory\n"
  "                    and it.deleted_at is null)",
  "                  where it.org_id = p_org_id and it.track_inventory)"
  "  -- deleted items counted as stock",
  "-- deleted items counted as stock")

m("whether anything is stock-tracked looks at EVERY company",
  "import_opening_balances",
  "                  where it.org_id = p_org_id and it.track_inventory\n"
  "                    and it.deleted_at is null)",
  "                  where it.track_inventory\n"
  "                    and it.deleted_at is null)  -- stock org scope dropped",
  "-- stock org scope dropped")

m("a file that does not balance is imported",
  "import_opening_balances",
  "  if round(v_file_debit - v_file_credit, 2) <> 0 then",
  "  if false then  -- unbalanced file accepted",
  "-- unbalanced file accepted")

m("a file that does not balance is reported only on a COMMIT",
  "import_opening_balances",
  "    v_results := v_results || jsonb_build_object(\n"
  "      'row_no', i + 1,\n      'code', '',\n      'status', 'error',",
  "    v_results := v_results || jsonb_build_object(\n"
  "      'row_no', i + 1,\n      'code', '',\n      'status', 'warning',"
  "  -- out-of-balance reported as a warning",
  "-- out-of-balance reported as a warning")

m("a file with bad rows in it is imported anyway",
  "import_opening_balances",
  "  if p_commit and v_bad > 0 then",
  "  if false then  -- bad rows no longer stop the import",
  "-- bad rows no longer stop the import")

m("a SECOND opening trial balance is brought in on top of the first",
  "import_opening_balances",
  "    if exists (select 1 from public.gl_entries ge\n"
  "                where ge.org_id = p_org_id",
  "    if false and exists (select 1 from public.gl_entries ge\n"
  "                where ge.org_id = p_org_id"
  "  -- second import no longer refused",
  "-- second import no longer refused")

m("ANOTHER COMPANY's opening balance blocks this company's import",
  "import_opening_balances",
  "                where ge.org_id = p_org_id\n"
  "                  and ge.source = 'opening_balance'",
  "                where ge.source = 'opening_balance'"
  "  -- prior-import org scope dropped",
  "-- prior-import org scope dropped")

m("a REVERSED opening balance still blocks a second import",
  "import_opening_balances",
  "                  and not exists (\n"
  "                    select 1 from public.gl_entries r\n"
  "                     where r.reversed_entry_id = ge.id\n"
  "                       and r.status = 'posted'))",
  "                  and true)  -- reversed entries still block",
  "-- reversed entries still block")

m("the REVERSAL itself is taken for an opening balance",
  "import_opening_balances",
  "                  and not coalesce(ge.is_reversal, false)",
  "                  and true  -- reversal no longer excluded",
  "-- reversal no longer excluded")

m("a control-account row is posted in the commit loop after all",
  "import_opening_balances",
  "      continue when v_acct_subtype in ('accounts_receivable',\n"
  "                                       'accounts_payable');",
  "      -- controls posted: continue when v_acct_subtype in"
  " ('accounts_receivable', 'accounts_payable');",
  "-- controls posted")

m("a nil line is posted in the commit loop after all",
  "import_opening_balances",
  "      continue when v_debit = 0 and v_credit = 0;",
  "      -- nil lines posted: continue when v_debit = 0 and v_credit = 0;",
  "-- nil lines posted")

m("a row with no description of its own gets none",
  "import_opening_balances",
  "        'description', coalesce(app.import_text(r, 'description'),\n"
  "                                'Opening balance'),",
  "        'description', app.import_text(r, 'description'),"
  "  -- opening line description fallback dropped",
  "-- opening line description fallback dropped")

m("the residual is struck on the whole FILE rather than what posted",
  "import_opening_balances",
  "    v_residual := round(v_post_debit - v_post_credit, 2);",
  "    v_residual := round(v_file_debit - v_file_credit, 2);"
  "  -- residual from the file totals",
  "-- residual from the file totals")

m("a file that needs no residual still posts an equity line of nothing",
  "import_opening_balances",
  "    if v_residual <> 0 then",
  "    if true then  -- nil residual line posted",
  "-- nil residual line posted")

m("the residual is put on the WRONG SIDE of equity",
  "import_opening_balances",
  "        'debit', greatest(-v_residual, 0),\n"
  "        'credit', greatest(v_residual, 0));",
  "        'debit', greatest(v_residual, 0),\n"
  "        'credit', greatest(-v_residual, 0));  -- residual sides swapped",
  "-- residual sides swapped")

m("a file with nothing postable in it posts an empty journal",
  "import_opening_balances",
  "    if jsonb_array_length(v_lines) = 0 then",
  "    if false then  -- empty journal posted",
  "-- empty journal posted")

m("the opening journal is dated the day it was typed",
  "import_opening_balances",
  "      p_org_id, p_as_at, 'opening_balance'::app.journal_source,",
  "      p_org_id, app.today(), 'opening_balance'::app.journal_source,"
  "  -- opening journal date forced to today",
  "-- opening journal date forced to today")

m("the opening journal is filed as this year's trading",
  "import_opening_balances",
  "      p_org_id, p_as_at, 'opening_balance'::app.journal_source,",
  "      p_org_id, p_as_at, 'manual'::app.journal_source,"
  "  -- opening journal source changed",
  "-- opening journal source changed")

m("the bank balances are not told what was brought in",
  "import_opening_balances",
  "      perform public.resync_bank_balance(v_bank.id);",
  "      -- not resynced: perform public.resync_bank_balance(v_bank.id);",
  "-- not resynced")

m("a CASH drawer's balance is not resynced, only a bank's",
  "import_opening_balances",
  "        and a.account_subtype in ('bank', 'cash')",
  "        and a.account_subtype in ('bank')  -- cash no longer resynced",
  "-- cash no longer resynced")

m("ANOTHER COMPANY's bank balances are resynced",
  "import_opening_balances",
  "      where b.org_id = p_org_id\n"
  "        and a.account_subtype in ('bank', 'cash')",
  "      where a.account_subtype in ('bank', 'cash')"
  "  -- resync org scope dropped",
  "-- resync org scope dropped")

m("a WARNING row is relabelled as imported",
  "import_opening_balances",
  "               case when x ->> 'status' = 'ok'\n"
  "                    then jsonb_set(x, '{status}', '\"imported\"')\n"
  "                    else x end)",
  "               jsonb_set(x, '{status}', '\"imported\"'))"
  "  -- every row relabelled as imported",
  "-- every row relabelled as imported")

m("CONTROL -- a comment beside the row counter",
  "import_opening_balances",
  "    i := i + 1;",
  "    i := i + 1;  -- CONTROL: this cannot change a count.",
  "-- CONTROL: this cannot change a count.")
