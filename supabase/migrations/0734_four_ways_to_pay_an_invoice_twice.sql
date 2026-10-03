-- ---------------------------------------------------------------------
-- 0734  Four ways to pay an invoice twice
--
-- The first tranche of the census's remaining 60 that needed a wrapper
-- rather than a verdict, and the first where the duplicate is MONEY
-- against a customer's account rather than an email or a line of
-- history.
--
-- All four were measured, not read, because reading has been wrong three
-- times in this programme. A thousand-ringgit invoice, a thousand-ringgit
-- receipt, and the same call twice:
--
--     allocate_with_discount(receipt, invoice, 300, 0, today)  twice
--       -> 2 allocations, invoice balance 1,000.00 -> 400.00
--
-- Seven hundred was expected. The second call is not refused, the
-- allocation is not idempotent, and nothing in the schema stops it: there
-- is no unique index on `payment_allocations` and no "already allocated"
-- check, because a receipt may legitimately be allocated to the same
-- invoice twice — in two instalments on two days. The database cannot
-- tell that from a retry. Only a key can.
--
-- | | | |
-- | --- | --- | --- |
-- | `allocate_with_discount` | a receipt against an invoice | **doubles** |
-- | `allocate_payment_with_discount` | a payment against a bill | the purchase-side twin, line for line |
-- | `apply_deposit` | a deposit note against a document | **doubles** |
-- | `knock_off` | credit notes and money on account against invoices, in one batch | **doubles** |
--
-- `apply_deposit` and `knock_off` were each measured the same way and
-- each applied twice. `allocate_payment_with_discount` is the same
-- function as the first with `purchase_payments` and `purchase_documents`
-- in place of `receipts` and `sales_documents`; it is wrapped on that
-- reading and asserted alongside the others.
--
-- ## Where the organization comes from
--
-- None of the four takes one, so each resolves it from the thing it is
-- told about, BEFORE the key is claimed — which is also what makes
-- `0475`'s membership guard apply, so a stranger replaying a guessed key
-- is refused there rather than handed somebody else's answer:
--
--     allocate_with_discount          public.receipts
--     allocate_payment_with_discount  public.purchase_payments
--     apply_deposit                   public.deposit_notes
--     knock_off                       public.contacts
--
-- Where that lookup finds nothing the wrapper claims no key and calls
-- straight through, so the inner function raises its own "No such
-- receipt." rather than this one inventing a worse message.
--
-- ## The optional date
--
-- Three of the four take a trailing date that defaults to null and is
-- `coalesce`d to today inside. The wrapper can therefore pass the null
-- straight through — unlike `0733`'s `email_document`, whose
-- `p_share_days default 30` meant null and omitted were different
-- numbers. Checked rather than assumed: `v_as_at := coalesce(p_as_at,
-- (now() at time zone 'Asia/Kuala_Lumpur')::date)` and `v_on :=
-- coalesce(p_date, app.today())`.
--
-- ## No defaults on the wrapper, again
--
-- `0307`'s rule. The key is required so PostgREST can tell the overloads
-- apart by name, which means nothing else on the wrapper may have a
-- default either, which means the client must name every parameter. The
-- four call sites omitted the date; they now pass it as null.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- allocate_with_discount
-- ---------------------------------------------------------------------
create or replace function public.allocate_with_discount(
  p_receipt uuid, p_invoice uuid, p_amount numeric, p_discount numeric,
  p_as_at date, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select r.org_id into v_org from public.receipts r where r.id = p_receipt;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'allocate_with_discount',
      jsonb_build_object('receipt', p_receipt, 'invoice', p_invoice,
                         'amount', p_amount, 'discount', p_discount,
                         'as_at', p_as_at));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.allocate_with_discount(p_receipt, p_invoice, p_amount,
                                        p_discount, p_as_at);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- allocate_payment_with_discount
-- ---------------------------------------------------------------------
create or replace function public.allocate_payment_with_discount(
  p_payment uuid, p_bill uuid, p_amount numeric, p_discount numeric,
  p_as_at date, p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select p.org_id into v_org
    from public.purchase_payments p where p.id = p_payment;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'allocate_payment_with_discount',
      jsonb_build_object('payment', p_payment, 'bill', p_bill,
                         'amount', p_amount, 'discount', p_discount,
                         'as_at', p_as_at));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.allocate_payment_with_discount(p_payment, p_bill, p_amount,
                                                p_discount, p_as_at);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- apply_deposit
