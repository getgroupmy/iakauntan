-- ---------------------------------------------------------------------
-- 0241  A client role does not vacuum your tables
-- ---------------------------------------------------------------------
--
-- 0240 took TRUNCATE, REFERENCES and TRIGGER off every table in `public`
-- and left MAINTAIN alone, saying it was a different argument and should
-- be decided on its own. This is that decision.
--
-- MAINTAIN arrived in PostgreSQL 17 and Supabase's default grant
-- includes it: the `m` in `anon=arwdDxtm/postgres`. Measured on
-- production before writing this, `authenticated` holds it on 240 of the
-- 249 relations in `public`.
--
-- A note on how that was established, because the obvious probe is
-- worthless. Running `analyze public.gl_lines` as `authenticated`
-- succeeds -- and it succeeds just as happily *after* the privilege has
-- been revoked, which is how this was caught. ANALYZE does not fail when
-- the caller lacks the privilege; it emits a warning and skips the
-- table. So "the command worked" says nothing at all here. The evidence
-- that means something is the privilege bit itself:
-- `has_table_privilege('authenticated', rel, 'MAINTAIN')` was true on
-- 240 relations before this migration and is false on all 249 after,
-- which is what the assertion below checks.
--
-- MAINTAIN carries ANALYZE, VACUUM, REINDEX, CLUSTER, LOCK TABLE and
-- REFRESH MATERIALIZED VIEW. ANALYZE is harmless. `VACUUM FULL` and
-- `CLUSTER` are not: both take an ACCESS EXCLUSIVE lock and rewrite the
-- table, so a signed-in user could stall the ledger for as long as the
-- rewrite takes. Neither was demonstrated end to end -- both refuse to
-- run inside a transaction block, so probing them on production would
-- have meant actually rewriting a live table, which is not a reasonable
-- thing to do to prove a point about a grant. That is an availability hole rather than an integrity
-- one, which is why it was held back from 0240 rather than folded into
-- it, but it is not one worth keeping: nothing in this project asks a
-- client role to maintain a table. Maintenance is autovacuum's job and
-- the platform's, both of which run as roles this migration does not
-- name.
--
-- ## The two environments are not the same major version
--
-- This is the part that decides how the migration has to be written.
-- Production runs PostgreSQL 17.6; the stack CI builds with `supabase
-- start` is pinned to major_version 15 in `supabase/config.toml`. Before
-- 17 there is no MAINTAIN privilege at all -- `revoke maintain` is a
-- syntax error, and `has_table_privilege(..., 'MAINTAIN')` raises
-- `unrecognized privilege type`. A migration that names MAINTAIN in
-- static SQL would fail every CI run on the first parse.
--
-- So everything below goes through `execute` inside a version guard: on
-- 15 the keyword is never parsed and the migration is a no-op, which is
-- also the truthful outcome, because on 15 the privilege being revoked
-- does not exist and the hole is not there to close.
--
-- The same split is worth stating plainly: CI cannot prove this change.
-- It runs on a major version where the privilege is absent, so the
-- assertions below pass vacuously there. What they are good for is the
-- hosted project, where `supabase db push` applies this file against
-- 17.6 and the assertions run for real.

do $do$
declare
  v_pg      int := current_setting('server_version_num')::int;
  r         record;
  v_touched int := 0;
  v_before  int[];
  v_after   int[];
  v_privs   text[] := array['SELECT', 'INSERT', 'UPDATE', 'DELETE'];
  v_held    int;
  v_names   text;
  v_defaults text;
  i         int;
begin
  if v_pg < 170000 then
    raise notice
      '0241: server_version_num is % -- MAINTAIN does not exist before 17, nothing to revoke',
      v_pg;
    return;
  end if;

  -- What a client role can do with data, before. Same instrument as
  -- 0240: the point is not that enough survives but that nothing other
  -- than MAINTAIN moves.
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
    execute format('revoke maintain on %s from authenticated, anon', r.rel);
    v_touched := v_touched + 1;
  end loop;

  if v_touched < 200 then
    raise exception
      'FAIL 0241: only % relations in public -- the revoke cannot have covered the schema',
      v_touched;
  end if;

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

  for i in 1 .. array_length(v_privs, 1) loop
    if v_before[i] is distinct from v_after[i] then
      raise exception
        'FAIL 0241: % went from % relations to % -- the revoke took more than MAINTAIN',
        v_privs[i], v_before[i], v_after[i];
    end if;
  end loop;

  -- And on whatever gets created next. Without this, one `create table`
  -- in a later migration hands MAINTAIN straight back for that table.
  execute 'alter default privileges for role postgres in schema public'
       || ' revoke maintain on tables from authenticated, anon';

  begin
    execute 'alter default privileges for role supabase_admin in schema public'
         || ' revoke maintain on tables from authenticated, anon';
    raise notice '0241: supabase_admin defaults narrowed as well';
  exception when insufficient_privilege or undefined_object then
    raise notice
      '0241: could not narrow supabase_admin defaults (%), postgres defaults govern this project',
      sqlerrm;
  end;

  -- Nobody holds it anywhere.
  select count(*), string_agg(rel, ', ' order by rel)
    into v_held, v_names
    from (
      select c.oid::regclass::text as rel
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       cross join unnest(array['authenticated', 'anon']) as g(grantee)
       where n.nspname = 'public'
         and c.relkind in ('r', 'p', 'v', 'm', 'f')
         and has_table_privilege(g.grantee, c.oid, 'MAINTAIN')
    ) t;

  if v_held > 0 then
    raise exception 'FAIL 0241: MAINTAIN survived on % relations: %',
      v_held, left(v_names, 400);
  end if;

  -- Nor will a new table carry it. `m` is MAINTAIN in an aclitem; the
  -- letters 0240 removed were `D`, `x` and `t`.
  select coalesce(string_agg(d.defaclacl::text, ' | '), '(none)')
    into v_defaults
    from pg_default_acl d
    join pg_namespace n on n.oid = d.defaclnamespace
   where n.nspname = 'public'
     and d.defaclobjtype = 'r'
     and pg_get_userbyid(d.defaclrole) = 'postgres';

  if v_defaults ~ '(anon|authenticated)=[a-zA-Z]*m' then
    raise exception
      'FAIL 0241: new tables would still be created with MAINTAIN: %', v_defaults;
  end if;

  -- The ledger, which this swept over as well, still reads as 0239 left
  -- it. Named tables rather than counts: these two are the same in every
  -- environment, which a count of relations is not.
  if not has_table_privilege('authenticated', 'public.gl_entries', 'INSERT')
     or not has_table_privilege('authenticated', 'public.gl_lines', 'SELECT')
     or has_table_privilege('authenticated', 'public.gl_lines', 'UPDATE')
  then
    raise exception 'FAIL 0241: the ledger no longer reads as 0239 left it';
  end if;

  raise notice
    '0241: MAINTAIN revoked on % relations; select/insert/update/delete unchanged at %',
    v_touched, v_after;
end
$do$;
