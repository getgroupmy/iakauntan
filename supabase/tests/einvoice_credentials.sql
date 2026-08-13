-- =====================================================================
-- iAkauntan :: LHDN credentials, one set per organization per environment
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/einvoice_credentials.sql
--
-- This table was correct in every respect except that nothing could
-- write to it. RLS is on with no policies — right, for client secrets
-- and certificate private keys — but the Settings screen wrote to the
-- table directly, so every save was refused and the table stayed empty.
-- e-Invoice, the most statutory thing here, was never reachable.
--
-- So the first assertion is the plain one that was missing: an
-- administrator can save credentials at all. After that, the four
-- properties that make them safe to hold:
--
--   * a signed-in user still cannot touch the table itself;
--   * the secret never comes back out of anything the app can call;
--   * correcting a client id does not silently blank the secret;
--   * sandbox and production coexist, so going live does not destroy
--     the sandbox setup you would want to go back to.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Saving them, which is the part that never worked
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Credentials Sdn Bhd');
  r record;
begin
  perform public.set_einvoice_credentials(v_org, 'sandbox', 'sb-client', 'sb-secret');
  perform pg_temp.check_eq('an administrator can save credentials',
    (select count(*) from public.einvoice_credentials where org_id = v_org), 1);

  -- The reason for the composite key. Going live must not destroy the
  -- sandbox setup — that is the one you go back to when production
  -- misbehaves.
  perform public.set_einvoice_credentials(v_org, 'production', 'pr-client', 'pr-secret');
  perform pg_temp.check_eq('and both environments are held at once',
    (select count(*) from public.einvoice_credentials where org_id = v_org), 2);

  -- Correcting a typo in the client id, with no secret re-entered.
  perform public.set_einvoice_credentials(v_org, 'sandbox', 'sb-client-fixed');
  perform pg_temp.check_true('editing the id leaves the secret alone',
    (select client_secret = 'sb-secret' and client_id = 'sb-client-fixed'
       from public.einvoice_credentials
      where org_id = v_org and environment = 'sandbox'));
  perform pg_temp.check_true('and does not reach the other environment',
    (select client_secret = 'pr-secret' from public.einvoice_credentials
      where org_id = v_org and environment = 'production'));

  -- A first save with nothing to authenticate with is refused rather
  -- than stored half-made. `client_secret` is NOT NULL, so the friendly
  -- message has to be raised before the insert, not caught after it.
  begin
    perform public.set_einvoice_credentials(v_org, 'sandbox', 'x', null);
    -- Reaching here is fine: sandbox already has a secret to keep.
  exception when others then
    raise exception 'FAIL: refused an edit that should have kept the secret';
  end;

  begin
    perform public.set_einvoice_credentials(
      pg_temp.test_org('Nothing Yet Sdn Bhd'), 'sandbox', 'id-only', null);
    raise exception 'FAIL: stored a first credential with no secret';
  exception when sqlstate '23514' then
    raise notice 'ok   a first save with no secret is refused';
  end;

  begin
    perform public.set_einvoice_credentials(v_org, 'staging', 'x', 'y');
    raise exception 'FAIL: accepted an environment LHDN does not have';
  exception when sqlstate '23514' then
    raise notice 'ok   an unknown environment is refused';
  end;

  begin
    perform public.set_einvoice_credentials(v_org, 'sandbox', '   ', 'y');
    raise exception 'FAIL: accepted a blank client id';
  exception when sqlstate '23514' then
    raise notice 'ok   a blank client id is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Reading them back, without reading them
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Status Sdn Bhd');
  v_fresh uuid := pg_temp.test_org('Untouched Sdn Bhd');
  r record;
