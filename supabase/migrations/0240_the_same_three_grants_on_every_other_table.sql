-- ---------------------------------------------------------------------
-- 0240  The same three grants, on every other table
-- ---------------------------------------------------------------------
--
-- 0239 revoked TRUNCATE, REFERENCES and TRIGGER from `authenticated` and
-- `anon` on `gl_entries` and `gl_lines`, and said in as many words that
-- the same three grants sat on the rest of the schema and that revoking
-- them across the board was a decision for whoever owns it. That
-- decision has been taken. This is that change, and nothing else.
--
-- Counted on production before writing, not assumed:
--
--     authenticated   TRUNCATE 238   REFERENCES 238   TRIGGER 238
--     anon            TRUNCATE 228   REFERENCES 228   TRIGGER 228
--
-- out of 247 tables and 2 views in `public`. The handful already clear
-- are the ledger, from 0239, and the tables earlier migrations locked
-- down by hand.
--
-- Why a client role should hold none of the three:
--
--   TRUNCATE   empties a table without producing a row for RLS to
--              filter or for an audit trigger to see. It is the hole
--              0239 was written for, and it is open on every other
--              table in the schema -- payroll runs, audit_logs,
--              security_events, org_modules, the lot.
--   REFERENCES the right to point a foreign key at the table, which
--              also pins the rows it references against deletion.
--   TRIGGER    the right to attach code to somebody else's table.
--
-- None of the three is reachable through PostgREST, which emits no verb
-- that produces any of them. That was true in 0239 as well, and it is
-- still a property of the client in front of the database rather than
-- of the database. Anything holding a connection string -- a psql
-- session, a pooler, a future service that talks SQL rather than REST --
-- gets the privilege, not the API's opinion of it.
--
-- ## Scope
--
-- Every table, view and materialized view in `public`, for
-- `authenticated` and `anon`. SELECT, INSERT, UPDATE and DELETE are not
-- touched anywhere: this migration removes no ability the application
-- uses. `service_role` and `postgres` are not named and so are not
-- affected.
--
-- Nothing in the schema or the app truncates anything -- checked across
-- every migration and every Dart file before writing this. No client
-- role does DDL, which is the only thing REFERENCES and TRIGGER are for.
--
-- MAINTAIN is deliberately left alone here, and is worth its own change:
-- Supabase's default grant includes it, `authenticated` holds it on 240
-- tables, and it was confirmed live on production (`analyze
-- public.gl_lines` as `authenticated` succeeds). It carries VACUUM FULL
-- and CLUSTER, both of which take an ACCESS EXCLUSIVE lock. That is an
-- availability question rather than an integrity one, it is a different
-- argument from this one, and it should be reviewable on its own.

-- ---------------------------------------------------------------------
-- The revoke
-- ---------------------------------------------------------------------
--
-- Measure, revoke, measure again, and require that the only thing that
-- moved is the three privileges named. That is the assertion this
-- migration needs, and the first version of it did not do that: it
-- checked the surviving counts against fixed thresholds taken from
-- production -- 242 tables insertable by `authenticated` -- and CI
-- failed on `write 189`, because a stack built from these migrations
-- alone grants each data privilege by name in 0125 while the hosted
-- project also carries Supabase's blanket defaults. The two environments
-- were never going to agree on that number, and neither number was the
-- point. A before-and-after comparison inside one transaction is true
-- in both, and says something stronger: not "enough is left" but
-- "nothing else changed".
--
-- One block, because the two measurements have to see the same schema
-- with only the revoke between them.
--
-- The loop is used rather than `revoke ... on all tables in schema
-- public` so that materialized views are named explicitly and so the
-- count of what was touched is available to assert on.

do $do$
declare
  r         record;
  v_touched int := 0;
  v_before  int[];
  v_after   int[];
  v_privs   text[] := array['SELECT', 'INSERT', 'UPDATE', 'DELETE'];
  i         int;
begin
  -- What a client role can do with data, before.
  select array_agg(n order by ord) into v_before
    from (
      select p.ord,
             count(*) filter (
               where has_table_privilege('authenticated', c.oid, p.priv)
                  or has_table_privilege('anon', c.oid, p.priv)) as n
        from unnest(v_privs) with ordinality as p(priv, ord)
       cross join pg_class c
        join pg_namespace ns on ns.oid = c.relnamespace
       where ns.nspname = 'public'
         and c.relkind in ('r', 'p', 'v', 'm', 'f')
       group by p.ord
    ) t;

  for r in
    select c.oid::regclass as rel
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p', 'v', 'm', 'f')
     order by 1
  loop
    execute format(
      'revoke truncate, references, trigger on %s from authenticated, anon',
      r.rel);
    v_touched := v_touched + 1;
  end loop;

  if v_touched < 200 then
    raise exception
      'FAIL 0240: only % relations in public -- the revoke cannot have covered the schema',
      v_touched;
  end if;

  -- And after.
  select array_agg(n order by ord) into v_after
    from (
      select p.ord,
             count(*) filter (
               where has_table_privilege('authenticated', c.oid, p.priv)
                  or has_table_privilege('anon', c.oid, p.priv)) as n
        from unnest(v_privs) with ordinality as p(priv, ord)
       cross join pg_class c
        join pg_namespace ns on ns.oid = c.relnamespace
       where ns.nspname = 'public'
         and c.relkind in ('r', 'p', 'v', 'm', 'f')
       group by p.ord
    ) t;

  -- The positive control, and the whole of it. If any of the four moved,
  -- this migration took something it was not asked to take.
  for i in 1 .. array_length(v_privs, 1) loop
    if v_before[i] is distinct from v_after[i] then
      raise exception
        'FAIL 0240: % went from % relations to % -- the revoke took more than the three',
        v_privs[i], v_before[i], v_after[i];
    end if;
  end loop;

  raise notice
    '0240: revoked on % relations; select/insert/update/delete unchanged at %',
    v_touched, v_after;
