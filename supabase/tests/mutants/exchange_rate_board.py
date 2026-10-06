# Mutants for public.exchange_rate_board (0739) -- every active currency
# with the rate the company would use on a date, and where it came from.
#
#     python3 scripts/mutate_sql.py \
#       supabase/migrations/0739_thirty_nine_defaults_on_the_wrong_clock.sql \
#       supabase/tests/exchange_rate_feed.sql \
#       supabase/tests/mutants/exchange_rate_board.py
#
# RESULT: (pending)

m("a stranger reads the board",
  "exchange_rate_board",
  "  if not app.is_org_member(p_org_id) then",
  "  if false then  -- anybody",
  "-- anybody")

m("the published rate is never flagged as the company's own",
  "exchange_rate_board",
  "  select c.code, c.name, e.rate, e.rate_date, e.source, e.org_id is not null",
  "  select c.code, c.name, e.rate, e.rate_date, e.source, false  -- never own",
  "-- never own")

m("another company's own rate is on the board",
  "exchange_rate_board",
  "       where (x.org_id = p_org_id or x.org_id is null)",
  "       where true  -- any org",
  "-- any org")

m("the published rates are ignored",
  "exchange_rate_board",
  "       where (x.org_id = p_org_id or x.org_id is null)",
  "       where x.org_id = p_org_id  -- own only",
  "-- own only")

m("a rate into another currency is read",
  "exchange_rate_board",
  "         and x.to_currency = v_base",
  "         and true  -- any target",
  "-- any target")

m("a rate after the date is read",
  "exchange_rate_board",
  "         and x.rate_date <= p_on_date",
  "         and true  -- future",
  "-- future")

m("the oldest rate is read",
  "exchange_rate_board",
  "       order by x.rate_date desc, (x.org_id is not null) desc",
  "       order by x.rate_date, (x.org_id is not null) desc  -- oldest",
  "-- oldest")

m("the published rate beats the company's own on the same day",
  "exchange_rate_board",
  "       order by x.rate_date desc, (x.org_id is not null) desc",
  "       order by x.rate_date desc, (x.org_id is not null)  -- published wins",
  "-- published wins")

m("a retired currency is on the board",
  "exchange_rate_board",
  "   where c.is_active and c.code <> v_base",
  "   where c.code <> v_base  -- retired too",
  "-- retired too")

m("the base currency is on the board",
  "exchange_rate_board",
  "   where c.is_active and c.code <> v_base",
  "   where c.is_active  -- base too",
  "-- base too")

m("CONTROL: a comment inside the block",
  "exchange_rate_board",
  "  v_base := app.base_currency(p_org_id);\n\n  return query\n  select c.code",
  "  v_base := app.base_currency(p_org_id);\n  -- CONTROL\n  return query\n  select c.code",
  "-- CONTROL")
