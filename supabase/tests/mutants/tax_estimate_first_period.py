# Mutants for public.tax_estimate_first_period (0671) -- a company's
# first basis period: the CP204 is due three months from commencing
# operations, and a new SME pays no instalments for its first two years
# of assessment.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0671_the_first_year_has_its_own_rules.sql \
#       supabase/tests/tax_estimate_first_period.sql \
#       supabase/tests/mutants/tax_estimate_first_period.py
#
# then again against `tax_stack_end_to_end.sql`.
#
# RESULT: 12 mutants and a control. 12 killed in
# tax_estimate_first_period.sql.
#
#   The first sweep killed 9. Nobody outside the company asked, no
#   company sat on the RM2.5m capital limit, and no PERSON had a first
#   period -- a CP500 grants no exemption years, the one case where the
#   rules' own count decides. "tax_estimate_first_period, rule by rule"
#   asks all three.

m("a stranger reads it",
  "tax_estimate_first_period",
  "  if not app.is_org_member(e.org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("a missing capital is taken as within the limit",
  "tax_estimate_first_period",
  "             and e.paid_up_capital is not null\n",
  "             and true  -- capital unknown\n",
  "-- capital unknown")

m("a missing turnover is taken as within the limit",
  "tax_estimate_first_period",
  "             and e.gross_business_income is not null\n",
  "             and true  -- turnover unknown\n",
  "-- turnover unknown")

m("an established company is tested as a new one",
  "tax_estimate_first_period",
  "  v_known := e.first_period\n",
  "  v_known := true  -- any year\n",
  "-- any year")

m("a year with no exemption grants one",
  "tax_estimate_first_period",
  "              and r.first_period_exempt_years > 0",
  "              and true  -- no years",
  "-- no years")

m("capital on the limit is over it",
  "tax_estimate_first_period",
  "              and e.paid_up_capital <= rates.sme_capital_limit",
  "              and e.paid_up_capital < rates.sme_capital_limit  -- strictly",
  "-- strictly")

m("the capital limit is ignored",
  "tax_estimate_first_period",
  "              and e.paid_up_capital <= rates.sme_capital_limit",
  "              and true  -- any capital",
  "-- any capital")

m("the turnover limit is ignored",
  "tax_estimate_first_period",
  "              and e.gross_business_income <= rates.sme_turnover_limit;",
  "              and true;  -- any turnover",
  "-- any turnover")

m("the first CP204 is due a day late",
  "tax_estimate_first_period",
  "               + make_interval(months => r.first_period_filing_months)\n               - interval '1 day')::date",
  "               + make_interval(months => r.first_period_filing_months))::date  -- day late",
  "-- day late")

m("the first CP204 is due on commencing",
  "tax_estimate_first_period",
  "               + make_interval(months => r.first_period_filing_months)\n               - interval '1 day')::date",
  "               )::date  -- on the day",
  "-- on the day")

m("the ordinary date is the period's start",
  "tax_estimate_first_period",
  "    (e.start_date - coalesce(r.filing_days_before, 0))::date,",
  "    e.start_date,  -- no days before",
  "-- no days before")

m("the exemption runs one year too long",
  "tax_estimate_first_period",
  "         then e.year_of_assessment + r.first_period_exempt_years - 1",
  "         then e.year_of_assessment + r.first_period_exempt_years  -- a year long",
  "-- a year long")

m("CONTROL: a comment inside the block",
  "tax_estimate_first_period",
  "  -- The SME limits are READ from `0665`'s table rather than copied",
  "  -- CONTROL\n  -- The SME limits are READ from `0665`'s table rather than copied",
  "-- CONTROL")
