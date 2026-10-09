# Mutants for public.ingest_exchange_rates (0104) -- a fetched batch of
# rates, sourced bnm or api, against a known quote currency, arriving as
# an array; each row reported on its own: all three fields required, a
# three-letter code, a positive unit (never assumed to be one), a
# positive rate, the quote currency against itself skipped, a currency
# this system does not hold skipped; stored as the rate per ONE unit at
# eight decimals, replacing the system rate for that date.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0104_live_exchange_rates.sql \
#       supabase/tests/exchange_rate_feed.sql \
#       supabase/tests/mutants/ingest_exchange_rates.py
#
# RESULT: 16 mutants and a control, all killed by
# `exchange_rate_feed.sql`; ten before its row-by-row block. The batch
# refusal was caught by SQLSTATE, which reading an object as an array
# raises too; no row was missing a field, sent in lower case, quoted at
# nothing, or for a currency switched off.
#
# Noted, not raised: a rate or unit that is not a number ("N/A"), or a
# date that is not one, still takes the WHOLE batch down -- the comment
# about holding the code as text says one bad row should not -- and
# '08/10/2026' is read in the server's DateStyle (MDY here). Only
# service_role may call it, and its one caller, `fetch-rates`, drops a
# rate that is not a finite number and passes BNM's ISO date through,
# so neither is reachable today.

F = "ingest_exchange_rates"

m("any source is taken", F,
  "  if p_source not in ('bnm', 'api') then",
  "  if false then  -- any source",
  "-- any source")

m("an unknown quote currency is taken", F,
  "  if not exists (select 1 from public.ref_currencies rc where rc.code = p_quote) then",
  "  if false then  -- any quote",
  "-- any quote")

m("an object is read as a batch", F,
  "  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then",
  "  if false then  -- not an array",
  "-- not an array")

m("a code is kept in its own case", F,
  "    v_code   := upper(nullif(trim(r ->> 'currency_code'), ''));",
  "    v_code   := nullif(trim(r ->> 'currency_code'), '');  -- case kept",
  "-- case kept")

m("a row without a date is taken", F,
  "    if v_code is null or v_quoted is null or v_on is null then",
  "    if v_code is null or v_quoted is null then  -- no date",
  "-- no date")

m("a row without a rate is taken", F,
  "    if v_code is null or v_quoted is null or v_on is null then",
  "    if v_code is null or v_on is null then  -- no rate",
  "-- no rate")

m("any length of code is taken", F,
  "    if length(v_code) <> 3 then",
  "    if false then  -- any length",
  "-- any length")

m("a missing unit is one", F,
  "    if v_unit is null or v_unit <= 0 then",
  "    if v_unit <= 0 then  -- missing taken",
  "-- missing taken")

m("a nought unit is taken", F,
  "    if v_unit is null or v_unit <= 0 then",
  "    if v_unit is null or v_unit < 0 then  -- nought taken",
  "-- nought taken")

m("a nought rate is taken", F,
  "    if v_quoted <= 0 then",
  "    if v_quoted < 0 then  -- nought taken",
  "-- nought taken")

m("the quote currency is rated against itself", F,
  "    if v_code = p_quote then",
  "    if false then  -- against itself",
  "-- against itself")

m("an inactive currency is stored", F,
  "       where rc.code = v_code and rc.is_active) then",
  "       where rc.code = v_code) then  -- inactive too",
  "-- inactive too")

m("the rate is not divided by its unit", F,
  "    v_rate := round(v_quoted / v_unit, 8);",
  "    v_rate := round(v_quoted, 8);  -- per quote",
  "-- per quote")

m("the rate is rounded to four places", F,
  "    v_rate := round(v_quoted / v_unit, 8);",
  "    v_rate := round(v_quoted / v_unit, 4);  -- four places",
  "-- four places")

m("a stored rate is not replaced", F,
  "      do update set rate = excluded.rate, source = excluded.source;",
  "      do nothing;  -- first wins",
  "-- first wins")

m("the unit is not mentioned", F,
  "      when v_unit = 1 then null",
  "      when true then null  -- unit unsaid",
  "-- unit unsaid")

m("CONTROL: a comment inside the block", F,
  "    if v_quoted <= 0 then",
  "    if v_quoted <= 0 then  -- (control)",
  "(control)")
