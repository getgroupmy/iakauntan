-- =====================================================================
-- iAkauntan :: what a caller can actually call
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/function_grants.sql
--
-- `table_grants.sql` asserts what a stranger can READ. This asserts
-- what anybody can CALL, and it exists because ten functions with live
-- callers could not be called by them and nothing noticed for months.
--
-- ---------------------------------------------------------------------
-- The rule, which `0618` had to establish twice
--
-- A new function in `public` is executable by **postgres and nobody
-- else**. Two different mechanisms produce that: on the real Supabase
-- stack a default ACL of `{postgres=X/postgres}`, and on the local stub
-- PostgreSQL's built-in grant to PUBLIC followed by `0165`'s event
-- trigger revoking it. Same end state, which is why the two agree.
--
-- `0617` believed the opposite -- that Supabase grants new functions to
-- `authenticated` and `service_role` by default -- and taught the stub
-- to model it. CI refused it, and `0618` says at length why the
-- evidence behind that belief was a misreading.
--
-- So every caller needs an explicit grant, and a function nobody can
-- call is a feature that silently never happens: PostgREST answers
-- 42501, the edge function catches it, and nothing is logged anywhere
-- anybody looks.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- =====================================================================
-- A new function is callable by nobody until somebody says otherwise
--
-- Asserted on a function created here and now, because this is the
-- premise every other assertion in the file rests on. Getting it
-- backwards is what `0617` did.
-- =====================================================================
do $$
begin
  create function public.pg_temp_probe_function() returns integer
    language sql as 'select 1';

  perform pg_temp.check_true(
    'a function created now is callable by no signed-in user',
    not has_function_privilege(
      'authenticated', 'public.pg_temp_probe_function()', 'execute'));
  perform pg_temp.check_true(
    'nor by a stranger',
    not has_function_privilege(
      'anon', 'public.pg_temp_probe_function()', 'execute'));
  perform pg_temp.check_true(
    'nor by the service role, which is the half that keeps being '
    'forgotten',
    not has_function_privilege(
      'service_role', 'public.pg_temp_probe_function()', 'execute'));

  -- And a grant reaches it, so the assertions above are about the
  -- default rather than about privileges being broken outright.
  grant execute on function public.pg_temp_probe_function() to service_role;
  perform pg_temp.check_true(
    'and an explicit grant is what makes it callable',
    has_function_privilege(
      'service_role', 'public.pg_temp_probe_function()', 'execute'));

  drop function public.pg_temp_probe_function();
end $$;

-- =====================================================================
-- 0165's event trigger still strips PUBLIC
--
-- It is what makes the local stub agree with the hosted stack. Without
-- it a new function here would be callable by everybody and by nobody
-- there.
-- =====================================================================
do $$
begin
  perform pg_temp.check_true(
    'the trigger that strips PUBLIC and anon from a new function exists',
    exists (select 1 from pg_event_trigger
             where evtname = 'revoke_public_execute' and evtenabled <> 'D'));
end $$;

-- =====================================================================
-- Nothing in public is callable by nobody
--
-- The assertion this file is for. A function in the schema PostgREST
-- exposes that no client role can execute is either dead or a feature
-- that has never worked once.
--
-- Three are deliberately unreachable and are named, and all three run
-- INSIDE the database where PostgREST is not involved and the caller is
-- the job owner: `chat_expire_calls` and `prune_device_tokens` from
-- `app.run_daily_jobs`, and `ticket_sla_sweep` from the `pg_cron` job
-- `iakauntan-sla-sweep` that `0356` schedules every five minutes.
-- Granting any of them would widen the client surface for nothing.
--
-- `0618` said of the third that only the demo builder calls it. That is
-- what a grep of the migrations shows and it is misleading: `0356` is
-- titled "the SLA clock nobody wound" and exists precisely because the
-- sweep was not being run, so a note implying it still is not would
-- send the next reader to fix something that was fixed.
--
-- Named rather than counted, so that a fourth one is a failure with a
-- name in it rather than a number that somebody raises.
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

  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname)
    into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.proacl is not null
     and not has_function_privilege('authenticated', p.oid, 'execute')
     and not has_function_privilege('anon', p.oid, 'execute')
     and not has_function_privilege('service_role', p.oid, 'execute')
     and p.proname not in ('chat_expire_calls', 'prune_device_tokens',
                           'ticket_sla_sweep')
     -- `citext`, `btree_gist` and `pg_trgm` install into `public`.
     -- Their grants are how an extension installs, not a decision
     -- anybody here made.
     and not exists (
       select 1 from pg_depend d
        where d.objid = p.oid and d.classid = 'pg_proc'::regclass
          and d.deptype = 'e');

  perform pg_temp.check_eq(
    'every function in public can be called by somebody',
    coalesce(v_left, ''), '');
end $$;

-- =====================================================================
-- The ten that `0618` fixed, by name
--
-- The list above would go quiet if somebody granted these to
-- `authenticated` instead -- reachable by somebody, and wrong. So the
-- role is asserted as well as the reachability.
-- =====================================================================
do $$
declare
  v_fn     text;
  v_missing text := '';
  v_open   text := '';
begin
  foreach v_fn in array array[
    'public.push_targets(uuid, uuid)',
    'public.forget_device_token(text)',
    'public.begin_shared_payment(text, text, text, text)',
    'public.settle_shared_payment(text, text, boolean, numeric, jsonb)',
    'public.record_terminal_punch(uuid, text, timestamptz, text)',
    'public.terminal_secret_matches(uuid, text)',
    'public.scheduler_prepare_consolidated_einvoice(uuid)',
    'public.einvoice_consolidations_due(integer)',
    'public.ocr_finish(uuid, text, jsonb, text)',
    'public.receive_email(text, text, text, text, text, text, text, text)',
    'public.settle_gateway_payment(text, text, boolean, numeric, jsonb)'
  ] loop
    if not has_function_privilege('service_role', v_fn, 'execute') then
      v_missing := v_missing || v_fn || ' ';
    end if;
    -- And still nobody else's. A push target list reachable by a
    -- signed-in user is every device token in the database.
    if has_function_privilege('authenticated', v_fn, 'execute')
       or has_function_privilege('anon', v_fn, 'execute') then
      v_open := v_open || v_fn || ' ';
    end if;
  end loop;

  perform pg_temp.check_eq(
    'every edge function entry point is callable by the service role',
    v_missing, '');
  perform pg_temp.check_eq(
    'and by nobody else', v_open, '');
end $$;

-- =====================================================================
-- And the two the app calls
-- =====================================================================
do $$
begin
  perform pg_temp.check_true(
    'the reliefs an employee may declare are readable by a signed-in user',
    has_function_privilege(
      'authenticated', 'public.declarable_reliefs(integer)', 'execute'));
  perform pg_temp.check_true(
    'and an administrator can say where the takings land',
    has_function_privilege(
      'authenticated',
      'public.set_org_payment_settlement(uuid, text, text, uuid, text)',
      'execute'));

  -- Neither is a stranger's. Both were revoked from `anon` by their own
  -- migrations and the grant above must not have widened that.
  perform pg_temp.check_true(
    'and neither is reachable by a stranger',
    not has_function_privilege(
      'anon', 'public.declarable_reliefs(integer)', 'execute')
    and not has_function_privilege(
      'anon',
      'public.set_org_payment_settlement(uuid, text, text, uuid, text)',
      'execute'));
end $$;

rollback;
