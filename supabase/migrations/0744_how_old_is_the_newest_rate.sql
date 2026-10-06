-- How old is the newest exchange rate, asked by somebody with no session.
--
-- `exchange_rates` was eleven days stale on 6 October 2026 and nothing
-- noticed. Bank Negara's endpoint began refusing the TLS handshake from
-- the `fetch-rates` edge function in the last week of September; the
-- scheduled job that calls it failed loudly every weekday and nobody was
-- reading it. Meanwhile `revalue_foreign_balances`, which refuses a
-- currency it cannot price rather than assuming par, quietly stopped
-- revaluing anything -- month end did not fail, it did not happen.
--
-- `.github/workflows/rate-feed-fresh.yml` now asks the TABLE rather than
-- the job, every morning. It needs to read one date, and it has no way
-- to do so as things stand:
--
--   * the repository's Actions secrets hold `SCHEDULER_SECRET` and the
--     anon key, which is what `exchange-rates.yml` actually runs on --
--     NOT the service role key that file mentions as a fallback. The
--     gate's first run, by hand on 6 October, failed for exactly that
--     reason and said so;
--   * the anon key cannot read the table: its only SELECT policy is for
--     `authenticated`, so anon gets ZERO ROWS with HTTP 200 -- which the
--     gate, correctly, reports as an empty rate table. It would be red
--     for ever, for the wrong reason.
--
-- The service role key could be added as a secret and would work. It
-- would also read and write everything in the database in order to
-- learn one date, which is the trade `exchange-rates.yml` itself calls
-- "far more authority than this job needs" and built `SCHEDULER_SECRET`
-- to avoid.
--
-- So: one function, no arguments, one date out. It is SECURITY DEFINER
-- because it must see past RLS to answer at all, and it is safe to hand
-- to a stranger because of what it CANNOT do -- it takes no parameter
-- that could steer it at anything else, and what it returns is the
-- publication date of a rate Bank Negara publishes to the world.
--
-- GLOBAL rows only (`org_id is null`), which is every row the feed
-- writes. A company that keeps its own rates is not the feed, and its
-- dates are its own business -- so they are excluded rather than
-- trusted not to exist. On 6 October all 588 rows were global.

create or replace function public.rate_feed_newest()
returns date
language sql
stable
security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select max(r.rate_date)
    from public.exchange_rates r
   where r.org_id is null;
$$;

comment on function public.rate_feed_newest() is
  'The date of the newest exchange rate the feed has stored, or null '
  'when it has stored none. Anon too: it is read by a scheduled gate '
  'that has no session, and the answer is a public publication date. '
  'Global rows only. 0744.';

revoke all on function public.rate_feed_newest() from public;
grant execute on function public.rate_feed_newest() to anon, authenticated;
