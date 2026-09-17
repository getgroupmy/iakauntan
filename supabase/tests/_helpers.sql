-- =====================================================================
-- iAkauntan :: shared test helpers
--
-- EVERY FAILURE HERE IS RAISED WITH ERRCODE 'P0004', assert_failure,
-- and that is not decoration. PL/pgSQL's `when others` does not catch
-- assert_failure -- it is one of the two conditions (with
-- query_canceled) that pass straight through. Without it, this shape,
-- which the suite uses everywhere, quietly asserts nothing:
--
--   begin
--     perform <the thing that must be refused>;
--     perform pg_temp.check_true('a contra between two parties', false);
--   exception when others then
--     get stacked diagnostics v_msg = message_text;
--     perform pg_temp.check_true('... is refused',
--       v_msg like '%two parties%');
--   end;
--
-- When the refusal does NOT happen, `check_true(..., false)` raises
-- `FAIL a contra between two parties: expected true` -- and the handler
-- immediately below catches it and matches its own label against the
-- pattern. The test passes BECAUSE it failed. It was found by a
-- mutation sweep of create_contra: app.same_party could be deleted
-- outright and contra.sql still read green.
--
-- With P0004 the marker escapes the handler and reaches psql, which is
-- what a failure is supposed to do.
--
-- Included by the other files in this directory with
--
--   \i supabase/tests/_helpers.sql
--
-- so paths are relative to the repository root, which is where CI runs
-- psql from. Everything lives in pg_temp and dies with the session.
-- =====================================================================

create or replace function pg_temp.check_eq(
  p_label text, p_actual numeric, p_expected numeric)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_label, p_expected, p_actual
      using errcode = 'P0004';
  end if;
  raise notice 'ok   % = %', p_label, p_actual;
end;
$$;

-- The same helper for the two other things a test actually compares.
--
-- `check_eq(text, numeric, numeric)` above cannot take them: numeric has
-- no implicit cast from text and none at all from uuid, so an assertion
-- about which station a dish routes to, or which contact ended up on a
-- sale, failed to resolve rather than failing to hold — which reads in
-- CI like a broken test rather than a broken expectation.
--
-- Three overloads resolve without ambiguity because the arguments are
-- typed at every real call site, and an all-literal call picks text,
-- which is the preferred type of the string category and the right
-- guess.
create or replace function pg_temp.check_eq(
  p_label text, p_actual text, p_expected text)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_label, p_expected, p_actual
      using errcode = 'P0004';
  end if;
  raise notice 'ok   % = %', p_label, p_actual;
end;
$$;

create or replace function pg_temp.check_eq(
  p_label text, p_actual uuid, p_expected uuid)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %', p_label, p_expected, p_actual
      using errcode = 'P0004';
  end if;
  raise notice 'ok   %', p_label;
end;
$$;

create or replace function pg_temp.check_true(p_label text, p_value boolean)
returns void language plpgsql as $$
begin
  if p_value is not true then
    raise exception 'FAIL %: expected true', p_label
      using errcode = 'P0004';
  end if;
  raise notice 'ok   %', p_label;
end;
$$;

-- What a refusal is allowed to say.
--
-- `pg_temp.check_refused(label, statement, like)` runs a statement,
-- requires it to be refused, and requires the refusal to be the one
-- meant. Written because a sweep of `create_withholding` found the
-- opposite habit doing real damage:
--
--     begin
--       perform public.create_withholding(v_draft, 'S109B_SPECIAL');
--       raise exception 'FAIL: withheld against an unposted bill';
--     exception when sqlstate '22023' then
--       raise notice 'ok   the bill has to be posted first';
--     end;
--
-- That assertion passes with the unposted-bill guard DELETED, because
-- the next guard along raises the same `22023` for a different reason.
-- `when others` is worse again: it catches a typo in the statement
-- under test and reports it as a pass.
--
-- A guard is identified by what it SAYS. Where two guards on one path
-- word themselves identically there is nothing to tell them apart,
-- which is an argument for wording them differently rather than for
-- asserting less.
create or replace function pg_temp.check_refused(
  p_label text, p_statement text, p_message_like text,
  p_sqlstate text default null)
returns void language plpgsql as $$
declare
  v_msg   text;
  v_state text;
begin
  begin
    execute p_statement;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    -- Our own FAIL assertions are P0004; catching one here would turn a
    -- failed inner assertion into a passed outer one.
    if v_state = 'P0004' then
      raise exception 'FAIL %: the statement failed an assertion of its own: %',
        p_label, v_msg using errcode = 'P0004';
    end if;
    if v_msg not like p_message_like then
      raise exception 'FAIL %: refused, but for the wrong reason: %',
        p_label, v_msg using errcode = 'P0004';
    end if;
    if p_sqlstate is not null and v_state <> p_sqlstate then
      raise exception 'FAIL %: refused with % rather than %',
        p_label, v_state, p_sqlstate using errcode = 'P0004';
    end if;
    raise notice 'ok   %', p_label;
    return;
  end;
  raise exception 'FAIL %: it was not refused at all', p_label
    using errcode = 'P0004';
end;
$$;

