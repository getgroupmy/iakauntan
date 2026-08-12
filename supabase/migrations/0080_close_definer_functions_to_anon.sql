-- Shut five SECURITY DEFINER functions that were left open to anon.
--
-- PostgreSQL grants EXECUTE on a new function to PUBLIC by default.
-- Writing `grant execute ... to authenticated` and stopping there does
-- not narrow anything — it re-states a permission everyone already has,
-- and `anon` is a member of PUBLIC. Every one of these carries the
-- definer's rights, so the default made them callable by anybody holding
-- the publishable key:
--
--   app.base_currency              an org's currency, no membership check
--   app.exchange_rate_for          an org's rates, no membership check
--   app.fx_account                 an account id for an org
--   app.realised_fx_on_settlement  reads allocations and documents
--   app.demo_credentials_locked    a trigger body
--
-- The leaks are small — the worst needs a guessed UUID — and the trigger
-- body would error outside a trigger. That is not the point. The rule in
-- supabase/tests/statutory.sql is that no definer function is reachable
-- by anon unless it is on a named allowlist, precisely so nobody has to
-- reason about severity case by case. The test caught all five; it had
-- been failing since 0076 and went unnoticed for four commits.
--
-- These are revoked from `authenticated` as well, not only anon. Every
-- caller is another SECURITY DEFINER function, which executes them as the
-- definer and needs no grant of its own — the same reasoning as the
-- `app.*_internal` pair in 0056. `public.exchange_rate_for` stays granted
-- to authenticated because it checks membership before delegating.

revoke all on function app.base_currency(uuid)
  from public, anon, authenticated;

revoke all on function app.exchange_rate_for(uuid, character, date)
  from public, anon, authenticated;

revoke all on function app.fx_account(uuid, boolean)
  from public, anon, authenticated;

revoke all on function app.realised_fx_on_settlement(uuid, boolean, character, numeric)
  from public, anon, authenticated;

revoke all on function app.demo_credentials_locked()
  from public, anon, authenticated;
