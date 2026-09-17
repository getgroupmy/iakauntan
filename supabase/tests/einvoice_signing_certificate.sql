-- =====================================================================
-- iAkauntan :: the signature on a tax document
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/einvoice_signing_certificate.sql
--
-- `0615`. A version 1.1 e-Invoice must be signed; a 1.0 one must not
-- be. What the database is responsible for is the CUSTODY of the key
-- and the ORDER of the setup -- the signature itself is arithmetic and
-- is asserted in `supabase/functions/_shared/xades_test.ts`.
--
-- Four claims, and the first is the one that matters most:
--
--   * **Nothing an organization can call returns the private key.**
--     `einvoice_credentials` has RLS with no policies and no grants;
--     the status function says whether a certificate is on file and
--     never what it is. Asserted against the function's own signature
--     rather than by reading it, because a column added later would
--     otherwise slip through.
--   * **A certificate needs credentials first.** `client_secret` is
--     NOT NULL and a company that cannot log in to MyInvois has
--     nothing to sign for, so this refuses rather than inserting half a
--     row -- and the refusal says which order to do it in.
--   * **Version 1.1 is refused without a certificate.** A company
--     switched to 1.1 with nothing to sign with has a submit button
--     that stops working, and the refusal it would get then comes from
--     LHDN by way of an edge function rather than from the screen that
--     caused it.
--   * **Setting the version does not eat the other settings.**
--     `jsonb_set` rather than an overwrite: `organizations.settings`
--     holds other things and a screen that writes the one key it knows
--     about is how a setting disappears with nobody touching it.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A certificate and a key, in the shape the columns take. Neither is
-- real and neither is ever parsed here -- the parser is in the edge
-- function, deliberately, and this file is about custody.
create or replace function pg_temp.a_certificate()
returns text language sql immutable as $$
  select '-----BEGIN CERTIFICATE-----' || chr(10) || 'QUJDRA==' || chr(10)
      || '-----END CERTIFICATE-----'
$$;

create or replace function pg_temp.a_key()
returns text language sql immutable as $$
  select '-----BEGIN PRIVATE KEY-----' || chr(10) || 'RUZHSA==' || chr(10)
      || '-----END PRIVATE KEY-----'
$$;

-- =====================================================================
-- The table nothing can read
--
-- Restated here rather than assumed from 0107, because this is the
-- migration that gave the key a reason to be there.
-- =====================================================================
do $$
declare
  v_policies integer;
  v_grants   integer;
begin
  select count(*) into v_policies
    from pg_policies
   where schemaname = 'public' and tablename = 'einvoice_credentials';
  perform pg_temp.check_eq(
    'the table holding the signing key has no policies at all',
    v_policies, 0);

  select count(*) into v_grants
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'einvoice_credentials'
     and grantee in ('anon', 'authenticated');
  perform pg_temp.check_eq(
    'and no grants to anybody signed in or not', v_grants, 0);

  perform pg_temp.check_true(
    'and row level security is on, so the absence of policies means '
    'nothing rather than everything',
    (select relrowsecurity from pg_class
      where oid = 'public.einvoice_credentials'::regclass));
end $$;

-- =====================================================================
-- What the status function is allowed to say
--
-- Asserted against the function's declared output columns. A future
-- edit that adds `cert_private_key_pem` to the select would otherwise
-- be a private key on a settings screen, and every assertion below
-- would still pass.
-- =====================================================================
do $$
declare
  v_columns text;
begin
  select string_agg(a.attname, ',' order by a.attnum) into v_columns
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join unnest(p.proallargtypes, p.proargmodes, p.proargnames)
         with ordinality as a(atttypid, attmode, attname, attnum)
      on a.attmode = 't'
   where n.nspname = 'public' and p.proname = 'einvoice_credential_status';

  perform pg_temp.check_true(
    'the status function returns no certificate and no key: ' || v_columns,
    v_columns not like '%cert_pem%'
      and v_columns not like '%private_key%'
      and v_columns not like '%client_secret%');

  perform pg_temp.check_true(
    'and does say which certificate, which is on the paperwork anyway',
    v_columns like '%cert_issuer_name%'
      and v_columns like '%cert_serial_number%'
      and v_columns like '%einvoice_version%');
