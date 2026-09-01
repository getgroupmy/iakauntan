-- ---------------------------------------------------------------------
-- 0413  The customer can pay the invoice they were sent
-- ---------------------------------------------------------------------
--
-- `open_shared_document` gives a customer a document to read and no way
-- to pay it. `0412` gave the organization somewhere to keep its own
-- acquirer credentials and said in its own header that nothing charged
-- anybody yet. This is the rest of it, in the database: the pending
-- payment, the settlement, and the receipt that lands in the tenant's
-- own ledger when the acquirer confirms.
--
-- ## Modelled on the platform's, because the platform's is right
--
-- `platform_payments` and `settle_gateway_payment` have been taking
-- money for iAkauntan's own subscription invoices, and the shape they
-- settled on is the shape a tenant needs:
--
--   * one row per acquirer reference, unique on
--     `(gateway_code, provider_ref)`, so a retried callback finds the
--     payment it already settled instead of making a second one;
--   * five outcomes, named — `unknown`, `already_paid`, `not_paid`,
--     `underpaid`, `paid` — rather than a boolean that cannot tell a
--     forged reference from a short payment;
--   * `unknown` returns quietly. Saying "no such reference" out loud to
--     a caller who guessed one tells them whether the guess was right;
--   * a payment for less than was owed is **recorded and refused**,
--     never rounded up into a settled invoice.
--
-- What a tenant's payment has that the platform's does not is a ledger
-- behind it. A confirmed payment posts a receipt through
-- `app.post_receipt_internal`, allocated against the invoice, so the
-- money appears in the bank account and comes off the receivable the
-- same way a receipt keyed in by hand does. There is no second path
-- into the ledger and this migration does not add one.
--
-- ## Where the money lands, and what to call it
--
-- Two columns on `0412`'s table, because both are the shop's answer and
-- not ours:
--
--   * `settlement_bank_account_id` — the account the acquirer pays out
--     to. Required before a gateway may be offered: a receipt with
--     nowhere to bank is a receipt that cannot post, and finding that
--     out at the moment a customer has already paid is the wrong time.
--   * `payment_mode_code` — what the receipt calls it, defaulting to
--     `03 Bank Transfer` because FPX is what most Malaysian gateway
--     traffic is. An acquirer that took a card does not reliably say
--     so, and inventing the answer would put a fact in the ledger that
--     nobody established.
--
-- They are set by their own function rather than by widening
-- `0412`'s. `0307` is the reason: an overload whose extra parameters
-- have defaults means a call that omits one silently resolves to the
-- other function, and `check_idempotent_calls.py` exists because that
-- shipped once already.
--
-- ## What still is not here
--
-- The acquirer call itself. `begin_shared_payment` and
-- `settle_shared_payment` are the two ends the edge function holds on
-- to; the HTTP between them is `billplz-checkout`'s job and cannot be
-- exercised from a test suite with no acquirer to talk to. Said plainly
-- so that "payments work" is not read into a migration that has never
-- seen a ringgit.
-- ---------------------------------------------------------------------

alter table public.org_payment_gateways
  add column if not exists settlement_bank_account_id uuid
    references public.bank_accounts(id),
  add column if not exists payment_mode_code text
    references public.ref_payment_modes(code) default '03';

comment on column public.org_payment_gateways.settlement_bank_account_id is
  'The account the acquirer pays out to. Required before the gateway '
  'may be offered to a customer: a receipt with nowhere to bank cannot '
  'post, and a customer who has already paid is the wrong moment to '
  'discover it.';

