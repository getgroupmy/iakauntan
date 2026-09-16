-- =====================================================================
-- iAkauntan :: the signature on a tax document
--
-- README: "XAdES digital signature for e-Invoice version 1.1."
--
-- A version 1.0 e-Invoice is submitted as it stands. A version 1.1 one
-- must be SIGNED by the taxpayer, with a certificate from a Malaysian
-- certification authority, and LHDN recomputes the digests and the
-- signature before it will validate the document.
--
-- ---------------------------------------------------------------------
-- Almost none of this is new storage, and that is the point
--
-- `0107` built `einvoice_credentials` with `cert_pem`,
-- `cert_private_key_pem`, `cert_serial_number`, `cert_issuer_name` and
-- `cert_expires_at` already on it -- a table with RLS, no policies and
-- no grants at all, whose only reader is the edge function through the
-- service role. That is exactly where a signing key belongs and it has
-- been sitting empty since.
--
-- What was missing is three things:
--
--   * a way to PUT a certificate there without also restating the
--     client id and secret, which `set_einvoice_credentials` requires;
--   * a way to take one back off;
--   * a way to say which VERSION this company files at, which has lived
--     in `organizations.settings ->> 'einvoice_version'` since `0015`
--     and has never had a screen.
--
-- ---------------------------------------------------------------------
-- Who parses the certificate
--
-- Not this. The serial number, the issuer's distinguished name and the
-- expiry are read off the DER by `supabase/functions/_shared/der.ts`
-- and passed in, because that is the one place in this product that
-- reads a certificate and having a second one in PL/pgSQL would mean
-- two answers to "what is this certificate's issuer" that can disagree.
--
-- So these are write-through: the edge function has already refused a
-- key that does not match its certificate, and an expired one, by the
-- time anything gets here.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Putting a certificate on file
--
-- Refuses where there are no credentials yet rather than creating a
-- half row: `client_secret` is NOT NULL and a company that cannot log
-- in to MyInvois has nothing to sign FOR. The message says which order
-- to do it in, which is the whole reason to refuse rather than to
-- insert something.
-- ---------------------------------------------------------------------
create or replace function public.set_einvoice_signing_certificate(
  p_org_id uuid,
  p_environment text,
  p_cert_pem text,
  p_cert_private_key_pem text,
  p_cert_serial_number text default null,
  p_cert_issuer_name text default null,
  p_cert_expires_at timestamptz default null)
returns void
language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can set the e-Invoice signing '
                    'certificate'
      using errcode = '42501';
  end if;

  if p_environment not in ('sandbox', 'production') then
    raise exception 'Environment must be sandbox or production, not %',
      p_environment using errcode = '23514';
  end if;

  if coalesce(btrim(p_cert_pem), '') = ''
     or coalesce(btrim(p_cert_private_key_pem), '') = '' then
    raise exception 'A signing certificate needs both the certificate and '
                    'its private key'
      using errcode = '23514';
  end if;

  update public.einvoice_credentials set
    cert_pem             = btrim(p_cert_pem),
    cert_private_key_pem = btrim(p_cert_private_key_pem),
    cert_serial_number   = nullif(btrim(coalesce(p_cert_serial_number, '')), ''),
    cert_issuer_name     = nullif(btrim(coalesce(p_cert_issuer_name, '')), ''),
    cert_expires_at      = p_cert_expires_at,
    updated_by           = auth.uid(),
    updated_at           = now()
   where org_id = p_org_id and environment = p_environment;

  if not found then
    raise exception 'Add the MyInvois client id and secret for % first — a '
                    'certificate signs documents for a submitter that can '
                    'log in', p_environment
      using errcode = 'P0002';
  end if;
end;
$function$;

comment on function public.set_einvoice_signing_certificate(
  uuid, text, text, text, text, text, timestamptz) is
  'Puts a XAdES signing certificate and its key on file for one '
  'environment. The fields describing the certificate are read off the '
  'DER by the edge function, which is the only thing here that parses '
  'one. 0615.';

revoke all on function public.set_einvoice_signing_certificate(
  uuid, text, text, text, text, text, timestamptz) from public, anon;
grant execute on function public.set_einvoice_signing_certificate(
  uuid, text, text, text, text, text, timestamptz) to authenticated;

-- ---------------------------------------------------------------------
-- Taking it back off
--
-- Separate from writing, the same way `clear_einvoice_credentials` is
-- and for the same reason: removing the thing that signs tax documents
-- should not be reachable by saving an empty form.
--
-- The client id and secret stay. Removing a certificate is what you do
-- when it is about to expire and the new one has not arrived; it is not
-- a reason to stop being able to poll the status of what was already
-- filed.
-- ---------------------------------------------------------------------
create or replace function public.clear_einvoice_signing_certificate(
  p_org_id uuid, p_environment text)
