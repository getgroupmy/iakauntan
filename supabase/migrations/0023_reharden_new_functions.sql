-- =====================================================================
-- iAkauntan :: 0023 hardening sweep
--
-- Functions added since the first hardening pass inherited PUBLIC
-- execute and an unpinned search_path. This sweep is idempotent, so it
-- can be re-run whenever new functions land.
-- =====================================================================

do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
       and p.prokind = 'f'
       and not exists (
         select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
       and not exists (
         select 1 from unnest(coalesce(p.proconfig, '{}')) c
          where c like 'search\_path=%')
  loop
    execute format('alter function %s set search_path = public, pg_temp', r.sig);
  end loop;
end
$do$;

-- No SECURITY DEFINER function in the API schema should be reachable
-- without signing in: every one of them keys off auth.uid().
do $do$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and not exists (
         select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end
$do$;

comment on table public.einvoice_credentials is
  'MyInvois client credentials and signing certificate. RLS is enabled with NO policies on purpose: only the service role (edge functions) may read it, so a client secret can never reach the browser.';
