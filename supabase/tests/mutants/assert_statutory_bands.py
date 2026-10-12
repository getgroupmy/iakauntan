# Mutants for app.assert_statutory_bands (0404) -- the check that a
# statutory table's wage bands start at nothing, run to the top, and
# neither leave a wage between two bands nor cover one twice.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0404_the_wage_that_fell_between_two_bands.sql \
#       supabase/tests/statutory_schedules.sql \
#       supabase/tests/mutants/assert_statutory_bands.py
#
# RESULT: 10 of 10 killed against `statutory_schedules.sql`, the control
# surviving -- after five assertions were added there. Run first
# against `statutory_bands.sql`, it killed one: that file loops the check
# over every SHIPPED table, which are all well formed, so it can only
# notice a mutant that refuses a good table ("the next sen is a gap").
# `statutory_schedules.sql` publishes broken tables; it lacked a gap
# under a ringgit, two bands meeting on one sen, a category stopping
# short while another follows, a sen-apart table accepted, and a
# schedule with no bands at all.

m('a category may stop short of the top, if another follows',
  'assert_statutory_bands',
  '      if not v_first and v_prev_to is not null then',
  '      if false then  -- earlier categories unasked',
  '-- earlier categories unasked')

m('the first band may start above nothing',
  'assert_statutory_bands',
  '      if r.wage_from > 0 then',
  '      if false then  -- any start',
  '-- any start')

m('a band may follow one that runs to the top',
  'assert_statutory_bands',
  '      if v_prev_to is null then',
  '      if false then  -- open bands mid-table',
  '-- open bands mid-table')

m('a gap is allowed',
  'assert_statutory_bands',
  '      if r.wage_from > v_prev_to + 0.01 then',
  '      if false then  -- gaps',
  '-- gaps')

m('a gap of under a ringgit is allowed',
  'assert_statutory_bands',
  '      if r.wage_from > v_prev_to + 0.01 then',
  '      if r.wage_from > v_prev_to + 1 then  -- a ringgit of slack',
  '-- a ringgit of slack')

m('the next sen is a gap',
  'assert_statutory_bands',
  '      if r.wage_from > v_prev_to + 0.01 then',
  '      if r.wage_from >= v_prev_to + 0.01 then  -- no slack at all',
  '-- no slack at all')

m('two bands may cover the same wage',
  'assert_statutory_bands',
  '      if r.wage_from <= v_prev_to then',
  '      if false then  -- overlaps',
  '-- overlaps')

m('two bands may share their edge',
  'assert_statutory_bands',
  '      if r.wage_from <= v_prev_to then',
  '      if r.wage_from < v_prev_to then  -- shared edge',
  '-- shared edge')

m('a schedule may have no bands',
  'assert_statutory_bands',
  '  if v_first then',
  '  if false then  -- empty is fine',
  '-- empty is fine')

m('the last category may stop short of the top',
  'assert_statutory_bands',
  '  if v_prev_to is not null then',
  '  if false then  -- last unasked',
  '-- last unasked')

m('CONTROL: a comment inside assert_statutory_bands',
  'assert_statutory_bands',
  '  if v_first then',
  '  if v_first then  -- (control)',
  '(control)')
