# Mutants for public.strata_arrears (0739) -- what each parcel in a strata
# scheme owes, how late, the by-law's late payment interest, and the two
# together.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/property.sql \
#       supabase/tests/mutants/strata_arrears.py
#
# RESULT, 6 October: 13 mutants, ALL 13 KILLED, control alive, on
# property.sql. 2 died before "The arrears list, rule by rule": the one
# read was one parcel's interest on one date. The ordering mutant
# survived the block's first draft too -- the only January debt was
# also the first parcel, so parcel order and date order agreed -- and
# died once B-1 paid January and B-5's January invoice stood.
#
# NOT a mutant, a question (docs/handoff.md item 14): the function takes
# an as-at date but reads each invoice's CURRENT balance_amount and does
# not leave out invoices dated after it.

m("a scheme that does not exist returns nothing rather than an error",
  "strata_arrears",
  "  if not found then\n    raise exception 'No such strata scheme'",
  "  if false then  -- no such\n    raise exception 'No such strata scheme'",
  "-- no such")

m("a stranger reads a scheme's arrears",
  "strata_arrears",
  "  if not app.is_org_member(s.org_id)\n     or not app.has_module(s.org_id, 'property_strata') then",
  "  if false  -- stranger\n     or not app.has_module(s.org_id, 'property_strata') then",
  "-- stranger")

m("a company without the strata module reads them",
  "strata_arrears",
  "     or not app.has_module(s.org_id, 'property_strata') then",
  "     or false then  -- no module",
  "-- no module")

m("days overdue goes negative before the due date",
  "strata_arrears",
  "           greatest(0, (p_as_at - d.due_date))::integer,",
  "           (p_as_at - d.due_date)::integer,  -- floor",
  "-- floor")

m("days overdue counts from the as-at date the wrong way",
  "strata_arrears",
  "           greatest(0, (p_as_at - d.due_date))::integer,",
  "           greatest(0, (d.due_date - p_as_at))::integer,  -- backwards",
  "-- backwards")

m("late interest ignores the scheme's rate",
  "strata_arrears",
  "           app.strata_late_interest(d.balance_amount, d.due_date, p_as_at,\n                                    coalesce(r.late_interest_percent, 0)),\n           d.balance_amount",
  "           0::numeric,  -- no interest\n           d.balance_amount",
  "-- no interest")

m("the total leaves out the interest",
  "strata_arrears",
  "           d.balance_amount\n             + app.strata_late_interest(d.balance_amount, d.due_date, p_as_at,\n                                        coalesce(r.late_interest_percent, 0))\n      from",
  "           d.balance_amount  -- total no interest\n      from",
  "-- total no interest")

m("another scheme's charges are in this one's arrears",
  "strata_arrears",
  "     where run.scheme_id = p_scheme_id",
  "     where true  -- any scheme",
  "-- any scheme")

m("a void invoice is in arrears",
  "strata_arrears",
  "       and d.status not in ('void', 'draft')",
  "       and d.status not in ('draft')  -- void",
  "-- void")

m("a draft invoice is in arrears",
  "strata_arrears",
  "       and d.status not in ('void', 'draft')",
  "       and d.status not in ('void')  -- draft",
  "-- draft")

m("a paid invoice is in arrears",
  "strata_arrears",
  "       and d.balance_amount > 0",
  "       and true  -- paid",
  "-- paid")

m("a deleted invoice is in arrears",
  "strata_arrears",
  "       and d.deleted_at is null\n     order by",
  "       and true  -- deleted\n     order by",
  "-- deleted")

m("arrears are listed by due date before unit",
  "strata_arrears",
  "     order by u.unit_no, d.due_date;",
  "     order by d.due_date, u.unit_no;  -- date first",
  "-- date first")

m("CONTROL: a comment inside the block",
  "strata_arrears",
  "  r := app.strata_rate_on(p_scheme_id, p_as_at);",
  "  -- CONTROL\n  r := app.strata_rate_on(p_scheme_id, p_as_at);",
  "-- CONTROL")
