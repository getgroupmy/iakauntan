-- =====================================================================
-- iAkauntan :: what the API is allowed to reach
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/table_grants.sql
--
-- A row policy is two things standing together: a table privilege that
-- lets PostgREST ask about the table at all, and a policy that decides
-- which rows come back. Miss the first and the second never runs — the
-- API answers `permission denied for table x` and the careful policy
-- underneath it is decoration.
--
-- That is not hypothetical. Until 0125 almost nothing in this schema was
-- granted to `authenticated`, and it worked only because the hosted
-- project carries Supabase's default privileges. A database built from
-- these migrations alone could reach nothing. Every other test in this
-- directory runs as the superuser, which bypasses privileges and row
-- level security alike, so none of them could see it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Everything with a policy for a signed-in user is reachable by one
-- ---------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  select string_agg(t.relname || ' (' || t.cmd || ')', ', ' order by t.relname)
    into v_missing
    from (
      select distinct c.relname, p.cmd
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        join pg_policies p
          on p.schemaname = 'public' and p.tablename = c.relname
       where n.nspname = 'public'
         and c.relkind = 'r'
         and c.relrowsecurity
         and (p.roles::text like '%authenticated%'
              or p.roles::text like '%public%')
         and p.cmd <> 'ALL'
         and not has_table_privilege('authenticated', c.oid, p.cmd)
    ) t;

  if v_missing is not null then
    raise exception
      'FAIL a policy without the privilege to reach it: %', v_missing;
  end if;
  raise notice 'ok   every user-facing policy has the grant it needs';
end $$;

-- ---------------------------------------------------------------------
-- And the credentials tables are still out of reach
--
-- Row level security with no policy at all is how this schema says
-- "service role only": there is nothing to permit, so everyone is
-- denied. The grant must agree, because a table one dropped policy away
-- from handing out an organization's LHDN client secret is not a margin
-- worth keeping.
-- ---------------------------------------------------------------------
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'einvoice_credentials', 'org_ocr_credentials'
  ]
  loop
    perform pg_temp.check_true(
      format('%s has no policy, so it is nobody''s to read', v_table),
      not exists (select 1 from pg_policies
                   where schemaname = 'public' and tablename = v_table));

    perform pg_temp.check_true(
      format('%s is not granted to authenticated', v_table),
      not has_table_privilege('authenticated', 'public.' || v_table, 'select'));
    perform pg_temp.check_true(
      format('%s is not granted to anon', v_table),
      not has_table_privilege('anon', 'public.' || v_table, 'select'));
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Nothing in public is left unguarded
--
-- The grants above are derived from the policies, so a table with row
-- level security switched off would be granted to nobody and reachable
-- by nobody — which sounds safe until somebody notices the screen is
-- empty and fixes it with a grant instead of a policy.
-- ---------------------------------------------------------------------
do $$
declare v_open text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_open
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

  if v_open is not null then
    raise exception 'FAIL a table in public has no row level security: %',
      v_open;
  end if;
  raise notice 'ok   every table in public has row level security on';
end $$;

-- ---------------------------------------------------------------------
-- No client role holds TRUNCATE, REFERENCES or TRIGGER on anything
--
-- 0239 took these three off the ledger; 0240 took them off the rest of
-- `public`. None of them is a data privilege:
--
--   TRUNCATE   empties a table without producing a row for RLS to
--              filter or an audit trigger to see
--   REFERENCES points a foreign key at the table, pinning its rows
--   TRIGGER    attaches code to the table
--
-- The environments differ in how they got here, which is the reason
-- this is asserted rather than assumed. On the hosted project every one
-- of these was granted by Supabase's default privileges -- 238 tables
-- for `authenticated`, 228 for `anon`, counted before 0240 was written.
-- A stack built from these migrations alone never had them, because
-- 0125 grants each data privilege by name rather than `grant all`. The
-- assertion has to be true in both.
-- ---------------------------------------------------------------------
do $$
declare
  v_held      text;
  v_n         int;
  v_relations int;
  v_readable  int;
