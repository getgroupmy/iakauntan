-- =====================================================================
-- iAkauntan :: nothing in `app` that writes is a client's to start
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/app_writers_are_not_a_client_surface.sql
--
-- `0095` found this shape, fixed two instances, and said what caught
-- them: "`supabase/tests/statutory.sql` asserts that no SECURITY DEFINER
-- function outside a three-name allowlist is executable by `anon`. It
-- caught both of these, which is the entire reason it exists."
--
-- That assertion names `anon`, and only `anon`. Nobody asked the same
-- question of `authenticated`, which is the role anybody gets by
-- signing up.
--
-- Measured before `0407`, under `set local role authenticated`, as a
-- member of one company who is not a member of the other:
--
--     app.roll_leave_year(<the other company>, 2026)  -- accepted
--     app.run_recurring_journals(current_date)        -- accepted,
--         for every tenant on the platform, on a date the caller chose
--
-- Four functions in `app` write and were executable by a client role,
-- and not one carried a guard: those two, plus `seed_chart_of_accounts`
-- and `seed_org_modules` — the second of which writes the module
-- entitlements `0127` and `0129` built to decide what a company has
-- paid for.
--
-- ---------------------------------------------------------------------
-- Excess privilege, not an open door
--
-- Said plainly, because `0399` had to correct itself on this exact
-- point. PostgREST publishes `public` and not `app`, and no `public`
-- wrapper names any of the four, so a caller speaking to the API cannot
-- reach them. What is left is `0240`'s argument: "anything holding a
-- connection string gets the privilege, not the API's opinion of it" —
-- and the grant was explicit, `authenticated=X/postgres`, not a
-- leftover default.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_app (mine uuid, theirs uuid, me uuid);
grant select on t_app to authenticated;

do $$
declare
  v_mine uuid; v_theirs uuid; v_owner uuid := pg_temp.test_user(); v_me uuid;
begin
  v_theirs := pg_temp.test_org('Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);

  v_me := pg_temp.another_user('penyusup@example.test');
  insert into public.organizations (name, slug, entity_type, base_currency,
                                    created_by)
  values ('Saya Sdn Bhd', 'saya-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          v_owner)
  returning id into v_mine;
  perform app.seed_chart_of_accounts(v_mine);
  insert into public.org_members (org_id, user_id, role, status)
  values (v_mine, v_me, 'owner', 'active');

  insert into t_app values (v_mine, v_theirs, v_me);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select me from t_app),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record;
begin
  select * into c from t_app;

  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('and this member is a stranger to the other company',
    not app.is_org_member(c.theirs));

  begin
    perform app.roll_leave_year(c.theirs, 2026);
    raise exception
      'FAIL: a stranger rolled another company''s leave year';
  exception when insufficient_privilege then
    raise notice 'ok   another company''s leave year cannot be rolled';
  end;

  begin
    perform app.run_recurring_journals(current_date);
    raise exception
      'FAIL: a stranger posted every tenant''s recurring journals';
  exception when insufficient_privilege then
    raise notice 'ok   nor every tenant''s recurring journals posted';
  end;

  begin
    perform app.seed_org_modules(c.mine);
    raise exception
      'FAIL: a member granted their own company every module';
  exception when insufficient_privilege then
    raise notice 'ok   nor a company''s entitlements written by hand';
  end;

  begin
    perform app.seed_chart_of_accounts(c.theirs);
    raise exception
      'FAIL: a stranger wrote into another company''s chart of accounts';
  exception when insufficient_privilege then
    raise notice 'ok   nor another company''s chart of accounts';
  end;

  -- The positive control. All four refusals would also happen if this
  -- role could execute nothing at all, and `app` is full of predicates
  -- that RLS itself calls -- `is_org_member` above is one, and every
  -- policy in the schema would stop working without it.
  perform pg_temp.check_true('a client role still calls the RLS predicates',
    app.is_org_member(c.mine));
  perform pg_temp.check_true('and the pure helpers beside them',
    app.has_module(c.mine, 'accounting') is not null);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The scheduler and org creation still reach them
-- ---------------------------------------------------------------------
-- Revoking from a client role must not revoke from the nightly run.
-- A SECURITY DEFINER function calling another runs as the definer, so
-- the inner grant is never consulted -- asserted by doing it rather
-- than by saying it.
do $$
declare c record; v_before bigint; v_org uuid;
begin
  select * into c from t_app;
  perform pg_temp.sign_in_as(pg_temp.test_user());

  perform app.roll_leave_year(c.theirs, 2026);
  raise notice 'ok   the scheduler still rolls a leave year';

  perform app.run_recurring_journals(current_date);
  raise notice 'ok   and still posts the recurring journals';

  -- Org creation seeds a chart of accounts, which is the other pair.
  insert into public.organizations (name, slug, entity_type, base_currency,
                                    created_by)
  values ('Baharu Sdn Bhd', 'baharu-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          pg_temp.test_user())
  returning id into v_org;
  perform app.seed_chart_of_accounts(v_org);
  perform app.seed_org_modules(v_org);
  perform pg_temp.check_true('and a new company still gets its accounts',
    (select count(*) from public.accounts where org_id = v_org) > 0);
end $$;

-- ---------------------------------------------------------------------
-- And the rule, asked of the catalogue rather than of those four
-- ---------------------------------------------------------------------
-- Mechanical on purpose, and taking no view on guards. Asking "does it
-- carry a guard" means matching the *names* of guards, and a sweep
-- written as a list of guard names measures the list rather than the
-- code. A function in `app` that writes and runs as its definer is not
-- something a client role executes, guarded or not.
do $$
declare v_open text; v_n int; v_writers int;
begin
  select count(*), string_agg(p.proname, ', ' order by p.proname)
    into v_n, v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.prosecdef
     and (has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute'))
     and p.prosrc ~* '(insert into|update +public\.|delete +from)';

  if v_n > 0 then
    raise exception
      'FAIL: % writes and runs as its definer, and a client role can '
      'execute it. PostgREST does not publish `app`, so this is excess '
      'privilege rather than an open door -- but a connection string is '
      'not PostgREST. Revoke it, or exempt it in `0407` with a reason.',
      v_open;
  end if;

  -- Stated, because "no writer is open" is also true of a schema with
  -- no writers in it, and this whole file would then be measuring
  -- nothing at all.
  select count(*) into v_writers
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.prosecdef
     and p.prosrc ~* '(insert into|update +public\.|delete +from)';
  perform pg_temp.check_true(
    'and there are definer writers in `app` for the rule to be about: '
    || v_writers, v_writers > 20);

  raise notice
    'ok   none of the % writers in `app` is executable by a client role',
    v_writers;
end $$;

rollback;
