# Mutants for app.run_recurring_journals -- the CRON-WIDE standing
# journal run. Every organization in the database, in one call, with no
# permission guard and no org argument, because the thing that calls it
# is pg_cron and not a person.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/recurring_shapes.sql \
#       supabase/tests/mutants/run_recurring_journals.py
#
# then again against `ledger.sql`, `recurring_documents.sql`,
# `scheduled_work.sql` and `app_writers_are_not_a_client_surface.sql`.
#
# WHY THIS FUNCTION IS NOT ALREADY COVERED BY recurring_journals.py.
#
# `public.run_recurring_journals_for` and `app.run_recurring_journals`
# have THE SAME BODY. The `_for` one adds an `app.can_post` guard and
# `org_id = p_org_id`; everything below the `for` is character-for-
# character the same, and `0739`'s own comment says so in those words:
# "Same body, one org."
#
# That is exactly the shape CLAUDE.md warns about -- two halves of a
# symmetric thing do not get symmetric coverage -- except here the two
# halves are not two branches of one function but two functions, and
# they are reached by two disjoint sets of test files. `_for` is swept
# by `recurring_shapes.sql`, `pricing_and_dimensions.sql` and
# `idempotency.sql`. The cron one is called by `ledger.sql`,
# `recurring_documents.sql`, `scheduled_work.sql`,
# `app_writers_are_not_a_client_surface.sql` and one line of
# `recurring_shapes.sql`. A mutant killed on one proves nothing about
# the other: the migration applies ONE function, and the test files that
# reach it are different files.
#
# THE ONE BEHAVIOUR ONLY THIS FUNCTION HAS is that it crosses the
# tenant boundary ON PURPOSE. Every other money mover in this sweep is
# wrong if it touches another company's rows; this one is wrong if it
# does NOT. So the scope mutant here is the INVERSE of the usual one:
# instead of dropping the org filter, it ADDS one. A cron sweep narrowed
# to a single organization leaves every other tenant's rent unposted and
# every other tenant's schedule un-advanced -- for a month, silently,
# with a return value that still looks like a number of journals.
#
# That mutant can only die on a fixture with TWO organizations, each
# with a journal due on the same day.
#
# RESULT, 5 October: 35 mutants (34 plus a control).
#
#   recurring_shapes.sql       kills 14, then 32
#   ledger.sql                 kills 11, five of them new
#   recurring_documents.sql    kills  7, three of them new
#   scheduled_work.sql         kills  0
#   app_writers_...surface.sql kills  0
#
# 22 of 34 before the work; 33 of 33 killable after it. One is
# EQUIVALENT and proven so by the column rather than by a fixture --
# see "a journal with no schedule at all is run" below. The control
# lived on every file.
#
# TWO OF THE FIVE CALLERS CANNOT KILL ANYTHING, and that is not a flaw
# in them. `scheduled_work.sql` asserts that something SCHEDULES this
# function: it walks `cron.job` commands and function source text and
# never runs it. `app_writers_are_not_a_client_surface.sql` asserts
# that a stranger cannot EXECUTE it, and that refusal comes from the
# EXECUTE privilege rather than from the body, so all 34 mutants raise
# the same `insufficient_privilege`. Zero of 34 in each, measured.
# A count of callers is not a coverage figure.
#
# WHAT LIVED, grouped:
#
#   * THE TENANT BOUNDARY. No fixture anywhere had two companies with a
#     journal due on the same night, so the sweep could be narrowed to
#     one tenant with nothing to say. The usual cross-org mutant,
#     inverted -- see the note above.
#   * THE TWO INCLUSIVE BOUNDARIES. Nothing was ever due exactly on the
#     night of the sweep, or exactly on the last day of its lease.
#   * `last_run_date`, READ ONLY IN THE WRONG DIRECTION: asserted as
#     `is null` on the three schedules that did NOT run, and nowhere as
#     a value. It could be left null or stamped with the night of the
#     sweep. `scripts/state_write_coverage.py` has never reported this
#     function, because that column IS named -- in the wrong direction.
#   * `interval_count`, because every fixture in the suite was
#     `monthly, 1`.
#   * `last_error` left stale on a repaired schedule, and
#     `last_error_at` left null on one that just failed. `ledger.sql`
#     reads the reason; nothing read the clock.
#   * `source_table` and `reference` on the posted entry: read by
#     nothing at all.
#   * `template -> 'lines'` under the wrong key, which posts an entry
#     with NO LINES and balances -- the sixth zero-value journal of
#     this shape in the sweep.

# ---------------------------------------------------------------- scope

