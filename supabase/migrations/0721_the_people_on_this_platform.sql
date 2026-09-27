-- =====================================================================
-- iAkauntan :: 0721 the people on this platform
--
-- The last of what the console was asked for: view, add and edit users.
--
-- ---------------------------------------------------------------------
-- What is here and what is NOT, and why the line falls where it does
--
-- READING people, and editing the parts of a person that live in
-- `profiles`, are here. They are ordinary SQL behind
-- `app.is_platform_admin()`, like every other console function.
--
-- CREATING an account, SETTING A PASSWORD and SUSPENDING one are not.
-- Those live in `auth.users`, and the only supported way to write them
-- is the Admin API with the service role key. That key can read and
-- write every row in this database with no policy in its way, so it
-- exists in exactly one place -- the edge function -- and never in the
-- app, never in this schema, and never in a payload anybody can read.
--
-- `supabase/functions/platform-users/` is the other half. It checks
-- `am_i_platform_admin` through the CALLER's own client before it
-- touches the admin one, so holding the service key is not the same as
-- being allowed to use it.
--
-- ---------------------------------------------------------------------
-- `search_platform_users` already exists and is not this
--
-- `0663` gave the console a search box: two characters minimum,
-- exact e-mail first, for picking one person out of a list. It answers
-- "who do I mean", and it deliberately returns nothing for a short
-- query because a directory of every user on the platform is not what a
-- search box is for.
--
-- This one answers "who is on this platform", which is a different
-- question: it lists without a query, and it carries the things a
-- support call actually asks about -- when they last signed in, whether
-- they ever confirmed their address, whether they are suspended, and
-- how many companies they can open. Both are kept.
-- =====================================================================

create or replace function public.platform_users(
  p_query text default null,
  p_limit integer default 50)
returns table (
  user_id uuid,
  full_name text,
  email text,
  phone text,
  created_at timestamptz,
  last_sign_in_at timestamptz,
  confirmed boolean,
  suspended boolean,
  deleted boolean,
  company_count integer,
  is_platform_admin boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_needle text;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  v_needle := nullif(btrim(coalesce(p_query, '')), '');

  return query
    select p.id,
           p.full_name,
           coalesce(p.email::text, u.email::text),
           p.phone,
           p.created_at,
           u.last_sign_in_at,
           u.email_confirmed_at is not null,
           -- `banned_until` in the past is somebody whose suspension has
           -- run out, which is not suspended. Reading the column for
           -- its presence rather than its value would show them as
           -- locked out while they are signing in perfectly happily.
           coalesce(u.banned_until > now(), false),
           p.deleted_at is not null,
           (select count(*)::integer from public.org_members m
             join public.organizations o on o.id = m.org_id
            where m.user_id = p.id
              and m.status = 'active'
              and o.deleted_at is null),
           exists (select 1 from public.platform_admins a where a.user_id = p.id)
      from public.profiles p
      left join auth.users u on u.id = p.id
     where v_needle is null
        or p.full_name ilike '%' || v_needle || '%'
        or coalesce(p.email::text, u.email::text) ilike '%' || v_needle || '%'
     order by
       -- Somebody who pasted a whole address knows who they mean and
       -- should not have to read a list, which is
       -- `search_platform_users`'s rule and holds here too.
       (v_needle is not null
         and lower(coalesce(p.email::text, u.email::text)) = lower(v_needle)) desc,
       p.created_at desc
     limit least(coalesce(p_limit, 50), 200);
end;
$$;

revoke all on function public.platform_users(text, integer) from public, anon;
grant execute on function public.platform_users(text, integer) to authenticated;

comment on function public.platform_users(text, integer) is
  'Who is on this platform, for the console: when they last signed in, '
  'whether they confirmed their address, whether they are suspended, '
  'and how many companies they can open. `search_platform_users` '
  'answers the narrower question "who do I mean" and is kept. `0721`.';

-- ---------------------------------------------------------------------
-- Editing the half of a person that is ours
--
-- The name and the phone number live in `profiles` and are a plain
-- update. The e-mail address does NOT: it is the sign-in identity, it
-- lives in `auth.users`, and changing it there without changing it here
-- would leave somebody signing in as one address and shown as another.
-- The edge function owns that one.
-- ---------------------------------------------------------------------
create or replace function public.platform_update_user(
  p_user_id uuid,
  p_full_name text default null,
  p_phone text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_before jsonb;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  select to_jsonb(p) into v_before from public.profiles p where p.id = p_user_id;
  if v_before is null then
    raise exception 'No such person.' using errcode = 'P0002';
  end if;

  -- A blank box is "I did not type here", not "delete this", which is
  -- `platform_update_organization`'s rule and the same forms.
  update public.profiles p
     set full_name = coalesce(nullif(btrim(coalesce(p_full_name, '')), ''), p.full_name),
         phone     = coalesce(nullif(btrim(coalesce(p_phone, '')), ''), p.phone),
         updated_at = now()
   where p.id = p_user_id;

  -- `org_id` null, so it lands in the PLATFORM trail rather than in
  -- some company's. Editing a person is not something one of their
  -- companies did.
  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data)
  select null, auth.uid(), 'profiles', p_user_id, 'update',
         v_before,
         to_jsonb(p) || jsonb_build_object('event', 'platform_update_user')
    from public.profiles p where p.id = p_user_id;
end;
$$;

revoke all on function public.platform_update_user(uuid, text, text)
  from public, anon;
grant execute on function public.platform_update_user(uuid, text, text)
  to authenticated;

comment on function public.platform_update_user(uuid, text, text) is
  'Edits the parts of a person that live in `profiles`. The e-mail '
  'address is the sign-in identity and lives in `auth.users`; the '
  'edge function owns that one. `0721`.';
