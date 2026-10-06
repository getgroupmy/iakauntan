# Mutants for public.capital_allowance_schedule (0664) -- the Schedule 3
# working for a year of assessment: qualifying expenditure, initial and
# annual allowances, the small value write-off and its RM20,000 cap,
# the balancing adjustment on disposal, and the residual carried on.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0664_what_the_taxman_allows_is_not_what_the_accounts_say.sql \
#       supabase/tests/capital_allowances.sql \
#       supabase/tests/mutants/capital_allowance_schedule.py
#
# RESULT: (pending)

m("a stranger reads the schedule",
  "capital_allowance_schedule",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- stranger",
  "-- stranger")

m("another company's assets are on the schedule",
  "capital_allowance_schedule",
  "     where a.org_id = p_org_id\n       and a.deleted_at is null",
  "     where true  -- any org\n       and a.deleted_at is null",
  "-- any org")

m("a deleted asset is on the schedule",
  "capital_allowance_schedule",
  "     where a.org_id = p_org_id\n       and a.deleted_at is null",
  "     where a.org_id = p_org_id\n       and true  -- deleted",
  "-- deleted")

m("an asset bought after the year is on the schedule",
  "capital_allowance_schedule",
  "       and extract(year from a.acquisition_date) <= p_year",
  "       and true  -- future asset",
  "-- future asset")

m("an asset is first on the schedule the year AFTER it was bought",
  "capital_allowance_schedule",
  "       and extract(year from a.acquisition_date) <= p_year",
  "       and extract(year from a.acquisition_date) < p_year  -- lt",
  "-- lt")

m("an asset sold in an earlier year stays on the schedule",
  "capital_allowance_schedule",
  "       and (a.disposal_date is null\n            or extract(year from a.disposal_date) >= p_year)",
  "       and (true  -- sold earlier\n            or extract(year from a.disposal_date) >= p_year)",
  "-- sold earlier")

m("an asset leaves the schedule the year it is sold",
  "capital_allowance_schedule",
  "            or extract(year from a.disposal_date) >= p_year)",
  "            or extract(year from a.disposal_date) > p_year)  -- gone in year",
  "-- gone in year")

m("the cost cap is ignored",
  "capital_allowance_schedule",
  "           app.ca_qualifying_expenditure(s.cost, s.cost_cap) as qe,",
  "           s.cost as qe,  -- no cap",
  "-- no cap")

m("a sale in another year is treated as this year's",
  "capital_allowance_schedule",
  "            and extract(year from s.disposal_date) = p_year)  as sold_now,",
  "            )  as sold_now,  -- any year sold",
  "-- any year sold")

m("an asset AT the small value threshold is small",
  "capital_allowance_schedule",
  "                  < s.small_value_threshold)                  as is_small",
  "                  <= s.small_value_threshold)  -- le             as is_small",
  "-- le")

m("small value is judged on cost, not the restricted amount",
  "capital_allowance_schedule",
  "            and app.ca_qualifying_expenditure(s.cost, s.cost_cap)\n                  < s.small_value_threshold)",
  "            and s.cost  -- raw cost\n                  < s.small_value_threshold)",
  "-- raw cost")

m("the RM20,000 cap is not applied",
  "capital_allowance_schedule",
  "             when not (f.is_small and f.is_first) then null\n             else greatest(",
  "             when not (f.is_small and f.is_first) then null\n             when true then f.qe  -- no aggregate cap\n             else greatest(",
  "-- no aggregate cap")

m("the cap is shared out ignoring what earlier assets took",
  "capital_allowance_schedule",
  "                        - (sum(f.qe) filter (where f.is_small and f.is_first)",
  "                        - 0 * (sum(f.qe) filter (where f.is_small and f.is_first)  -- no running",
  "-- no running")

m("an asset that misses the cap gets a negative allowance",
  "capital_allowance_schedule",
  "             else greatest(\n                    least(",
  "             else greatest(-1e9,  -- negative\n                    least(",
  "-- negative")

m("last year's small assets eat this year's cap",
  "capital_allowance_schedule",
  "                        - (sum(f.qe) filter (where f.is_small and f.is_first)",
  "                        - (sum(f.qe) filter (where f.is_small)  -- old smalls",
  "-- old smalls")

