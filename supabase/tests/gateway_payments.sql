-- =====================================================================
-- iAkauntan :: a payment that actually arrives
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/gateway_payments.sql
--
-- 0297 is the first thing on this platform that marks an invoice paid
-- without a person deciding to. What tells it to is an HTTP request
-- from the public internet, at a function deployed without `verify_jwt`
-- because Billplz's servers hold no session with us.
--
-- The signature that stands in for the JWT is asserted on the
-- TypeScript side, in `supabase/functions/_shared/billplz_test.ts`.
-- This file is the second line, and it is written as though the first
-- had failed — because that is the only useful way to write it. Every
-- assertion below is about what a caller who somehow got past the
-- signature still cannot do:
--
--   * settle an invoice for less than it is worth,
--   * pay the same bill twice,
--   * bring a voided invoice back to life,
--   * find out whether a reference they guessed exists,
--   * reach either function at all as a signed-in user.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- One outstanding invoice, made the way the platform makes them.
create or replace function pg_temp.an_invoice(p_org uuid, p_no text, p_total numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.platform_invoices
    (invoice_no, org_id, issuer_name, bill_to_name, description,
     subtotal, total_amount)
  values (p_no, p_org, 'iAkauntan Sdn Bhd', 'Contoh Sdn Bhd',
          'Modules for August', p_total, p_total)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- The money rule
--
-- The assertion this whole migration exists for. A confirmation for one
-- sen against a five hundred ringgit invoice is recorded and refused,
-- not rounded up into a paid invoice.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Pembayar Sdn Bhd');
  v_inv uuid;
  v_out text;
begin
  -- `billplz` is in the catalogue from 0295 and the payments table's
  -- foreign key needs it there; nothing here switches it on, because
  -- settlement does not ask whether the gateway is active. It asks
  -- whether the money arrived.
  v_inv := pg_temp.an_invoice(v_org, 'PLT-0001', 500.00);
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_underpaid', 'https://www.billplz.com/bills/W_underpaid');

  v_out := public.settle_gateway_payment(
    'billplz', 'W_underpaid', true, 0.01,
    jsonb_build_object('id', 'W_underpaid', 'paid', 'true'));

  perform pg_temp.check_eq('a sen against five hundred ringgit is underpaid',
    v_out, 'underpaid');
  perform pg_temp.check_eq('and the invoice is still outstanding',
    (select status from public.platform_invoices where id = v_inv), 'issued');
  perform pg_temp.check_eq('while what did arrive is recorded',
    (select paid_amount from public.platform_payments
      where provider_ref = 'W_underpaid'), 0.01);
  perform pg_temp.check_true('and it is not called paid',
    (select state from public.platform_payments
      where provider_ref = 'W_underpaid') = 'underpaid');

  -- A sen under is still under. The comparison is >=, and the case that
  -- would slip past a > is the exact amount.
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_almost', 'https://www.billplz.com/bills/W_almost');
  perform pg_temp.check_eq('four ninety nine ninety nine does not settle five hundred',
    public.settle_gateway_payment('billplz', 'W_almost', true, 499.99),
    'underpaid');
  perform pg_temp.check_eq('and the invoice is still outstanding after that too',
    (select status from public.platform_invoices where id = v_inv), 'issued');

  -- Exactly the amount settles it.
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_exact', 'https://www.billplz.com/bills/W_exact');
  perform pg_temp.check_eq('the exact amount settles it',
    public.settle_gateway_payment('billplz', 'W_exact', true, 500.00), 'paid');
  perform pg_temp.check_eq('and the invoice is paid',
    (select status from public.platform_invoices where id = v_inv), 'paid');
  perform pg_temp.check_true('with a note saying how',
    (select paid_note from public.platform_invoices where id = v_inv)
      like 'Paid through billplz%');
end $$;

-- ---------------------------------------------------------------------
-- A retry is not a second payment
--
-- Billplz retries anything it does not get a 2xx for, and will resend a
-- callback it is unsure about. Both have to be no-ops.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Ulang Sdn Bhd');
  v_inv uuid; v_paid_at timestamptz;
begin
  v_inv := pg_temp.an_invoice(v_org, 'PLT-0002', 120.00);
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_retry', 'https://www.billplz.com/bills/W_retry');

  perform pg_temp.check_eq('the first callback settles it',
    public.settle_gateway_payment('billplz', 'W_retry', true, 120.00), 'paid');
  select paid_at into v_paid_at from public.platform_invoices where id = v_inv;

  perform pg_temp.check_eq('the second says so and does nothing',
    public.settle_gateway_payment('billplz', 'W_retry', true, 120.00),
    'already_paid');
  perform pg_temp.check_eq('there is still one payment',
    (select count(*) from public.platform_payments where invoice_id = v_inv), 1);
  perform pg_temp.check_eq('and the invoice was not paid a second time',
    (select paid_at from public.platform_invoices where id = v_inv)::text,
    v_paid_at::text);

  -- Nor can a retry that claims MORE money reopen anything.
  perform pg_temp.check_eq('nor does a richer retry change it',
    public.settle_gateway_payment('billplz', 'W_retry', true, 100000.00),
    'already_paid');
  perform pg_temp.check_eq('the payment is still what was actually paid',
    (select paid_amount from public.platform_payments
      where provider_ref = 'W_retry'), 120.00);

  -- Starting a payment against an invoice that has been settled is
  -- refused rather than creating a second way to pay it.
  begin
    perform public.begin_gateway_payment(
      v_inv, 'billplz', 'W_again', 'https://www.billplz.com/bills/W_again');
    perform pg_temp.check_true('FAIL a paid invoice was offered a new bill', false);
  exception when sqlstate '55006' then
    perform pg_temp.check_true('a paid invoice cannot be billed again', true);
  end;
end $$;

-- ---------------------------------------------------------------------
-- A voided invoice does not come back to life
--
-- The one that only happens once and matters when it does: a bill is
-- raised, the invoice is voided by a platform administrator, and the
-- payer pays anyway. The money is real and is recorded as such; the
-- invoice stays void and somebody owes a refund.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Batal Sdn Bhd');
  v_inv uuid;
begin
  v_inv := pg_temp.an_invoice(v_org, 'PLT-0003', 90.00);
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_void', 'https://www.billplz.com/bills/W_void');
  update public.platform_invoices set status = 'void' where id = v_inv;

  perform pg_temp.check_eq('the payment is recorded and says what happened',
    public.settle_gateway_payment('billplz', 'W_void', true, 90.00),
    'paid_but_invoice_not_issued');
  perform pg_temp.check_eq('the invoice stays void',
    (select status from public.platform_invoices where id = v_inv), 'void');
  perform pg_temp.check_true('and the money is not lost track of',
    (select state from public.platform_payments
      where provider_ref = 'W_void') = 'paid');
  perform pg_temp.check_eq('with the amount that arrived',
    (select paid_amount from public.platform_payments
      where provider_ref = 'W_void'), 90.00);
end $$;

-- ---------------------------------------------------------------------
-- An unpaid callback, and one for a bill nobody raised
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Gagal Sdn Bhd');
  v_inv uuid;
begin
  v_inv := pg_temp.an_invoice(v_org, 'PLT-0004', 60.00);
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_failed', 'https://www.billplz.com/bills/W_failed');

  perform pg_temp.check_eq('a callback saying not paid marks it failed',
    public.settle_gateway_payment('billplz', 'W_failed', false, 0), 'not_paid');
  perform pg_temp.check_eq('and the invoice is untouched',
    (select status from public.platform_invoices where id = v_inv), 'issued');

  -- A guessed reference is told nothing it did not already know. The
  -- answer is the same word whether the guess was close or absurd, so
  -- the reply is not an oracle for which references exist.
  perform pg_temp.check_eq('a reference nobody raised is unknown',
    public.settle_gateway_payment('billplz', 'W_invented', true, 1000.00),
    'unknown');
  perform pg_temp.check_eq('and so is one for the wrong gateway',
    public.settle_gateway_payment('toyyibpay', 'W_failed', true, 60.00),
    'unknown');
  perform pg_temp.check_eq('nothing was written for either',
    (select count(*) from public.platform_payments
      where provider_ref in ('W_invented')), 0);
end $$;

-- ---------------------------------------------------------------------
-- The signature is not kept with the thing it signs
--
-- A MAC filed next to the message it authenticates is worth nothing and
-- costs something: it is a working credential for that exact payload,
-- sitting in a table that the paying company can read.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Tandatangan Sdn Bhd');
  v_inv uuid; v_payload jsonb;
begin
  v_inv := pg_temp.an_invoice(v_org, 'PLT-0005', 30.00);
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_sig', 'https://www.billplz.com/bills/W_sig');
  perform public.settle_gateway_payment('billplz', 'W_sig', true, 30.00,
    jsonb_build_object(
      'id', 'W_sig', 'paid', 'true', 'paid_amount', '3000',
      'x_signature', 'e3b0c44298fc1c149afbf4c8996fb924'));

  select provider_payload into v_payload from public.platform_payments
   where provider_ref = 'W_sig';

  perform pg_temp.check_true('the callback is kept for the audit trail',
    v_payload ? 'id' and v_payload ->> 'paid' = 'true');
  perform pg_temp.check_true('and its signature is not',
    not (v_payload ? 'x_signature'));
  perform pg_temp.check_eq('nowhere in it, not merely absent from the top',
    (select count(*) from jsonb_each_text(v_payload)
      where value like 'e3b0c442%'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Neither function is reachable by a signed-in user
--
-- Both are `public` rather than `app` only because PostgREST exposes no
-- other schema and an edge function has to be able to call them. The
-- wall is the grant, so the grant is what is asserted — a company owner
-- who can call `settle_gateway_payment` can mark their own invoices
-- paid.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Percubaan Sdn Bhd');
  v_inv uuid; v_owner uuid; v_ok boolean; v_role text; v_seen integer;
begin
  v_inv := pg_temp.an_invoice(v_org, 'PLT-0006', 250.00);
  perform public.begin_gateway_payment(
    v_inv, 'billplz', 'W_grant', 'https://www.billplz.com/bills/W_grant');

  v_owner := pg_temp.another_user('pemilik@iakauntan.test');
  perform pg_temp.sign_in_as(v_owner);

  v_ok := false;
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.settle_gateway_payment('billplz', 'W_grant', true, 250.00);
  exception when insufficient_privilege then v_ok := true;
  end;
  reset role;
  perform pg_temp.check_true('the attempt ran as a signed-in user',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'a signed-in user cannot settle a payment', v_ok);

  v_ok := false;
  begin
    set local role authenticated;
    perform public.begin_gateway_payment(
      v_inv, 'billplz', 'W_mine', 'https://www.billplz.com/bills/W_mine');
  exception when insufficient_privilege then v_ok := true;
  end;
  reset role;
  perform pg_temp.check_true('nor start one', v_ok);

  perform pg_temp.check_eq('and the invoice is as it was',
    (select status from public.platform_invoices where id = v_inv), 'issued');

  -- Nor may they write the table directly, which is the same wall by
  -- another door — but asserted by its effect rather than by an
  -- exception, and that distinction is the point.
  --
  -- The first draft caught `insufficient_privilege`, which is what
  -- happens here and is NOT what happens in production. Supabase ships
  -- `alter default privileges in schema public grant all on tables to
  -- authenticated`, so every table in `public` reaches the deployed
  -- database with INSERT, UPDATE and DELETE already granted — checked
  -- against the running project, where `platform_payments` carries all
  -- four while this harness gives it only SELECT.
  --
  -- What refuses the write there is row level security: the table has
  -- one policy and it is `for select`, so nothing permits an UPDATE and
  -- the statement succeeds having changed nothing. An assertion that
  -- waits for an exception would pass here for ever while saying
  -- nothing at all about the system anybody actually uses — and would
  -- go on passing the day somebody added a permissive write policy.
  -- As a member of the company the payment belongs to, not a stranger.
  -- The first version of this used the stranger above and passed for
  -- the wrong reason: the read policy hid the row from them, so the
  -- UPDATE matched nothing whatever the write rules said, and adding a
  -- permissive write policy did not disturb it. Somebody who can see
  -- the row is the only caller that tests whether they can change it.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  begin
    set local role authenticated;
    select count(*) into v_seen from public.platform_payments
     where provider_ref = 'W_grant';
    update public.platform_payments set state = 'paid'
     where provider_ref = 'W_grant';
  exception when insufficient_privilege then null;
  end;
  reset role;
  perform pg_temp.check_eq('a member can see their own payment', v_seen, 1);
  perform pg_temp.check_eq('and still cannot write the payments table by hand',
    (select state from public.platform_payments
      where provider_ref = 'W_grant'), 'pending');
  perform pg_temp.sign_out();
end $$;

rollback;