-- ---------------------------------------------------------------------
-- One row per acquirer reference
-- ---------------------------------------------------------------------
create table if not exists public.sales_gateway_payments (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations(id) on delete cascade,
  document_id      uuid not null references public.sales_documents(id) on delete cascade,
  gateway_code     text not null references public.payment_gateways(code),
  mode             text not null default 'sandbox'
                     check (mode in ('sandbox', 'production')),
  provider_ref     text not null,
  amount           numeric(18, 2) not null check (amount > 0),
  currency         char(3) not null default 'MYR',
  state            text not null default 'pending'
                     check (state in ('pending', 'paid', 'failed',
                                      'underpaid', 'cancelled')),
  checkout_url     text check (checkout_url is null or checkout_url ~* '^https://'),
  paid_amount      numeric(18, 2),
  paid_at          timestamptz,
  receipt_id       uuid references public.receipts(id),
  provider_payload jsonb,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint sales_gateway_payments_one_per_provider_ref
    unique (gateway_code, provider_ref)
);

create index if not exists sales_gateway_payments_document_idx
  on public.sales_gateway_payments (document_id);
create index if not exists sales_gateway_payments_org_idx
  on public.sales_gateway_payments (org_id, created_at desc);

comment on table public.sales_gateway_payments is
  'A customer''s attempt to pay a tenant''s invoice through the '
  'tenant''s own acquirer. Written only by SECURITY DEFINER functions: '
  'the row is what a callback is matched against, so a client that '
  'could write one could mark an invoice paid.';

alter table public.sales_gateway_payments enable row level security;

-- Readable by the people who read the invoice it belongs to, and
-- written by nobody: a client that could insert a row here could invent
-- the provider reference a forged callback would then settle.
drop policy if exists sales_gateway_payments_read on public.sales_gateway_payments;
create policy sales_gateway_payments_read on public.sales_gateway_payments
  for select to authenticated
  using (app.can_read_module(org_id, 'sales'));

revoke all on public.sales_gateway_payments from anon, authenticated;
-- Granted explicitly rather than left to Supabase's default ACL, which
-- `0399` measured differing between a fresh local stack and the hosted
-- project. A table whose grants depend on which stack created it is a
-- table nobody can reason about.
grant select on public.sales_gateway_payments to authenticated;

do $do$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.sales_gateway_payments'::regclass
                    and tgname = 'set_updated_at') then
    create trigger set_updated_at before update on public.sales_gateway_payments
      for each row execute function app.set_updated_at();
  end if;
end
$do$;

-- ---------------------------------------------------------------------
-- Where the money lands
-- ---------------------------------------------------------------------
create or replace function public.set_org_payment_settlement(
  p_org_id       uuid,
  p_gateway      text,
  p_mode         text default 'sandbox',
  p_bank_account uuid default null,
  p_payment_mode text default null)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
begin
  if not app.can_admin(p_org_id) then
    raise exception
      'Only an administrator can say where this company''s takings land'
      using errcode = '42501';
  end if;

  -- The reach a parameter has that a policy cannot see: a bank account
  -- id from another company would otherwise be accepted here, and every
  -- receipt from then on would bank somebody else's money.
  if p_bank_account is not null
     and not exists (select 1 from public.bank_accounts b
                      where b.id = p_bank_account and b.org_id = p_org_id) then
    raise exception 'That bank account does not belong to this company.'
      using errcode = '23503';
  end if;

  update public.org_payment_gateways c
     set settlement_bank_account_id =
           coalesce(p_bank_account, c.settlement_bank_account_id),
         payment_mode_code =
           coalesce(nullif(btrim(coalesce(p_payment_mode, '')), ''),
                    c.payment_mode_code),
         updated_at = now()
   where c.org_id = p_org_id and c.gateway_code = p_gateway
     and c.mode = p_mode;

  if not found then
    raise exception
      'Set the % credentials up before saying where its takings land.',
      p_gateway using errcode = 'P0002';
  end if;
end
$fn$;

-- ---------------------------------------------------------------------
-- What a customer may be offered
-- ---------------------------------------------------------------------
--
-- Reachable by `anon`, because the person holding the link is not
-- signed in. It answers with acquirer codes and names, and it is the
-- only thing about a gateway that ever crosses to an unauthenticated
-- caller.
--
-- "Fully configured" is checked here rather than at the moment of
-- payment: a button that leads to a failure is worse than a button that
-- is not there.
create or replace function public.shared_payment_options(p_token text)
returns table (code text, name text)
language plpgsql
security definer
stable
set search_path = public, app, pg_temp
as $fn$
declare
  l public.document_share_links;
  d public.sales_documents;
