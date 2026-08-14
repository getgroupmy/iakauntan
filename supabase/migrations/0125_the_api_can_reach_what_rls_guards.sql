-- =====================================================================
-- iAkauntan :: the API can reach what row level security guards
--
-- 0122 granted three tables because a test caught three tables. That was
-- treating a symptom. The next assertion written under the
-- `authenticated` role found the next one:
--
--   ERROR: permission denied for table expense_claims
--
-- The real state of things: almost none of the 155 tables in `public`
-- are granted to `authenticated` by these migrations. It works on the
-- hosted project because that project carries Supabase's default
-- privileges, which grant each new table in `public` to `anon`,
-- `authenticated` and `service_role` as it is created. A database built
-- from these files alone does not carry them, so PostgREST can reach
-- almost nothing and every row policy in the schema is unreachable
-- rather than enforcing. Nothing noticed because every other test runs
-- as the superuser, which bypasses row level security and table
-- privileges alike.
--
-- ---------------------------------------------------------------------
-- Why this is not `grant all on all tables`
--
-- Two tables here hold an organization's own credentials — its LHDN
-- client secret, its OCR provider keys. Both have row level security on
-- and *no policy at all*, which is how you say "service role only" in
-- Postgres: RLS with nothing to permit denies everyone. A blanket grant
-- would hand `authenticated` a table privilege on them. It would still
-- be denied by RLS, but the schema would then be one dropped policy away
-- from handing out API keys, and that is not a margin worth keeping.
--
-- So the grant is derived from the policies instead: a table is reachable
-- exactly where somebody wrote a policy saying who may reach it, and the
-- verbs granted are the verbs those policies name. `select` where there
-- is a select policy, `insert` where there is an insert policy, and so
-- on. The schema ends up stating its intent once, in the policies, with
-- the grants following.
--
-- Row level security is still what decides *which rows*. These grants
-- only decide which tables the API may ask about at all.
--
-- Nothing here grants anything to `anon`. No policy in this schema names
-- `anon` — the paths open to somebody without an account go through
-- SECURITY DEFINER functions, never table access, which 0090 and 0091
-- went to some trouble to arrange.
--
-- `supabase/tests/table_grants.sql` asserts the result, so a table added
-- next year without a grant fails CI instead of failing a customer.
-- =====================================================================

do $$
declare
  r record;
  v_verbs text;
begin
  for r in
    select c.relname,
           -- The verbs the policies on this table actually name. An
           -- `all` policy covers every one of them.
           string_agg(distinct
             case p.cmd
               when 'SELECT' then 'select'
               when 'INSERT' then 'insert'
               when 'UPDATE' then 'update'
               when 'DELETE' then 'delete'
               when 'ALL'    then 'select, insert, update, delete'
             end, ', ') as verbs
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_policies p
        on p.schemaname = 'public' and p.tablename = c.relname
     where n.nspname = 'public'
       and c.relkind = 'r'
       -- Never widen a table that is not guarded. There are none today;
       -- this is here so that adding one and forgetting its policies
       -- cannot quietly publish it to every signed-in user.
       and c.relrowsecurity
       -- Policies written for somebody in particular. A table whose only
       -- policies name `service_role` stays out of reach, as does one
       -- with no policies at all.
       and (p.roles::text like '%authenticated%'
            or p.roles::text like '%public%')
     group by c.relname
  loop
    execute format('grant %s on public.%I to authenticated',
                   r.verbs, r.relname);
  end loop;
end $$;