begin
  perform public.set_einvoice_credentials(v_org, 'sandbox', 'sb-id', 'sb-secret');

  select * into r from public.einvoice_credential_status(v_org)
   where environment = 'sandbox';
  perform pg_temp.check_true('the status names the client id', r.client_id = 'sb-id');
  perform pg_temp.check_true('says a secret is set without saying what it is',
    r.has_secret);
  perform pg_temp.check_true('and knows there is no certificate yet',
    not r.has_certificate);

  -- The whole point of the reader. If this ever returns the secret, the
  -- table might as well have a select policy on it.
  --
  -- Matched against `client_secret` and `private_key`, the actual column
  -- names, rather than the word "secret" — which `has_secret` contains,
  -- so the obvious version of this assertion contradicts itself and can
  -- never pass. It went in that way and CI caught it.
  perform pg_temp.check_true('the secret is not among the columns at all',
    pg_get_function_result(
      (select oid from pg_proc where proname = 'einvoice_credential_status'))
      not ilike '%client_secret%');
  perform pg_temp.check_true('nor the certificate private key',
    pg_get_function_result(
      (select oid from pg_proc where proname = 'einvoice_credential_status'))
      not ilike '%private_key%');
  perform pg_temp.check_true('only whether one is on file',
    pg_get_function_result(
      (select oid from pg_proc where proname = 'einvoice_credential_status'))
      ilike '%has_secret%');

  -- Both environments always come back, so a screen can say production
  -- is empty rather than leaving it to be inferred from an absence.
  perform pg_temp.check_eq('an organization with nothing set still lists both',
    (select count(*) from public.einvoice_credential_status(v_fresh)), 2);
  perform pg_temp.check_eq('with neither configured',
    (select count(*) filter (where has_secret)
       from public.einvoice_credential_status(v_fresh)), 0);

  -- Which one is in force is the organization's setting, not a property
  -- of the credentials — the same question the edge function has to ask
  -- before it picks a row.
  perform pg_temp.check_eq('exactly one environment is the current one',
    (select count(*) filter (where is_current)
       from public.einvoice_credential_status(v_org)), 1);

  -- Removing them is its own verb, so an empty form cannot do it.
  perform public.clear_einvoice_credentials(v_org, 'sandbox');
  perform pg_temp.check_eq('clearing removes just that environment',
    (select count(*) from public.einvoice_credentials where org_id = v_org), 0);
end $$;

-- ---------------------------------------------------------------------
-- Who may, and who may not
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Locked Sdn Bhd');
  v_msg text;
begin
  perform public.set_einvoice_credentials(v_org, 'sandbox', 'id', 'secret');

  -- The bug this migration fixed, asserted so it cannot come back: the
  -- app must not be able to write the table directly, and until 0107 it
  -- was trying to.
  begin
    execute 'set local role authenticated';
    insert into public.einvoice_credentials (org_id, environment, client_id, client_secret)
    values (v_org, 'production', 'direct', 'direct');
    execute 'reset role';
    raise exception 'FAIL: wrote credentials directly as a signed-in user';
  exception when insufficient_privilege or sqlstate '42501' then
    execute 'reset role';
    raise notice 'ok   a signed-in user cannot write the table directly';
  when others then
    execute 'reset role';
    get stacked diagnostics v_msg = message_text;
    if v_msg not like '%row-level security%' and v_msg not like '%permission denied%' then
      raise exception 'FAIL: unexpected error writing directly: %', v_msg;
    end if;
    raise notice 'ok   a signed-in user cannot write the table directly';
  end;

  -- Two barriers rather than one. RLS refuses these roles, and so does
  -- the grant — so disabling RLS by accident does not hand every
  -- organization's client secret to anyone holding the publishable key.
  perform pg_temp.check_eq('no table privileges remain for the app roles',
    (select count(*) from information_schema.role_table_grants
      where table_schema = 'public' and table_name = 'einvoice_credentials'
        and grantee in ('anon', 'authenticated')), 0);
  perform pg_temp.check_true('and the table still has RLS with no policies',
    (select relrowsecurity from pg_class where relname = 'einvoice_credentials')
    and not exists (select 1 from pg_policies
                     where schemaname = 'public'
                       and tablename = 'einvoice_credentials'));

  perform pg_temp.check_true('setting them is closed to anon',
    not has_function_privilege('anon',
      'public.set_einvoice_credentials(uuid, text, text, text, text, text, text, text, timestamptz)',
      'execute'));
  perform pg_temp.check_true('and reading the status too',
    not has_function_privilege('anon',
      'public.einvoice_credential_status(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may call both',
    has_function_privilege('authenticated',
      'public.einvoice_credential_status(uuid)', 'execute'));
end $$;

-- ---------------------------------------------------------------------
-- Somebody else's organization
-- ---------------------------------------------------------------------
do $$
declare
  v_mine   uuid := pg_temp.test_org('Mine Sdn Bhd');
  v_theirs uuid;
begin
  -- Made by a different owner, so the current user is not a member.
  insert into public.organizations (name, slug, entity_type, base_currency, created_by)
  values ('Theirs Sdn Bhd', 'theirs-' || gen_random_uuid(), 'sdn_bhd', 'MYR',
          (select id from auth.users order by created_at limit 1))
  returning id into v_theirs;
  delete from public.org_members where org_id = v_theirs;

  begin
    perform public.set_einvoice_credentials(v_theirs, 'sandbox', 'x', 'y');
    raise exception 'FAIL: set credentials on an organization I do not belong to';
  exception when sqlstate '42501' then
    raise notice 'ok   another organization''s credentials cannot be set';
  end;

  begin
    perform public.einvoice_credential_status(v_theirs);
    raise exception 'FAIL: read the e-Invoice setup of another organization';
  exception when sqlstate '42501' then
    raise notice 'ok   nor read';
  end;
end $$;

rollback;