begin
  select count(*),
         string_agg(distinct rel || ' (' || grantee || ' ' || priv || ')',
                    ', ' order by rel || ' (' || grantee || ' ' || priv || ')')
    into v_n, v_held
    from (
      select c.oid::regclass::text as rel, g.grantee, p.priv
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       cross join unnest(array['authenticated', 'anon']) as g(grantee)
       cross join unnest(array['TRUNCATE', 'REFERENCES', 'TRIGGER']) as p(priv)
       where n.nspname = 'public'
         and c.relkind in ('r', 'p', 'v', 'm', 'f')
         and has_table_privilege(g.grantee, c.oid, p.priv)
    ) t;

  if v_n > 0 then
    raise exception 'FAIL % client grants of truncate/references/trigger remain: %',
      v_n, left(v_held, 400);
  end if;

  -- The positive control. The check above counts absences, and an empty
  -- schema -- or one where every grant had been revoked -- would satisfy
  -- it without meaning anything. Say what was actually examined, and
  -- that the application can still reach it.
  select count(*),
         count(*) filter (where has_table_privilege('authenticated', c.oid, 'SELECT'))
    into v_relations, v_readable
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p', 'v', 'm', 'f');

  if v_relations < 200 then
    raise exception
      'FAIL only % relations in public -- the check above proved nothing',
      v_relations;
  end if;
  if v_readable < 200 then
    raise exception
      'FAIL authenticated can read only % of % relations -- too much was revoked',
      v_readable, v_relations;
  end if;

  raise notice
    'ok   none of the three on any of % relations, % still readable',
    v_relations, v_readable;
end $$;

-- ---------------------------------------------------------------------
-- And the next table created does not get them back
--
-- Supabase's default ACL hands `anon` and `authenticated` arwdDxtm on
-- every new table in `public`. Without 0240's `alter default
-- privileges`, one `create table` in a later migration re-opens the hole
-- for that table and nothing says so. `D`, `x` and `t` in an aclitem are
-- TRUNCATE, REFERENCES and TRIGGER.
--
-- Only `postgres` is checked, and the second block says why rather than
-- leaving it to be taken on trust. There is a second default ACL over
-- this schema owned by `supabase_admin` which still carries all three,
-- and 0240 cannot touch it: `postgres` is not a member of that role and
-- `alter default privileges` for it fails with 42501, measured. It is
-- inert here only because nothing in `public` is created by that role —
-- which is the premise the block below turns into an assertion.
--
-- Where no default ACL row exists for a role the built-in default
-- applies, which grants a client role nothing — so an absent row is a
-- pass, not a gap.
-- ---------------------------------------------------------------------
do $$
declare v_acl text;
begin
  select coalesce(string_agg(d.defaclacl::text, ' | '), '(no row, built-in default)')
    into v_acl
    from pg_default_acl d
    join pg_namespace n on n.oid = d.defaclnamespace
   where n.nspname = 'public'
     and d.defaclobjtype = 'r'
     and pg_get_userbyid(d.defaclrole) = 'postgres';

  if v_acl ~ '(anon|authenticated)=[a-zA-Z]*[Dxt]' then
    raise exception
      'FAIL tables created by postgres would carry truncate/references/trigger: %',
      v_acl;
  end if;
  raise notice 'ok   new tables are created without the three';
end $$;

-- ---------------------------------------------------------------------
-- The premise that scoping the check to `postgres` rests on
--
-- Checking one role's defaults is only sufficient while that role is the
-- one creating things here. Every relation in `public` is owned by
-- `postgres` — 249 of them on the hosted project, counted. If a table
-- ever appears under another owner, the check above stops covering the
-- schema, and this is what says so instead of leaving it silently
-- half-true.
-- ---------------------------------------------------------------------
do $$
declare
  v_others text;
  v_mine   int;
begin
  select string_agg(distinct pg_get_userbyid(c.relowner), ', '),
         count(*) filter (where pg_get_userbyid(c.relowner) = 'postgres')
    into v_others, v_mine
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind in ('r', 'p', 'v', 'm', 'f')
     and pg_get_userbyid(c.relowner) <> 'postgres';

  if v_others is not null then
    raise exception
      'FAIL relations in public are owned by %, whose default privileges 0240 does not reach',
      v_others;
  end if;

  select count(*) into v_mine
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'f');

  if v_mine < 200 then
    raise exception 'FAIL only % relations in public -- nothing was examined', v_mine;
  end if;

  raise notice 'ok   all % relations in public are owned by postgres', v_mine;
end $$;

rollback;
