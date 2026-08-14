-- =====================================================================
-- iAkauntan :: a trigger function is nobody's to call
--
-- `supabase/tests/statutory.sql` keeps an allowlist: exactly three
-- SECURITY DEFINER functions may be executable by `anon`, and they are
-- the three that authorise themselves against a token. 0135 and 0136
-- added two more without meaning to —
--
--   app.touch_conversation     moves a conversation's last_message_at
--   app.clear_typing_on_send   drops the sender's typing flag
--
-- — because a new function in PostgreSQL is executable by PUBLIC unless
-- somebody says otherwise, and for a trigger function it is easy not to
-- think of it as a function anybody could call at all.
--
-- This is the second time. 0120 closed exactly this on
-- `app.claim_chain_trigger`, one function at a time, and the shape came
-- straight back the moment two more trigger functions were written. So
-- this closes the class instead of the instances: every SECURITY
-- DEFINER function in `app` that returns `trigger`, including any
-- written after today.
--
-- ---------------------------------------------------------------------
-- Revoking does not stop the trigger
--
-- Worth stating, because it looks alarming. PostgreSQL checks EXECUTE on
-- a trigger function when the trigger is *created*, not each time it
-- fires; the firing runs as part of the statement that caused it. 0120
-- proved this in practice — claims have been posting through a revoked
-- trigger function ever since — and the claim tests would have failed
-- loudly if it were otherwise.
--
-- What it does stop is the one thing worth stopping: a stranger with the
-- anon key calling it directly. That call would fail anyway, because a
-- trigger function invoked outside a trigger has no row to work on. The
-- point is not this function's blast radius; it is that "SECURITY
-- DEFINER and callable by anon" is a combination nobody should have to
-- reason about case by case.
-- =====================================================================

do $$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and p.prosecdef
       and p.prorettype = 'trigger'::regtype
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated', v_fn.sig);
  end loop;
end $$;
