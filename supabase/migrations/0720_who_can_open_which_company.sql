-- =====================================================================
-- iAkauntan :: 0720 who can open which company
--
-- Asked for straight after `0719`: "also allow assign or remove a
-- organisation access for user".
--
-- `0719` gave the console a way to make a company for somebody and a
-- way to read one temporarily. Neither of them moves a PERSON in or out
-- of a company, which is the ordinary support request: somebody joined,
-- somebody left, somebody was given the wrong role on their first day.
--
-- ---------------------------------------------------------------------
-- This is not support access, and the difference matters
--
-- A support grant is the platform reading a customer's books for an
-- hour, read-only, with a reason, and it expires on its own.
--
-- THIS IS PERMANENT AND IT IS THE CUSTOMER'S OWN ACCESS. A person
-- assigned here is a member like any other: they can write, and
-- depending on the role they can post to the ledger. There is no expiry
-- because a colleague is not a support call.
--
-- So it is audited the same way and refused in the same places, but it
-- is deliberately a separate pair of functions rather than a flag on
-- the grant. One of these is a lens; the other hands somebody a key.
--
-- ---------------------------------------------------------------------
-- The one invariant: a company always has an owner
--
-- `create_organization` makes the creator an owner.
-- `app.hand_company_over` moves ownership and leaves the outgoing owner
-- as an admin rather than removing them -- "steps down rather than
-- out", because somebody has to still be able to open the books.
--
-- Every one of those exists to keep a company openable. So removing the
-- last owner, or demoting them, is refused here in the same words
-- `platform_create_organization` uses when nobody is named: a company
-- with no owner is a company nobody can open.
--
-- That is checked on BOTH paths, because demoting the last owner and
-- removing the last owner leave the company in exactly the same state
-- and it would be easy to guard only the one that looks like a removal.
--
-- ---------------------------------------------------------------------
-- Assign is an upsert, on purpose
--
-- "Assign an organisation access" and "change somebody's role" are the
-- same request arriving twice, and a console that refused the second
-- because the row already existed would send somebody to remove the
-- person and add them back -- which loses `joined_at` and writes two
-- audit rows describing something that never happened.
--
-- A member who was SUSPENDED is reactivated by an assign. That is the
-- literal reading of what was asked for, and the audit row carries the
-- before and after so it is legible afterwards.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Reading it, from either end
-- ---------------------------------------------------------------------
create or replace function public.platform_user_organizations(p_user_id uuid)
returns table (
  org_id uuid, org_name text, role text, status text,
  joined_at timestamptz, is_demo boolean)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  return query
    select o.id, o.name, m.role::text, m.status::text, m.joined_at,
           coalesce(o.is_demo, false)
      from public.org_members m
      join public.organizations o on o.id = m.org_id
     where m.user_id = p_user_id
       and o.deleted_at is null
     order by o.name;
end;
$$;

revoke all on function public.platform_user_organizations(uuid) from public, anon;
grant execute on function public.platform_user_organizations(uuid) to authenticated;

comment on function public.platform_user_organizations(uuid) is
  'Which companies one person can open, and as what. The console''s '
  'answer to "what does this user have access to". `0720`.';

create or replace function public.platform_org_members(p_org_id uuid)
returns table (
  user_id uuid, full_name text, email text, role text, status text,
  joined_at timestamptz)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  return query
    select m.user_id, p.full_name,
           coalesce(p.email::text, m.invited_email::text),
           m.role::text, m.status::text, m.joined_at
      from public.org_members m
      left join public.profiles p on p.id = m.user_id
     where m.org_id = p_org_id
     order by m.role, coalesce(p.full_name, p.email::text, '');
end;
$$;

revoke all on function public.platform_org_members(uuid) from public, anon;
grant execute on function public.platform_org_members(uuid) to authenticated;

comment on function public.platform_org_members(uuid) is
  'Who can open one company, for the console. `org_team` answers the '
  'same question from inside and needs membership; this one does not. '
  '`0720`.';

