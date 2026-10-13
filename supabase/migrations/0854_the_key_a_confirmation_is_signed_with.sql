-- =====================================================================
-- iAkauntan :: 0854 the key a confirmation is signed with
--
-- A company's own payment gateway keys live in `org_payment_gateways`
-- (`0412`): the Billplz API key, and the X-Signature key that
-- `pay-invoice-callback` verifies every payment confirmation against
-- (`0414`). They are write-only by design -- no client role, the owner
-- included, may read the table, and `0414` says a function that hands
-- such a key to a client is the same exposure as a policy that does.
--
-- The company export (`company_export_page`, administrators only)
-- carries that table, and masks what it writes out by column name
-- through `app.audit_redact` (`0236`, `0289`): whole words within a
-- snake_case name, `api_key` among them. `signature_key` is not.
--
-- Measured on 13 October 2026, locally, as the owner with the role
-- `authenticated`: reading `org_payment_gateways` was refused, and the
-- export returned `"signature_key": "XSIG-SECRET-9876"` in clear beside
-- `"api_key": "***"`. Whoever holds that key can sign a confirmation
-- the callback will believe. Every exported column was checked: this is
-- the one real secret the pattern let through.
--
-- Answered "redact signature and signing keys": `app.audit_redact` is
-- restated from `0289`, its text unchanged but for one line naming
-- `signature_key`, `signing_key`, `hmac` and `webhook_key` (and their
-- plurals). Only `org_payment_gateways.signature_key` is named any of
-- them today. A bare `signature` is NOT among them: on
-- `einvoice_documents` it is the document's own signature value, part
-- of what was filed, and nobody's credential.
--
-- Production held no payment gateway on 13 October.
-- =====================================================================

create or replace function app.audit_redact(p_row jsonb)
returns jsonb
language sql
immutable
set search_path = pg_catalog, pg_temp as $$
  select case
           when p_row is null then null
           else coalesce(
             (select jsonb_object_agg(
                       key,
                       case when key ~* ('(^|_)('
                              || 'secret|secrets|password|passwords|passwd|pwd'
                              || '|private_key|private_keys|passphrase'
                              || '|api_key|api_keys|apikey'
                              || '|token|tokens|credential|credentials'
                              || '|signature_key|signature_keys|signing_key|signing_keys|hmac|webhook_key|webhook_keys'
                              || ')(_|$)')
                            then to_jsonb('***'::text)
                            else value
                       end)
                from jsonb_each(p_row)),
             '{}'::jsonb)
         end;
$$;
