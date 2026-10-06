# Mutants for app.leave_entitlement (0058) -- the days a leave type gives
# an employee in a year: flat, or by years of service through the bands.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0058_periodic_jobs.sql \
#       supabase/tests/leave_year_shapes.sql \
#       supabase/tests/mutants/leave_entitlement.py
#
# then again against `hr_reference.sql`.
#
# Noted, not a defect: service is counted as `year - year(hire_date)`,
# the calendar years since the hire year, which credits a December hire
# a year early -- more than the Employment Act's minimum, never less.
#
# RESULT: 6 mutants and a control. 6 killed in leave_year_shapes.sql.
#
#   The first sweep killed 5. The band's END was never consulted: the
#   Act's bands are contiguous, so the highest band starting at or
#   before the service always runs past it. "A band with a gap after it"
#   gives HR's own bands a gap, where the end is what decides.

m("a scaling type is given its flat default",
  "leave_entitlement",
  "    when not p_leave_type.scales_with_service then p_leave_type.default_days",
  "    when true then p_leave_type.default_days  -- never scales",
  "-- never scales")

m("a band starting after the service is used",
  "leave_entitlement",
  "          and b.service_years_from <= greatest(",
  "          and b.service_years_from >= greatest(  -- wrong side",
  "-- wrong side")

m("a band that has ended is used",
  "leave_entitlement",
  "          and (b.service_years_to is null or b.service_years_to >= greatest(",
  "          and (true or b.service_years_to >= greatest(  -- open ended",
  "-- open ended")

m("the lowest band wins",
  "leave_entitlement",
  "        order by b.service_years_from desc limit 1),",
  "        order by b.service_years_from limit 1),  -- lowest",
  "-- lowest")

m("another leave type's bands are read",
  "leave_entitlement",
  "        where b.leave_type_id = p_leave_type.id",
  "        where true  -- any type",
  "-- any type")

m("with no band the type gives nothing",
  "leave_entitlement",
  "      p_leave_type.default_days)\n  end;",
  "      0)  -- nothing\n  end;",
  "-- nothing")

m("CONTROL: a comment inside the block",
  "leave_entitlement",
  "    when not p_leave_type.scales_with_service then p_leave_type.default_days",
  "    -- CONTROL\n    when not p_leave_type.scales_with_service then p_leave_type.default_days",
  "-- CONTROL")
