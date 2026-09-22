-- =====================================================================
-- iAkauntan :: 0677 a grant that was a default privilege is not a grant
--
--     supabase/functions/ocr/index.ts:801: ocr_key_pool_size called as
--     service_role, but it is granted to authenticated
--
-- `check_rpc_grants.py`, in CI, on `0675`. It is right, and the
-- interesting part is that `supabase/tests/run_locally.sh` said the
-- same file was fine.
--
-- ---------------------------------------------------------------------
-- Why the two disagreed
--
-- Supabase ships
--
--     alter default privileges in schema public
--       grant all on functions to anon, authenticated, service_role
--
-- so a function created in `public` arrives executable by all three and
-- `0165`'s event trigger then strips PUBLIC and `anon`, leaving
-- `authenticated` AND `service_role`. `_local_stack.sql` reproduces
-- that, which is why the local runner saw a grant the CI database does
-- not have — its own header says where the stubs stop being the real
-- thing, and this is one more line for that list.
--
-- `0675` wrote `revoke all ... from public, anon` and then
-- `grant execute ... to authenticated`. On a database with the default
-- privilege that leaves service_role holding an implicit grant; on one
-- without it, service_role holds nothing. So the edge function's call
-- would have come back 42501, and `whyThePoolIsEmpty` catches
-- everything — meaning the ONE sentence explaining why a pool gave
-- nothing would itself have failed, and the operator would have been
-- told the reader is not configured rather than which of the three
-- things to do about it.
--
-- This is `0618` again, whose title is "the grant that was never
-- written". The rule that keeps coming back: write the grant. A
-- privilege that arrives by default is a privilege that arrives only
-- where that default is set.
--
-- ---------------------------------------------------------------------
-- Both roles, on purpose
--
-- `ocr_key_pool_size` is the one function in `0675` that BOTH sides
-- ask. A tenant's Settings screen asks it before offering a reader, so
-- that choosing one with an empty pool is refused before the first
-- scan rather than after it; and the edge function asks it when a
-- claim came back empty, to say which of the three reasons it was. It
-- returns counts and nothing else — no labels, no key tails — which is
-- why it can be granted this widely at all.
--
-- The other two stay service-role-only and are re-stated below rather
-- than left to be checked: `claim_ocr_key` returns a key, and
-- `note_ocr_key_error` writes to a table nothing else may touch.
-- =====================================================================

grant execute on function public.ocr_key_pool_size(text, uuid)
  to authenticated, service_role;

comment on function public.ocr_key_pool_size(text, uuid) is
  'How many keys a reader''s pool holds, and how many of them could run '
  'right now. Counts only -- no labels and no key tails -- so both a '
  'tenant''s Settings screen and the edge function may ask it: the '
  'first to refuse a reader with an empty pool before the first scan, '
  'the second to say which of the three reasons a claim came back with '
  'nothing.';

-- Re-stated, not changed. A reader of this file should not have to go
-- back to `0675` and `0676` to find out whether the two that hand out
-- and mark keys are as narrow as they look.
revoke all on function public.claim_ocr_key(text, uuid)
  from public, anon, authenticated;
grant execute on function public.claim_ocr_key(text, uuid) to service_role;

revoke all on function public.note_ocr_key_error(uuid, text)
  from public, anon, authenticated;
grant execute on function public.note_ocr_key_error(uuid, text)
  to service_role;