-- ---------------------------------------------------------------------
create or replace function public.apply_deposit(
  p_deposit uuid, p_document uuid, p_amount numeric, p_date date,
  p_idempotency_key text)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_id uuid;
begin
  select d.org_id into v_org
    from public.deposit_notes d where d.id = p_deposit;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key,
      'apply_deposit',
      jsonb_build_object('deposit', p_deposit, 'document', p_document,
                         'amount', p_amount, 'date', p_date));
    if v_seen is not null then
      return nullif(v_seen ->> 'id', '')::uuid;
    end if;
  end if;

  v_id := public.apply_deposit(p_deposit, p_document, p_amount, p_date);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('id', v_id));
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- knock_off
--
-- Returns a COUNT of the lines it settled, so the stored result is that
-- integer and a replay hands back the same number rather than zero. A
-- replay returning zero would read as "nothing was there to settle",
-- which is the opposite of what happened.
-- ---------------------------------------------------------------------
create or replace function public.knock_off(
  p_contact_id uuid, p_lines jsonb, p_idempotency_key text)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_seen jsonb; v_n integer;
begin
  select c.org_id into v_org
    from public.contacts c where c.id = p_contact_id;

  if v_org is not null then
    v_seen := app.idempotency_begin(v_org, p_idempotency_key, 'knock_off',
      jsonb_build_object('contact_id', p_contact_id, 'lines', p_lines));
    if v_seen is not null then
      return coalesce((v_seen ->> 'lines_settled')::integer, 0);
    end if;
  end if;

  v_n := public.knock_off(p_contact_id, p_lines);
  if v_org is not null then
    perform app.idempotency_end(v_org, p_idempotency_key,
                                jsonb_build_object('lines_settled', v_n));
  end if;
  return v_n;
end;
$$;

-- 0165's event trigger strips PUBLIC and anon from every new function;
-- these are new signatures and arrive with no grant at all.
grant execute on function public.allocate_with_discount(
  uuid, uuid, numeric, numeric, date, text) to authenticated;
grant execute on function public.allocate_payment_with_discount(
  uuid, uuid, numeric, numeric, date, text) to authenticated;
grant execute on function public.apply_deposit(
  uuid, uuid, numeric, date, text) to authenticated;
grant execute on function public.knock_off(uuid, jsonb, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- What each one refuses, for `docs/api/`
-- ---------------------------------------------------------------------
comment on function public.allocate_with_discount(
  uuid, uuid, numeric, numeric, date, text) is
  'Sets a receipt against an invoice, at most once per idempotency key. '
  'Without one a retry allocates AGAIN: a receipt may legitimately be '
  'applied to the same invoice twice in two instalments, so neither a '
  'unique index nor a state check can tell that from a dropped '
  'connection. Pass p_as_at as null for today. The key is required and '
  'has no default -- that is what makes PostgREST choose this overload '
  'rather than the unprotected one, so every parameter must be named. '
  'Refuses a key already used for different arguments (22023), a key '
  'still in flight (55006), and a caller who is not a member of the '
  'receipt''s organization.';

comment on function public.allocate_payment_with_discount(
  uuid, uuid, numeric, numeric, date, text) is
  'The purchase side of allocate_with_discount: sets a payment against a '
  'bill, at most once per idempotency key, with the same reasoning and '
  'the same refusals. The organization comes from the payment.';

comment on function public.apply_deposit(uuid, uuid, numeric, date, text) is
  'Applies part or all of a deposit note to a document, at most once per '
  'idempotency key -- measured: without one, two identical calls apply '
  'it twice. Pass p_date as null for today. Refuses a key already used '
  'for different arguments (22023), a key still in flight (55006), and a '
  'caller who is not a member of the deposit''s organization.';

comment on function public.knock_off(uuid, jsonb, text) is
  'Settles credit notes and money on account against invoices in one '
  'batch and returns how many lines were settled, at most once per '
  'idempotency key -- measured: without one the whole batch applies '
  'twice. A REPLAY RETURNS THE SAME COUNT, not zero, because zero would '
  'read as "nothing was there to settle". Refuses a key already used '
  'for different arguments (22023), a key still in flight (55006), and a '
  'caller who is not a member of the contact''s organization.';
