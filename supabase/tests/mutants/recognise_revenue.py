# Mutants for public.recognise_revenue (0310) -- deferred revenue released
# as it is earned: by somebody who may post; every period not yet
# released, with something left after credit notes, ending on or before
# the day given; one journal per period end, dated that day, debiting
# deferred revenue by what is left and crediting each revenue account;
# each period marked with its journal and the day it was recognised.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0310_a_credit_note_stops_the_schedule.sql \
#       supabase/tests/revenue_recognition.sql \
#       supabase/tests/mutants/recognise_revenue.py
#
# RESULT: 12 mutants and a control, all killed by `revenue_recognition.sql`.
# Five only after its rule-by-rule block: who may run it, a period taken
# back in full released beside a live one, releasing the first line of
# a period end and not the rest, and the two dates. Every release before
# it was of ONE invoice, so no period end ever carried two schedules.
# The journal's date needed asking against its own periods: "dated a
# month end" let the mutant date all three 31 March, which is one.

m("anybody releases revenue",
  "recognise_revenue",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a period already released is released again",
  "recognise_revenue",
  "       and gl_entry_id is null\n",
  "       and true  -- twice\n",
  "-- twice")

m("a period a credit note took back in full is released",
  "recognise_revenue",
  "       and amount > cancelled_amount\n",
  "       and true  -- cancelled too\n",
  "-- cancelled too")

m("a period ending ON the day is not released until the next",
  "recognise_revenue",
  "       and period_end <= v_upto\n",
  "       and period_end < v_upto  -- strictly before\n",
  "-- strictly before")

m("every period is released whenever it ends",
  "recognise_revenue",
  "       and period_end <= v_upto\n",
  "       and true  -- future too\n",
  "-- future too")

m("revenue credited ignores what a credit note took back",
  "recognise_revenue",
  "             'debit', 0, 'credit', amount - cancelled_amount)",
  "             'debit', 0, 'credit', amount)  -- credit gross",
  "-- credit gross")

m("deferred revenue is debited the gross",
  "recognise_revenue",
  "           sum(amount - cancelled_amount) as total,",
  "           sum(amount) as total,  -- debit gross",
  "-- debit gross")

m("the journal is dated the day it was run",
  "recognise_revenue",
  "      v_row.period_end,\n      'revenue_recognition'::app.journal_source,",
  "      v_upto,  -- run day\n      'revenue_recognition'::app.journal_source,",
  "-- run day")

m("the period says it was recognised the day it was run",
  "recognise_revenue",
  "       set gl_entry_id = v_entry, recognised_on = v_row.period_end",
  "       set gl_entry_id = v_entry, recognised_on = v_upto  -- recognised on run day",
  "-- recognised on run day")

m("the period does not keep its journal",
  "recognise_revenue",
  "       set gl_entry_id = v_entry, recognised_on = v_row.period_end",
  "       set gl_entry_id = null, recognised_on = v_row.period_end  -- no journal",
  "-- no journal")

m("the count says nothing was released",
  "recognise_revenue",
  "    v_n := v_n + 1;",
  "    v_n := v_n;  -- not counted",
  "-- not counted")

m("one period's lines are released alone, not all of that day's",
  "recognise_revenue",
  "     where id = any (v_row.ids);",
  "     where id = (v_row.ids)[1];  -- first only",
  "-- first only")

m("CONTROL: a comment inside the block",
  "recognise_revenue",
  "  if not app.can_post(p_org_id) then",
  "  if not app.can_post(p_org_id) then  -- (control)",
  "(control)")
