-- =====================================================================
-- iAkauntan :: a member is invited (0839)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/org_members_by_invitation.sql
--
-- An owner alone may close or hand over a company. Before `0839` an
-- admin who was not the owner could not promote themselves -- the update
-- policy asked -- but could insert a second account of theirs as an
-- owner, because the insert policy asked nothing of the role. Asked as
-- that admin, with the role `authenticated`, as the team screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_om (org uuid, owner uuid, admin uuid, alt uuid, clerk uuid);
grant select on t_om to authenticated;

do $$
declare r t_om;
begin
  r.owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.owner);
  r.org := pg_temp.test_org('Pemilik Tunggal Sdn Bhd');
  r.admin := pg_temp.another_user('admin@pemiliktunggal.test');
  r.alt := pg_temp.another_user('alt@pemiliktunggal.test');
  r.clerk := pg_temp.another_user('kerani@pemiliktunggal.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (r.org, r.admin, 'admin', 'active', now()),
         (r.org, r.clerk, 'accountant', 'active', now());
  insert into t_om select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select admin from t_om), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_om; v_token text;
begin
  select * into d from t_om;
  perform pg_temp.check_true('an admin who is not the owner',
    app.can_admin(d.org) and not app.has_org_role(d.org, array['owner'::app.member_role]));

  -- What was measured: a second account of theirs, made an owner.
  perform pg_temp.check_refused('a member is not inserted as an owner',
    format($q$insert into public.org_members (org_id, user_id, role, status, joined_at)
              values (%L, %L, 'owner', 'active', now())$q$, d.org, d.alt),
    'permission denied for table org_members', '42501');
  -- Nor as anything else, uninvited.
  perform pg_temp.check_refused('nor anybody added without an invitation',
    format($q$insert into public.org_members (org_id, user_id, role, status, joined_at)
              values (%L, %L, 'viewer', 'active', now())$q$, d.org, d.alt),
    'permission denied for table org_members', '42501');
  -- The update door, which already asked.
  perform pg_temp.check_refused('nor do they promote themselves',
    format($q$update public.org_members set role = 'owner'
              where org_id = %L and user_id = %L$q$, d.org, d.admin),
    'new row violates row-level security policy for table "org_members"', '42501');

  -- What the team screen does is as before: invite, and change a role.
  v_token := public.invite_member(d.org, 'baru@pemiliktunggal.test', 'viewer');
  perform pg_temp.check_true('an invitation is still recorded',
    v_token is not null and exists (select 1 from public.org_members
      where org_id = d.org and invited_email = 'baru@pemiliktunggal.test'
        and status = 'invited'));
  perform pg_temp.check_refused('and still refuses an owner',
    format($q$select public.invite_member(%L, 'pemilik@pemiliktunggal.test', 'owner')$q$, d.org),
    'Ownership is transferred, not invited');
  update public.org_members set role = 'viewer'
   where org_id = d.org and user_id = d.clerk;
  perform pg_temp.check_eq('a member''s role is still changed by an admin',
    (select role::text from public.org_members where org_id = d.org and user_id = d.clerk),
    'viewer');

  perform pg_temp.check_eq('so the company has one owner',
    (select count(*)::integer from public.org_members where org_id = d.org and role = 'owner'), 1);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('no client may insert a member',
    not has_table_privilege('authenticated', 'public.org_members', 'INSERT')
    and not has_table_privilege('anon', 'public.org_members', 'INSERT'));
  perform pg_temp.check_true('and no policy lets one',
    not exists (select 1 from pg_policies where schemaname = 'public'
                 and tablename = 'org_members' and cmd in ('INSERT', 'ALL')));
end $$;

rollback;