end $$;

-- =====================================================================
-- A certificate needs credentials first
-- =====================================================================
do $$
declare
  v_me  uuid := pg_temp.test_user();
  v_org uuid;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Tandatangan Sdn Bhd');

  perform pg_temp.check_refused(
    'a certificate with no credentials behind it is refused, and says '
    'what to do first',
    format(
      $q$select public.set_einvoice_signing_certificate(%L, 'sandbox', %L, %L)$q$,
      v_org, pg_temp.a_certificate(), pg_temp.a_key()),
    '%client id and secret%');

  -- With credentials, it goes on.
  perform public.set_einvoice_credentials(
    v_org, 'sandbox', 'client-abc', 'secret-xyz');
  perform public.set_einvoice_signing_certificate(
    v_org, 'sandbox', pg_temp.a_certificate(), pg_temp.a_key(),
    '379834714592', 'CN=Contoh Issuing CA G3,C=MY',
    timestamptz '2030-01-01 00:00:00+08');

  perform pg_temp.check_true(
    'and then it is on file',
    (select cert_pem is not null and cert_private_key_pem is not null
       from public.einvoice_credentials
      where org_id = v_org and environment = 'sandbox'));

  -- Half a certificate is not a certificate.
  perform pg_temp.check_refused(
    'a certificate with no key is refused',
    format(
      $q$select public.set_einvoice_signing_certificate(%L, 'sandbox', %L, '')$q$,
      v_org, pg_temp.a_certificate()),
    '%both the certificate and its private key%');
end $$;

-- =====================================================================
-- Version 1.1 is refused without one, and 1.0 never is
-- =====================================================================
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_org   uuid;
  v_value text;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Belum Bertandatangan Sdn Bhd');

  perform pg_temp.check_refused(
    'switching to 1.1 with no certificate is refused where somebody can '
    'see it, rather than at submission',
    format($q$select public.set_einvoice_version(%L, '1.1')$q$, v_org),
    '%signing certificate first%');

  -- CONTROL. 1.0 needs nothing, and is accepted by the same function
  -- on the same company -- so the refusal above is about the version
  -- and not about the company.
  perform pg_temp.check_eq(
    'and 1.0 is accepted, because a 1.0 document carries no signature',
    public.set_einvoice_version(v_org, '1.0'), '1.0');

  perform pg_temp.check_refused(
    'a version that is not one of the two is refused, naming both',
    format($q$select public.set_einvoice_version(%L, '2.0')$q$, v_org),
    '%1.0 or 1.1%');

  -- With a certificate on the environment this company submits to, 1.1
  -- goes on.
  perform public.set_einvoice_credentials(
    v_org, 'sandbox', 'client-abc', 'secret-xyz');
  perform public.set_einvoice_signing_certificate(
    v_org, 'sandbox', pg_temp.a_certificate(), pg_temp.a_key());
  perform pg_temp.check_eq(
    'with one on file, 1.1 is allowed',
    public.set_einvoice_version(v_org, '1.1'), '1.1');

  select settings ->> 'einvoice_version' into v_value
    from public.organizations where id = v_org;
  perform pg_temp.check_eq(
    'and that is what prepare_einvoice will read', v_value, '1.1');
end $$;