begin
  select * into l from public.document_share_links
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null or l.revoked_at is not null or l.expires_at < now() then
    return;
  end if;

  select * into d from public.sales_documents where id = l.document_id;
  if d.id is null or d.deleted_at is not null
     or d.status in ('void', 'rejected')
     or coalesce(d.balance_amount, 0) <= 0 then
    return;
  end if;

  return query
    select c.gateway_code, g.name
      from public.org_payment_gateways c
      join public.payment_gateways g on g.code = c.gateway_code
     where c.org_id = l.org_id
       and c.is_active
       and c.settlement_bank_account_id is not null
     order by c.gateway_code;
end
$fn$;

-- ---------------------------------------------------------------------
-- What the edge function needs to call the acquirer
-- ---------------------------------------------------------------------
--
-- In `app`, not `public`, and revoked from every client role. It hands
-- back an API key: a function that returns a secret is the same
-- exposure as a policy that does, arriving through a different door,
-- and `0407` is the migration that went looking for exactly this shape.
-- Only the service role — which is to say `billplz-checkout` — reaches
-- it.
create or replace function app.shared_payment_intent(
  p_token text, p_gateway text)
returns table (
  org_id         uuid,
  document_id    uuid,
  doc_no         text,
  amount         numeric,
  currency       char(3),
  gateway_code   text,
  mode           text,
  api_key        text,
  collection_ref text,
  signature_key  text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $fn$
declare
  l public.document_share_links;
  d public.sales_documents;
begin
  select * into l from public.document_share_links
   where token_hash = app.corp_token_hash(p_token);
  if l.id is null or l.revoked_at is not null or l.expires_at < now() then
    raise exception 'That link is no longer open.' using errcode = 'P0002';
  end if;

  select * into d from public.sales_documents where id = l.document_id;
  if d.id is null or d.deleted_at is not null
     or d.status in ('void', 'rejected') then
    raise exception 'That document has been withdrawn.' using errcode = '55006';
  end if;

  -- The amount is taken from the document and never from the caller.
  -- A checkout for an amount somebody else chose is how an invoice gets
  -- settled for a ringgit.
  if coalesce(d.balance_amount, 0) <= 0 then
    raise exception 'There is nothing left to pay on %.', d.doc_no
      using errcode = '55006';
  end if;

  return query
    select l.org_id, d.id, d.doc_no, d.balance_amount, d.currency,
           c.gateway_code, c.mode, c.api_key, c.collection_ref,
           c.signature_key
      from public.org_payment_gateways c
     where c.org_id = l.org_id
       and c.gateway_code = p_gateway
       and c.is_active
       and c.settlement_bank_account_id is not null;
end
$fn$;

revoke all on function app.shared_payment_intent(text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The pending payment
-- ---------------------------------------------------------------------
create or replace function public.begin_shared_payment(
  p_token        text,
  p_gateway      text,
  p_provider_ref text,
  p_checkout_url text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $fn$
declare
  i record;
  v_id uuid;
begin
  select * into i from app.shared_payment_intent(p_token, p_gateway);
  if i.org_id is null then
    raise exception 'That way of paying is not available.'
      using errcode = 'P0002';
  end if;

  if coalesce(btrim(p_provider_ref), '') = '' then
    raise exception 'A payment needs the acquirer''s own reference'
      using errcode = '23514';
  end if;

  insert into public.sales_gateway_payments
    (org_id, document_id, gateway_code, mode, provider_ref, amount,
     currency, checkout_url)
  values (i.org_id, i.document_id, i.gateway_code, i.mode,
          btrim(p_provider_ref), i.amount, i.currency, p_checkout_url)
  on conflict (gateway_code, provider_ref) do update
     set checkout_url = excluded.checkout_url,
         updated_at = now()
  returning id into v_id;

  return v_id;
end
$fn$;

revoke all on function public.begin_shared_payment(text, text, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The settlement, and the receipt behind it
-- ---------------------------------------------------------------------
create or replace function public.settle_shared_payment(
  p_gateway      text,
  p_provider_ref text,
  p_paid         boolean,
  p_paid_amount  numeric,
  p_payload      jsonb default null)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_pay     public.sales_gateway_payments;
  v_doc     public.sales_documents;
  v_cfg     public.org_payment_gateways;
  v_payload jsonb := coalesce(p_payload, '{}'::jsonb) - 'x_signature';
  v_no      text;
  v_rcp     uuid;
  v_take    numeric;
begin
  select * into v_pay from public.sales_gateway_payments
   where gateway_code = lower(btrim(coalesce(p_gateway, '')))
     and provider_ref = btrim(coalesce(p_provider_ref, ''));

  -- A confirmation for a payment this system never started. Quiet on
  -- purpose: `settle_gateway_payment` made the same choice, and for the
  -- same reason -- an answer that distinguishes a wrong guess from a
  -- right one is an oracle.
  if v_pay.id is null then
    return 'unknown';
  end if;

  -- Acquirers retry. A retry is not a payment.
  if v_pay.state = 'paid' then
    return 'already_paid';
  end if;

  if not coalesce(p_paid, false) then
    update public.sales_gateway_payments
       set state = 'failed', provider_payload = v_payload
     where id = v_pay.id;
    return 'not_paid';
  end if;

  -- What was handed over has to cover what was owed. Recorded and
  -- refused, never rounded up into a settled invoice.
  if coalesce(p_paid_amount, 0) < v_pay.amount then
    update public.sales_gateway_payments
       set state = 'underpaid', paid_amount = coalesce(p_paid_amount, 0),
           provider_payload = v_payload
     where id = v_pay.id;
    return 'underpaid';
  end if;

  select * into v_doc from public.sales_documents where id = v_pay.document_id;
  select * into v_cfg from public.org_payment_gateways
   where org_id = v_pay.org_id and gateway_code = v_pay.gateway_code
     and mode = v_pay.mode;

  -- Never more than is still owed. Two customers paying the same link
  -- twice, or a payment that landed after somebody keyed the cheque in,
  -- must not leave the invoice in credit through this door.
  v_take := least(v_pay.amount, coalesce(v_doc.balance_amount, 0));

  if v_take > 0 then
    v_no := app.next_document_number_internal(v_pay.org_id, 'receipt');

    insert into public.receipts
      (org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
       bank_account_id, currency, exchange_rate, amount, base_amount,
       status, reference, notes)
    values (
      v_pay.org_id, v_no, current_date, v_doc.contact_id,
      coalesce(v_cfg.payment_mode_code, '03'),
      v_cfg.settlement_bank_account_id,
      v_doc.currency, coalesce(v_doc.exchange_rate, 1), v_take, v_take,
      'draft', v_pay.provider_ref,
      'Paid online through ' || v_pay.gateway_code
        || ' (' || v_pay.provider_ref || ')')
    returning id into v_rcp;

    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount)
    values (v_pay.org_id, v_rcp, v_doc.id, v_take);

    -- The one path into the ledger. Nothing here writes gl_entries:
    -- `0399` closed that door and this migration does not reopen it.
    perform app.post_receipt_internal(v_rcp);
  end if;

  update public.sales_gateway_payments
     set state = 'paid', paid_amount = p_paid_amount, paid_at = now(),
         receipt_id = v_rcp, provider_payload = v_payload
   where id = v_pay.id;

  return 'paid';
end
$fn$;

revoke all on function public.settle_shared_payment(
  text, text, boolean, numeric, jsonb) from public, anon, authenticated;

grant execute on function public.shared_payment_options(text) to anon, authenticated;

-- `open_shared_document` is recreated below, and `0165`'s event trigger
-- strips PUBLIC and anon from a function as it is created — so the
-- recreation silently takes the share link away from every customer
-- holding one. Caught by `shared_invoice_payment.sql` refusing to open
-- a link as `anon`, which is why that file signs itself out and runs
-- the last section under the role the customer actually has.
CREATE OR REPLACE FUNCTION public.open_shared_document(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  l public.document_share_links;
  d public.sales_documents;
  o public.organizations;
  c public.contacts;
  v_state text;
  v_pay jsonb;
begin
  select * into l from public.document_share_links
   where token_hash = app.corp_token_hash(p_token);

  if l.id is null then
    return jsonb_build_object('state', 'invalid');
  end if;

  select * into d from public.sales_documents where id = l.document_id;
  select * into o from public.organizations where id = l.org_id;
  select * into c from public.contacts where id = d.contact_id;

  v_state := case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at < now() then 'expired'
    when d.id is null or d.deleted_at is not null then 'withdrawn'
    when d.status in ('void', 'rejected') then 'withdrawn'
    else 'open'
  end;

  -- Recorded even when the answer is 'expired': that somebody tried is
  -- worth as much as that somebody read it.
  update public.document_share_links
     set opened_at = coalesce(opened_at, now()),
         last_opened_at = now(),
         open_count = open_count + 1,
         ip_address = coalesce(ip_address, nullif(split_part(coalesce(
           app.request_header('x-forwarded-for'), ''), ',', 1), '')::inet),
         user_agent = coalesce(user_agent, app.request_header('user-agent'))
   where id = l.id;

  if v_state <> 'open' then
    return jsonb_build_object('state', v_state);
  end if;

  -- Whether this customer can pay it here, and with which acquirers.
  -- Names only: nothing about a gateway that is not already on the
  -- button the customer is about to press.
  -- Aliased `g`, not `o`: this function already has an `o` of its own
  -- for the organization, and plpgsql resolves the variable ahead of
  -- the alias, so `o.code` asks the organizations row for a column it
  -- does not have.
  select coalesce(jsonb_agg(jsonb_build_object('code', g.code, 'name', g.name)
                            order by g.code), '[]'::jsonb)
    into v_pay
    from public.shared_payment_options(p_token) g;

  return jsonb_build_object(
    'state', 'open',
    'pay_with', case when coalesce(d.balance_amount, 0) > 0
                     then v_pay else '[]'::jsonb end,
    'company', jsonb_build_object(
      'name', coalesce(o.legal_name, o.name),
      'registration_no', o.registration_no,
      'tin', o.tin,
      'sst_registration_no', o.sst_registration_no,
      'address', concat_ws(E'\n', o.address_line1, o.address_line2,
                           o.address_line3,
                           nullif(concat_ws(' ', o.postcode, o.city), ''),
                           o.state_code),
      'email', o.email,
      'phone', o.phone,
      'website', o.website,
      'logo_url', o.logo_url),
    'contact', jsonb_build_object(
      'name', c.name,
      'address', concat_ws(E'\n', c.address_line1, c.address_line2,
                           nullif(concat_ws(' ', c.postcode, c.city), ''),
                           c.state_code)),
    'document', jsonb_build_object(
      'doc_type', d.doc_type,
      'doc_no', d.doc_no,
      'doc_date', d.doc_date,
      'due_date', d.due_date,
      'reference', d.reference,
      'subject', d.subject,
      'currency', d.currency,
      'subtotal', d.subtotal,
      'discount_amount', d.discount_amount,
      'tax_amount', d.tax_amount,
      'shipping_amount', d.shipping_amount,
      -- `0410` added this and `0411` prints it on a receipt; a customer
      -- reading the shared invoice was left with a total that did not
      -- add up from the figures above it.
      'service_charge_amount', d.service_charge_amount,
      'rounding_amount', d.rounding_amount,
      'total_amount', d.total_amount,
      'paid_amount', d.paid_amount,
      'balance_amount', d.balance_amount,
      'status', d.status,
      -- `notes` is what the sender wrote for the customer to read.
      -- `internal_notes` is not, and is deliberately absent.
      'notes', d.notes,
      'terms_conditions', d.terms_conditions),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'line_no', li.line_no,
               'description', li.description,
               'quantity', li.quantity,
               'uom_code', li.uom_code,
               'unit_price', li.unit_price,
               'discount_amount', li.discount_amount,
               'tax_amount', li.tax_amount,
               'line_total', li.line_total)
             order by li.line_no)
        from public.sales_document_lines li
       where li.document_id = d.id), '[]'::jsonb));
