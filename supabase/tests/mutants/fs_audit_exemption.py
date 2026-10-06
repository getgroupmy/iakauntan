# Mutants for public.fs_audit_exemption and app.audit_exemption_thresholds
# (0751) -- the three audit-exemption grounds, with the threshold ground
# under Practice Directive 3/2018 before 2025 and 10/2024 from 2025.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0751_the_audit_exemption_under_practice_directive_10_2024.sql \
#       supabase/tests/mbrs.sql \
#       supabase/tests/mutants/fs_audit_exemption.py
#
# RESULT: 15 mutants and a control. 15 killed in mbrs.sql.
#
#   The first sweep killed 12. The three left were the phase read from
#   the year's END (a July-to-June year that commenced in 2024 is the
#   old directive's), revenue of exactly RM1,000,000 (within, since the
#   directive says "not exceeding"), and "cannot tell" said of a missing
#   headcount that could not have made two. "Practice Directive 10/2024,
#   the edges" kills each.

m("2025 is still the old directive",
  "audit_exemption_thresholds",
  "  offset case when p_fy_start < date '2025-01-01' then 0",
  "  offset case when p_fy_start <= date '2025-01-01' then 0  -- day late",
  "-- day late")

m("2026 is still the first phase",
  "audit_exemption_thresholds",
  "              when p_fy_start < date '2026-01-01' then 1",
  "              when p_fy_start <= date '2026-01-01' then 1  -- day late",
  "-- day late")

m("2027 is still the second phase",
  "audit_exemption_thresholds",
  "              when p_fy_start < date '2027-01-01' then 2",
  "              when p_fy_start < date '2028-01-01' then 2  -- a year late",
  "-- a year late")

m("the first phase's headcount is the second's",
  "audit_exemption_thresholds",
  "    ('Practice Directive 10/2024', 1000000::numeric, 1000000::numeric, 10, true),",
  "    ('Practice Directive 10/2024', 1000000::numeric, 1000000::numeric, 20, true),  -- 20",
  "-- 20")

m("the first phase needs all three",
  "audit_exemption_thresholds",
  "    ('Practice Directive 10/2024', 1000000::numeric, 1000000::numeric, 10, true),",
  "    ('Practice Directive 10/2024', 1000000::numeric, 1000000::numeric, 10, false),  -- all three",
  "-- all three")

m("the old directive takes any two",
  "audit_exemption_thresholds",
  "    ('Practice Directive 3/2018',  100000::numeric,  300000::numeric,  5, false),",
  "    ('Practice Directive 3/2018',  100000::numeric,  300000::numeric,  5, true),  -- any two",
  "-- any two")

m("the phase is read from the year's end",
  "fs_audit_exemption",
  "  select * into t from app.audit_exemption_thresholds(f.fy_start);",
  "  select * into t from app.audit_exemption_thresholds(f.fy_end);  -- from the end",
  "-- from the end")

m("two of three is not enough",
  "fs_audit_exemption",
  "     case when t.any_two then v_met >= 2",
  "     case when t.any_two then v_met >= 3  -- all three",
  "-- all three")

m("one of three is enough",
  "fs_audit_exemption",
  "     case when t.any_two then v_met >= 2",
  "     case when t.any_two then v_met >= 1  -- just one",
  "-- just one")

m("revenue on the limit is over it",
  "fs_audit_exemption",
  "  v_rev_ok    := v_max_rev <= t.revenue;",
  "  v_rev_ok    := v_max_rev < t.revenue;  -- strictly",
  "-- strictly")

m("assets are never within",
  "fs_audit_exemption",
  "  v_assets_ok := v_max_assets <= t.assets;",
  "  v_assets_ok := false;  -- never",
  "-- never")

m("a missing headcount counts as within",
  "fs_audit_exemption",
  "  v_staff_ok  := v_staff_known and v_max_staff <= t.staff;",
  "  v_staff_ok  := v_max_staff <= t.staff;  -- unknown is fine",
  "-- unknown is fine")

m("the headcount limit is one short",
  "fs_audit_exemption",
  "  v_staff_ok  := v_staff_known and v_max_staff <= t.staff;",
  "  v_staff_ok  := v_staff_known and v_max_staff < t.staff;  -- one short",
  "-- one short")

m("the old directive needs only revenue and assets",
  "fs_audit_exemption",
  "          else v_staff_known and v_rev_ok and v_assets_ok and v_staff_ok end,",
  "          else v_rev_ok and v_assets_ok end,  -- no headcount",
  "-- no headcount")

m("a missing headcount that would not decide it is still cannot tell",
  "fs_audit_exemption",
  "       when t.any_two and not v_staff_known and v_met = 1",
  "       when t.any_two and not v_staff_known  -- always",
  "-- always")

m("CONTROL: a comment inside the block",
  "fs_audit_exemption",
  "       -- Practice Directive 10/2024: any two of the three.",
  "       -- CONTROL\n       -- Practice Directive 10/2024: any two of the three.",
  "-- CONTROL")