-- =====================================================================
-- A certificate on the WRONG environment does not count
--
-- The one this asserts is the mistake that silently sends a real
-- invoice out unsigned: a test certificate loaded against sandbox while
-- the company is submitting to production.
-- =====================================================================
do $$
declare
  v_me  uuid := pg_temp.test_user();
  v_org uuid;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Pengeluaran Sdn Bhd');
  update public.organizations set einvoice_environment = 'production'
   where id = v_org;

  perform public.set_einvoice_credentials(
    v_org, 'sandbox', 'client-abc', 'secret-xyz');
  perform public.set_einvoice_signing_certificate(
    v_org, 'sandbox', pg_temp.a_certificate(), pg_temp.a_key());

  perform pg_temp.check_refused(
    'a sandbox certificate does not let a production company file at 1.1',
    format($q$select public.set_einvoice_version(%L, '1.1')$q$, v_org),
    '%signing certificate first%');
end $$;

-- =====================================================================
-- Setting the version leaves the rest of `settings` alone
-- =====================================================================
do $$
declare
  v_me    uuid := pg_temp.test_user();
  v_org   uuid;
  v_other text;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Tetapan Sdn Bhd');

  update public.organizations
     set settings = coalesce(settings, '{}'::jsonb)
                    || jsonb_build_object('something_else', 'kept')
   where id = v_org;

  perform public.set_einvoice_version(v_org, '1.0');

  select settings ->> 'something_else' into v_other
    from public.organizations where id = v_org;
  perform pg_temp.check_eq(
    'another setting survives the version being written', v_other, 'kept');
end $$;

-- =====================================================================
-- Taking a certificate off leaves the credentials
--
-- Which is what somebody does when one is about to expire and the new
-- one has not arrived. Losing the client id at the same time would stop
-- them polling the status of what is already filed.
-- =====================================================================
do $$
declare
  v_me  uuid := pg_temp.test_user();
  v_org uuid;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Tamat Tempoh Sdn Bhd');
  perform public.set_einvoice_credentials(
    v_org, 'sandbox', 'client-abc', 'secret-xyz');
  perform public.set_einvoice_signing_certificate(
    v_org, 'sandbox', pg_temp.a_certificate(), pg_temp.a_key());

  perform public.clear_einvoice_signing_certificate(v_org, 'sandbox');

  perform pg_temp.check_true(
    'the certificate is gone',
    (select cert_pem is null and cert_private_key_pem is null
       from public.einvoice_credentials
      where org_id = v_org and environment = 'sandbox'));
  perform pg_temp.check_eq(
    'and the credentials are not',
    (select client_id from public.einvoice_credentials
      where org_id = v_org and environment = 'sandbox'),
    'client-abc');
end $$;

-- =====================================================================
-- And only an administrator does any of it
-- =====================================================================
do $$
declare
  v_me   uuid := pg_temp.test_user();
  v_them uuid := pg_temp.another_user('outsider.cert@example.test');
  v_org  uuid;
begin
  perform pg_temp.sign_in_as(v_me);
  v_org := pg_temp.test_org('Sulit Sdn Bhd');
  perform public.set_einvoice_credentials(
    v_org, 'sandbox', 'client-abc', 'secret-xyz');

  perform pg_temp.sign_in_as(v_them);

  perform pg_temp.check_refused(
    'somebody outside the company cannot load a signing certificate',
    format(
      $q$select public.set_einvoice_signing_certificate(%L, 'sandbox', %L, %L)$q$,
      v_org, pg_temp.a_certificate(), pg_temp.a_key()),
    '%administrator%', '42501');

  perform pg_temp.check_refused(
    'nor take one off',
    format(
      $q$select public.clear_einvoice_signing_certificate(%L, 'sandbox')$q$,
      v_org),
    '%administrator%', '42501');

  perform pg_temp.check_refused(
    'nor change the version',
    format($q$select public.set_einvoice_version(%L, '1.0')$q$, v_org),
    '%administrator%', '42501');

  perform pg_temp.check_refused(
    'nor even see what is configured',
    format($q$select * from public.einvoice_credential_status(%L)$q$, v_org),
    '%administrator%', '42501');
end $$;

rollback;
