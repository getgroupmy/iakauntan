-- =====================================================================
-- iAkauntan :: who holds which access type
--
-- 0127 gave a company access types and 0128 let somebody ask what their
-- own is. This is the third thing the feature needs to be usable at
-- all: the team screen has to show which access type each person holds,
-- and an administrator has to be able to change it.
--
-- `org_team` gains two columns rather than the app making a second
-- query. The team list is already one round trip that joins the profile
-- to the membership; the access type belongs in the same answer, and a
-- separate read would be a second list to keep in step with the first.
-- The return type changes, so it is dropped and recreated — the only
-- way Postgres allows it.
-- =====================================================================

drop function if exists public.org_team(uuid);

create function public.org_team(p_org_id uuid)
returns table (
  member_id uuid,
  user_id uuid,
  email text,
  full_name text,
  role app.member_role,
  status app.member_status,
  invited_email text,
  joined_at timestamptz,
  created_at timestamptz,
  access_type_id uuid,
  access_type_name text
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select m.id, m.user_id, coalesce(p.email::text, m.invited_email::text),
         p.full_name, m.role, m.status, m.invited_email::text,
         m.joined_at, m.created_at,
         m.access_type_id, a.name
    from public.org_members m
    left join public.profiles p on p.id = m.user_id
    left join public.access_types a on a.id = m.access_type_id
   where m.org_id = p_org_id
     and app.is_org_member(p_org_id)
   order by m.created_at;
$$;

revoke all on function public.org_team(uuid) from public, anon;
grant execute on function public.org_team(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Changing somebody's access type
--
-- An administrator's job, and only within their own company — the
-- membership row and the access type must both belong to it, or an
-- administrator of one company could hand their staff an access type
-- belonging to another.
--
-- Null clears it, which is how somebody goes back to unrestricted.
-- ---------------------------------------------------------------------
create or replace function public.set_member_access_type(
  p_member_id uuid,
  p_access_type_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org uuid;
begin
  select org_id into v_org from public.org_members where id = p_member_id;
  if v_org is null then
    raise exception 'No such member' using errcode = 'P0002';
  end if;
  if not app.can_admin(v_org) then
    raise exception 'Only an administrator can change access'
      using errcode = '42501';
  end if;

  if p_access_type_id is not null
     and not exists (select 1 from public.access_types t
                      where t.id = p_access_type_id and t.org_id = v_org) then
    raise exception 'That access type belongs to another company'
      using errcode = '42501';
  end if;

  update public.org_members
     set access_type_id = p_access_type_id
   where id = p_member_id;
end; $$;

revoke all on function public.set_member_access_type(uuid, uuid)
  from public, anon;
grant execute on function public.set_member_access_type(uuid, uuid)
  to authenticated;
