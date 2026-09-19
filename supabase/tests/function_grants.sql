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
-- The rule, which took three migrations and two CI runs to settle
--
-- A new function in `public` arrives executable by `authenticated` and
-- `service_role`. Supabase ships `alter default privileges in schema
-- public grant all on functions to anon, authenticated, service_role`,
-- and `0165`'s event trigger then strips PUBLIC and `anon` -- so those
-- two survive, and `anon` does not. In schema `app` there is no such
-- default and a new function is callable by nobody.
--
-- **This file used to assert the opposite**, and was right about the
-- wrong database. CI has two: `supabase start` brings up the CLI's
-- local stack, which is where this file runs and where the default ACL
-- really is `{postgres=X/postgres}`; the migrations are pushed to the
-- LINKED HOSTED PROJECT in a different job, and that one has the
-- default. `0617` modelled the hosted behaviour, CI refused it against
-- the CLI stack, and `0618` concluded the hosted evidence had been
-- misread. It had not. `supabase/tests/_local_stack.sql` carries the
-- whole argument and the three hosted observations that settle it,
-- including CI run 1941.
--
-- Two consequences for what is below.
--
-- **A missing GRANT is still a silent feature that never happens** --
-- PostgREST answers 42501, the edge function catches it, and nothing is
-- logged anywhere anybody looks. That is what the "callable by
-- somebody" assertion is for, and it still has teeth: a migration that
-- revokes from all three and grants none is exactly the shape of
-- `chat_expire_calls`.
--
-- **A missing REVOKE is now the commoner mistake**, because the default
-- does the granting. `0657` revoked `push_targets` from the PUBLIC
-- pseudo-role alone, which does not touch a grant held DIRECTLY by
-- `authenticated`, and shipped a function returning every handset of
-- everybody in a conversation to any signed-in user. It passed 333
-- local files. The assertions below about who CANNOT call a function
-- are the ones that catch that, and until `_local_stack.sql` reproduced
-- the default they could not fail here.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- =====================================================================
-- What a new function arrives with
--
-- Asserted on functions created here and now, in both schemas, because
-- this is the premise every other assertion in the file rests on and it
-- has been wrong twice. The two schemas differ, and the difference is
-- the evidence: the default privilege names `public` and not `app`.
-- =====================================================================
do $$
begin
  create function public.pg_temp_probe_function() returns integer
    language sql as 'select 1';

  -- The default privilege, surviving `0165`'s trigger.
  perform pg_temp.check_true(
    'a new function in public arrives callable by a signed-in user',
    has_function_privilege(
      'authenticated', 'public.pg_temp_probe_function()', 'execute'));
  perform pg_temp.check_true(
    'and by the service role',
    has_function_privilege(
      'service_role', 'public.pg_temp_probe_function()', 'execute'));

  -- And `0165`'s trigger, which is the only thing standing between a
  -- new function in this schema and the open internet. PostgREST
  -- exposes `public`, and `anon` is who an unauthenticated request is.
  perform pg_temp.check_true(
    'but NOT by a stranger, because 0165 revokes anon at creation',
    not has_function_privilege(
      'anon', 'public.pg_temp_probe_function()', 'execute'));

  -- So closing one takes an explicit revoke, and `from public` alone is
  -- not it. This is the exact statement `0657` wrote, and the exact
  -- reason it was not enough.
  revoke execute on function public.pg_temp_probe_function() from public;
  perform pg_temp.check_true(
    'revoking from PUBLIC alone leaves a direct grant untouched',
    has_function_privilege(
      'authenticated', 'public.pg_temp_probe_function()', 'execute'));

  revoke execute on function public.pg_temp_probe_function()
    from public, anon, authenticated;
  perform pg_temp.check_true(
    'and naming the roles is what actually closes it',
    not has_function_privilege(
      'authenticated', 'public.pg_temp_probe_function()', 'execute'));

  drop function public.pg_temp_probe_function();
end $$;