# The deterministic narrowing: order by org_id and keep the first. The
# summary of this sweep's own traps says to prefer an inverted or
# ordered form over `limit 1` on an unordered scan, because `select ...
# into` over two matching rows takes whichever the planner reaches
# first and the mutant becomes a coin flip. `order by org_id` is a
# total order over uuids, so the same fixture always loses the same
# tenant.
m("the cron sweep is narrowed to ONE organization",
  "run_recurring_journals",
  "     where is_active\n"
  "       and next_run_date is not null",
  "     where is_active\n"
  "       and org_id = (select org_id from public.recurring_journals\n"
  "                      where is_active and next_run_date is not null\n"
  "                      order by org_id limit 1)  -- cron sweep narrowed\n"
  "       and next_run_date is not null",
  "-- cron sweep narrowed")

m("a standing journal that was SWITCHED OFF runs anyway",
  "run_recurring_journals",
  "     where is_active\n",
  "     where true  -- is_active dropped\n",
  "-- is_active dropped")

# EQUIVALENT, and proven by the column rather than by a fixture.
# `recurring_journals.next_run_date` is NOT NULL in the table, so this
# conjunct can never be false and the row that would distinguish the
# two forms cannot be inserted -- and `next_run_date <= p_on`, one line
# below, excludes a null anyway. The mutant is kept because the kill
# sheet should record WHY it cannot die. Sixth of this family in the
# sweep; `scripts/mutate_sql.py` says to ask the column first.
m("a journal with no schedule at all is run",
  "run_recurring_journals",
  "       and next_run_date is not null\n",
  "       and true  -- unscheduled journals included\n",
  "-- unscheduled journals included")

m("a journal due TODAY is not run until tomorrow",
  "run_recurring_journals",
  "       and next_run_date <= p_on\n",
  "       and next_run_date < p_on  -- due-today boundary narrowed\n",
  "-- due-today boundary narrowed")

m("a journal not due for weeks is run today",
  "run_recurring_journals",
  "       and next_run_date <= p_on\n",
  "       and true  -- due date no longer checked\n",
  "-- due date no longer checked")

m("a journal ENDING today is not run on its last day",
  "run_recurring_journals",
  "       and (end_date is null or next_run_date <= end_date)",
  "       and (end_date is null or next_run_date < end_date)"
  "  -- end-date boundary narrowed",
  "-- end-date boundary narrowed")

m("a journal whose run PASSED its end date runs anyway",
  "run_recurring_journals",
  "       and (end_date is null or next_run_date <= end_date)",
  "       and true  -- end date no longer checked",
  "-- end date no longer checked")

m("a journal with NO end date never runs at all",
  "run_recurring_journals",
  "       and (end_date is null or next_run_date <= end_date)",
  "       and (next_run_date <= end_date)  -- open-ended arm dropped",
  "-- open-ended arm dropped")

# ----------------------------------------------------------- the posting

m("a journal the bookkeeper wanted to review posts itself",
  "run_recurring_journals",
  "      if r.auto_post then",
  "      if true then  -- auto_post no longer consulted",
  "-- auto_post no longer consulted")

m("a journal set to post ITSELF posts nothing",
  "run_recurring_journals",
  "      if r.auto_post then",
  "      if false then  -- auto_post never true",
  "-- auto_post never true")

m("the journal is dated the day the sweep ran, not the day it was due",
  "run_recurring_journals",
  "          p_entry_date   => r.next_run_date,",
  "          p_entry_date   => p_on,  -- entry date forced to the run day",
  "-- entry date forced to the run day")

m("the journal is dated off the real clock rather than the schedule",
  "run_recurring_journals",
  "          p_entry_date   => r.next_run_date,",
  "          p_entry_date   => app.today(),  -- entry date off the clock",
  "-- entry date off the clock")

m("the posting is not marked as a recurring one",
  "run_recurring_journals",
  "          p_source       => 'recurring'::app.journal_source,",
  "          p_source       => 'manual'::app.journal_source,  -- source lied about",
  "-- source lied about")

m("the standing journal's own lines are not the ones posted",
  "run_recurring_journals",
  "          p_lines        => r.template -> 'lines',",
  "          p_lines        => r.template -> 'line',  -- wrong template key",
  "-- wrong template key")

m("the journal's description falls back when it has one of its own",
  "run_recurring_journals",
  "          p_description  => coalesce(r.description, r.name),",
  "          p_description  => r.name,  -- own description ignored",
  "-- own description ignored")

m("a standing journal with no description of its own gets none",
  "run_recurring_journals",
  "          p_description  => coalesce(r.description, r.name),",
  "          p_description  => r.description,  -- name fallback dropped",
  "-- name fallback dropped")

m("the posting does not say what KIND of thing made it",
  "run_recurring_journals",
  "          p_source_table => 'recurring_journals',",
  "          p_source_table => 'recurring_documents',  -- source table wrong",
  "-- source table wrong")

m("the posting does not say which standing journal made it",
  "run_recurring_journals",
  "          p_source_id    => r.id,",
  "          p_source_id    => null,  -- source journal forgotten",
  "-- source journal forgotten")

m("the posting carries no reference back to the schedule",
  "run_recurring_journals",
  "          p_reference    => r.name);",
  "          p_reference    => null);  -- reference dropped",
  "-- reference dropped")

