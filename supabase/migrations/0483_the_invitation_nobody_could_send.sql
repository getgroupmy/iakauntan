-- ---------------------------------------------------------------------
-- 0483  The invitation nobody could send
-- ---------------------------------------------------------------------
-- `public.invite_firm_member` has never worked. Not for an address with
-- an account, not for one without: every call raises
--
--   42804: column "status" is of type member_status but expression is
--          of type text
--
-- because the status it writes is chosen in a `case`, and a `case` over
-- two unknown literals resolves to `text`. A literal on its own would
-- have been coerced to the column's type; wrapped in a `case` it is
-- `text` by the time the insert sees it, and there is no implicit cast
-- from `text` to `app.member_status`.
--
-- It is the only way the app has to add somebody to a practice --
-- `firms_repository.dart` calls it and nothing else -- so a firm has
-- been a place exactly one person can ever work in, since 0450.
--
-- ### Why nothing caught it
--
-- `firm_portfolio.sql` has an assertion called "a new joiner gets the
-- firm's clients", and it passes. It makes the joiner with a direct
-- `insert into public.firm_members` and then calls
-- `app.sync_firm_access` by hand. Both are things `invite_firm_member`
-- is supposed to do, and doing them in the test instead asserts the
-- consequence of joining while leaving the act of inviting untested.
-- `demo_practice_rebuild` seeds its partner the same way, so the demo
-- did not exercise it either.
--
-- That is the same lesson 0463's header drew about assertions that
-- cannot fail, in a new set of clothes: **a test that reproduces what
-- the function should have done proves the schema will accept the row,
-- not that anything puts it there.**
--
-- ### What changes
--
-- The cast, and nothing else. The function is restated from the live
-- definition so the diff is the one line.
--
-- ### Mutants
--
-- Run against `supabase/tests/firm_invitations.sql`, each named with
-- the assertion that kills it:
--   * the cast dropped again -- "a colleague who already has an account
--     can be invited";
--   * the status always `active` -- "an address with no account is
--     invited, not joined";
--   * the status always `invited` -- "and is a member from the moment
--     they are invited";
--   * `sync_firm_access` not called -- "who gets the firm's clients
--     without being invited to each one";
--   * the guard dropped -- "somebody who does not run the firm may not
--     invite";
--   * the empty-address check dropped -- "an invitation needs an
--     address";
--   * `on conflict` doing nothing -- "inviting somebody again changes
--     what they are, not how many they are".
-- ---------------------------------------------------------------------

create or replace function public.invite_firm_member(
  p_firm_id uuid, p_email text, p_role app.firm_role default 'staff')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id    uuid;
  v_user  uuid;
  v_token text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  if not app.can_manage_firm(p_firm_id) then
    raise exception 'Only a partner or manager may invite'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_email, '')), '') is null then
    raise exception 'An invitation needs an address.' using errcode = '23514';
  end if;

  select u.id into v_user from auth.users u
   where lower(u.email) = lower(btrim(p_email));

  -- The cast 0450 left off. Somebody who already has an account is a
  -- member from this moment; an address that does not answer to one
  -- yet is invited, and joins when it does.
  insert into public.firm_members
    (firm_id, user_id, invited_email, role, status, invited_by,
     invite_token, invite_expires_at, joined_at)
  values (p_firm_id, v_user, lower(btrim(p_email)), p_role,
          (case when v_user is null then 'invited' else 'active' end)
            ::app.member_status,
          auth.uid(), v_token, now() + interval '14 days',
          case when v_user is null then null else now() end)
  on conflict (firm_id, user_id) do update
     set role = excluded.role, status = 'active'
  returning id into v_id;

  -- Somebody who joins the office gets the office's clients. Doing this
  -- here rather than leaving it to be noticed is the whole point of a
  -- portfolio: a new joiner with forty clients to be invited to one at
  -- a time is how people end up sharing a login.
  if v_user is not null then
    perform app.sync_firm_access(p_firm_id);
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    'public.invite_firm_member(uuid, text, app.firm_role)'::regprocedure);
begin
  if position('::app.member_status' in v_src) = 0 then
    raise exception '0483: the status is still written untyped';
  end if;
  if not has_function_privilege('authenticated',
       'public.invite_firm_member(uuid, text, app.firm_role)', 'execute') then
    raise exception '0483: the invitation is unreachable';
  end if;
  if has_function_privilege('anon',
       'public.invite_firm_member(uuid, text, app.firm_role)', 'execute') then
    raise exception '0483: the invitation is open to anon';
  end if;
end $do$;