-- A user to hang the fixtures off. A freshly migrated stack has no one
-- signed up yet, and the trigger that enrols an organization's creator as
-- its owner needs a real row in auth.users, so make one if it is not
-- already there. Rolled back with everything else.
--
-- Pinned to its own address. This used to be "the first row in
-- auth.users", selected with `order by created_at limit 1` — and
-- `auth.users.created_at` has no default and is nullable, so every user
-- these helpers make carries NULL in it. The ordering was therefore over
-- a column in which every value was null, and the row that came back was
-- whichever the scan happened to reach first.
--
-- That is fine right up to the moment a file makes a second user, after
-- which `test_user()` can hand back somebody else's. It is not a
-- hypothetical: `manufacturing.sql` asserts that the owner of one
-- company can read its own bill of materials, and that assertion passed
-- on one CI run and failed on the next with nothing between them but an
-- unrelated commit — because `test_user()` returned the outsider created
-- forty lines earlier, who belongs to the other company and correctly
-- sees nothing. A fixture identity that is decided by physical row order
-- makes every test built on it a coin toss.
--
-- The empty strings are not decoration. GoTrue reads its token columns
-- into non-nullable Go strings, so a user inserted with those columns
-- left NULL cannot sign in at all: the row fails to scan and the API
-- answers 500 `{"code":"unexpected_failure","message":"Database error
-- querying schema"}` — before it ever looks at the password, which makes
-- it read like anything except what it is. Tests never call GoTrue, so
-- this changes nothing here; it is written down because this is the
-- pattern anyone will copy when they need to make a real user by hand.
create or replace function pg_temp.test_user()
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  select id into v_id from auth.users
   where email = 'fixture@iakauntan.test';
  if v_id is null then
    insert into auth.users (
      id, email, created_at, updated_at,
      confirmation_token, recovery_token,
      email_change_token_new, email_change_token_current,
      phone_change_token, reauthentication_token,
      email_change, phone_change)
    values (gen_random_uuid(), 'fixture@iakauntan.test', now(), now(),
      '', '', '', '', '', '', '', '')
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- A *different* person each time, for tests about more than one.
--
-- `test_user()` above is idempotent by design — it returns the fixture
-- user and creates one only if it is not there — which is right for
-- hanging a fixture off and wrong whenever the point of the test is that
-- these are two people. Asked for three users it hands back the same one
-- three times, and every assertion about what a colleague cannot do
-- quietly becomes an assertion about yourself, which passes for the
-- wrong reason or fails for a reason that makes no sense.
--
-- `created_at` is set here for the same reason it is set above: the
-- column has no default, and a table of users that are all null in it
-- cannot be ordered by it.
--
-- The empty strings are load-bearing for the same reason they are above.
create or replace function pg_temp.another_user(p_email text)
returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    id, email, created_at, updated_at,
    confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current,
    phone_change_token, reauthentication_token,
    email_change, phone_change)
  values (v_id, p_email, now(), now(), '', '', '', '', '', '', '', '');
  return v_id;
end;
$$;

-- Runs the rest of the transaction as that user, so the `can_*` guards
-- inside the SECURITY DEFINER functions see somebody rather than nobody.
create or replace function pg_temp.sign_in_as(p_user uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end;
$$;

create or replace function pg_temp.sign_out()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
end;
$$;

-- A throwaway organization owned by the fixture user, already signed in
-- and with the standard chart of accounts, which anything that posts
-- needs. Deliberately not create_organization(): that reads auth.uid(),
-- and the caller has not signed in yet at this point.
-- `p_modules` decides what the fixture holds.
--
-- Null means every module, which is right for almost every file here:
-- they assert business rules rather than billing, and since 0232 made
-- entitlement real a fixture that said nothing would be a fixture that
-- cannot post a journal.
--
-- An explicit list is for the files that assert a module is *absent*.
-- `property.sql` is the one that found this: it proves a strata-only
-- company is refused rent invoicing, "otherwise the modules are one
-- module with two names" — and a blanket grant quietly turned that
-- assertion into a no-op. Granting everything by default is convenient;
-- granting everything unconditionally deletes exactly the tests worth
-- having.
-- 0486 makes the second company an entitlement: the first is what
-- signing up is for, the rest are the Multi-Company module. A file
-- testing what a company *is* -- its country, its tax registration,
-- its ledger -- is not a file about paying for one, so it says this
-- once and goes on standing up as many as it needs.
--
-- Deliberately after the fact rather than a blanket exemption: the
-- entitlement is granted on the companies the caller already owns,
-- which is exactly how somebody buys it in the product.
create or replace function pg_temp.allow_many_companies()
returns void language sql as $$
  insert into public.org_modules (org_id, module_code, is_enabled)
  select m.org_id, 'multi_company', true
    from public.org_members m
   where m.user_id = (nullif(current_setting('request.jwt.claims', true), '')
                        ::jsonb ->> 'sub')::uuid
     and m.role = 'owner'
  on conflict (org_id, module_code) do update set is_enabled = true;
$$;

create or replace function pg_temp.test_org(
  p_name    text,
  p_modules text[] default null)
returns uuid language plpgsql as $$
declare v_owner uuid := pg_temp.test_user(); v_org uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', v_owner)
  returning id into v_org;
  perform app.seed_chart_of_accounts(v_org);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, pm.code, true from public.platform_modules pm
   where p_modules is null or pm.code = any(p_modules)
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);
  return v_org;
end;
$$;