# ------------------------------------------------------------- the state

m("the schedule does not record when it last ran",
  "run_recurring_journals",
  "         set last_run_date = r.next_run_date,",
  "         set last_run_date = null,  -- last run not recorded",
  "-- last run not recorded")

m("it records the day the sweep ran rather than the day it was due",
  "run_recurring_journals",
  "         set last_run_date = r.next_run_date,",
  "         set last_run_date = p_on,  -- last run dated the run day",
  "-- last run dated the run day")

m("the schedule is never advanced, so it runs again tomorrow",
  "run_recurring_journals",
  "             next_run_date = app.advance_schedule(\n"
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "             next_run_date = r.next_run_date,  -- schedule not advanced",
  "-- schedule not advanced")

m("the schedule is advanced from the run day rather than its due date",
  "run_recurring_journals",
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "               p_on, r.frequency, r.interval_count, r.start_date),"
  "  -- advanced from the run day",
  "-- advanced from the run day")

m("the schedule's own interval is ignored, so every third month is monthly",
  "run_recurring_journals",
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "               r.next_run_date, r.frequency, 1, r.start_date),"
  "  -- interval forced to one",
  "-- interval forced to one")

m("every schedule is treated as monthly, whatever it says",
  "run_recurring_journals",
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "               r.next_run_date, 'monthly', r.interval_count, r.start_date),"
  "  -- frequency forced to monthly",
  "-- frequency forced to monthly")

m("the schedule loses its day of the month the first time it meets February",
  "run_recurring_journals",
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date),",
  "               r.next_run_date, r.frequency, r.interval_count, null),"
  "  -- anchor day dropped",
  "-- anchor day dropped")

m("an OLD error stays on a schedule that has since run cleanly",
  "run_recurring_journals",
  "             last_error = null,\n"
  "             last_error_at = null",
  "             last_error = r.last_error,\n"
  "             last_error_at = r.last_error_at  -- stale error kept",
  "-- stale error kept")

m("advancing one schedule advances every schedule in the same company",
  "run_recurring_journals",
  "             last_error_at = null\n"
  "       where id = r.id;",
  "             last_error_at = null\n"
  "       where org_id = r.org_id;  -- advanced the whole company",
  "-- advanced the whole company")

# -------------------------------------------------------- the error path

m("a standing journal that FAILS does not say why",
  "run_recurring_journals",
  "         set last_error = sqlerrm, last_error_at = now()",
  "         set last_error = null, last_error_at = now()"
  "  -- failure reason not recorded",
  "-- failure reason not recorded")

m("a standing journal that FAILS does not say when",
  "run_recurring_journals",
  "         set last_error = sqlerrm, last_error_at = now()",
  "         set last_error = sqlerrm, last_error_at = null"
  "  -- failure time not recorded",
  "-- failure time not recorded")

m("a standing journal that FAILED is counted as having run",
  "run_recurring_journals",
  "         set last_error = sqlerrm, last_error_at = now()\n"
  "       where id = r.id;",
  "         set last_error = sqlerrm, last_error_at = now()\n"
  "       where id = r.id;\n"
  "      v_n := v_n + 1;  -- failure counted as a run",
  "-- failure counted as a run")

# `next_run_date` is deliberately LEFT ALONE on failure, so a template
# that would not post is retried the moment it is repaired. Advancing it
# instead means a broken month is skipped for good: the accrual never
# posts, nothing is overdue any more, and `last_error` is the only trace.
m("a journal that FAILED is skipped for good rather than retried",
  "run_recurring_journals",
  "         set last_error = sqlerrm, last_error_at = now()\n"
  "       where id = r.id;",
  "         set last_error = sqlerrm, last_error_at = now(),\n"
  "             next_run_date = app.advance_schedule(\n"
  "               r.next_run_date, r.frequency, r.interval_count, r.start_date)\n"
  "       where id = r.id;  -- failure skipped the month",
  "-- failure skipped the month")

# One broken standing journal must not stop the rent. Re-raising turns
# the swallow into a propagation: the whole cron run dies on the first
# bad template, and every schedule after it in the scan keeps its due
# date with no error recorded anywhere.
m("one broken standing journal stops the whole cron run",
  "run_recurring_journals",
  "    exception when others then\n",
  "    exception when others then\n"
  "      raise;  -- one failure stops the sweep\n",
  "-- one failure stops the sweep")

# ------------------------------------------------------------ the count

m("the sweep always reports that it did nothing",
  "run_recurring_journals",
  "  end loop;\n  return v_n;",
  "  end loop;\n  return 0;  -- count always zero",
  "-- count always zero")

m("CONTROL -- a comment beside the loop counter",
  "run_recurring_journals",
  "  v_n integer := 0;",
  "  v_n integer := 0;  -- CONTROL: this cannot change a count.",
  "-- CONTROL: this cannot change a count.")
