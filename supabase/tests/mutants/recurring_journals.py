# Mutants for public.run_recurring_journals_for -- the monthly standing
# journals (rent, depreciation, a management fee) posted on their due
# date and rescheduled for the next one.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/recurring_shapes.sql \
#       supabase/tests/mutants/recurring_journals.py
#
# then again against `pricing_and_dimensions.sql` and `idempotency.sql`.
#
# RESULT, 5 October: 25 mutants (24 plus a control). 11 killed on
# `recurring_shapes.sql` and 13 survived; across all three files
# 24 of 24 die. Nothing is equivalent, and the control lived.
#
#   recurring_shapes.sql       kills 11, then 23
#   pricing_and_dimensions.sql kills 5, three of them new
#   idempotency.sql            kills 4, one of them the last
#
# ALL THIRTEEN SURVIVORS WERE INSIDE THE LOOP. The run's return value
# and the posted entry's date and description were asserted; the three
# columns the loop writes on its way out -- `last_run_date`,
# `next_run_date`, `last_error` -- were not, except as `is null` on the
# two schedules that did not run. That is the same finding clear_pdc
# gave an hour earlier: a file that watches the money does not watch
# the state.
#
# AND THE ERROR PATH WAS ASSERTED -- FOR THE OTHER RUNNER.
# `recurring_shapes.sql` has four assertions on `last_error` after a
# failed run, and every one of them is about `recurring_documents`.
# `run_recurring_documents_for` and `run_recurring_journals_for` are
# two runners with two `where` clauses, which the file's own section-8
# comment says in those words -- and the half it wrote the comment for
# was still the half with no coverage of the error path, the interval,
# the review flag or the template.
#
# ONE SURVIVOR WAS AN EMPTY JOURNAL, which is the fifth of this shape
# in the sweep. `r.template -> 'lines'` read under the wrong key gives
# NULL, `app.create_gl_entry_internal` posts an entry with no lines at
# all, and it balances -- nothing counted the lines, so a month-end
# accrual that accrued nothing passed every assertion in section 8,
# including "the accrual is dated the month it accrues".
#
# AND auto_post, WHICH NOTHING HAD EVER SET TO FALSE. A schedule the
# bookkeeper wants to review first must advance and post NOTHING. With
# every fixture set to auto-post, "it posted" and "it ran" were one
# claim.
#
# Two things make this one different from the postings swept so far.
#
# First, the SELECTION is the behaviour. Four conjuncts decide which
# journals run -- active, scheduled, due, and not past their end date --
# and three of them are the kind of boundary no fixture stands on
# unless it is built to.
#
# Second, it SWALLOWS ITS OWN ERRORS on purpose: a template that will
# not post records the reason on its row and the loop carries on to the
# next journal. That is right (one broken standing journal must not stop
# the rent), and it means a mutation INSIDE the loop can be hidden by
# the handler -- the run still returns, and only `last_error` and the
# count say anything happened. After the lesson clear_pdc gave, the
# first thing to check here is whether anything asserts the state the
# loop writes, and not only the money.

m("anybody can run the standing journals",
  "run_recurring_journals_for",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- recurring post guard dropped",
  "-- recurring post guard dropped")

m("ANOTHER COMPANY's standing journals are run too",
  "run_recurring_journals_for",
  "     where org_id = p_org_id and is_active",
  "     where is_active  -- recurring org scope dropped",
  "-- recurring org scope dropped")

m("a standing journal that was SWITCHED OFF runs anyway",
  "run_recurring_journals_for",
  "     where org_id = p_org_id and is_active",
  "     where org_id = p_org_id  -- is_active dropped",
  "-- is_active dropped")

m("a journal due TODAY is not run until tomorrow",
  "run_recurring_journals_for",
  "       and next_run_date is not null and next_run_date <= p_on",
  "       and next_run_date is not null and next_run_date < p_on"
  "  -- due-today boundary narrowed",
  "-- due-today boundary narrowed")

m("a journal not due for weeks is run today",
  "run_recurring_journals_for",
  "       and next_run_date is not null and next_run_date <= p_on",
  "       and next_run_date is not null  -- due date no longer checked",
  "-- due date no longer checked")

m("a journal ENDING today is not run on its last day",
  "run_recurring_journals_for",
  "       and (end_date is null or next_run_date <= end_date)",
  "       and (end_date is null or next_run_date < end_date)"
  "  -- end-date boundary narrowed",
  "-- end-date boundary narrowed")

