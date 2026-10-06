# Mutants for public.fs_deadlines (0607) -- the Companies Act 2016 clock
# for a set of financial statements: circulate within six months of the
# year end (s.258), lodge within thirty days of circulating (s.259), and
# the outside limit if it was never circulated.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0607_a_company_is_a_kind_of_business_too.sql \
#       supabase/tests/fs_deadlines.sql \
#       supabase/tests/mutants/fs_deadlines.py
#
# then again against `mbrs.sql`, `fs_statutory_order.sql`,
# `corp_filing_shapes.sql` and `entity_types_for_companies.sql`.
#
# RESULT: 9 mutants and a control. 9 killed in fs_deadlines.sql alone,
# which was already written boundary by boundary -- the day due, the day
# after, ten days out, a lodged filing, both companies' sections and an
# outsider. Recorded so the census counts it rather than re-sweeping it.

m("a stranger reads the company's clock",
  "fs_deadlines",
  "  if not app.is_org_member(f.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("six months is 180 days",
  "fs_deadlines",
  "  v_circulate := (f.fy_end + interval '6 months')::date;",
  "  v_circulate := f.fy_end + 180;  -- 180 days",
  "-- 180 days")

m("circulation is due in five months",
  "fs_deadlines",
  "  v_circulate := (f.fy_end + interval '6 months')::date;",
  "  v_circulate := (f.fy_end + interval '5 months')::date;  -- five",
  "-- five")

m("lodgement runs from the deadline even when circulated early",
  "fs_deadlines",
  "  v_lodge := app.fs_lodge_by(f.fy_end, f.circulated_on);",
  "  v_lodge := app.fs_lodge_by(f.fy_end, null);  -- ignores the act",
  "-- ignores the act")

m("the outside limit is the circulation deadline itself",
  "fs_deadlines",
  "    (v_circulate + 30)::date,",
  "    v_circulate,  -- no thirty days",
  "-- no thirty days")

m("days left counts to the circulation deadline",
  "fs_deadlines",
  "    (v_lodge - app.today())::integer,",
  "    (v_circulate - app.today())::integer,  -- wrong deadline",
  "-- wrong deadline")

m("a lodged filing is still late",
  "fs_deadlines",
  "    f.lodged_on is null and app.today() > v_lodge,",
  "    app.today() > v_lodge,  -- lodged too",
  "-- lodged too")

m("the last day is already late",
  "fs_deadlines",
  "    f.lodged_on is null and app.today() > v_lodge,",
  "    f.lodged_on is null and app.today() >= v_lodge,  -- last day late",
  "-- last day late")

m("a public company is told the private company's sections",
  "fs_deadlines",
  "    case when coalesce(v_public, false)",
  "    case when false  -- never public",
  "-- never public")

m("CONTROL: a comment inside the block",
  "fs_deadlines",
  "  -- 0607. Was `o.entity_type = 'bhd'`.",
  "  -- CONTROL\n  -- 0607. Was `o.entity_type = 'bhd'`.",
  "-- CONTROL")
