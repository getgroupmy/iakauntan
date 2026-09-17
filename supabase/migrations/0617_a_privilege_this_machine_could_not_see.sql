-- =====================================================================
-- iAkauntan :: a privilege this machine could not see
--
-- `_local_stack.sql` reproduces Supabase's default privileges so that a
-- migration which forgets to revoke fails HERE rather than in CI. Its
-- own comments record two occasions when that mattered -- `0496`, where
-- a table arrived readable by `anon` and nothing local noticed, and
-- `0536`, where being more generous than the hosted project hid three
-- tables with policies and no grants.
--
-- It reproduced the defaults for TABLES and for SEQUENCES. It did not
-- reproduce the one for FUNCTIONS, and `0165` already had the hosted
-- behaviour written down, verified rather than assumed:
--
--     Supabase ships `alter default privileges in schema public grant
--     all on functions to anon, authenticated, service_role`, so a new
--     function in `public` arrives with an explicit anon grant already
--     attached.
--
-- So on the hosted project every new `public` function is executable by
-- every signed-in user unless its migration says otherwise, and on this
-- machine it was executable by nobody. A SECURITY DEFINER function that
-- forgot to revoke from `authenticated` passed every local run, every
-- test, and was open in production -- and no test here COULD have
-- caught it, because the privilege it would have tested for did not
-- exist locally.
--
-- The stub now carries that default. This migration is what the change
-- immediately found.
--
-- ---------------------------------------------------------------------
-- What it found, and what it did not
--
-- It did NOT find an open door. With the default modelled, no function
-- in `public` is reachable by nobody and none of the SECURITY DEFINER
-- functions meant for the service role turned out to be exposed --
-- every one that matters already revokes by name. The ten that looked
-- unreachable before the change were an artefact of the missing
-- default, which is worth writing down because it was the first thing
-- the change appeared to say.
--
-- What it found is one write reachable by every signed-in user with no
-- `comment on function` on it. `check_undocumented_writes.py` has
-- guarded that since it was written and could not see this one: the
-- check asks what a signed-in user can reach, and locally the answer
-- had been "nothing without an explicit grant".
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where a company's takings land
--
-- `0413` wrote the function and the reasoning above it and never gave
-- it a comment, so `docs/api/` has printed its name and five argument
-- types and nothing about what it refuses -- which, for a write, is the
-- rule.
--
-- Both refusals are worth a caller knowing, and the second is the one
-- that is not obvious: a bank account id from ANOTHER company would
-- otherwise be accepted, and every receipt from then on would bank
-- somebody else's money. That is reach a parameter has which no policy
-- can see, which is why it is checked in the body and why it belongs in
-- the description.
-- ---------------------------------------------------------------------
comment on function public.set_org_payment_settlement(
  uuid, text, text, uuid, text) is
  'Says which bank account a gateway''s takings settle into, and under '
  'which payment mode. Administrators only. Refuses a bank account that '
  'belongs to another company -- a parameter reaches further than a '
  'policy can see, and the wrong id here banks somebody else''s money '
  'from then on. Refuses before the gateway''s credentials exist, '
  'naming the gateway. An absent argument leaves what is stored. 0617.';
