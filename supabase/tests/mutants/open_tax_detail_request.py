# Mutants for public.open_tax_detail_request (0627, from 0626) -- the
# tax-details form a customer opens from their link, with no login: the
# link's state; every opening recorded, the first kept; and for an open
# link, what the company holds about them, the state list, and whether
# they have answered before.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0627_the_states_the_form_has_to_offer.sql \
#       supabase/tests/tax_details.sql \
#       supabase/tests/mutants/open_tax_detail_request.py
#
# RESULT: 11 mutants and a control, all 11 killed by `tax_details.sql`,
# from 2: a deleted customer's form, the first opening's time and the
# count, the TIN, identification and verification the form shows, the
# states in code order, and both ways round of whether it was answered
# before -- each only after its rule-by-rule block.

F = "open_tax_detail_request"

m("a revoked link opens", F,
  "    when l.revoked_at is not null then 'revoked'",
  "    when false then 'revoked'  -- revoked opens",
  "-- revoked opens")
m("an expired link opens", F,
  "    when l.expires_at < now() then 'expired'",
  "    when false then 'expired'  -- expired opens",
  "-- expired opens")
m("a deleted customer's form opens", F,
  "    when c.id is null or c.deleted_at is not null then 'withdrawn'",
  "    when c.id is null then 'withdrawn'  -- deleted opens",
  "-- deleted opens")
m("the first opening is overwritten", F,
  "     set opened_at = coalesce(opened_at, now()),",
  "     set opened_at = now(),  -- first overwritten",
  "-- first overwritten")
m("openings are not counted", F,
  "         open_count = open_count + 1,",
  "         open_count = open_count,  -- uncounted",
  "-- uncounted")
m("the TIN held is not shown", F,
  "      'tin', c.tin,",
  "      'tin', null,  -- no tin",
  "-- no tin")
m("whether it was verified is not shown", F,
  "      'is_tin_verified', c.is_tin_verified,",
  "      'is_tin_verified', false,  -- never verified",
  "-- never verified")
m("the identification held is not shown", F,
  "      'id_value', c.id_value,",
  "      'id_value', null,  -- no id",
  "-- no id")
m("the states are out of order", F,
  "               'code', s.code, 'name', s.name) order by s.code), '[]'::jsonb)",
  "               'code', s.code, 'name', s.name) order by s.name), '[]'::jsonb)  -- by name",
  "-- by name")
m("an answered form says it never was", F,
  "    'already_submitted', l.submission_count > 0);",
  "    'already_submitted', false);  -- never answered",
  "-- never answered")
m("an unanswered form says it was", F,
  "    'already_submitted', l.submission_count > 0);",
  "    'already_submitted', l.submission_count >= 0);  -- always answered",
  "-- always answered")

m("CONTROL", F,
  "  v_state text;\nbegin",
  "  v_state text;  -- control\nbegin",
  "-- control")
