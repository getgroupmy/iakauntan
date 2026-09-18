-- =====================================================================
-- The record of a person nobody could edit
--
-- `profiles` has held a person's name, salutation, telephone number and
-- avatar since `0001`, and `0590` added what a business typed at
-- registration so setup could offer it back. Every one of those columns
-- is written once, by `app.handle_new_user` at signup, and then reached
-- by exactly one screen: `create_org_screen.dart`, to pre-fill
-- onboarding.
--
-- Nothing in the product lets anybody change their own name.
--
-- Reported as "why is there no profile settings page on the mobile
-- app", and the answer is that there is none on any surface. What
-- personal settings exist are a card at the FOOT of the company
-- settings screen -- signed in as, role, change password, change email,
-- change mobile -- on a page that is otherwise about the company and
-- most of which is gated on being an owner or an admin. On a phone
-- there is not even that doorway: the avatar that opens it appears in
-- three places in `app_shell.dart` and all three are rail layouts, so
-- the narrow layout's More sheet offers Sign out and nothing else.
--
-- ## Why a function and not a PATCH
--
-- `profiles_update` is `id = auth.uid()` in both USING and WITH CHECK,
-- which is the right rule about ROWS and says nothing about COLUMNS. A
-- policy cannot, so with nothing but that policy a person holding their
-- own token may write any column of their own row:
--
--   * `email`, which is a COPY of `auth.users.email` written at signup.
--     Editing it here changes what "Signed in as" says and does not
--     change the address that signs them in or receives a reset link.
--     The screen would be confidently wrong about the one fact somebody
--     checks it for. The real change belongs where it already is -- the
--     Change email dialog, which goes through GoTrue and re-verifies.
--
--   * `deleted_at`, which four membership guards read -- `is_org_member`
--     and the three beside it in `0619` -- and which NOTHING in this
--     schema writes. A person could set their own and lock themselves
--     out of every company they belong to, through a door nobody built.
--     (Not anybody else's: the policy is self-only, so this is not an
--     escalation. It is a self-inflicted wound that should not be
--     reachable.)
--
--   * `last_org_id`, which the client does write and should keep
--     writing -- see `currentOrgIdProvider`. It is not a field on a
--     form and it is not offered here.
--
-- So the writable set is named in a function instead, which is this
-- repository's own rule: permissions are policies PLUS `app.can_*`
-- guards inside SECURITY DEFINER functions, and a rule enforced only in
-- Dart is not enforced.
--
-- ## What is deliberately not offered
--
-- `locale` and `timezone` have defaults of `en-MY` and
-- `Asia/Kuala_Lumpur` and NOTHING READS EITHER. Every date in the app
-- goes through `Fmt`, which carries Malaysian formats as constants.
-- Two controls that change nothing are worse than two missing
-- controls: somebody sets their timezone, nothing moves, and they stop
-- believing the rest of the page. Making them work is its own piece of
-- work and this is not it.
--
-- `email` is not offered, for the reason above. `avatar_url` IS
-- offered, because it is a plain string this function can set and the
-- shell already falls back to initials when it is null -- but no upload
-- is built here, so nothing in the app sets it yet. It is in the
-- signature rather than left out so that the upload, when it comes, is
-- a screen and not a migration.
-- =====================================================================

create or replace function public.update_my_profile(
  p_full_name  text default null,
  p_salutation text default null,
  p_phone      text default null,
  p_avatar_url text default null)
returns public.profiles
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_row  public.profiles;
begin
  if v_user is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;

  -- A closed login does not get to tidy its own nameplate. `0158`
  -- empties the identity and bans the auth row on the way out, so this
  -- is unreachable in practice today -- a banned user cannot get a
  -- token to call it with. Asserted anyway, because "unreachable
  -- because of something two migrations away" is a property that stops
  -- being true without anybody editing this file.
  if exists (select 1 from public.profiles p
              where p.id = v_user and p.deleted_at is not null) then
    raise exception 'This login has been closed.' using errcode = '42501';
  end if;

  -- COALESCE, so a null argument means "leave it" rather than "clear
  -- it". The screen sends every field it has, and a caller that sends
  -- one field must not silently blank the others.
  --
  -- The cost is that nothing here can CLEAR a field. Emptying the
  -- telephone box sends '' rather than null, which is a real value and
  -- lands -- so the form can still clear what it shows. That is the
  -- reason the empty string is not normalised to null on the way in.
  update public.profiles p
     set full_name  = coalesce(p_full_name, p.full_name),
         salutation = coalesce(p_salutation, p.salutation),
         phone      = coalesce(p_phone, p.phone),
         avatar_url = coalesce(p_avatar_url, p.avatar_url),
         updated_at = now()
   where p.id = v_user
  returning p.* into v_row;

  if v_row.id is null then
    -- No profile row. `app.handle_new_user` makes one at signup and
    -- `0619`'s guards are written as NOT EXISTS precisely so that a
    -- user without one keeps working, so this is a real state rather
    -- than an impossible one.
    raise exception 'No profile on file for this login.'
      using errcode = '22023';
  end if;

  return v_row;
end $$;

revoke all on function public.update_my_profile(text, text, text, text)
  from public, anon;
grant execute on function public.update_my_profile(text, text, text, text)
  to authenticated;

comment on function public.update_my_profile(text, text, text, text) is
  'The columns of your own profile row that you may change: name, '
  'salutation, telephone and avatar. Not email -- that is a copy of '
  'the auth address and belongs to GoTrue -- and not deleted_at, which '
  'four membership guards read. A null argument leaves the column '
  'alone; an empty string clears it. 0649.';

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'update_my_profile';

  if v_src is null then
    raise exception 'update_my_profile did not survive this migration';
  end if;

  -- The whole point of the function. If it ever writes one of these,
  -- it has become the PATCH it was written to replace.
  if v_src ~* 'set[^;]*\yemail\y' then
    raise exception 'update_my_profile writes email';
  end if;
  if v_src ~* 'set[^;]*\ydeleted_at\y' then
    raise exception 'update_my_profile writes deleted_at';
  end if;
  if v_src ~* 'set[^;]*\ylast_org_id\y' then
    raise exception 'update_my_profile writes last_org_id';
  end if;

  -- And it is still the caller's own row.
  if v_src not like '%p.id = v_user%' then
    raise exception 'update_my_profile no longer scopes to auth.uid()';
  end if;

  if not has_function_privilege('authenticated',
       'public.update_my_profile(text, text, text, text)', 'execute') then
    raise exception 'authenticated cannot call update_my_profile';
  end if;
  if has_function_privilege('anon',
       'public.update_my_profile(text, text, text, text)', 'execute') then
    raise exception 'anon can call update_my_profile';
  end if;
end $do$;
