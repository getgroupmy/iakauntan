-- =====================================================================
-- iAkauntan :: 0779 the keys a waiting payment needs stay
--
-- A customer paying a shared invoice is sent to the company's own
-- acquirer, and the acquirer's callback is checked against the
-- signature key of the mode the payment was RECORDED in
-- (`app.shared_payment_signature_key`, `0414`). `clear_org_payment_
-- gateway` deleted that mode's keys without asking whether a payment
-- in it was still on its way back. A payment in flight then came home
-- to no key: its callback failed the signature check, the customer's
-- money arrived at the acquirer, and the invoice never settled.
-- Measured on 9 October 2026, locally: with a payment pending, the key
-- its callback would be checked against read 'xsig_live'; the keys
-- were removed without a word, and it read null.
--
-- First answered "refuse with payments pending". That was asked
-- without two facts, and asked again with them: nothing lets anybody
-- mark a pending payment failed -- only the acquirer's own callback
-- moves it -- and every customer who opens the pay link and backs out
-- leaves a pending row that never resolves. Refusing on ANY pending
-- payment would lock a company's keys in for good after one abandoned
-- checkout.
--
-- Answered the second time "refuse only recent ones". Removing a
-- mode's keys is refused while a payment through that acquirer, in
-- that mode, for this company, was started in the last day and is
-- still pending; an older pending row counts as abandoned. Switching
-- the acquirer off (`set_org_payment_gateway`, `is_active` false)
-- stays allowed, and is what the refusal suggests: it stops new
-- payments at once, and the keys can go a day later.
--
-- What this does not close, said so nobody assumes it does: a customer
-- who comes back to a bill older than a day and pays it after the keys
-- are gone still meets the failure above.
--
-- Restated from `0412`, whose text production runs exactly (identical
-- source hash on 9 October). No company in production had a gateway
-- configured or a gateway payment recorded, so nothing is refused.
-- =====================================================================

create or replace function public.clear_org_payment_gateway(
  p_org_id  uuid,
  p_gateway text,
  p_mode    text default 'sandbox')
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_waiting integer;
  v_name    text;
begin
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an administrator can remove this company''s payment credentials'
      using errcode = '42501';
  end if;

  -- `0779`. A payment started in the last day and not yet confirmed
  -- will be confirmed against these keys; take them away and its
  -- callback fails while the money still arrives. Older than a day,
  -- a pending payment is a checkout somebody abandoned.
  select count(*) into v_waiting
    from public.sales_gateway_payments p
   where p.org_id = p_org_id
     and p.gateway_code = p_gateway
     and p.mode = p_mode
     and p.state = 'pending'
     and p.created_at > now() - interval '24 hours';

  if v_waiting > 0 then
    select g.name into v_name
      from public.payment_gateways g where g.code = p_gateway;
    raise exception
      '% % started through % in the last day % still waiting to be '
      'confirmed. Wait a day, or switch the acquirer off now, which '
      'stops new ones.',
      v_waiting,
      case when v_waiting = 1 then 'payment' else 'payments' end,
      coalesce(v_name, p_gateway),
      case when v_waiting = 1 then 'is' else 'are' end
      using errcode = '23514';
  end if;

  delete from public.org_payment_gateways c
   where c.org_id = p_org_id and c.gateway_code = p_gateway
     and c.mode = p_mode;
end
$fn$;

comment on function public.clear_org_payment_gateway(uuid, text, text) is
  'Removes a company''s own acquirer credentials for one gateway in one '
  'mode, live or test. Customers stop being offered that gateway on a '
  'shared invoice -- `shared_payment_options` returns only gateways '
  'that are configured and active with a settlement account. Payments '
  'already taken are unaffected; what ends is the ability to take more. '
  'Refused while a payment through that acquirer in that mode was '
  'started in the last day and is still pending, because its callback '
  'is checked against these keys (`0779`); switching the acquirer off '
  'is not refused. Needs `can_admin`.';
