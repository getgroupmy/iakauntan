-- ---------------------------------------------------------------------
-- A payment that actually arrives
--
-- 0292 built the gateway settings, 0295 seeded the catalogue, and both
-- said in as many words that a row is a listing and not a connection.
-- This is the connection, for one named provider: Billplz.
--
-- The two edge functions are `billplz-checkout`, which creates a bill
-- and hands back where to send the payer, and `billplz-callback`, which
-- Billplz posts to when they have paid. Everything with money in it
-- lives here rather than there, for the reason the whole project is
-- built on: a rule enforced only in TypeScript is not enforced.
--
-- ## What the callback is allowed to do
--
-- `billplz-callback` is the first function in this project deployed
-- without `verify_jwt`. It has to be — Billplz's servers hold no
-- session with us — and its only credential is an HMAC over the
-- callback's own fields, asserted in
-- `supabase/functions/_shared/billplz_test.ts`.
--
-- That makes the settlement function the second line, and it is written
-- as though the first had failed:
--
--   * it settles nothing unless the amount handed over covers the
--     invoice. A confirmation for one sen against a five hundred
--     ringgit invoice is recorded and refused, not rounded up into a
--     paid invoice.
--   * it moves an invoice from `issued` and from nowhere else. A void
--     invoice does not come back to life because a stale callback
--     arrived, and a paid one is not paid twice.
--   * it is idempotent by the provider's own reference. Billplz retries;
--     a retry has to be a no-op, not a second payment.
--   * it never trusts the payment's own `org_id` — there is none. The
--     organization is read from the invoice, which is the only place
--     it can come from without letting the caller name it.
--
-- ## Why these are in `public` and not in `app`
--
-- Everything else with a guard this tight lives in `app`, and these two
-- would belong there but for one thing: PostgREST exposes `public` and
-- `graphql_public` and nothing else, so an `app.` function cannot be
-- reached by an edge function's `.rpc()` at all. `public` with execute
-- revoked from `anon` and `authenticated` and granted only to
-- `service_role` is the same wall in the place the caller can reach —
-- the shape `public.ingest_exchange_rates` has used since 0104.
--
-- ## The signature is not kept with the thing it signs
--
-- The callback body is stored for the audit trail, less `x_signature`.
-- A MAC filed next to the message it authenticates is worth nothing and
-- costs something: it is a working credential for that exact payload,
-- sitting in a table.
-- ---------------------------------------------------------------------