end
$do$;

-- ---------------------------------------------------------------------
-- And on whatever gets created next
-- ---------------------------------------------------------------------
--
-- The revoke above is a fact about the tables that exist today. Supabase
-- ships a default ACL that hands `anon` and `authenticated` arwdDxtm on
-- every new table in `public` -- the D, x and t being exactly the three
-- privileges this migration removes. Without this, migration 0241
-- creating one table quietly re-opens the hole for that table, and
-- nothing would fail to say so.
--
-- Migrations run as `postgres`, so that is the default that governs what
-- this project creates from here on, and all 249 relations in `public`
-- are owned by `postgres` -- counted, not assumed.
--
-- `supabase_admin` owns a second default ACL over the same schema which
-- still carries all three, and this migration cannot change it:
-- `postgres` is not a member of that role, and the attempt fails with
-- 42501, measured rather than predicted. It is left attempted-and-
-- reported rather than dropped, so that the day the platform grants that
-- membership the migration starts closing it too.
--
-- That gap is inert while nothing in `public` is created by
-- `supabase_admin`, which is true today. `table_grants.sql` asserts that
-- premise directly, so if a relation ever appears under another owner
-- the test fails rather than the schema quietly going half-covered.

alter default privileges for role postgres in schema public
  revoke truncate, references, trigger on tables from authenticated, anon;

do $do$
begin
  execute 'alter default privileges for role supabase_admin in schema public'
       || ' revoke truncate, references, trigger on tables from authenticated, anon';
  raise notice '0240: supabase_admin defaults narrowed as well';
exception when insufficient_privilege or undefined_object then
  raise notice
    '0240: could not narrow supabase_admin defaults (%), postgres defaults are the ones that govern this project',
    sqlerrm;
end
$do$;

-- ---------------------------------------------------------------------
-- What is left
-- ---------------------------------------------------------------------
do $do$
declare
  v_still_held int;
  v_offenders  text;
  v_defaults   text;
begin
  -- 1. Nobody holds any of the three, anywhere in public.
  select count(*),
         string_agg(distinct rel || ' (' || grantee || ' ' || priv || ')', ', ')
    into v_still_held, v_offenders
    from (
      select c.oid::regclass::text as rel, g.grantee, p.priv
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       cross join unnest(array['authenticated', 'anon']) as g(grantee)
       cross join unnest(array['TRUNCATE', 'REFERENCES', 'TRIGGER']) as p(priv)
       where n.nspname = 'public'
         and c.relkind in ('r', 'p', 'v', 'm', 'f')
         and has_table_privilege(g.grantee, c.oid, p.priv)
    ) held;

  if v_still_held > 0 then
    raise exception 'FAIL 0240: % grants survived: %', v_still_held, left(v_offenders, 400);
  end if;

  -- 2. The ledger still behaves the way 0238 and 0239 left it, since
  --    this migration swept over it too. Named tables rather than
  --    counts: these two are the same in every environment.
  if not has_table_privilege('authenticated', 'public.gl_entries', 'INSERT')
     or not has_table_privilege('authenticated', 'public.gl_lines', 'SELECT')
     or has_table_privilege('authenticated', 'public.gl_lines', 'UPDATE')
  then
    raise exception 'FAIL 0240: the ledger no longer reads as 0239 left it';
  end if;

  -- 3. The default for new tables no longer carries the three. `D`, `x`
  --    and `t` are TRUNCATE, REFERENCES and TRIGGER in an aclitem.
  select coalesce(string_agg(d.defaclacl::text, ' | '), '(none)')
    into v_defaults
    from pg_default_acl d
    join pg_namespace n on n.oid = d.defaclnamespace
   where n.nspname = 'public'
     and d.defaclobjtype = 'r'
     and pg_get_userbyid(d.defaclrole) = 'postgres';

  if v_defaults ~ '(anon|authenticated)=[a-zA-Z]*[Dxt]' then
    raise exception
      'FAIL 0240: new tables would still be created with truncate/references/trigger: %',
      v_defaults;
  end if;
end
$do$;