m("a mis-classed asset at the threshold is written off in full",
  "capital_allowance_schedule",
  "             when a.in_small_class and not a.is_small then 0\n             when a.is_small and a.is_first then a.small_allowed",
  "             when a.in_small_class and not a.is_small then a.qe  -- misclass full\n             when a.is_small and a.is_first then a.small_allowed",
  "-- misclass full")

m("a small asset gets its whole cost, past the cap",
  "capital_allowance_schedule",
  "             when a.is_small and a.is_first then a.small_allowed",
  "             when a.is_small and a.is_first then a.qe  -- uncapped",
  "-- uncapped")

m("a small asset is written off again in later years",
  "capital_allowance_schedule",
  "             when a.is_small then 0\n             when a.is_first then round(a.qe * a.initial_rate, 2)",
  "             when a.is_small then a.qe  -- again\n             when a.is_first then round(a.qe * a.initial_rate, 2)",
  "-- again")

m("the initial allowance is given every year",
  "capital_allowance_schedule",
  "             when a.is_first then round(a.qe * a.initial_rate, 2)\n             else 0\n           end as ia_raw,",
  "             when true then round(a.qe * a.initial_rate, 2)  -- ia every year\n             else 0\n           end as ia_raw,",
  "-- ia every year")

m("the initial allowance is at the annual rate",
  "capital_allowance_schedule",
  "             when a.is_first then round(a.qe * a.initial_rate, 2)\n             else 0\n           end as ia_raw,",
  "             when a.is_first then round(a.qe * a.annual_rate, 2)  -- ia at aa\n             else 0\n           end as ia_raw,",
  "-- ia at aa")

m("an annual allowance is given in the year of sale",
  "capital_allowance_schedule",
  "             when a.in_small_class or a.sold_now then 0",
  "             when a.in_small_class then 0  -- aa on sale",
  "-- aa on sale")

m("a small value asset also gets an annual allowance",
  "capital_allowance_schedule",
  "             when a.in_small_class or a.sold_now then 0",
  "             when a.sold_now then 0  -- aa on small",
  "-- aa on small")

m("the annual allowance is at the initial rate",
  "capital_allowance_schedule",
  "             else round(a.qe * a.annual_rate, 2)\n           end as aa_raw,",
  "             else round(a.qe * a.initial_rate, 2)  -- aa at ia\n           end as aa_raw,",
  "-- aa at ia")

m("prior years are counted one short",
  "capital_allowance_schedule",
  "                  + round(a.qe * a.annual_rate, 2) * (p_year - a.first_ya)",
  "                  + round(a.qe * a.annual_rate, 2) * (p_year - a.first_ya - 1)  -- short",
  "-- short")

m("the initial allowance is forgotten in prior years",
  "capital_allowance_schedule",
  "             else round(a.qe * a.initial_rate, 2)\n                  + round(a.qe * a.annual_rate, 2) * (p_year - a.first_ya)",
  "             else 0  -- prior no ia\n                  + round(a.qe * a.annual_rate, 2) * (p_year - a.first_ya)",
  "-- prior no ia")

m("a small asset claimed nothing in its first year",
  "capital_allowance_schedule",
  "             when a.is_small then a.qe\n             else round(a.qe * a.initial_rate, 2)",
  "             when a.is_small then 0  -- small prior nil\n             else round(a.qe * a.initial_rate, 2)",
  "-- small prior nil")

m("a mis-classed asset claimed allowances in prior years",
  "capital_allowance_schedule",
  "             when a.is_first then 0\n             when a.in_small_class and not a.is_small then 0\n             when a.is_small then a.qe",
  "             when a.is_first then 0\n             when false then 0  -- misclass prior\n             when a.is_small then a.qe",
  "-- misclass prior")

m("prior claims are not capped at the qualifying expenditure",
  "capital_allowance_schedule",
  "           least(m.prior_raw, m.qe) as prior_capped",
  "           m.prior_raw as prior_capped  -- uncapped prior",
  "-- uncapped prior")

m("the initial allowance is not capped by what is left",
  "capital_allowance_schedule",
  "           least(c.ia_raw, greatest(c.qe - c.prior_capped, 0)) as ia",
  "           c.ia_raw as ia  -- ia uncapped",
  "-- ia uncapped")

