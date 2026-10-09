# Mutants for public.connect_bank_feed, public.disconnect_bank_feed and
# public.set_bank_feed_paused (0567) -- an owner or administrator
# connects a named bank's feed to one of the company's accounts
# (trimmed; an empty box leaves a stored credential alone; a new key
# mends a failed feed), disconnects it (the credentials and the cursor
# go, the row and its runs stay), or pauses and resumes it.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0567_a_statement_that_arrives_by_itself.sql \
#       supabase/tests/bank_feed.sql \
#       supabase/tests/mutants/bank_feed_writers.py
#
# RESULT: 18 mutants and a control, all killed by `bank_feed.sql`; six
# before its rule-by-rule block. The file connected one well-formed
# feed and asked the two properties it was written for, so a missing
# account or feed, an unnamed bank, spaces round a key, the secret and
# reference an empty box leaves alone, a key-less save on a failed
# feed, the error mending clears, the cursor a disconnect drops, and
# who may pause were all unasked.
#
# Found and not yet raised (no connector exists, and production held no
# feed): reconnecting a DISCONNECTED feed stores the new key and leaves
# it 'revoked' -- only a 'failed' feed is re-armed -- while resuming
# one marks it 'connected' with no key at all.

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
  "         status      = case when bank_feeds.status = 'failed'\n                             and excluded.api_key is not null\n                            then 'connected' else bank_feeds.status end,",
  "         status      = bank_feeds.status,  -- stays failed\n",
  "-- stays failed")

m("saving anything mends a failed feed", C,
  "         status      = case when bank_feeds.status = 'failed'\n                             and excluded.api_key is not null",
  "         status      = case when bank_feeds.status = 'failed'  -- any save",
  "-- any save")

m("the failure is kept after mending", C,
  "         last_error  = case when bank_feeds.status = 'failed'\n                             and excluded.api_key is not null\n                            then null else bank_feeds.last_error end,",
  "         last_error  = bank_feeds.last_error,  -- error kept\n",
  "-- error kept")

m("disconnecting nothing is not said so", D,
  "  if v_org is null then\n    raise exception 'There is no feed on that account'",
  "  if false then  -- any account\n    raise exception 'There is no feed on that account'",
  "-- any account")

m("anybody disconnects", D,
  "  if not app.can_admin(v_org) then\n    raise exception 'Only an owner or administrator can disconnect a bank feed'",
  "  if false then  -- anybody\n    raise exception 'Only an owner or administrator can disconnect a bank feed'",
  "-- anybody")

m("the key survives a disconnect", D,
  "         api_key = null,",
  "         api_key = api_key,  -- key kept",
  "-- key kept")

m("the secret survives a disconnect", D,
  "         api_secret = null,",
  "         api_secret = api_secret,  -- secret kept",
  "-- secret kept")

m("the cursor survives a disconnect", D,
  "         cursor = null,",
  "         cursor = cursor,  -- cursor kept",
  "-- cursor kept")

m("a disconnected feed reads as paused", D,
  "     set status = 'revoked',",
  "     set status = 'paused',  -- paused",
  "-- paused")

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
