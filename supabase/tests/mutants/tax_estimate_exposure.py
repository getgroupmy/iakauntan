# Mutants for public.tax_estimate_exposure (0670) -- whether a CP204 or
# CP500 estimate meets its floor (85% of last year's), how far it fell
# short of the tax actually charged, and the s.107C(10) penalty on the
# part of the shortfall beyond the 30% tolerance.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0670_a_person_pays_on_a_different_rhythm.sql \
#       supabase/tests/tax_estimates.sql \
#       supabase/tests/mutants/tax_estimate_exposure.py
#
# then again against `tax_estimate_cp500.sql` and `tax_stack_end_to_end.sql`.
#
# RESULT: 14 mutants and a control. 13 killed in tax_estimates.sql, 1
# equivalent.
#
#   The first sweep killed 9 there. No computation recorded zakat, no
#   CP500 had a prior figure, and no fixture pinned which month of its
#   basis period today falls in. "tax_estimate_exposure, rule by rule"
#   asks all three -- the revision month as a PAIR of companies on the
#   same day, one in its sixth month and one in its fifth, so a month
#   counted from anything but the period's own start gives both the same
#   answer and fails one, whatever today's month is.
#
#   EQUIVALENT by the callee: "a refund due is a negative tax owed".
#   `tax_computation` caps the zakat rebate at the tax charged, so
#   charged less rebate is never negative.

m("a stranger reads the exposure",
  "tax_estimate_exposure",
  "  if not app.is_org_member(e.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("the floor is the whole of last year's",
  "tax_estimate_exposure",
  "                   * r.floor_percent_of_prior / 100, 2);",
  "                   * 100 / 100, 2);  -- all of it",
  "-- all of it")

m("the zakat rebate is not taken off what was charged",
  "tax_estimate_exposure",
  "    select tc.tax_charged - tc.zakat_rebate into v_actual",
  "    select tc.tax_charged into v_actual  -- no zakat",
  "-- no zakat")

m("a refund due is a negative tax owed",
  "tax_estimate_exposure",
  "    v_actual := greatest(v_actual, 0);",
  "    v_actual := v_actual;  -- negative",
  "-- negative")

m("an over-estimate is a negative shortfall",
  "tax_estimate_exposure",
  "    v_short := greatest(v_actual - e.estimated_tax, 0);",
  "    v_short := v_actual - e.estimated_tax;  -- negative",
  "-- negative")

m("the tolerance is a share of the estimate",
  "tax_estimate_exposure",
  "    v_tol := round(v_actual * r.under_tolerance_percent / 100, 2);",
  "    v_tol := round(e.estimated_tax * r.under_tolerance_percent / 100, 2);  -- of estimate",
  "-- of estimate")

m("the penalty is on the whole shortfall",
  "tax_estimate_exposure",
  "    v_excess := greatest(v_short - v_tol, 0);",
  "    v_excess := v_short;  -- no tolerance",
  "-- no tolerance")

m("a shortfall inside the tolerance is a negative excess",
  "tax_estimate_exposure",
  "    v_excess := greatest(v_short - v_tol, 0);",
  "    v_excess := v_short - v_tol;  -- negative",
  "-- negative")

m("the penalty is the excess itself",
  "tax_estimate_exposure",
  "         then round(v_excess * r.under_penalty_percent / 100, 2)",
  "         then round(v_excess, 2)  -- 100%",
  "-- 100%")

m("an unknown prior is a floor of nothing, met",
  "tax_estimate_exposure",
  "    (v_has_floor and e.prior_estimate is not null\n       and e.estimated_tax >= v_floor),",
  "    (v_has_floor\n       and e.estimated_tax >= v_floor),  -- unknown met",
  "-- unknown met")

m("an estimate exactly on the floor misses it",
  "tax_estimate_exposure",
  "       and e.estimated_tax >= v_floor),",
  "       and e.estimated_tax > v_floor),  -- strictly",
  "-- strictly")

m("a CP500 is said to meet a floor it does not have",
  "tax_estimate_exposure",
  "    (v_has_floor and e.prior_estimate is not null\n       and e.estimated_tax >= v_floor),",
  "    (e.prior_estimate is not null\n       and e.estimated_tax >= v_floor),  -- floorless",
  "-- floorless")

m("the revision month is counted from January",
  "tax_estimate_exposure",
  "               + (extract(month from app.today())::integer\n                    - extract(month from e.start_date)::integer);",
  "               + (extract(month from app.today())::integer\n                    - 1);  -- from january",
  "-- from january")

m("the revision month is one late",
  "tax_estimate_exposure",
  "  v_month := 1 + (extract(year from app.today())::integer",
  "  v_month := 2 + (extract(year from app.today())::integer  -- one late",
  "-- one late")

m("CONTROL: a comment inside the block",
  "tax_estimate_exposure",
  "    -- The tolerance is a share of what was ACTUALLY owed, not of the",
  "    -- CONTROL\n    -- The tolerance is a share of what was ACTUALLY owed, not of the",
  "-- CONTROL")