-- ---------------------------------------------------------------------
-- Assigning it
-- ---------------------------------------------------------------------
create or replace function public.platform_assign_org_access(
  p_org_id uuid, p_user_email text, p_role text)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_user   uuid;
  v_role   app.member_role;
  v_before jsonb;
  v_owners integer;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  if not exists (select 1 from public.organizations o
                  where o.id = p_org_id and o.deleted_at is null) then
    raise exception 'No such company.' using errcode = 'P0002';
  end if;

  select u.id into v_user from auth.users u
   where lower(u.email) = lower(btrim(coalesce(p_user_email, '')));
  if v_user is null then
    raise exception 'Nobody here has that address.' using errcode = 'P0002';
  end if;

  -- Named rather than cast blindly: `'manger'::app.member_role` raises
  -- 22P02 with the input value and nothing about what was expected, at
  -- the end of a form somebody has just filled in.
  begin
    v_role := btrim(coalesce(p_role, ''))::app.member_role;
  exception when others then
    raise exception
      '% is not a role. This platform has: %.', coalesce(p_role, '(none)'),
      (select string_agg(e::text, ', ' order by e::text)
         from unnest(enum_range(null::app.member_role)) e)
      using errcode = '23514';
  end;

  select to_jsonb(m) into v_before from public.org_members m
   where m.org_id = p_org_id and m.user_id = v_user;

  -- Demoting the last owner leaves the company exactly as unopenable as
  -- removing them, so it is refused in the same place and the same
  -- words. Guarding only the removal would be guarding the half that
  -- looks dangerous.
  if v_role <> 'owner'
     and (v_before ->> 'role') = 'owner'
     and (v_before ->> 'status') = 'active' then
    select count(*) into v_owners from public.org_members m
     where m.org_id = p_org_id and m.role = 'owner' and m.status = 'active';
    if v_owners <= 1 then
      raise exception
        'That is the only owner. A company with no owner is a company '
        'nobody can open — give somebody else ownership first.'
        using errcode = '23514';
    end if;
  end if;

  insert into public.org_members
    (org_id, user_id, role, status, joined_at)
  values (p_org_id, v_user, v_role, 'active', now())
  on conflict (org_id, user_id) do update
     set role = excluded.role,
         status = 'active',
         joined_at = coalesce(public.org_members.joined_at, now()),
         updated_at = now();

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data)
  select p_org_id, auth.uid(), 'org_members', m.id,
         case when v_before is null then 'insert' else 'update' end,
         v_before,
         to_jsonb(m) || jsonb_build_object('event', 'platform_assign_access')
    from public.org_members m
   where m.org_id = p_org_id and m.user_id = v_user;
end;
$$;

revoke all on function public.platform_assign_org_access(uuid, text, text)
  from public, anon;
grant execute on function public.platform_assign_org_access(uuid, text, text)
  to authenticated;

comment on function public.platform_assign_org_access(uuid, text, text) is
  'Gives somebody access to a company, or changes the access they have '
  '— the same request arriving twice, so it is an upsert. Refuses to '
  'demote the last owner. Unlike a support grant this is PERMANENT and '
  'is the customer''s own access. `0720`.';

-- ---------------------------------------------------------------------
-- Taking it away
-- ---------------------------------------------------------------------
create or replace function public.platform_remove_org_access(
  p_org_id uuid, p_user_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_before jsonb;
  v_id     uuid;
  v_owners integer;
begin
  if not app.is_platform_admin() then
    raise exception 'Platform administrators only' using errcode = '42501';
  end if;

  select m.id, to_jsonb(m) into v_id, v_before from public.org_members m
   where m.org_id = p_org_id and m.user_id = p_user_id;
  if v_id is null then
    raise exception 'That person has no access to this company.'
      using errcode = 'P0002';
  end if;

  if (v_before ->> 'role') = 'owner' and (v_before ->> 'status') = 'active' then
    select count(*) into v_owners from public.org_members m
     where m.org_id = p_org_id and m.role = 'owner' and m.status = 'active';
    if v_owners <= 1 then
      raise exception
        'That is the only owner. A company with no owner is a company '
        'nobody can open — hand it over first.'
        using errcode = '23514';
    end if;
  end if;

  -- The row goes. A suspended membership is still a row somebody has to
  -- explain, and "remove" was what was asked for.
  delete from public.org_members m
   where m.org_id = p_org_id and m.user_id = p_user_id;

  insert into public.audit_logs
    (org_id, user_id, table_name, record_id, action, old_data, new_data)
  values (p_org_id, auth.uid(), 'org_members', v_id, 'delete',
          v_before,
          jsonb_build_object('event', 'platform_remove_access'));
end;
$$;

revoke all on function public.platform_remove_org_access(uuid, uuid)
  from public, anon;
grant execute on function public.platform_remove_org_access(uuid, uuid)
  to authenticated;

comment on function public.platform_remove_org_access(uuid, uuid) is
  'Takes somebody''s access to a company away. Refuses the last owner, '
  'for the reason a company with no owner is a company nobody can '
  'open. `0720`.';
