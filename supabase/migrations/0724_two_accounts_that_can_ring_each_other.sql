-- =====================================================================
-- iAkauntan :: 0724 two accounts that can ring each other
--
-- App Review asked for a screen recording of the VoIP feature, or for
-- `voip` to come out of `UIBackgroundModes` -- see
-- `docs/apple-voip-review.md` for why the key stays. Recording it needs
-- two accounts that can call each other, and so does letting a reviewer
-- try it themselves.
--
-- Wiring that by hand is four things, and the third is the one
-- everybody forgets:
--
--   1. both people are members of a company;
--   2. that company is entitled to `chat`;
--   3. EACH PERSON is switched on for chat individually -- `chat_access`
--      is a per-person row and `app.chat_enabled` requires it, so two
--      members of a company with the module bought still cannot see
--      each other;
--   4. a direct conversation exists with exactly those two in it, which
--      is what draws the call buttons.
--
-- Miss any one and the call button is simply absent, with nothing on
-- screen saying which of the four is missing. That is a bad thing to
-- debug at all and a worse thing to debug the evening before a
-- resubmission, so it is one call.
--
-- ---------------------------------------------------------------------
-- WHAT THIS DELIBERATELY CANNOT DO: create the accounts
--
-- The two people must already exist. Creating an account and setting a
-- password live in `auth.users`, and the only supported way to write
-- that table is the Admin API with the service role key -- which is why
-- `platform-users` exists as an edge function and why this is not it.
-- `supabase/functions/platform-users/index.ts` says it plainly: the
-- password is not a column you can set, it is a hash in a format GoTrue
-- owns and changes, so a row written here would be an account that
-- exists and cannot sign in.
--
-- So an account that is missing is named in the error rather than
-- conjured, and the console is where it gets made.
--
-- ---------------------------------------------------------------------
-- Idempotent, because it will be run again
--
-- Every step is find-or-create. A second call after somebody has
-- already chatted returns the same conversation rather than a second
-- one beside it -- which would split the history in half and leave the
-- reviewer looking at the empty one. This mirrors `chat_start_direct`'s
-- own rule: exactly these two participants and no third.
-- =====================================================================

create or replace function public.demo_calling_pair(
  p_email_a text,
  p_email_b text,
  p_org_name text default 'iAkauntan Demo')
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_a    uuid;
  v_b    uuid;
  v_org  uuid;
  v_slug text;
  v_id   uuid;
begin
  if not public.am_i_platform_admin() then
    raise exception 'Only a platform administrator may do this'
      using errcode = '42501';
  end if;

  select id into v_a from auth.users
   where lower(email) = lower(trim(p_email_a));
  if v_a is null then
    raise exception
      'No account for %. Create it in the console first (Users -> new); '
      'an account cannot be made from SQL.', trim(p_email_a)
      using errcode = 'P0002';
  end if;

  select id into v_b from auth.users
   where lower(email) = lower(trim(p_email_b));
  if v_b is null then
    raise exception
      'No account for %. Create it in the console first (Users -> new); '
      'an account cannot be made from SQL.', trim(p_email_b)
      using errcode = 'P0002';
  end if;

  if v_a = v_b then
    raise exception 'A call needs two people, and those are the same one.'
      using errcode = '22023';
  end if;

  -- The company. Found by slug rather than by name so that running this
  -- twice with the name typed differently does not make a second one.
  v_slug := regexp_replace(lower(trim(p_org_name)), '[^a-z0-9]+', '-', 'g');
  v_slug := trim(both '-' from v_slug);

  select id into v_org from public.organizations where slug = v_slug;
  if v_org is null then
    insert into public.organizations (name, slug)
    values (trim(p_org_name), v_slug)
    returning id into v_org;
    perform app.seed_org_modules(v_org);
  end if;

  -- Entitled to chat. `seed_org_modules` switches on the four a new
  -- company gets and chat is not one of them, so this is not redundant.
  insert into public.org_modules (org_id, module_code, is_enabled, enabled_at)
  values (v_org, 'chat', true, now())
  on conflict (org_id, module_code)
    do update set is_enabled = true, enabled_at = now(),
                  expires_at = null;

  -- Members, and admins rather than owners: two owners is a shape this
  -- schema allows and nothing else in the product produces.
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_a, 'admin', 'active', now()),
         (v_org, v_b, 'admin', 'active', now())
  on conflict do nothing;

  -- The per-person switch. THE ONE THAT IS EASY TO MISS.
  insert into public.chat_access (org_id, user_id, is_enabled)
  values (v_org, v_a, true), (v_org, v_b, true)
  on conflict (org_id, user_id) do update set is_enabled = true;

  -- The conversation, found the way `chat_start_direct` finds one:
  -- exactly these two and no third.
  select c.id into v_id
    from public.chat_conversations c
   where c.is_direct
     and exists (select 1 from public.chat_participants p
                  where p.conversation_id = c.id and p.user_id = v_a
                    and p.org_id = v_org)
     and exists (select 1 from public.chat_participants p
                  where p.conversation_id = c.id and p.user_id = v_b
                    and p.org_id = v_org)
     and (select count(*) from public.chat_participants p
           where p.conversation_id = c.id) = 2
   limit 1;

  if v_id is null then
    insert into public.chat_conversations (is_direct, created_by)
    values (true, v_a) returning id into v_id;

    insert into public.chat_participants (conversation_id, user_id, org_id)
    values (v_id, v_a, v_org), (v_id, v_b, v_org);
  end if;

  return v_id;
end; $$;

revoke all on function public.demo_calling_pair(text, text, text)
  from public, anon;
grant execute on function public.demo_calling_pair(text, text, text)
  to authenticated;

comment on function public.demo_calling_pair(text, text, text) is
  'Wires two EXISTING accounts into one company with chat entitled, '
  'each switched on individually, and a direct conversation between '
  'them -- the four things an in-app call needs. Platform admins only. '
  'Idempotent. It cannot create the accounts: see 0724''s header and '
  'the platform-users edge function.';
