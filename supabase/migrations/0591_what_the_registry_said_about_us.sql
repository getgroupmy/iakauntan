-- =====================================================================
-- iAkauntan :: 0591 what the registry said about us
--
-- The SSM lookup signs in to ssmsearch.com the way its own website
-- does, and on 14 Sep 2026 the first live search after the host was
-- corrected (api.ssmsearch.com, not ssmsearch.com/api) was still
-- answered `is_not_logged_in: true` with a perfectly good Bearer
-- token. Their website sends four things from the login answer back
-- with EVERY call -- `_user_id`, `_org_id`, `_org_role` and `_role_id`
-- -- and that, not the token alone, is what their backend keys on.
--
-- So the sign-in keeps what it was told, and
-- `supabase/functions/ssm-search/provider.ts` sends it back with each
-- search. One nullable column on the one-row session table.
--
-- Applied by hand in the dashboard the same evening, before this file
-- existed, which is why it says IF NOT EXISTS: `db push` records this
-- migration and changes nothing on the hosted project.
-- =====================================================================

alter table public.ssm_session
  add column if not exists upstream_user jsonb;

comment on column public.ssm_session.upstream_user is
  'What ssmsearch.com said about the signed-in user at login (id, orgId, orgRole, roleId), sent back as _user_id/_org_id/_org_role/_role_id with every call, the way their own website does.';
