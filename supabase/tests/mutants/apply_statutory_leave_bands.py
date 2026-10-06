# Mutants for public.apply_statutory_leave_bands (0091) -- the
# Employment Act 1955 bands written onto a leave type: annual leave
# 8 / 12 / 16 days (s.60E) and sick leave 14 / 18 / 22 (s.60F), for
# under two years, two to under five, and five or more.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0091_hr_reference_data.sql \
#       supabase/tests/hr_reference.sql \
#       supabase/tests/mutants/apply_statutory_leave_bands.py
#
# then again against `leave_year_shapes.sql`.
#
# RESULT: 12 mutants and a control. 12 killed in leave_year_shapes.sql,
# which asserts every band's days and edges for both presets; the HR
# guard is the one hr_reference.sql does not reach.

m("somebody who is not HR sets the bands",
  "apply_statutory_leave_bands",
  "  if not app.can_manage_hr(v_org) then",
  "  if false then  -- anybody",
  "-- anybody")

m("an unknown preset is applied as sick leave",
  "apply_statutory_leave_bands",
  "  if p_preset not in ('annual', 'sick') then",
  "  if false then  -- any preset",
  "-- any preset")

m("the old bands are kept beside the new",
  "apply_statutory_leave_bands",
  "  delete from public.leave_entitlement_bands\n   where leave_type_id = p_leave_type_id;",
  "  null;  -- kept",
  "-- kept")

m("annual leave under two years is 10 days",
  "apply_statutory_leave_bands",
  "      (0, 1,    case p_preset when 'annual' then 8  else 14 end),",
  "      (0, 1,    case p_preset when 'annual' then 10 else 14 end),  -- 10",
  "-- 10")

m("sick leave under two years is 12 days",
  "apply_statutory_leave_bands",
  "      (0, 1,    case p_preset when 'annual' then 8  else 14 end),",
  "      (0, 1,    case p_preset when 'annual' then 8  else 12 end),  -- 12",
  "-- 12")

m("the middle band starts at three years",
  "apply_statutory_leave_bands",
  "      (2, 4,    case p_preset when 'annual' then 12 else 18 end),",
  "      (3, 4,    case p_preset when 'annual' then 12 else 18 end),  -- from 3",
  "-- from 3")

m("annual leave in the middle band is 14 days",
  "apply_statutory_leave_bands",
  "      (2, 4,    case p_preset when 'annual' then 12 else 18 end),",
  "      (2, 4,    case p_preset when 'annual' then 14 else 18 end),  -- 14",
  "-- 14")

m("sick leave in the middle band is 16 days",
  "apply_statutory_leave_bands",
  "      (2, 4,    case p_preset when 'annual' then 12 else 18 end),",
  "      (2, 4,    case p_preset when 'annual' then 12 else 16 end),  -- 16",
  "-- 16")

m("the top band starts at six years",
  "apply_statutory_leave_bands",
  "      (5, null, case p_preset when 'annual' then 16 else 22 end)",
  "      (6, null, case p_preset when 'annual' then 16 else 22 end)  -- from 6",
  "-- from 6")

m("annual leave at five years is 18 days",
  "apply_statutory_leave_bands",
  "      (5, null, case p_preset when 'annual' then 16 else 22 end)",
  "      (5, null, case p_preset when 'annual' then 18 else 22 end)  -- 18",
  "-- 18")

m("sick leave at five years is 20 days",
  "apply_statutory_leave_bands",
  "      (5, null, case p_preset when 'annual' then 16 else 22 end)",
  "      (5, null, case p_preset when 'annual' then 16 else 20 end)  -- 20",
  "-- 20")

m("the type is not switched to scale with service",
  "apply_statutory_leave_bands",
  "  update public.leave_types\n     set scales_with_service = true\n   where id = p_leave_type_id and not scales_with_service;",
  "  null;  -- not switched",
  "-- not switched")

m("CONTROL: a comment inside the block",
  "apply_statutory_leave_bands",
  "  -- The bands are only consulted when the leave type says it scales.",
  "  -- CONTROL\n  -- The bands are only consulted when the leave type says it scales.",
  "-- CONTROL")
