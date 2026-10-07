-- =====================================================================
-- 0758 :: a suspended member is out of the chat too
--
-- Answered on 7 October: "fix it".
--
-- `app.chat_enabled` (0135) is the gate under every chat permission.
-- `is_chat_participant`, the `chat_messages` insert policy,
-- `chat_start_direct`, the call functions and presence all go through
-- it. Its membership test was
--
--     exists (select 1 from public.org_members om
--              where om.org_id = p_org_id and om.user_id = p_user_id)
--
-- which is true for ANY row, at any status. Every other guard in the
-- schema asks for 'active', and 0619 suspends memberships on the
-- strength of it ("this is already no access everywhere"). Chat was
-- the exception. Reproduced locally: an administrator suspends a member,
-- `is_org_member` turns false, and the member goes on reading the whole
-- conversation, sending into it and starting calls from it, in their
-- own company and in every company linked to it.
--
-- The same test let chat run in a company that has been closed, and for
-- an account that has been closed (0619 bans the login, but the other
-- side could still open a conversation with them and ring them).
--
-- Production had two chat users, both active members of open companies,
-- when this was written, so nobody had been let through this way.
--
-- Now membership means what `is_org_member` means by it: an active row,
-- a company not closed, an account not closed. Support access is
-- deliberately NOT carried over. Support is there to look at the books,
-- not to talk as somebody in the company. Grants survive a CREATE OR
-- REPLACE: 0135 granted execute to `authenticated`, which every policy
-- calling this needs, and that stands.
-- =====================================================================

create or replace function app.chat_enabled(
  p_org_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select exists (
           select 1 from public.org_modules m
            where m.org_id = p_org_id and m.module_code = 'chat'
              and m.is_enabled
              and (m.expires_at is null or m.expires_at > now()))
     and exists (
           select 1 from public.chat_access a
            where a.org_id = p_org_id and a.user_id = p_user_id
              and a.is_enabled)
     -- A member in the sense every other guard means (0619): active, in
     -- a company still open, with an account still open.
     and exists (
           select 1 from public.org_members om
             join public.organizations o on o.id = om.org_id
            where om.org_id = p_org_id and om.user_id = p_user_id
              and om.status = 'active'
              and o.deleted_at is null
              and not exists (select 1 from public.profiles p
                               where p.id = om.user_id
                                 and p.deleted_at is not null));
$$;

comment on function app.chat_enabled(uuid, uuid) is
  'Whether a person may use chat in a company: the company has the '
  'module, the person is switched on for it, and they are an ACTIVE '
  'member of a company that is not closed, with an account that is not '
  'closed (0758). A suspended member is out of every conversation they '
  'were in, as they are out of everything else.';