do $$
begin
  -- `app` is not in the default privilege, so a function there arrives
  -- with PUBLIC only, which `0165` strips. Callable by nobody.
  create function app.pg_temp_probe_function() returns integer
    language sql as 'select 1';

  perform pg_temp.check_true(
    'a new function in app is callable by nobody',
    not has_function_privilege(
      'authenticated', 'app.pg_temp_probe_function()', 'execute')
    and not has_function_privilege(
      'anon', 'app.pg_temp_probe_function()', 'execute')
    and not has_function_privilege(
      'service_role', 'app.pg_temp_probe_function()', 'execute'));

  -- And a grant reaches it, so the assertion above is about the absence
  -- of a default rather than about privileges being broken outright.
  grant execute on function app.pg_temp_probe_function() to authenticated;
  perform pg_temp.check_true(
    'and an explicit grant is what makes it callable',
    has_function_privilege(
      'authenticated', 'app.pg_temp_probe_function()', 'execute'));

  drop function app.pg_temp_probe_function();
end $$;

-- =====================================================================
-- 0165's event trigger still strips PUBLIC and anon
--
-- It is the only thing between a new function in `public` and an
-- unauthenticated request. Supabase's default privilege grants `anon`
-- EXECUTE on every function created in this schema; PostgREST exposes
-- the schema; `anon` is who a request with no session is. Disable this
-- trigger and the next migration publishes its function to the
-- internet, quietly.
-- =====================================================================
do $$
begin
  perform pg_temp.check_true(
    'the trigger that strips PUBLIC and anon from a new function exists',
    exists (select 1 from pg_event_trigger
             where evtname = 'revoke_public_execute' and evtenabled <> 'D'));
end $$;

-- =====================================================================
-- And every function a stranger CAN call is one somebody meant
--
-- Twenty-one, all of them a deliberate front door: a signing link, a
-- portal opened with a token, the landing page, the public menu, the
-- two the sign-in form needs before anybody is signed in. Each carries
-- its own `grant execute ... to anon` written after its create,
-- precisely because `0165` had just taken it away.
--
-- Named rather than counted, so a twenty-second is a failure with a
-- name in it. This is the assertion `table_grants.sql` makes about what
-- a stranger can READ, for what a stranger can DO -- and it is the one
-- with the most to lose, because everything on this list is reachable
-- by anybody who knows the URL.
-- =====================================================================
do $$
declare v_extra text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_extra
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'execute')
     and not exists (
       select 1 from pg_depend d
        where d.objid = p.oid and d.classid = 'pg_proc'::regclass
          and d.deptype = 'e')
     and p.proname not in (
       -- Corporate secretarial signing, by emailed link.
       'corp_decline_with_link',
       'corp_open_signing_link',
       'corp_sign_with_link',
       -- The shopfront, and what it needs to draw itself.
       'landing_page',
       'maintenance_notice',
       'site_pages',
       'workspace_by_host',
       'signup_reference',
       -- Asked before anybody is signed in, which is the whole point:
       -- `may_sign_in_here` decides whether this surface offers the
       -- form at all, and `report_failed_sign_in` counts an attempt
       -- that by definition had no session.
       'may_sign_in_here',
       'report_failed_sign_in',
       -- Opened with a token in the URL and nothing else.
       'open_customer_portal',
       'open_shared_document',
       'open_shared_ticket',
       'open_tax_detail_request',
       'portal_document_token',
       'reply_to_shared_ticket',
       'submit_tax_details',
       'shared_payment_options',
       -- A menu on a table and an order placed from it.
       'place_public_pos_order',
       'public_pos_menu',
       'public_pos_menu_modifiers');

  perform pg_temp.check_eq(
    'no function in public is reachable by a stranger unless it is on '
    'this list', coalesce(v_extra, ''), '');

  -- And the control, so the list above is not passing because the
  -- query is broken: one that IS on it really is reachable.
  perform pg_temp.check_true(
    'and the ones on the list really are reachable by a stranger',
    has_function_privilege('anon', 'public.landing_page()', 'execute'));
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
