# Mutants for public.connect_bank_feed and public.set_bank_feed_paused
# (0567, restated in 0786); `disconnect_bank_feed.py` has the third
# writer, which 0786 did not restate -- an owner or administrator
# connects a named bank's feed to one of the company's accounts
# (trimmed; an empty box leaves a stored credential alone; a new key
# mends a failed feed), disconnects it (the credentials and the cursor
# go, the row and its runs stay), or pauses and resumes it; since 0786
# a new key brings back a disconnected feed too, and a disconnected
# feed is neither paused nor resumed.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0786_a_disconnected_feed_is_connected_again_not_resumed.sql \
#       supabase/tests/bank_feed.sql \
#       supabase/tests/mutants/bank_feed_writers.py
#
# RESULT: 15 mutants and a control, all killed by `bank_feed.sql`.
# Swept first against 0567, with the disconnect mutants beside them: 6
# of 18 before a rule-by-rule block, which then took all 18 -- the file
# had connected one well-formed feed and asked two properties. The
# sweep found what `0786` fixes: a disconnected feed could not be
# reconnected, and resuming one said connected with no key. Three
# mutants are 0786's.
#
C = "connect_bank_feed"
D = "disconnect_bank_feed"
P = "set_bank_feed_paused"

m("an account that does not exist is not said so", C,
  "  if v_org is null then\n    raise exception 'Bank account % not found', p_bank_account_id",
  "  if false then  -- any account\n    raise exception 'Bank account % not found', p_bank_account_id",
  "-- any account")

m("anybody connects a feed", C,
  "  if not app.can_admin(v_org) then\n    raise exception 'Only an owner or administrator can connect a bank feed'",
  "  if false then  -- anybody\n    raise exception 'Only an owner or administrator can connect a bank feed'",
  "-- anybody")

m("no bank is named", C,
  "  if v_provider is null then",
  "  if false then  -- no bank",
  "-- no bank")

m("the key keeps its spaces", C,
  "    nullif(btrim(coalesce(p_api_key, '')), ''),",
  "    nullif(coalesce(p_api_key, ''), ''),  -- untrimmed",
  "-- untrimmed")

m("an empty key box clears the stored key", C,
  "         api_key     = coalesce(excluded.api_key, bank_feeds.api_key),",
  "         api_key     = excluded.api_key,  -- cleared",
  "-- cleared")

m("an empty secret box clears the stored secret", C,
  "         api_secret  = coalesce(excluded.api_secret, bank_feeds.api_secret),",
  "         api_secret  = excluded.api_secret,  -- cleared",
  "-- cleared")

m("an empty reference box clears the stored reference", C,
  "         account_ref = coalesce(excluded.account_ref, bank_feeds.account_ref),",
  "         account_ref = excluded.account_ref,  -- cleared",
  "-- cleared")

m("a new key does not mend a failed feed", C,
  "         status      = case when bank_feeds.status in ('failed', 'revoked')\n                             and excluded.api_key is not null\n                            then 'connected' else bank_feeds.status end,",
  "         status      = bank_feeds.status,  -- stays failed\n",
  "-- stays failed")

m("saving anything mends a failed feed", C,
  "         status      = case when bank_feeds.status in ('failed', 'revoked')\n                             and excluded.api_key is not null",
  "         status      = case when bank_feeds.status in ('failed', 'revoked')  -- any save",
  "-- any save")

m("a disconnected feed stays disconnected under a new key (as before 0786)", C,
  "         status      = case when bank_feeds.status in ('failed', 'revoked')\n                             and excluded.api_key is not null\n                            then 'connected'",
  "         status      = case when bank_feeds.status in ('failed')  -- not revoked\n                             and excluded.api_key is not null\n                            then 'connected'",
  "-- not revoked")

m("the failure is kept after mending", C,
  "         last_error  = case when bank_feeds.status in ('failed', 'revoked')\n                             and excluded.api_key is not null\n                            then null else bank_feeds.last_error end,",
  "         last_error  = bank_feeds.last_error,  -- error kept\n",
  "-- error kept")

m("a disconnected feed's error is kept after its key brings it back", C,
  "         last_error  = case when bank_feeds.status in ('failed', 'revoked')\n                             and excluded.api_key is not null\n                            then null",
  "         last_error  = case when bank_feeds.status in ('failed')  -- revoked error kept\n                             and excluded.api_key is not null\n                            then null",
  "-- revoked error kept")

m("a disconnected feed is resumed (as before 0786)", P,
  "  if exists (select 1 from public.bank_feeds f\n              where f.bank_account_id = p_bank_account_id\n                and f.status = 'revoked') then",
  "  if false then  -- revoked resumed",
  "-- revoked resumed")

m("anybody pauses", P,
  "  if not app.can_admin(v_org) then",
  "  if false then  -- anybody",
  "-- anybody")

m("resuming keeps the old error", P,
  "         last_error = case when p_paused then last_error else null end,",
  "         last_error = last_error,  -- error kept",
  "-- error kept")

m("CONTROL: a comment inside the block", C,
  "  if v_provider is null then",
  "  if v_provider is null then  -- (control)",
  "(control)")
