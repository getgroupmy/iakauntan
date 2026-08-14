-- =====================================================================
-- iAkauntan :: the chain builder is not something you may call
--
-- 0119 revoked the grant on `app.build_claim_chain` and missed the
-- trigger function that calls it. A function left at its default is
-- executable by PUBLIC, which `anon` inherits, so an unauthenticated
-- caller could reach a SECURITY DEFINER function through PostgREST.
--
-- It needs no EXECUTE grant at all: a trigger function runs as part of
-- the table operation that fires it, not through the caller's privilege
-- on the function. Revoking it changes nothing about how claims are
-- built and closes the door.
--
-- `supabase/tests/statutory.sql` asserts that nothing outside a
-- three-name allowlist is executable by `anon`, and that is what caught
-- this — on CI, one commit after the function was added.
-- =====================================================================

revoke all on function app.claim_chain_trigger() from public, anon, authenticated;
