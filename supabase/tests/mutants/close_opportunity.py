# Mutants for public.close_opportunity (0422) and reopen_opportunity
# (0373) -- a deal closed with its outcome and, unless won, its reason:
# it must exist and not be deleted, the caller write; won, lost or
# abandoned only; not twice; into the pipeline's LAST won or lost stage
# (abandoned lands in lost); the reason trimmed, on the right column;
# the competitor trimmed; dated the day given, else the date it already
# had, else today. Reopened only when closed, into the stage asked for
# if it is an open stage of THIS pipeline, else the first open stage,
# with the close date and both reasons cleared.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0422_what_day_the_work_was_done.sql \
#       supabase/tests/win_loss.sql \
#       supabase/tests/mutants/close_opportunity.py
#
# and for `reopen_opportunity` the same against 0373 with
# `mutants/reopen_opportunity.py`.
#
# RESULT: 11 mutants and a control, all killed by `win_loss.sql`; six
# before its rule-by-rule block. Every pipeline had one won and one
# lost stage, every deal was the owner's with a clean competitor -- so
# the last-stage rule, a pipeline with nowhere to close into, the trim,
# a missing deal and a stranger were unasked. "Closes as anything"
# died to the table's own check constraint.

m("a deal that does not exist is not said so",
  "close_opportunity",
  "  if v_o.id is null then\n    raise exception 'No such opportunity.'",
  "  if false then  -- no such deal\n    raise exception 'No such opportunity.'",
  "-- no such deal")

m("anybody closes a deal",
  "close_opportunity",
  "  if not app.can_write(v_o.org_id) then",
  "  if false then  -- whoever asks",
  "-- whoever asks")

m("a deal closes as anything",
  "close_opportunity",
  "  if p_outcome not in ('won', 'lost', 'abandoned') then",
  "  if false then  -- any outcome",
  "-- any outcome")

m("a closed deal is closed again",
  "close_opportunity",
  "  if v_o.status <> 'open' then",
  "  if false then  -- twice",
  "-- twice")

m("a lost deal needs no reason",
  "close_opportunity",
  "  if p_outcome <> 'won' and v_reason is null then",
  "  if false then  -- no reason",
  "-- no reason")

m("an abandoned deal lands in the won column",
  "close_opportunity",
  "  v_type := case when p_outcome = 'won' then 'won' else 'lost' end;",
  "  v_type := case when p_outcome = 'lost' then 'lost' else 'won' end;  -- abandoned as won",
  "-- abandoned as won")

m("the first closing stage is used, not the last",
  "close_opportunity",
  "   order by s.sort_order desc limit 1;",
  "   order by s.sort_order limit 1;  -- first stage",
  "-- first stage")

m("a pipeline with no closing stage is not said so",
  "close_opportunity",
  "  if v_stage is null then\n    raise exception\n      'This pipeline has no % stage to close into.",
  "  if false then  -- no stage\n    raise exception\n      'This pipeline has no % stage to close into.",
  "-- no stage")

m("a date given is not used",
  "close_opportunity",
  "    actual_close_date = coalesce(p_closed_on, actual_close_date, app.today()),",
  "    actual_close_date = coalesce(actual_close_date, app.today()),  -- date ignored",
  "-- date ignored")

m("a lost reason is filed as a won one",
  "close_opportunity",
  "    lost_reason       = case when p_outcome = 'won' then null else v_reason end,",
  "    lost_reason       = null,  -- reason lost",
  "-- reason lost")

m("the competitor is kept untrimmed",
  "close_opportunity",
  "    competitor        = nullif(trim(coalesce(p_competitor, '')), ''),",
  "    competitor        = p_competitor,  -- untrimmed",
  "-- untrimmed")

m("CONTROL: a comment inside the block",
  "close_opportunity",
  "  if v_o.status <> 'open' then",
  "  if v_o.status <> 'open' then  -- (control)",
  "(control)")
