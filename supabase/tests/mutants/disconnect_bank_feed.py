# Mutants for public.disconnect_bank_feed (0567) -- an owner or
# administrator disconnects a feed: the key, the secret and the cursor
# go, the status says revoked, the row and its runs stay. Split from
# `bank_feed_writers.py` when 0786 restated the other two.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0567_a_statement_that_arrives_by_itself.sql \
#       supabase/tests/bank_feed.sql \
#       supabase/tests/mutants/disconnect_bank_feed.py
#
# RESULT: 6 mutants and a control, all killed by `bank_feed.sql`.

D = "disconnect_bank_feed"

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

m("CONTROL: a comment inside the block", D,
  "         cursor = null,",
  "         cursor = null,  -- (control)",
  "(control)")