returns void
language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can remove the e-Invoice signing '
                    'certificate'
      using errcode = '42501';
  end if;

  update public.einvoice_credentials set
    cert_pem             = null,
    cert_private_key_pem = null,
    cert_serial_number   = null,
    cert_issuer_name     = null,
    cert_expires_at      = null,
    updated_by           = auth.uid(),
    updated_at           = now()
   where org_id = p_org_id and environment = p_environment;
end;
$function$;

comment on function public.clear_einvoice_signing_certificate(uuid, text) is
  'Takes the signing certificate off one environment, leaving the '
  'client id and secret. 0615.';

revoke all on function public.clear_einvoice_signing_certificate(uuid, text)
  from public, anon;
grant execute on function public.clear_einvoice_signing_certificate(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Which version this company files at
--
-- On `organizations.settings` since `0015`, read by `prepare_einvoice`
-- and stamped onto each document as it is prepared -- so switching to
-- 1.1 does not retroactively invalidate what is already queued, and a
-- document carries the rule it was made under.
--
-- `jsonb_set` rather than an update of the whole object: `settings`
-- holds other things, and a screen that writes the key it knows about
-- and drops the rest is how a setting disappears without anybody
-- touching it.
-- ---------------------------------------------------------------------
create or replace function public.set_einvoice_version(
  p_org_id uuid, p_version text)
returns text
language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_version text := btrim(coalesce(p_version, ''));
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can change the e-Invoice version'
      using errcode = '42501';
  end if;

  if v_version not in ('1.0', '1.1') then
    raise exception 'The e-Invoice version is 1.0 or 1.1, not %', p_version
      using errcode = '23514';
  end if;

  -- Named rather than allowed and then failed at submission. A company
  -- switched to 1.1 with nothing to sign with has an e-Invoice button
  -- that stops working, and the refusal it gets then comes from LHDN
  -- by way of an edge function rather than from the screen that did it.
  if v_version = '1.1' and not exists (
       select 1 from public.einvoice_credentials c
        join public.organizations o on o.id = c.org_id
       where c.org_id = p_org_id
         and c.environment = coalesce(o.einvoice_environment, 'sandbox')
         and c.cert_pem is not null
         and c.cert_private_key_pem is not null) then
    raise exception 'Load a signing certificate first: a version 1.1 '
                    'e-Invoice has to be signed, and there is none on file '
                    'for the environment this company submits to'
      using errcode = '23514';
  end if;

  update public.organizations
     set settings = jsonb_set(
           coalesce(settings, '{}'::jsonb),
           '{einvoice_version}',
           to_jsonb(v_version),
           true)
   where id = p_org_id;

  return v_version;
end;
$function$;

comment on function public.set_einvoice_version(uuid, text) is
  'Sets the e-Invoice version a company files at. Refuses 1.1 without a '
  'signing certificate, because a 1.1 document that cannot be signed is '
  'a submit button that stops working. 0615.';

revoke all on function public.set_einvoice_version(uuid, text)
  from public, anon;
grant execute on function public.set_einvoice_version(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What the screen is allowed to know
--
-- `0107`'s status function already said whether a certificate is on
-- file and when it expires, without returning either half of it. This
-- adds which certificate -- the issuer and the serial, both of which
-- are printed on the paperwork a certification authority sends -- and
-- the version, so the card is one call rather than three.
--
-- Still nothing that is a secret. The certificate itself is public by
-- definition and is not returned anyway; the private key has no reader
-- outside the edge function and does not appear here.
-- ---------------------------------------------------------------------
drop function if exists public.einvoice_credential_status(uuid);

create function public.einvoice_credential_status(p_org_id uuid)
returns table (
  environment        text,
  is_current         boolean,
  client_id          text,
  has_secret         boolean,
  has_certificate    boolean,
  cert_expires_at    timestamptz,
  cert_issuer_name   text,
  cert_serial_number text,
  einvoice_version   text,
  updated_at         timestamptz)
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if not app.can_admin(p_org_id) then
    raise exception 'Only an administrator can see the e-Invoice setup'
      using errcode = '42501';
  end if;

  return query
  select e.env,
         e.env = coalesce(o.einvoice_environment, 'sandbox'),
         c.client_id,
         c.client_secret is not null,
         c.cert_pem is not null and c.cert_private_key_pem is not null,
         c.cert_expires_at,
         c.cert_issuer_name,
         c.cert_serial_number,
         coalesce(o.settings ->> 'einvoice_version', '1.0'),
         c.updated_at
    from (values ('sandbox'), ('production')) as e(env)
    cross join public.organizations o
    left join public.einvoice_credentials c
      on c.org_id = p_org_id and c.environment = e.env
   where o.id = p_org_id
   order by e.env desc;   -- sandbox first, which is where to start
end;
$function$;

comment on function public.einvoice_credential_status(uuid) is
  'What is configured per environment, and never what it is. 0107, '
  'extended by 0615 with which certificate and which version.';

revoke all on function public.einvoice_credential_status(uuid)
  from public, anon;
grant execute on function public.einvoice_credential_status(uuid)
  to authenticated;
