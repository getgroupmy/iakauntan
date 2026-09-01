-- ---------------------------------------------------------------------
-- 0414  The key a callback is verified against is the shop's
-- ---------------------------------------------------------------------
--
-- `billplz-callback` verifies an inbound confirmation against
-- `BILLPLZ_XSIGNATURE_KEY`, an Edge Function secret. That is right for
-- the platform's own bills: there is one Billplz account behind
-- `platform_invoices` and one key.
--
-- A tenant's bills are not that. Every organization has its own Billplz
-- account, its own collection and its own X Signature key, so the key a
-- confirmation is verified against depends on **which** confirmation it
-- is — and the only thing identifying that before verification is the
-- provider reference in an unverified body.
--
-- ## Looking a key up by an unverified reference is not a decision
--
-- The reference is used to *find* a row, and finding a row decides
-- nothing. If one is found, its organization's key verifies the body;
-- if the body does not verify, nothing happens. A caller who guesses a
-- reference gets exactly as far as a caller who does not: the
-- signature is still the credential, and it is still checked before a
-- single field is believed.
--
-- What the caller must not learn is which of the two happened. A
-- reference nobody has heard of and a signature that did not verify are
-- answered identically by `pay-invoice-callback`, because answering
-- them differently turns the endpoint into an oracle for guessing
-- references — the same reason `settle_shared_payment` returns
-- `unknown` quietly rather than raising.
--
-- ## Where it lives
--
-- `app`, and revoked from every client role. It returns a secret, and
-- `0412` and `0413` both say what that means: a function that hands a
-- key to a client role is the same exposure as a policy that does.
-- Only the service role reaches it, which is to say the callback.
-- ---------------------------------------------------------------------

create or replace function app.shared_payment_signature_key(
  p_gateway text, p_provider_ref text)
returns text
language sql
stable
security definer
set search_path = public, app, pg_temp
as $fn$
  select c.signature_key
    from public.sales_gateway_payments p
    join public.org_payment_gateways c
      on c.org_id = p.org_id
     and c.gateway_code = p.gateway_code
     and c.mode = p.mode
   where p.gateway_code = lower(btrim(coalesce(p_gateway, '')))
     and p.provider_ref = btrim(coalesce(p_provider_ref, ''));
$fn$;

revoke all on function app.shared_payment_signature_key(text, text)
  from public, anon, authenticated;

comment on function app.shared_payment_signature_key(text, text) is
  'The X Signature key a tenant''s payment callback is verified '
  'against, found from the provider reference in the unverified body. '
  'Finding a row decides nothing; the signature is still the '
  'credential. Service role only.';

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
begin
  if has_function_privilege('authenticated',
       'app.shared_payment_signature_key(text,text)', 'EXECUTE')
     or has_function_privilege('anon',
       'app.shared_payment_signature_key(text,text)', 'EXECUTE') then
    raise exception
      'FAIL 0414: a client role can read the key that verifies a '
      'payment callback. With it, a forged callback marks an invoice '
      'paid.';
  end if;

  -- It answers null rather than raising for a reference nobody has
  -- heard of. A function that raises here would tell the callback --
  -- and through it whoever called the callback -- that the reference
  -- was wrong.
  if app.shared_payment_signature_key('billplz', 'no-such-reference')
     is not null then
    raise exception
      'FAIL 0414: an unknown reference produced a key';
  end if;

  raise notice
    '0414: a tenant''s callback is verified against that tenant''s key';
end
$do$;
