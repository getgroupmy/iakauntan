# Mutants for app.statutory_schedule_on (0029) -- which statutory table
# applies on which day -- and app.pcb_schedule_for_year beside it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0029_hrms_statutory_functions.sql \
#       supabase/tests/statutory_changeover.sql \
#       supabase/tests/mutants/statutory_schedule_on.py
#
# `statutory_changeover.sql` says an earlier sweep of the engine killed
# 26 of 33 and that this file was written for the seven about the day a
# table changes; no mutants file was kept, so `mutation_targets`-style
# scans read the function as never swept. This is that file.
#
# RESULT: 7 of 7 killed, the control surviving -- after one assertion
# was added. The first run left "a closed table applies for ever"
# alive: every fixture's tables were open-ended, or closed only by a
# successor that began the next day, so the `effective_to` clause never
# decided anything. A table for a season laid over a standing one --
# KWSP's 9% for 2021 alone -- is the shape it decides, and section 2b
# of the test now asks for it.

m('a table applies the day before it starts',
  'statutory_schedule_on',
  '     and s.effective_from <= p_date',
  '     and s.effective_from <= p_date + 1  -- a day early',
  '-- a day early')

m('a table does not apply on its first day',
  'statutory_schedule_on',
  '     and s.effective_from <= p_date',
  '     and s.effective_from < p_date  -- not on day one',
  '-- not on day one')

m('a table does not apply on its last day',
  'statutory_schedule_on',
  '     and (s.effective_to is null or s.effective_to >= p_date)',
  '     and (s.effective_to is null or s.effective_to > p_date)  -- not on the last day',
  '-- not on the last day')

m('a closed table applies for ever',
  'statutory_schedule_on',
  '     and (s.effective_to is null or s.effective_to >= p_date)',
  '     and true  -- never closed',
  '-- never closed')

m('an open-ended table never applies',
  'statutory_schedule_on',
  '     and (s.effective_to is null or s.effective_to >= p_date)',
  '     and (s.effective_to >= p_date)  -- open ends shut',
  '-- open ends shut')

m('the oldest table wins',
  'statutory_schedule_on',
  '   order by s.effective_from desc',
  '   order by s.effective_from asc  -- oldest first',
  '-- oldest first')

m('any body will do',
  'statutory_schedule_on',
  '   where s.body = p_body',
  '   where true  -- any body',
  '-- any body')

m('CONTROL: a comment inside statutory_schedule_on',
  'statutory_schedule_on',
  '   limit 1;\n$$;',
  '   limit 1;  -- (control)\n$$;',
  '(control)')
