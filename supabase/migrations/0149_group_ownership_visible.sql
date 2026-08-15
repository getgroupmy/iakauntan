-- =====================================================================
-- iAkauntan :: making recorded ownership visible where it is set
--
-- 0148 added `parent_org_id` and `owned_percent` and refuses to produce
-- a consolidated trial balance until every company in the group except
-- the one being looked at has a parent recorded. Its own error message
-- says "Record it in Settings" — and nothing in Settings could.
--
-- The awkward part is *whose* ownership needs recording. The check in
-- `report_group_consolidated_trial_balance` is over the whole group, but
-- `set_group_ownership` deliberately asks for administrator rights on
-- the company being owned, not on the parent. So somebody standing in
-- the holding company can be told that three subsidiaries have no
-- ownership recorded while being able to fix only the ones they
-- administer. That is the right rule — a company's share capital is a
-- fact about that company — but it only works if the screen can show
-- the whole picture and offer the button on the rows where pressing it
-- would succeed.
--
-- `my_group_companies` already returns exactly the companies the caller
-- belongs to, so it is the right place to carry ownership: it adds no
-- reach that the caller did not already have.
--
-- The one column that goes slightly further is `parent_name`. A parent
-- must be a company the person recording it belonged to, but a group can
-- have several administrators, so a subsidiary you can see may be owned
-- by a company you cannot. The alternative is a screen that says "owned
-- 100% by" and then nothing, which reads as a bug. A name, for a company
-- already recorded as owning one of yours, is the smaller disclosure.
-- =====================================================================

drop function if exists public.my_group_companies(uuid);

create or replace function public.my_group_companies(p_org_id uuid)
returns table (
  org_id          uuid,
  name            text,
  registration_no text,
  is_current      boolean,
  parent_org_id   uuid,
  parent_name     text,
  owned_percent   numeric,
  can_admin       boolean)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select o.id, o.name, o.registration_no, o.id = p_org_id,
         o.parent_org_id, p.name, o.owned_percent,
         -- Per company, not per group: the button belongs on the rows
         -- where `set_group_ownership` would not refuse.
         app.can_admin(o.id)
    from public.organizations o
    left join public.organizations p on p.id = o.parent_org_id
   where app.is_org_member(p_org_id)
     and o.group_id is not null
     and o.group_id = (select group_id from public.organizations
                        where id = p_org_id)
     and app.is_org_member(o.id)
   order by o.name;
$$;

revoke all on function public.my_group_companies(uuid) from public, anon;
grant execute on function public.my_group_companies(uuid) to authenticated;

comment on function public.my_group_companies(uuid) is
  'The companies in this one''s group that the caller is already a '
  'member of, with the ownership 0148 records and whether the caller '
  'may change it for that company.';