m("a journal whose run PASSED its end date runs anyway",
  "run_recurring_journals_for",
  "       and (end_date is null or next_run_date <= end_date)",
  "       and true  -- end date no longer checked",
  "-- end date no longer checked")

m("a journal with NO end date never runs at all",
  "run_recurring_journals_for",
  "       and (end_date is null or next_run_date <= end_date)",
  "       and (next_run_date <= end_date)  -- open-ended arm dropped",
  "-- open-ended arm dropped")

m("a journal the bookkeeper wanted to review posts itself",
  "run_recurring_journals_for",
  "      if r.auto_post then",
  "      if true then  -- auto_post no longer consulted",
  "-- auto_post no longer consulted")

m("a journal set to post ITSELF posts nothing",
  "run_recurring_journals_for",
  "      if r.auto_post then",
  "      if false then  -- auto_post never true",
  "-- auto_post never true")

m("the journal is dated the day the job ran, not the day it was due",
  "run_recurring_journals_for",
  "          p_entry_date   => r.next_run_date,",
  "          p_entry_date   => app.today(),  -- entry date forced to today",
  "-- entry date forced to today")

m("the standing journal's own lines are not the ones posted",
  "run_recurring_journals_for",
  "          p_lines        => r.template -> 'lines',",
  "          p_lines        => r.template -> 'line',  -- wrong template key",
  "-- wrong template key")

m("the journal's description falls back when it has one of its own",
  "run_recurring_journals_for",
  "          p_description  => coalesce(r.description, r.name),",
  "          p_description  => r.name,  -- own description ignored",
  "-- own description ignored")

m("a standing journal with no description of its own gets none",
  "run_recurring_journals_for",
  "          p_description  => coalesce(r.description, r.name),",
  "          p_description  => r.description,  -- name fallback dropped",
  "-- name fallback dropped")

m("the posting does not say which standing journal made it",
  "run_recurring_journals_for",
  "          p_source_id    => r.id,",
  "          p_source_id    => null,  -- source journal forgotten",
  "-- source journal forgotten")

m("the posting carries no reference back to the schedule",
  "run_recurring_journals_for",
  "          p_reference    => r.name);",
  "          p_reference    => null);  -- reference dropped",
  "-- reference dropped")

m("the schedule does not record when it last ran",
  "run_recurring_journals_for",
  "         set last_run_date = r.next_run_date,",
  "         set last_run_date = null,  -- last run not recorded",
  "-- last run not recorded")

m("it records the day the job ran rather than the day it was due",
  "run_recurring_journals_for",
  "         set last_run_date = r.next_run_date,",
  "         set last_run_date = app.today(),  -- last run dated today",
  "-- last run dated today")

m("the schedule is never advanced, so it runs again tomorrow",
  "run_recurring_journals_for",
  "             next_run_date = app.advance_schedule(\n"
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "             next_run_date = r.next_run_date,  -- schedule not advanced",
  "-- schedule not advanced")

m("the schedule is advanced from TODAY rather than from its due date",
  "run_recurring_journals_for",
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "               app.today(), r.frequency, r.interval_count, r.start_date),"
  "  -- advanced from today",
  "-- advanced from today")

m("the schedule's own interval is ignored, so monthly means every month",
  "run_recurring_journals_for",
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "               r.next_run_date, r.frequency, 1, r.start_date),"
  "  -- interval forced to one",
  "-- interval forced to one")

m("an OLD error stays on a schedule that has since run cleanly",
  "run_recurring_journals_for",
  "             last_error = null, last_error_at = null",
  "             last_error = r.last_error, last_error_at = r.last_error_at"
  "  -- stale error kept",
  "-- stale error kept")

m("a standing journal that FAILS does not say why",
  "run_recurring_journals_for",
  "         set last_error = sqlerrm, last_error_at = now()",
  "         set last_error = null, last_error_at = now()"
  "  -- failure reason not recorded",
  "-- failure reason not recorded")

m("a standing journal that FAILED is counted as having run",
  "run_recurring_journals_for",
  "         set last_error = sqlerrm, last_error_at = now()\n"
  "       where id = r.id;",
  "         set last_error = sqlerrm, last_error_at = now()\n"
  "       where id = r.id;\n"
  "      v_n := v_n + 1;  -- failure counted as a run",
  "-- failure counted as a run")

m("CONTROL -- a comment beside the loop",
  "run_recurring_journals_for",
  "  v_n integer := 0;",
  "  v_n integer := 0;  -- CONTROL: this cannot change a count.",
  "-- CONTROL: this cannot change a count.")