m("the annual allowance is not capped by what is left",
  "capital_allowance_schedule",
  "           least(f.aa_raw, greatest(f.qe - f.prior_capped - f.ia, 0)) as aa",
  "           least(f.aa_raw, greatest(f.qe - f.prior_capped, 0)) as aa  -- aa ignores ia",
  "-- aa ignores ia")

m("the annual allowance is never capped",
  "capital_allowance_schedule",
  "           least(f.aa_raw, greatest(f.qe - f.prior_capped - f.ia, 0)) as aa",
  "           f.aa_raw as aa  -- aa uncapped",
  "-- aa uncapped")

m("proceeds are not restricted with the cost",
  "capital_allowance_schedule",
  "               round(coalesce(f.disposal_proceeds, 0) * f.qe / f.cost, 2)",
  "               round(coalesce(f.disposal_proceeds, 0), 2)  -- unrestricted",
  "-- unrestricted")

m("an asset given away is sold for its residual",
  "capital_allowance_schedule",
  "               round(coalesce(f.disposal_proceeds, 0) * f.qe / f.cost, 2)",
  "               round(coalesce(f.disposal_proceeds, f.qe - f.prior_capped) * f.qe / f.cost, 2)  -- gift",
  "-- gift")

m("the residual before sale forgets this year's allowances",
  "capital_allowance_schedule",
  "           greatest(f.qe - f.prior_capped - f.ia - f.aa, 0) as residual_before",
  "           greatest(f.qe - f.prior_capped, 0) as residual_before  -- no this year",
  "-- no this year")

m("the residual can go negative",
  "capital_allowance_schedule",
  "           greatest(f.qe - f.prior_capped - f.ia - f.aa, 0) as residual_before",
  "           (f.qe - f.prior_capped - f.ia - f.aa) as residual_before  -- negative residual",
  "-- negative residual")

m("a balancing allowance is given on an asset not sold",
  "capital_allowance_schedule",
  "         case when b.sold_now\n              then greatest(b.residual_before - b.restricted_proceeds, 0)\n              else 0 end,",
  "         case when true  -- ba unsold\n              then greatest(b.residual_before - coalesce(b.restricted_proceeds, 0), 0)\n              else 0 end,",
  "-- ba unsold")

m("a balancing allowance can be negative",
  "capital_allowance_schedule",
  "              then greatest(b.residual_before - b.restricted_proceeds, 0)",
  "              then (b.residual_before - b.restricted_proceeds)  -- negative ba",
  "-- negative ba")

m("a balancing charge is not limited to the allowances given",
  "capital_allowance_schedule",
  "              then least(\n                     greatest(b.restricted_proceeds - b.residual_before, 0),\n                     b.prior_capped + b.ia + b.aa)",
  "              then greatest(b.restricted_proceeds - b.residual_before, 0)  -- gain taxed",
  "-- gain taxed")

m("a balancing charge forgets this year's allowance in its limit",
  "capital_allowance_schedule",
  "                     b.prior_capped + b.ia + b.aa)",
  "                     b.prior_capped)  -- limit prior only",
  "-- limit prior only")

m("a balancing charge can be negative",
  "capital_allowance_schedule",
  "                     greatest(b.restricted_proceeds - b.residual_before, 0),",
  "                     (b.restricted_proceeds - b.residual_before),  -- negative bc",
  "-- negative bc")

m("claimed leaves out the annual allowance",
  "capital_allowance_schedule",
  "         b.ia + b.aa,\n         case when b.sold_now then 0 else b.residual_before end",
  "         b.ia,  -- claimed ia only\n         case when b.sold_now then 0 else b.residual_before end",
  "-- claimed ia only")

m("a sold asset carries a residual forward",
  "capital_allowance_schedule",
  "         case when b.sold_now then 0 else b.residual_before end",
  "         b.residual_before  -- sold residual",
  "-- sold residual")

m("CONTROL: a comment inside the block",
  "capital_allowance_schedule",
  "  final2 as (",
  "  -- CONTROL\n  final2 as (",
  "-- CONTROL")
