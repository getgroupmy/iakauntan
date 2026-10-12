-- =====================================================================
-- iAkauntan :: a company always has an owner (0841)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/company_keeps_its_owner.sql
--
-- Only an owner may close a company or hand it over. Before `0841` the
-- sole owner could demote or suspend themselves and leave a company
-- nobody could close or hand over, or point their own membership at
-- another account and hand it over unrecorded; an admin could seat a
-- second account of theirs on somebody's invitation. Asked as the owner
-- and as an admin with the role `authenticated`, as the team screen
-- asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ow (org uuid, other_org uuid, owner uuid, admin uuid,
  clerk uuid, alt uuid, newcomer uuid, firm uuid);
grant select on t_ow to authenticated;
create temporary table t_tok (token text);
grant select, insert on t_tok to authenticated;

do $$
declare r t_ow;
begin
  r.owner := pg_temp.test_user();
  perform pg_temp.sign_in_as(r.owner);
  r.org := pg_temp.test_org('Pemilik Kekal Sdn Bhd');
  r.other_org := pg_temp.test_org('Syarikat Kedua Sdn Bhd');
  r.admin := pg_temp.another_user('admin@pemilikkekal.test');
  r.clerk := pg_temp.another_user('kerani@pemilikkekal.test');
  r.alt := pg_temp.another_user('alt@pemilikkekal.test');
  r.newcomer := pg_temp.another_user('baru@pemilikkekal.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (r.org, r.admin, 'admin', 'active', now()),
         (r.org, r.clerk, 'accountant', 'active', now());
  insert into public.firms (name, slug) values ('Tan & Rakan', 'tan-rakan')
  returning id into r.firm;
  insert into t_ow select r.*;
end $$;

-- As the sole owner.
select set_config('request.jwt.claims',
  json_build_object('sub', (select owner from t_ow), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ow;
begin
  select * into d from t_ow;
  perform pg_temp.check_true('the sole owner, asking as a client',
    current_user = 'authenticated'
    and app.has_org_role(d.org, array['owner'::app.member_role]));

  -- What was measured.
  perform pg_temp.check_refused('the sole owner does not step down to admin',
    format($q$update public.org_members set role = 'admin'
              where org_id = %L and user_id = %L$q$, d.org, d.owner),
    'This is the company''s only owner, and a company always has one.%', '42501');
  perform pg_temp.check_refused('nor suspend themselves',
    format($q$update public.org_members set status = 'suspended'
              where org_id = %L and user_id = %L$q$, d.org, d.owner),
    'This is the company''s only owner%', '42501');
  perform pg_temp.check_refused('nor hand the company over by pointing their seat elsewhere',
    format($q$update public.org_members set user_id = %L
              where org_id = %L and user_id = %L$q$, d.alt, d.org, d.owner),
    'The user_id of a membership is set when somebody is invited, accepts or is handed the company, not by hand.',
    '42501');
  -- An owner of both companies, moving a member between them.
  perform pg_temp.check_refused('nor move a member to another company',
    format($q$update public.org_members set org_id = %L
              where org_id = %L and user_id = %L$q$, d.other_org, d.org, d.clerk),
    'The org_id of a membership is set%', '42501');
  perform pg_temp.check_eq('so the company still has its one owner',
    (select string_agg(user_id::text || '/' || status::text, ',') from public.org_members
      where org_id = d.org and role = 'owner'),
    d.owner::text || '/active');
end $$;

reset role;

-- As an admin who is not the owner.
select set_config('request.jwt.claims',
  json_build_object('sub', (select admin from t_ow), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ow; v_token text; r record;
begin
  select * into d from t_ow;
  v_token := public.invite_member(d.org, 'baru@pemilikkekal.test', 'accountant');
  insert into t_tok values (v_token);

  -- What was measured: their own second account, seated on the invitation.
  perform pg_temp.check_refused('an admin does not seat another account on an invitation',
    format($q$update public.org_members set user_id = %L, status = 'active'
              where org_id = %L and invited_email = 'baru@pemilikkekal.test'$q$,
           d.alt, d.org),
    'The user_id of a membership is set%', '42501');

  -- Each of the invitation's own columns, alone.
  for r in select * from (values
      ('invited_email', $v$'lain@pemilikkekal.test'$v$),
      ('invited_by', quote_literal(d.clerk)),
      ('invite_token', $v$'diketahui'$v$),
      ('invite_expires_at', $v$now() + interval '10 years'$v$),
      ('joined_at', $v$now() - interval '1 year'$v$),
      ('via_firm_id', quote_literal(d.firm))) as t(col, val)
  loop
    perform pg_temp.check_refused(format('nor its %s by hand', r.col),
      format($q$update public.org_members set %I = %s
                where org_id = %L and invited_email = 'baru@pemilikkekal.test'$q$,
             r.col, r.val, d.org),
      format('The %s of a membership is set%%', r.col), '42501');
  end loop;

  -- What the team screen does is as before.
  update public.org_members set role = 'viewer'
   where org_id = d.org and user_id = d.clerk;
  update public.org_members set status = 'suspended'
   where org_id = d.org and user_id = d.clerk;
  perform pg_temp.check_eq('an admin still changes a member''s role, and suspends them',
    (select role::text || '/' || status::text from public.org_members
      where org_id = d.org and user_id = d.clerk),
    'viewer/suspended');
  update public.org_members set status = 'active'
   where org_id = d.org and user_id = d.clerk;
end $$;

reset role;

-- The invitation is taken up by the person it names.
select set_config('request.jwt.claims',
  json_build_object('sub', (select newcomer from t_ow), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ow;
begin
  select * into d from t_ow;
  perform public.accept_invitation((select token from t_tok));
  perform pg_temp.check_eq('an invitation is still accepted by its addressee',
    (select status::text from public.org_members
      where org_id = d.org and user_id = d.newcomer),
    'active');
end $$;

reset role;

-- Back to the owner: with a second owner, the first may step down; and
-- the company is handed over by handing it over.
select set_config('request.jwt.claims',
  json_build_object('sub', (select owner from t_ow), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ow;
begin
  select * into d from t_ow;
  update public.org_members set role = 'owner'
   where org_id = d.org and user_id = d.admin;
  update public.org_members set role = 'admin'
   where org_id = d.org and user_id = d.owner;
  perform pg_temp.check_eq('with a second owner, the first still steps down',
    (select string_agg(user_id::text, ',') from public.org_members
      where org_id = d.org and role = 'owner'),
    d.admin::text);
end $$;

reset role;

-- An owner suspended is no owner to leave the company to.
do $$
declare d t_ow;
begin
  select * into d from t_ow;
  update public.org_members set role = 'owner', status = 'active'
   where org_id = d.org and user_id = d.owner;
  update public.org_members set status = 'suspended'
   where org_id = d.org and user_id = d.admin;
end $$;

set local role authenticated;

do $$
declare d t_ow;
begin
  select * into d from t_ow;
  perform pg_temp.check_refused('a suspended co-owner is not one to step down for',
    format($q$update public.org_members set role = 'admin'
              where org_id = %L and user_id = %L$q$, d.org, d.owner),
    'This is the company''s only owner%', '42501');
  perform public.transfer_company(d.org, 'alt@pemilikkekal.test', 'Bersara');
  perform pg_temp.check_eq('the company is still handed over by transfer_company',
    (select role::text from public.org_members where org_id = d.org and user_id = d.owner)
      || ' -> ' ||
    (select role::text from public.org_members where org_id = d.org and user_id = d.alt),
    'admin -> owner');
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: every function that writes a membership is a
-- definer, which runs as the owner at any depth.
do $$
declare d t_ow;
begin
  select * into d from t_ow;
  update public.org_members set invite_expires_at = now() + interval '1 day'
   where org_id = d.org and user_id = d.clerk;
  perform pg_temp.check_true('the owner, at the top, is not refused',
    (select invite_expires_at is not null from public.org_members
      where org_id = d.org and user_id = d.clerk));
end $$;

rollback;
