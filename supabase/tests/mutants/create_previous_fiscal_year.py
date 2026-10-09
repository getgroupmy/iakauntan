# Mutants for public.create_previous_fiscal_year (0659, restated in
# 0782) and public.create_fiscal_year (0422, restated in 0782) -- a
# year with twelve open periods tiling it back to back whatever day it
# starts; the previous one anchored to its END, immediately before the
# earliest; refused for a company with no year (previous) or one that
# does not exist, an overlapping year, and anybody who may not post.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0782_a_fiscal_year_is_tiled_whatever_day_it_starts.sql \
#       supabase/tests/previous_fiscal_year.sql \
#       supabase/tests/mutants/create_previous_fiscal_year.py
#
# RESULT: 19 mutants and a control. 13 killed by
# `previous_fiscal_year.sql`. Swept first against 0659: 6 of 13; the
# function's two guards and the period names were unasked, and the
# sweep found what `0782` fixes -- periods built by adding months to a
# 31st left days in no period.
#
# Six are EQUIVALENT, each for a reason that is arithmetic rather than
# a fixture:
#   * "an overlap is not asked about" and "the end is not checked": a
#     year anchored to the day before the EARLIEST cannot overlap one
#     (any that did would be earlier still), and its end is the day
#     before by construction. Both are kept as guards against an edit.
#   * the two "starts a month on" mutants: the previous period ends on
#     the year's start plus n months less a day, so the day after it IS
#     the year's start plus n months.
#   * "the last period stops at a month boundary" (both functions) and
#     "a period runs past the year": counted from the year's start, no
#     period ends past the year end and the twelfth lands on it, so
#     neither clamp in `if i = 11 or v_p_end > v_end` can fire. Kept,
#     as `0659` kept it, against a year whose length is ever computed
#     differently from its periods.

m("a company that does not exist is not said so",
  "create_previous_fiscal_year",
  "  if not exists (select 1 from public.organizations where id = p_org_id) then",
  "  if false then  -- any company",
  "-- any company")

m("anybody opens a year",
  "create_previous_fiscal_year",
  "  if not app.can_post(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("the year before nothing is made",
  "create_previous_fiscal_year",
  "  if v_earliest is null then",
  "  if false then  -- before nothing",
  "-- before nothing")

m("it ends two days before",
  "create_previous_fiscal_year",
  "  v_end := (v_earliest - interval '1 day')::date;",
  "  v_end := (v_earliest - interval '2 days')::date;  -- a day short",
  "-- a day short")

m("it starts a day early",
  "create_previous_fiscal_year",
  "  v_start := (v_end - interval '1 year' + interval '1 day')::date;",
  "  v_start := (v_end - interval '1 year')::date;  -- a day long",
  "-- a day long")

m("an overlap is not asked about",
  "create_previous_fiscal_year",
  "  if exists (select 1 from public.fiscal_years f\n              where f.org_id = p_org_id\n                and f.start_date <= v_end and f.end_date >= v_start) then",
  "  if false then  -- no overlap check",
  "-- no overlap check")

m("the end is not checked",
  "create_previous_fiscal_year",
  "  if v_end <> (v_earliest - 1) then",
  "  if false then  -- unchecked",
  "-- unchecked")

m("a year across two calendar years is named for one",
  "create_previous_fiscal_year",
  "          case when extract(year from v_start) = extract(year from v_end)",
  "          case when true  -- one year's name",
  "-- one year's name")

m("eleven periods",
  "create_previous_fiscal_year",
  "  for i in 0 .. 11 loop",
  "  for i in 0 .. 10 loop  -- eleven",
  "-- eleven")

m("the last period stops at a month boundary",
  "create_previous_fiscal_year",
  "    if i = 11 or v_p_end > v_end then v_p_end := v_end; end if;",
  "    if v_p_end > v_end then v_p_end := v_end; end if;  -- month boundary",
  "-- month boundary")

m("a period runs past the year",
  "create_previous_fiscal_year",
  "    if i = 11 or v_p_end > v_end then v_p_end := v_end; end if;",
  "    if i = 11 then v_p_end := v_end; end if;  -- unclamped",
  "-- unclamped")

m("a period starts a month on from the year, not after the last (before 0782)",
  "create_previous_fiscal_year",
  "    v_p_start := (v_p_end + 1)::date;",
  "    v_p_start := (v_start + (i || ' months')::interval)::date;  -- by months",
  "-- by months")

m("a period ends a month after its own start (before 0782)",
  "create_previous_fiscal_year",
  "    v_p_end := (v_start + ((i + 1) || ' months')::interval\n                - interval '1 day')::date;",
  "    v_p_end := (v_p_start + interval '1 month' - interval '1 day')::date;  -- own start",
  "-- own start")

m("periods are numbered from nought",
  "create_previous_fiscal_year",
  "    values (p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'),",
  "    values (p_org_id, v_fy_id, i, to_char(v_p_start, 'Mon YYYY'),  -- from nought",
  "-- from nought")

m("periods are named by number",
  "create_previous_fiscal_year",
  "    values (p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'),",
  "    values (p_org_id, v_fy_id, i + 1, 'P' || (i + 1),  -- by number",
  "-- by number")

m("create_fiscal_year: a period starts a month on, not after the last (before 0782)",
  "create_fiscal_year",
  "    v_p_start := (v_p_end + 1)::date;",
  "    v_p_start := (v_start + (i || ' months')::interval)::date;  -- by months",
  "-- by months")

m("create_fiscal_year: a period ends a month after its own start (before 0782)",
  "create_fiscal_year",
  "    v_p_end := (v_start + ((i + 1) || ' months')::interval\n                - interval '1 day')::date;",
  "    v_p_end := (v_p_start + interval '1 month' - interval '1 day')::date;  -- own start",
  "-- own start")

m("create_fiscal_year: the first period starts a day late",
  "create_fiscal_year",
  "  v_p_end := (v_start - 1)::date;",
  "  v_p_end := v_start;  -- a day late",
  "-- a day late")

m("create_fiscal_year: the last period is not the year end",
  "create_fiscal_year",
  "    if i = 11 or v_p_end > v_end then v_p_end := v_end; end if;",
  "    if v_p_end > v_end then v_p_end := v_end; end if;  -- month boundary",
  "-- month boundary")

m("CONTROL: a comment inside the block",
  "create_previous_fiscal_year",
  "  if v_earliest is null then",
  "  if v_earliest is null then  -- (control)",
  "(control)")
