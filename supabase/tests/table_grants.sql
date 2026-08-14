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

rollback;
