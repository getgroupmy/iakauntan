-- =====================================================================
-- iAkauntan :: 0777 the certificate a signed e-Invoice needs stays
--
-- `0615` made version 1.1 e-Invoices signed, and `set_einvoice_version`
-- refuses to switch a company to 1.1 without a certificate AND its key
-- on file for the environment the company submits to -- named on the
-- settings screen rather than failed at LHDN by way of an edge function.
--
-- `clear_einvoice_signing_certificate` was the other road into the
-- state that refusal exists to prevent. It took the certificate off a
-- company already filing at 1.1, without asking, and every e-Invoice
-- after it was refused by LHDN instead. Found sweeping the three
-- signing functions, 9 October 2026.
--
-- Answered "refuse while on 1.1". Clearing the certificate of the
-- environment a 1.1 company submits to is refused, saying what to do
-- instead; the other environment's certificate, and any certificate of
-- a company on 1.0, may still be cleared.
--
-- Restated from `0615`, whose text production runs exactly (identical
-- source hash on 9 October). No company in production was on 1.1 and
-- none held a certificate, so nothing that exists is refused.
-- =====================================================================

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

  -- `0777`. The certificate a version 1.1 company signs with, for the
  -- environment it submits to, is not taken away from under it:
  -- `set_einvoice_version` refuses to reach that state, and this was
  -- the other road into it. Every e-Invoice after would be refused by
  -- LHDN rather than here, where somebody can do something about it.
  -- The other environment's certificate, and any certificate of a 1.0
  -- company, may still go.
  if exists (
       select 1 from public.organizations o
        where o.id = p_org_id
          and coalesce(o.settings ->> 'einvoice_version', '1.0') = '1.1'
          and o.einvoice_environment = p_environment) then
    raise exception 'This company files version 1.1 e-Invoices in %, and '
                    'those have to be signed. Switch back to version 1.0 '
                    'first, or load a new certificate in its place.',
      p_environment using errcode = '23514';
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
  'Removes a company''s e-Invoice signing certificate for one '
  'environment. Administrators only. Refuses the certificate a version '
  '1.1 company signs with in the environment it submits to (0777): '
  'switch back to 1.0, or load a new certificate, first.';