end;
$function$;

grant execute on function public.open_shared_document(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text; v_privs text; v_bad text;
begin
  -- The two that hand back a secret or start a payment must not be
  -- reachable by a client role. `0407` swept for exactly this shape and
  -- found four; adding a fifth without saying so would be worse than
  -- the four.
  for v_bad in
    select f from unnest(array[
      'app.shared_payment_intent(text,text)',
      'public.begin_shared_payment(text,text,text,text)',
      'public.settle_shared_payment(text,text,boolean,numeric,jsonb)']) f
  loop
    if has_function_privilege('authenticated', v_bad, 'EXECUTE')
       or has_function_privilege('anon', v_bad, 'EXECUTE') then
      raise exception
        'FAIL 0413: % is executable by a client role. It either hands '
        'back an acquirer key or settles an invoice, and neither is a '
        'thing a browser may ask for.', v_bad;
    end if;
  end loop;

  -- And the one that must be, because the person holding the link is
  -- not signed in.
  if not has_function_privilege('anon',
       'public.shared_payment_options(text)', 'EXECUTE') then
    raise exception
      'FAIL 0413: a customer holding a share link cannot see how to pay';
  end if;

  -- The amount comes from the document. A checkout for an amount the
  -- caller chose is how an invoice is settled for a ringgit, so the
  -- absence of an amount parameter is asserted rather than assumed.
  if exists (
    select 1 from pg_proc p
     cross join lateral unnest(coalesce(p.proargnames, '{}')) as a(name)
     where p.oid = 'public.begin_shared_payment(text,text,text,text)'::regprocedure
       and a.name ~ 'amount')
  then
    raise exception
      'FAIL 0413: begin_shared_payment takes an amount from its caller';
  end if;

  -- The receipt is the only way this reaches the ledger.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = 'public.settle_shared_payment(text,text,boolean,numeric,jsonb)'::regprocedure;
  if v_src !~ 'post_receipt_internal' then
    raise exception
      'FAIL 0413: a confirmed payment does not reach the ledger';
  end if;
  if v_src ~ 'insert into public\.gl_' then
    raise exception
      'FAIL 0413: this writes the ledger directly. 0399 closed that '
      'door and nothing here has a reason to reopen it.';
  end if;

  -- No client role may write the row a callback is matched against.
  select string_agg(distinct privilege_type, ', ' order by privilege_type)
    into v_privs
    from information_schema.role_table_grants
   where grantee in ('anon', 'authenticated')
     and table_schema = 'public' and table_name = 'sales_gateway_payments';
  if v_privs is distinct from 'SELECT' then
    raise exception
      'FAIL 0413: a client role holds % on sales_gateway_payments, '
      'expected SELECT. A client that can write one of these rows can '
      'invent the reference a forged callback then settles.',
      coalesce(v_privs, 'nothing');
  end if;

  if not has_function_privilege('anon',
       'public.open_shared_document(text)', 'EXECUTE') then
    raise exception
      'FAIL 0413: recreating open_shared_document took the share link '
      'away from every customer holding one -- 0165 strips anon from a '
      'function as it is created, and this migration recreates it';
  end if;

  -- And the shared document adds up again.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = 'public.open_shared_document(text)'::regprocedure;
  if v_src !~ 'service_charge_amount' then
    raise exception
      'FAIL 0413: the shared invoice still omits the service charge, so '
      'its own figures do not add up to its total';
  end if;

  raise notice
    '0413: a customer can be offered a way to pay, and a confirmed '
    'payment posts a receipt';
end
$do$;
