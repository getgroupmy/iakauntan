-- =====================================================================
-- iAkauntan :: what a signed-in user can call
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/function_grants.sql
--
-- `table_grants.sql` asserts what a stranger can READ. This asserts
-- what anybody can CALL, and it exists because until `0617` this
-- machine could not answer the question at all.
--
-- `_local_stack.sql` reproduces Supabase's default privileges so a
-- migration that forgets to revoke fails here rather than in CI. It
-- reproduced them for tables and for sequences and not for functions --
-- and `0165` had the hosted behaviour written down all along, verified
-- rather than assumed: a new `public` function arrives granted to
-- `anon`, `authenticated` and `service_role`, and 0165's event trigger
-- strips PUBLIC and `anon` back off.
--
-- Without that default modelled, a SECURITY DEFINER function that
-- forgot to revoke from `authenticated` was executable by every signed
-- in user in production and by nobody here. No local test could catch
-- it, because the privilege it would test for did not exist.
--
-- So the first thing asserted is the STUB, not the schema.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- =====================================================================
-- The default privilege itself
--
-- Asserted directly rather than through its effects. Taking the line
-- out of `_local_stack.sql` would make every assertion below pass for
-- the wrong reason -- a function nobody can reach breaks no rule about
-- what people can reach -- which is exactly how this was invisible in
-- the first place.
-- =====================================================================
do $$
declare
  v_acl text;
begin
  select coalesce(string_agg(d.defaclacl::text, ' | '), '(no row)')
    into v_acl
    from pg_default_acl d
    join pg_namespace n on n.oid = d.defaclnamespace
   where n.nspname = 'public' and d.defaclobjtype = 'f'
     and pg_get_userbyid(d.defaclrole) = 'postgres';

  perform pg_temp.check_true(
    'this machine models the hosted project''s default for FUNCTIONS, '
    'without which nothing below means anything: ' || v_acl,
    v_acl ~ 'authenticated=X' and v_acl ~ 'service_role=X');
end $$;

-- =====================================================================
-- 0165's event trigger still fires
--
-- The default hands every new function to `anon`; the event trigger
-- takes it away again. Both halves, because either one alone is a
-- different world: without the default there is nothing to revoke, and
-- without the trigger every function in the schema is anonymous.
-- =====================================================================
do $$
begin
  perform pg_temp.check_true(
    'the trigger that strips PUBLIC and anon from a new function exists',
    exists (select 1 from pg_event_trigger
             where evtname = 'revoke_public_execute' and evtenabled <> 'D'));

  -- And it works, on a function made here and now. A trigger that
  -- exists and is broken looks exactly like one that works.
  create function public.pg_temp_probe_function() returns integer
    language sql as 'select 1';

  perform pg_temp.check_true(
    'and a function created now is NOT reachable by a stranger',
    not has_function_privilege(
      'anon', 'public.pg_temp_probe_function()', 'execute'));

  -- The positive control. The same new function IS reachable by a
  -- signed-in user, which is the hosted default doing its work and is
  -- the whole reason a migration has to revoke by hand.
  perform pg_temp.check_true(
    'while a signed-in user reaches it without anybody granting anything',
    has_function_privilege(
      'authenticated', 'public.pg_temp_probe_function()', 'execute'));

  drop function public.pg_temp_probe_function();
end $$;

-- =====================================================================
-- Nothing in public is reachable by nobody
--
-- A function in the schema PostgREST exposes that no role can execute
-- is either dead or a feature that has never worked -- an edge function
-- calling it gets 42501 and, because that arrives inside a catch, gets
-- it silently.
--
-- Extension-owned functions are excluded: `btree_gist` and `pg_trgm`
-- install their own internals and their grants are how an extension
-- installs, not a decision anybody made here.
-- =====================================================================
do $$
declare
  v_left text;
  v_seen integer;
begin
  select count(*) into v_seen
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f';
  perform pg_temp.check_true(
    'there are functions in public to look at', v_seen > 500);

  select string_agg(p.proname, ', ' order by p.proname) into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.proacl is not null
     and not has_function_privilege('authenticated', p.oid, 'execute')
     and not has_function_privilege('anon', p.oid, 'execute')
     and not has_function_privilege('service_role', p.oid, 'execute')
     and not exists (
       select 1 from pg_depend d
        where d.objid = p.oid and d.classid = 'pg_proc'::regclass
          and d.deptype = 'e');

  perform pg_temp.check_eq(
    'every function in public is reachable by somebody',
    coalesce(v_left, ''), '');
end $$;

-- =====================================================================
-- And the ones meant for the service role alone really are alone
--
-- These are the entry points an edge function calls holding the service
-- key: a punch from a clock on a wall, a consolidated e-Invoice filed
-- on a deadline, a payment settling. A signed-in user who could call
-- any of them could file attendance for somebody else, submit another
-- company's tax document, or settle a payment that never arrived.
--
-- Named rather than derived. A rule like "everything with `scheduler`
-- in its name" would go quiet the day somebody named one differently.
-- =====================================================================
do $$
declare
  v_fn   text;
  v_open text := '';
begin
  foreach v_fn in array array[
    'public.record_terminal_punch(uuid, text, timestamptz, text)',
    'public.terminal_secret_matches(uuid, text)',
    'public.scheduler_prepare_consolidated_einvoice(uuid)',
    'public.einvoice_consolidations_due(integer)',
    'public.ocr_finish(uuid, text, jsonb, text)',
    'public.receive_email(text, text, text, text, text, text, text, text)',
    'public.settle_gateway_payment(text, text, boolean, numeric, jsonb)',
    'public.push_targets(uuid, uuid)'
  ] loop
    if has_function_privilege('authenticated', v_fn, 'execute')
       or has_function_privilege('anon', v_fn, 'execute') then
      v_open := v_open || v_fn || ' ';
    end if;
  end loop;

  perform pg_temp.check_eq(
    'the service role''s own entry points are reachable by nobody else',
    v_open, '');

  -- CONTROL. An ordinary RPC the app calls IS reachable by a signed-in
  -- user, so the assertion above is about those eight functions rather
  -- than about the privilege system being switched off.
  perform pg_temp.check_true(
    'while an ordinary one the app calls is reachable',
    has_function_privilege(
      'authenticated', 'public.declarable_reliefs(integer)', 'execute'));
end $$;

rollback;