create table if not exists public.platform_payments (
  id            uuid primary key default gen_random_uuid(),
  invoice_id    uuid not null references public.platform_invoices (id)
                  on delete restrict,
  org_id        uuid not null references public.organizations (id)
                  on delete restrict,
  gateway_code  text not null references public.payment_gateways (code),
  -- The provider's own identifier for the bill. Unique per gateway, so
  -- a retried callback finds the payment it already recorded.
  provider_ref  text not null,
  amount        numeric(18, 2) not null check (amount > 0),
  currency      character(3) not null default 'MYR',
  state         text not null default 'pending'
                  check (state in ('pending', 'paid', 'underpaid', 'failed')),
  checkout_url  text,
  paid_amount   numeric(18, 2) check (paid_amount >= 0),
  paid_at       timestamptz,
  -- What the provider sent, less its signature. See the header.
  provider_payload jsonb,
  created_by    uuid references auth.users (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint platform_payments_one_per_provider_ref
    unique (gateway_code, provider_ref),
  constraint platform_payments_checkout_absolute
    check (checkout_url is null or checkout_url ~* '^https://')
);

create index if not exists platform_payments_invoice_idx
  on public.platform_payments (invoice_id);
create index if not exists platform_payments_org_idx
  on public.platform_payments (org_id, created_at desc);

alter table public.platform_payments enable row level security;

-- A company sees its own attempts, so the app can say "we sent you to
-- Billplz and have not heard back yet" instead of nothing. Nobody
-- writes from a client: both writers below are service-role only,
-- because the only honest writer is the provider's own callback.
drop policy if exists platform_payments_read on public.platform_payments;
create policy platform_payments_read on public.platform_payments
  for select to authenticated
  using (app.is_org_member(org_id) or app.is_platform_admin());

-- The privilege the policy above needs to mean anything. A policy
-- without the grant behind it admits nobody, which `table_grants.sql`
-- exists to catch and did — this table shipped its first draft with the
-- policy and no grant, and a company would have seen an empty list of
-- its own payments with nothing to say why.
grant select on public.platform_payments to authenticated;

drop trigger if exists set_updated_at on public.platform_payments;
create trigger set_updated_at before update on public.platform_payments
  for each row execute function app.set_updated_at();

comment on table public.platform_payments is
  'One attempt to settle a platform invoice through a gateway. Written only by the edge functions under the service role; a company may read its own.';
comment on column public.platform_payments.provider_payload is
  'What the provider sent, less its signature. A MAC stored beside the message it authenticates is a working credential for that payload sitting in a table.';

-- ---------------------------------------------------------------------
-- Starting one
--
-- Called by `billplz-checkout` after the provider has issued a bill, so
-- there is a reference to record. It refuses an invoice that is not
-- outstanding rather than creating a way to pay something that has been
-- paid or voided.
-- ---------------------------------------------------------------------
create or replace function public.begin_gateway_payment(
  p_invoice      uuid,
  p_gateway      text,
  p_provider_ref text,
  p_checkout_url text,
  p_created_by   uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare v_inv public.platform_invoices; v_id uuid;
begin
  select * into v_inv from public.platform_invoices where id = p_invoice;
  if v_inv.id is null then
    raise exception 'No such invoice' using errcode = 'P0002';
  end if;
  if v_inv.status <> 'issued' then
    raise exception 'Invoice % is %, so there is nothing to pay',
      v_inv.invoice_no, v_inv.status using errcode = '55006';
  end if;
  if coalesce(btrim(p_provider_ref), '') = '' then
    raise exception 'A payment needs the provider''s own reference'
      using errcode = '23514';
  end if;

  insert into public.platform_payments
    (invoice_id, org_id, gateway_code, provider_ref, amount, currency,
     checkout_url, created_by)
  values (v_inv.id, v_inv.org_id, lower(btrim(p_gateway)),
          btrim(p_provider_ref), v_inv.total_amount, v_inv.currency,
          p_checkout_url, p_created_by)
  on conflict (gateway_code, provider_ref) do update
    set checkout_url = excluded.checkout_url
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.begin_gateway_payment(uuid, text, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.begin_gateway_payment(uuid, text, text, text, uuid)
  to service_role;

-- ---------------------------------------------------------------------
-- Finishing one
--
-- The whole of the money rule, in one place, called by the callback
-- once it has checked the signature. Returns what it decided so the
-- function can log it; raises nothing, because a callback that gets a
-- 500 is a callback the provider will send again for ever.
-- ---------------------------------------------------------------------
create or replace function public.settle_gateway_payment(
  p_gateway        text,
  p_provider_ref   text,
  p_paid           boolean,
  p_paid_amount    numeric,
  p_payload        jsonb default null)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_pay public.platform_payments;
  v_inv public.platform_invoices;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb) - 'x_signature';
begin
  select * into v_pay from public.platform_payments
   where gateway_code = lower(btrim(coalesce(p_gateway, '')))
     and provider_ref = btrim(coalesce(p_provider_ref, ''));

  -- A confirmation for a bill this platform never created. Nothing to
  -- do, and nothing to raise about: saying "unknown" out loud to a
  -- caller who guessed a reference tells them whether their guess was
  -- right.
  if v_pay.id is null then
    return 'unknown';
  end if;

  -- Already settled. Billplz retries, and a retry is not a payment.
  if v_pay.state = 'paid' then
    return 'already_paid';
  end if;

  if not coalesce(p_paid, false) then
    update public.platform_payments
       set state = 'failed', provider_payload = v_payload
     where id = v_pay.id;
    return 'not_paid';
  end if;

  -- The assertion this function exists for. What was handed over has to
  -- cover what was owed; a confirmation for less is recorded and
  -- refused rather than rounded up into a paid invoice.
  if coalesce(p_paid_amount, 0) < v_pay.amount then
    update public.platform_payments
       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),
           provider_payload = v_payload
     where id = v_pay.id;
    return 'underpaid';
  end if;

  update public.platform_payments
     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),
         provider_payload = v_payload
   where id = v_pay.id;

  -- From `issued` and from nowhere else: a void invoice does not come
  -- back to life because a stale callback arrived.
  update public.platform_invoices i
     set status = 'paid', paid_at = now(),
         paid_note = 'Paid through ' || v_pay.gateway_code
                     || ' (' || v_pay.provider_ref || ')'
   where i.id = v_pay.invoice_id and i.status = 'issued'
  returning * into v_inv;

  if v_inv.id is null then
    -- The money arrived against an invoice that is no longer
    -- outstanding. The payment is real and is recorded as such; the
    -- invoice is somebody's problem to refund, and saying so here is
    -- how they find out.
    return 'paid_but_invoice_not_issued';
  end if;

  return 'paid';
end;
$$;

revoke all on function
  public.settle_gateway_payment(text, text, boolean, numeric, jsonb)
  from public, anon, authenticated;
grant execute on function
  public.settle_gateway_payment(text, text, boolean, numeric, jsonb)
  to service_role;
