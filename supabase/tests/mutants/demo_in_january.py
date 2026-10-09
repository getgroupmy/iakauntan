# Mutants for 0771 -- the demo rebuilds in January: a demo company opens
# the year before this one, and Kilang's lodged accounts are for the last
# year whose lodgement (160 days on) has passed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0771_the_demo_rebuilds_in_january.sql \
#       supabase/tests/demo_rebuild.sql \
#       supabase/tests/mutants/demo_in_january.py
#
# RESULT: 5 of 6 killed by `demo_rebuild.sql` on 9 October, the control
# surviving.
#
# SURVIVES IN SEASON, NOT EQUIVALENT: "Kilang's year is the last
# complete one again". From 9 June to 31 December the old formula and
# `app.demo_last_lodged_year_end` give the same year, so no assertion
# run on those days can tell them apart; from 1 January to 8 June the
# old one dates a lodgement in the future, `fs_filing_dates_guard`
# refuses it and the rebuild fails -- which `run_at_dates.sh` sees on
# any of its January-to-May days. The helper itself is asserted at its
# boundaries (9 June / 8 June, 5 January, 31 December), which kills
# every mutant of it.
#
# The sweep also caught the test's own comment: it claimed "an open
# period 75 days back" killed "this year only" on any day. It does not
# -- from mid-March 75 days back is this year -- and "the year before
# this one" is the assertion that does.

m("a demo company has only the year today is in",
  "demo_company",
  "  perform public.create_previous_fiscal_year(v_org);",
  "  perform 1;  -- this year only",
  "-- this year only")

m("the lodged year is a day too late: lodged tomorrow counts",
  "demo_last_lodged_year_end",
  "  select date_trunc('year', (p_on - 159)::timestamp)::date - 1",
  "  select date_trunc('year', (p_on - 160)::timestamp)::date - 1  -- 160",
  "-- 160")

m("the lodged year is a day too early",
  "demo_last_lodged_year_end",
  "  select date_trunc('year', (p_on - 159)::timestamp)::date - 1",
  "  select date_trunc('year', (p_on - 158)::timestamp)::date - 1  -- 158",
  "-- 158")

m("the last complete year, whatever its lodgement",
  "demo_last_lodged_year_end",
  "  select date_trunc('year', (p_on - 159)::timestamp)::date - 1",
  "  select date_trunc('year', p_on::timestamp)::date - 1  -- last complete year",
  "-- last complete year")

m("the first day of the year rather than the last before it",
  "demo_last_lodged_year_end",
  "  select date_trunc('year', (p_on - 159)::timestamp)::date - 1",
  "  select date_trunc('year', (p_on - 159)::timestamp)::date  -- first day",
  "-- first day")

m("Kilang's year is the last complete one again (the old formula)",
  "demo_amanah_accounts",
  "  v_k_end  date := app.demo_last_lodged_year_end(v_today);",
  "  v_k_end  date := (date_trunc('year', v_today) - interval '1 day')::date;  -- old formula",
  "-- old formula")

m("CONTROL: a comment inside the block",
  "demo_company",
  "  perform public.create_previous_fiscal_year(v_org);",
  "  perform public.create_previous_fiscal_year(v_org);  -- (control)",
  "(control)")
