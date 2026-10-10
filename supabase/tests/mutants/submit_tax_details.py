# Mutants for public.submit_tax_details (0626) -- the public form a
# customer fills in with their own tax details: a live link to a live
# contact only; the answer recorded with who sent it and from where;
# earlier undismissed answers superseded; blanks filled and nothing
# overwritten; the link's submission recorded; the form told what was
# taken and whether anything waits for review.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0626_the_number_only_the_customer_has.sql \
#       supabase/tests/tax_details.sql \
#       supabase/tests/mutants/submit_tax_details.py
#
# RESULT: 26 mutants and a control. 25 killed by `tax_details.sql`, from
# 8: the deleted contact, the whole record of who answered and from
# where (address, the client's hop rather than the proxy's, browser,
# name, email), three spellings, the link's submission time and count,
# when an answer was taken and that one that took nothing is not
# stamped, what the form is told, and that a correction supersedes
# neither an answer the company set aside nor one already superseded
# (asked by dating the first supersede an hour back: in one transaction
# `now()` is one value, and without that the two are the same time).
#
# EQUIVALENT: "a state code is kept as typed". Every code `ref_states`
# holds is two digits and the submission's foreign key refuses any
# other, so upper-casing a valid code is the identity and an invalid one
# is refused either way.

F = "submit_tax_details"

# The door.
m("a revoked link submits", F,
  "     and revoked_at is null and expires_at >= now();",
  "     and expires_at >= now();  -- revoked open",
  "-- revoked open")
m("an expired link submits", F,
  "     and revoked_at is null and expires_at >= now();",
  "     and revoked_at is null;  -- expired open",
  "-- expired open")
m("a deleted contact takes answers", F,
  "  if c.id is null or c.deleted_at is not null then",
  "  if c.id is null then  -- deleted open",
  "-- deleted open")

# Who sent it, and from where.
m("the address it came from is not kept", F,
  "    v_ip, app.request_header('user-agent'),",
  "    null, app.request_header('user-agent'),  -- no address",
  "-- no address")
m("the browser it came from is not kept", F,
  "    v_ip, app.request_header('user-agent'),",
  "    v_ip, null,  -- no browser",
  "-- no browser")
m("the first forwarded address is not the one kept", F,
  "    app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet;",
  "    app.request_header('x-forwarded-for'), ''), ',', 2), '')::inet;  -- second hop",
  "-- second hop")
m("the sender's name is not kept", F,
  "    nullif(btrim(p_details ->> 'submitted_by_name'), ''),",
  "    null,  -- no name",
  "-- no name")
m("the sender's email is not kept", F,
  "    nullif(btrim(p_details ->> 'submitted_by_email'), ''),",
  "    null,  -- no email",
  "-- no email")

# The spelling of what they typed.
m("an SST number is kept as typed", F,
  "    upper(nullif(btrim(p_details ->> 'sst_registration_no'), '')),",
  "    nullif(btrim(p_details ->> 'sst_registration_no'), ''),  -- sst as typed",
  "-- sst as typed")
m("an email is kept as typed", F,
  "    lower(nullif(btrim(p_details ->> 'email'), '')),",
  "    nullif(btrim(p_details ->> 'email'), ''),  -- email as typed",
  "-- email as typed")
m("a state code is kept as typed", F,
  "    upper(nullif(btrim(p_details ->> 'state_code'), '')),",
  "    nullif(btrim(p_details ->> 'state_code'), ''),  -- state as typed",
  "-- state as typed")
m("a country code is kept as typed", F,
  "    upper(nullif(btrim(p_details ->> 'country_code'), '')))",
  "    nullif(btrim(p_details ->> 'country_code'), ''))  -- country as typed",
  "-- country as typed")
m("a phone keeps its spaces", F,
  "    nullif(btrim(p_details ->> 'phone'), ''),",
  "    nullif(p_details ->> 'phone', ''),  -- phone untrimmed",
  "-- phone untrimmed")

# Superseding.
m("a correction supersedes nothing", F,
  "     set superseded_at = now()\n   where request_id = l.id",
  "     set superseded_at = now()\n   where false  -- nothing superseded",
  "-- nothing superseded")
m("a dismissed answer is superseded too", F,
  "     and dismissed_at is null\n     and superseded_at is null;",
  "     and superseded_at is null;  -- dismissed superseded",
  "-- dismissed superseded")
m("a superseded answer is superseded again", F,
  "     and dismissed_at is null\n     and superseded_at is null;",
  "     and dismissed_at is null;  -- re-superseded",
  "-- re-superseded")

# What it did.
m("the form overwrites what we hold", F,
  "  v_done := app.tax_submission_apply(v_id, true);",
  "  v_done := app.tax_submission_apply(v_id, false);  -- overwrite",
  "-- overwrite")
m("what was taken is not recorded", F,
  "     set applied_fields = v_done,",
  "     set applied_fields = null,  -- taken unrecorded",
  "-- taken unrecorded")
m("when it was taken is not recorded", F,
  "         applied_at = case when cardinality(v_done) > 0 then now() end",
  "         applied_at = null  -- untimed",
  "-- untimed")
m("an answer that took nothing is stamped as taken", F,
  "         applied_at = case when cardinality(v_done) > 0 then now() end",
  "         applied_at = now()  -- always taken",
  "-- always taken")
m("the link does not record the submission", F,
  "     set submitted_at = now(),",
  "     set submitted_at = submitted_at,  -- unrecorded",
  "-- unrecorded")
m("the link does not count submissions", F,
  "         submission_count = submission_count + 1",
  "         submission_count = submission_count  -- uncounted",
  "-- uncounted")

# What the form is told.
m("the form is told something else", F,
  "    'state', 'received',",
  "    'state', 'open',  -- wrong state",
  "-- wrong state")
m("the form is never told anything waits", F,
  "    'awaiting_review', exists (",
  "    'awaiting_review', false and exists (  -- never waiting",
  "-- never waiting")
m("an echoed value counts as a disagreement", F,
  "         and nullif(btrim(coalesce(to_jsonb(s2) ->> f.field, '')), '')\n             is distinct from",
  "         and nullif(btrim(coalesce(to_jsonb(s2) ->> f.field, '')), '')\n             is not distinct from  -- echo disagrees",
  "-- echo disagrees")
m("a blank we hold counts as a disagreement", F,
  "         and nullif(btrim(coalesce(to_jsonb(c) ->> f.field, '')), '')\n             is not null",
  "         and true  -- blank disagrees",
  "-- blank disagrees")

m("CONTROL", F,
  "  v_text  text;\nbegin",
  "  v_text  text;  -- control\nbegin",
  "-- control")
