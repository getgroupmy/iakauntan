-- ---------------------------------------------------------------------
-- 0475  A replay is still somebody asking
-- ---------------------------------------------------------------------
-- Every protected write in this schema is a pair: a thin wrapper taking
-- an idempotency key, and the real function with the guard inside it.
-- CI has a step called "Check the protected writes actually reach the
-- protected overload", and on the first call they do.
--
-- On a *replay* they do not, and that is the hole.
-- `app.idempotency_begin` finds the key, returns the stored result, and
-- the wrapper hands it straight back -- the guarded function is never
-- called, so nothing ever asks whose company this is.
--
-- Measured against `post_manual_journal`, as somebody who is not a
-- member of the company at all:
--
--     replay, same key and args -> the stranger got the stored result
--     same key, different args  -> 'Idempotency key KEY-1 was already
--                                  used for a different request'
--     a fresh key               -> 'Insufficient privileges to post to
--                                  the ledger'
--
-- The third line is the system working. The first two are it answering
-- questions from somebody it had already decided may not ask: the
-- result of a write they had no right to see, and -- for a key they had
-- merely guessed -- confirmation that it exists in that company.
--
-- ### What it is and is not
--
-- Not an open door. It needs the organization's id *and* an exact
-- idempotency key, which clients generate. It is a defence-in-depth
-- failure, and it is the same shape as 0474: a rule stated in the
-- places that do the work and missing from the path that skips it.
--
-- Recorded because the fix is one line in one place and covers every
-- protected wrapper at once -- and because leaving it means the CI
-- step's name is not true.
--
-- ### Membership, not `can_write`
--
-- The floor every caller must clear. Which write is permitted --
-- `can_write`, `can_post`, `can_write_module` -- is still decided
-- inside the real function on the path that does the work, and asking
-- a stronger question here would refuse people the wrapper exists to
-- serve. `app.idempotency_end` needs nothing: it is not reachable
-- except after `begin` has returned, and neither is granted to
-- `authenticated` at all.
--
-- ### Mutants
--
-- Two, restated into a built database and run against
-- `supabase/tests/idempotency.sql`:
--
--   * the guard removed -- killed by "a stranger cannot replay somebody
--     else's key";
--   * the guard moved *below* the insert, which is where it would
--     naturally have been written and would still refuse a stranger --
--     killed by "and learns nothing from a key they guessed", because
--     by then the different-fingerprint refusal has already fired and
--     told them the key exists. Its own mutant because the two
--     assertions look alike and are not: one is about the answer, the
--     other about which answer arrives first.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.idempotency_begin(p_org_id uuid, p_key text, p_operation text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_fp  text := app.idempotency_fingerprint(p_args);
  v_row public.idempotency_keys;
begin
  -- No key: the caller is not asking for idempotency and gets today's
  -- behaviour exactly.
  if p_key is null or btrim(p_key) = '' then
    return null;
  end if;

  -- Whose company this is, asked here because on a replay nothing else
  -- asks it.
  --
  -- Every protected wrapper is a thin shell over a guarded function,
  -- and the guard is inside the function -- so on the *first* call it
  -- runs and refuses a stranger correctly. On a replay this function
  -- returns the stored result and the inner function is never called,
  -- which handed somebody who knew an org id and a key back the result
  -- of a write they had no right to see. The `already used for a
  -- different request` refusal said as much about a key they had merely
  -- guessed. See 0475.
  --
  -- Membership rather than `can_write`: this is the floor every caller
  -- must clear, and the operation's own guard -- can_write, can_post,
  -- can_write_module, whichever it is -- still runs inside on the path
  -- that does the work. Asking a stronger question here would refuse
  -- somebody the wrapper is meant to serve.
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of that company' using errcode = '42501';
  end if;

  insert into public.idempotency_keys
    (org_id, key, operation, fingerprint, user_id)
  values (p_org_id, btrim(p_key), p_operation, v_fp, auth.uid())
  on conflict (org_id, key) do nothing;

  if found then
    return null;              -- first through: go and do the work
  end if;

  select * into v_row from public.idempotency_keys
   where org_id = p_org_id and key = btrim(p_key);

  if v_row.operation <> p_operation or v_row.fingerprint <> v_fp then
    raise exception
      'Idempotency key % was already used for a different request',
      btrim(p_key) using errcode = '22023';
  end if;

  if v_row.status = 'in_progress' then
    raise exception
      'Idempotency key % is still in progress', btrim(p_key)
      using errcode = '55006';
  end if;

  return coalesce(v_row.result, 'null'::jsonb);
end;
$function$;

comment on function app.idempotency_begin(uuid, text, text, jsonb) is
  'Opens a protected write, or hands back what the same key produced '
  'before. Asks membership itself, because on a replay the guarded '
  'function it fronts is never called. See 0475.';

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('app.idempotency_begin(uuid, text, text, jsonb)'));
begin
  if position('app.is_org_member(p_org_id)' in v_src) = 0 then
    raise exception
      '0475: a replay still never asks whose company it is';
  end if;

  -- Before the insert and before the fingerprint comparison, or the
  -- refusal that leaks arrives first and the guard is decoration.
  if position('app.is_org_member(p_org_id)' in v_src)
     > position('insert into public.idempotency_keys' in v_src) then
    raise exception
      '0475: the membership check runs after the key has been looked '
      'up, so a stranger is still told whether it exists';
  end if;

  -- Neither half of this pair may become directly callable: the guard
  -- above only helps while the wrapper is the only way in.
  if has_function_privilege('authenticated',
       to_regprocedure('app.idempotency_begin(uuid, text, text, jsonb)'),
       'execute')
     or has_function_privilege('authenticated',
       to_regprocedure('app.idempotency_end(uuid, text, jsonb)'), 'execute')
  then
    raise exception
      '0475: the idempotency helpers are callable from a browser';
  end if;
end
$do$;
