# Mutants for app.assert_claim_caps (0364) -- an expense claim held to
# its claim types' per-claim, monthly and annual caps.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0364_the_claim_cap_that_was_only_a_number.sql \
#       supabase/tests/claim_caps.sql \
#       supabase/tests/mutants/assert_claim_caps.py
#
# RESULT: 23 mutants and a control. 23 killed, five only after a
# rule-by-rule block in `claim_caps.sql`. The fixture had one employee
# and only ever submitted claims, so "the claims already in this month"
# could have meant everybody's, and nothing asked whether a rejected
# claim still spends the allowance or an approved one stops spending it.
# The file's `claim_refused` helper counts ANY error as a refusal; the
# block's `cap_refusal` catches only the cap's 23514 and returns its
# words.

m("a draft is held to its caps",
  "assert_claim_caps",
  "  if new.id is null or new.status <> 'submitted' then",
  "  if new.id is null then  -- drafts too",
  "-- drafts too")

m("another claim's lines are counted as this one's",
  "assert_claim_caps",
  "     where l.claim_id = new.id\n     group by",
  "     where true  -- every claim\n     group by",
  "-- every claim")

m("the per-claim cap is ignored",
  "assert_claim_caps",
  "    if coalesce(r.per_claim_cap, 0) > 0 and r.claimed > r.per_claim_cap then",
  "    if false then  -- uncapped",
  "-- uncapped")

m("a claim AT the per-claim cap is refused",
  "assert_claim_caps",
  "    if coalesce(r.per_claim_cap, 0) > 0 and r.claimed > r.per_claim_cap then",
  "    if coalesce(r.per_claim_cap, 0) > 0 and r.claimed >= r.per_claim_cap then  -- at it",
  "-- at it")

m("a per-claim cap of nought refuses everything",
  "assert_claim_caps",
  "    if coalesce(r.per_claim_cap, 0) > 0 and r.claimed > r.per_claim_cap then",
  "    if r.claimed > coalesce(r.per_claim_cap, 0) then  -- nought caps",
  "-- nought caps")

m("the monthly cap is ignored",
  "assert_claim_caps",
  "      if v_already + r.claimed > r.monthly_cap then",
  "      if false then  -- uncapped month",
  "-- uncapped month")

m("a month AT its cap is refused",
  "assert_claim_caps",
  "      if v_already + r.claimed > r.monthly_cap then",
  "      if v_already + r.claimed >= r.monthly_cap then  -- at it",
  "-- at it")

m("the month forgets the claims already in it",
  "assert_claim_caps",
  "      if v_already + r.claimed > r.monthly_cap then",
  "      if r.claimed > r.monthly_cap then  -- this claim alone",
  "-- this claim alone")

m("another employee's claims count against the month",
  "assert_claim_caps",
  "       where c.employee_id = new.employee_id\n         and c.id <> new.id\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "       where true  -- everybody\n         and c.id <> new.id\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "-- everybody")

m("the claim counts itself twice in the month",
  "assert_claim_caps",
  "         and c.id <> new.id\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "         and true  -- itself\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "-- itself")

m("a rejected claim counts against the month",
  "assert_claim_caps",
  "         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "         and c.status <> 'draft'  -- rejected too\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "-- rejected too")

m("an approved claim does not count against the month",
  "assert_claim_caps",
  "         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "         and c.status in ('submitted')  -- pending only\n         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "-- pending only")

m("every claim type counts against the month",
  "assert_claim_caps",
  "         and l.claim_type_id = r.id\n         and date_trunc('month'",
  "         and true  -- any type\n         and date_trunc('month'",
  "-- any type")

m("any month counts against this one",
  "assert_claim_caps",
  "         and date_trunc('month', c.claim_date)\n             = date_trunc('month', new.claim_date);",
  "         and true;  -- any month",
  "-- any month")

m("the annual cap is ignored",
  "assert_claim_caps",
  "      if v_already + r.claimed > r.annual_cap then",
  "      if false then  -- uncapped year",
  "-- uncapped year")

m("a year AT its cap is refused",
  "assert_claim_caps",
  "      if v_already + r.claimed > r.annual_cap then",
  "      if v_already + r.claimed >= r.annual_cap then  -- at it",
  "-- at it")

m("the year forgets the claims already in it",
  "assert_claim_caps",
  "      if v_already + r.claimed > r.annual_cap then",
  "      if r.claimed > r.annual_cap then  -- this claim alone",
  "-- this claim alone")

m("another employee's claims count against the year",
  "assert_claim_caps",
  "       where c.employee_id = new.employee_id\n         and c.id <> new.id\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('year'",
  "       where true  -- everybody\n         and c.id <> new.id\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('year'",
  "-- everybody")

m("the claim counts itself twice in the year",
  "assert_claim_caps",
  "         and c.id <> new.id\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('year'",
  "         and true  -- itself\n         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('year'",
  "-- itself")

m("a rejected claim counts against the year",
  "assert_claim_caps",
  "         and c.status in ('submitted', 'approved')\n         and l.claim_type_id = r.id\n         and date_trunc('year'",
  "         and c.status <> 'draft'  -- rejected too\n         and l.claim_type_id = r.id\n         and date_trunc('year'",
  "-- rejected too")

m("every claim type counts against the year",
  "assert_claim_caps",
  "         and l.claim_type_id = r.id\n         and date_trunc('year'",
  "         and true  -- any type\n         and date_trunc('year'",
  "-- any type")

m("any year counts against this one",
  "assert_claim_caps",
  "         and date_trunc('year', c.claim_date)\n             = date_trunc('year', new.claim_date);",
  "         and true;  -- any year",
  "-- any year")

m("the year is the month",
  "assert_claim_caps",
  "         and date_trunc('year', c.claim_date)\n             = date_trunc('year', new.claim_date);",
  "         and date_trunc('month', c.claim_date)\n             = date_trunc('month', new.claim_date);  -- month",
  "-- month")

m("CONTROL: a comment inside the block",
  "assert_claim_caps",
  "    if coalesce(r.annual_cap, 0) > 0 then",
  "    if coalesce(r.annual_cap, 0) > 0 then  -- (control)",
  "(control)")
