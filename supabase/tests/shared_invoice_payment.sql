-- =====================================================================
-- iAkauntan :: the customer can pay the invoice they were sent
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/shared_invoice_payment.sql
--
-- `open_shared_document` gave a customer a document to read and no way
-- to pay it. `0412` gave the organization somewhere to keep its own
-- acquirer credentials; `0413` is the pending payment, the settlement,
-- and the receipt that lands in the tenant's own ledger.
--
-- What is asserted here is everything except the acquirer. The HTTP
-- call belongs to an edge function and cannot be exercised against a
-- sandbox this suite does not have, so the two ends it holds on to —
-- `begin_shared_payment` and `settle_shared_payment` — are driven
-- directly, which is exactly what the edge function does with them.
--
-- The money is the point. A confirmed payment has to come off the
-- receivable and land in the bank account the shop nominated, through
-- `app.post_receipt_internal` and no other door.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_pay_ctx (org uuid, token text, doc uuid, owner_user uuid);
grant select on t_pay_ctx to authenticated, anon;

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_cust   uuid;
  v_item   uuid;
  v_doc    uuid;
  v_bank   uuid;
  v_token  text;
  v_pay    uuid;
  v_ar     uuid;
  r        record;
  v_n      int;
  v_state  text;
  v_before numeric;
  v_no     text;
  v_rcp    uuid;
  v_other  uuid;
  v_other_bank uuid;
begin
  v_org := pg_temp.test_org('Kedai Pautan Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'CUST', 'Encik Rahman', 'customer', 'rahman@example.test')
  returning id into v_cust;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SVC', 'Consulting', 'service', false, 'C62', 500.00)
  returning id into v_item;

  insert into public.bank_accounts
    (org_id, account_id, name, account_type, currency)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Maybank current', 'current', 'MYR')
  returning id into v_bank;

  -- An invoice, posted, so there is a receivable for a payment to come
  -- off. Nothing below asserts anything about a draft.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-PAY-1', current_date, current_date,
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Consulting', 1, 'C62', 500.00);
  perform app.post_sales_document_internal(v_doc);

  perform pg_temp.check_eq('the invoice is owed in full',
    (select balance_amount from public.sales_documents where id = v_doc),
    500.00);

  v_token := public.share_document(v_doc);
  perform pg_temp.check_true('and it has a link to send', v_token is not null);

  -- ------------------------------------------------------------------
  -- Nothing to offer until the shop has set an acquirer up
  -- ------------------------------------------------------------------
  select count(*) into v_n from public.shared_payment_options(v_token);
  perform pg_temp.check_eq(
    'a company with no acquirer offers no way to pay', v_n, 0);

  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'sandbox', 'sk_test', 'col_1', 'xsig', true);

  -- A button that leads to a failure is worse than no button. The
  -- gateway is configured and switched on, and still not offered,
  -- because there is nowhere for the receipt to bank.
  select count(*) into v_n from public.shared_payment_options(v_token);
  perform pg_temp.check_eq(
    'nor one with nowhere for the takings to land', v_n, 0);

  perform public.set_org_payment_settlement(
    v_org, 'billplz', 'sandbox', v_bank, '03');

  select * into r from public.shared_payment_options(v_token);
  perform pg_temp.check_eq('once it can bank, the acquirer is offered',
    r.code, 'billplz');
  perform pg_temp.check_true('by name', coalesce(r.name, '') <> '');

  -- ------------------------------------------------------------------
  -- Another company's bank account
  -- ------------------------------------------------------------------
  -- The reach a parameter has that a policy cannot see. Without the
  -- check, every receipt from then on banks somebody else's money.
  --
  -- The other company's account is created here rather than looked for.
  -- The first version of this probe took whatever `where org_id <>
  -- v_org` happened to find and skipped itself when that was nothing --
  -- so it passed against a fixture with one company in it, and a mutant
  -- that deleted the check survived. A probe that measures whether it
  -- had anything to probe is not a probe.
  v_other := pg_temp.test_org('Syarikat Seberang Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.bank_accounts
    (org_id, account_id, name, account_type, currency)
  values (v_other,
          (select id from public.accounts where org_id = v_other and code = '1120'),
          'Their account', 'current', 'MYR')
  returning id into v_other_bank;

  begin
    perform public.set_org_payment_settlement(
      v_org, 'billplz', 'sandbox', v_other_bank, '03');
    raise exception
      'FAIL: another company''s bank account was accepted for settlement';
  exception when sqlstate '23503' then
    raise notice 'ok   and the settlement account has to be this company''s';
  end;

  perform pg_temp.check_true('so the takings still land where they were sent',
    (select settlement_bank_account_id from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz'
        and mode = 'sandbox') = v_bank);

  -- ------------------------------------------------------------------
  -- The pending payment
  -- ------------------------------------------------------------------
  v_pay := public.begin_shared_payment(
    v_token, 'billplz', 'bpz_ref_1', 'https://billplz.test/bills/1');
  perform pg_temp.check_true('a payment can be started', v_pay is not null);

  select * into r from public.sales_gateway_payments where id = v_pay;
  perform pg_temp.check_eq('for what is owed and not for what was asked',
    r.amount, 500.00);
  perform pg_temp.check_eq('and it is waiting', r.state, 'pending');

  -- The acquirer sends the customer back and then calls again. A retry
  -- must find the payment it already started, not make a second one.
  perform public.begin_shared_payment(
    v_token, 'billplz', 'bpz_ref_1', 'https://billplz.test/bills/1b');
  perform pg_temp.check_eq('a second start on the same reference is the same one',
    (select count(*) from public.sales_gateway_payments
      where document_id = v_doc), 1);

  begin
    perform public.begin_shared_payment(v_token, 'toyyibpay', 'tp_1', null);
    raise exception 'FAIL: a payment was started through an acquirer nobody set up';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and only through an acquirer this company set up';
  end;

  -- ------------------------------------------------------------------
  -- A confirmation for something nobody started
  -- ------------------------------------------------------------------
  -- Quiet on purpose. An answer that tells a caller whether their guess
  -- was right is an oracle for guessing references.
  perform pg_temp.check_eq('a reference nobody has heard of is nothing at all',
    public.settle_shared_payment('billplz', 'guessed_it', true, 500.00), 'unknown');

  -- ------------------------------------------------------------------
  -- Short payment
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a payment for less than was owed is refused',
    public.settle_shared_payment('billplz', 'bpz_ref_1', true, 499.99),
    'underpaid');
  perform pg_temp.check_eq('and recorded as such',
    (select state from public.sales_gateway_payments where id = v_pay),
    'underpaid');
  perform pg_temp.check_eq('with the invoice still owed in full',
    (select balance_amount from public.sales_documents where id = v_doc),
    500.00);
  perform pg_temp.check_eq('and no receipt behind it',
    (select count(*) from public.receipts where org_id = v_org), 0);

  -- ------------------------------------------------------------------
  -- The payment itself
  -- ------------------------------------------------------------------
  v_before := (select count(*) from public.gl_entries where org_id = v_org);

  perform pg_temp.check_eq('a payment that covers it settles',
    public.settle_shared_payment('billplz', 'bpz_ref_1', true, 500.00,
      jsonb_build_object('x_signature', 'do-not-keep-this',
                         'paid_at', '2026-09-01')),
    'paid');

  select * into r from public.sales_gateway_payments where id = v_pay;
  perform pg_temp.check_eq('the payment is paid', r.state, 'paid');
  perform pg_temp.check_eq('for the amount confirmed', r.paid_amount, 500.00);
  perform pg_temp.check_true('and a receipt was raised', r.receipt_id is not null);

  -- The acquirer's signature is not a thing to keep. It verifies one
  -- callback and is a secret for every callback after it.
  perform pg_temp.check_true('the acquirer''s signature is not stored',
    not (r.provider_payload ? 'x_signature'));
  perform pg_temp.check_true('though the rest of what it said is',
    r.provider_payload ? 'paid_at');

  -- ------------------------------------------------------------------
  -- The money, which is the point
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the invoice is settled',
    (select balance_amount from public.sales_documents where id = v_doc), 0);
  perform pg_temp.check_eq('and shows what was paid',
    (select paid_amount from public.sales_documents where id = v_doc), 500.00);

  select * into r from public.receipts where org_id = v_org;
  perform pg_temp.check_eq('the receipt is for the amount that arrived',
    r.amount, 500.00);
  perform pg_temp.check_true('banked where the shop said it would be',
    r.bank_account_id = v_bank);
  perform pg_temp.check_eq('under the mode the shop chose',
    r.payment_mode_code, '03');
  perform pg_temp.check_eq(
    'and carries the acquirer''s reference, so the statement can be tied '
    'back to it', r.reference, 'bpz_ref_1');
  perform pg_temp.check_true('and it posted', r.gl_entry_id is not null);

  perform pg_temp.check_eq('the ledger has one more entry for it',
    (select count(*) from public.gl_entries where org_id = v_org),
    v_before + 1);

  select id into v_ar from public.accounts
   where org_id = v_org and code = '1210';
  perform pg_temp.check_eq('which takes the receivable off',
    (select coalesce(sum(l.credit - l.debit), 0)
       from public.gl_lines l where l.entry_id = r.gl_entry_id
        and l.account_id = v_ar), 500.00);
  perform pg_temp.check_eq('and puts the money in the bank',
    (select coalesce(sum(l.debit - l.credit), 0)
       from public.gl_lines l
       join public.bank_accounts b on b.account_id = l.account_id
      where l.entry_id = r.gl_entry_id and b.id = v_bank), 500.00);

  -- ------------------------------------------------------------------
  -- The retry
  -- ------------------------------------------------------------------
  -- Acquirers retry, and a retry is not a payment. Without this the
  -- customer is receipted twice for paying once.
  perform pg_temp.check_eq('a repeated callback settles nothing again',
    public.settle_shared_payment('billplz', 'bpz_ref_1', true, 500.00),
    'already_paid');
  perform pg_temp.check_eq('so there is still one receipt',
    (select count(*) from public.receipts where org_id = v_org), 1);
  perform pg_temp.check_eq('and the invoice is not in credit',
    (select balance_amount from public.sales_documents where id = v_doc), 0);

  -- ------------------------------------------------------------------
  -- Nothing left to pay
  -- ------------------------------------------------------------------
  select count(*) into v_n from public.shared_payment_options(v_token);
  perform pg_temp.check_eq(
    'a settled invoice is not offered a way to pay again', v_n, 0);

  begin
    perform public.begin_shared_payment(v_token, 'billplz', 'bpz_ref_2', null);
    raise exception 'FAIL: a payment was started on an invoice owing nothing';
  -- 55006 and not P0002: "nothing left to pay" is a different answer
  -- from "no such acquirer", and a test that accepted either would pass
  -- on a gateway lookup that had quietly stopped working.
  exception when sqlstate '55006' then
    raise notice 'ok   nor can one be started on it';
  end;

  -- ------------------------------------------------------------------
  -- A failed payment
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-PAY-2', current_date, current_date,
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Consulting', 1, 'C62', 100.00);
  perform app.post_sales_document_internal(v_doc);
  v_token := public.share_document(v_doc);

  perform public.begin_shared_payment(v_token, 'billplz', 'bpz_ref_3', null);
  perform pg_temp.check_eq('a card that was declined is recorded as declined',
    public.settle_shared_payment('billplz', 'bpz_ref_3', false, 0), 'not_paid');
  perform pg_temp.check_eq('and the invoice is still owed',
    (select balance_amount from public.sales_documents where id = v_doc),
    100.00);
  perform pg_temp.check_eq('with no receipt for it',
    (select count(*) from public.receipts where org_id = v_org), 1);

  -- ------------------------------------------------------------------
  -- Paid twice over, by two different routes
  -- ------------------------------------------------------------------
  -- The customer starts a payment, then settles the invoice by bank
  -- transfer while the acquirer is still thinking about it. The
  -- callback arrives against a bill that owes nothing. The payment is
  -- real and is recorded as paid; what must not happen is a receipt
  -- that puts the invoice in credit.
  perform public.begin_shared_payment(v_token, 'billplz', 'bpz_ref_4', null);

  v_no := app.next_document_number_internal(v_org, 'receipt');
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
     bank_account_id, currency, exchange_rate, amount, base_amount, status)
  values (v_org, v_no, current_date, v_cust, '03', v_bank, 'MYR', 1,
          100.00, 100.00, 'draft')
  returning id into v_rcp;
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_doc, 100.00);
  perform app.post_receipt_internal(v_rcp);

  perform pg_temp.check_eq('the invoice was settled another way first',
    (select balance_amount from public.sales_documents where id = v_doc), 0);

  perform pg_temp.check_eq('and the acquirer''s confirmation still lands',
    public.settle_shared_payment('billplz', 'bpz_ref_4', true, 100.00), 'paid');
  perform pg_temp.check_eq('without a second receipt for the same money',
    (select count(*) from public.receipts where org_id = v_org), 2);
  perform pg_temp.check_eq('and the invoice is not left in credit',
    (select balance_amount from public.sales_documents where id = v_doc), 0);
  perform pg_temp.check_true(
    'the payment records that it took no receipt of its own',
    (select receipt_id is null from public.sales_gateway_payments
      where provider_ref = 'bpz_ref_4'));

  -- A third invoice, still owing, for the two sections below: the one
  -- above has been settled twice over and would offer no way to pay.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-PAY-3', current_date, current_date,
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Consulting', 1, 'C62', 250.00);
  perform app.post_sales_document_internal(v_doc);
  v_token := public.share_document(v_doc);
  perform public.begin_shared_payment(v_token, 'billplz', 'bpz_ref_5', null);

  insert into t_pay_ctx values (v_org, v_token, v_doc, v_owner);
end $$;

-- ---------------------------------------------------------------------
-- And what a client role can reach, as a client role
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', (select owner_user from t_pay_ctx),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record;
begin
  select * into c from t_pay_ctx;

  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');

  -- The row a callback is matched against. A client that could write
  -- one could invent the reference a forged callback then settles.
  begin
    insert into public.sales_gateway_payments
      (org_id, document_id, gateway_code, mode, provider_ref, amount)
    values (c.org, c.doc, 'billplz', 'sandbox', 'invented_ref', 1.00);
    raise exception 'FAIL: a client role invented a payment reference';
  exception when sqlstate '42501' then
    raise notice 'ok   a client role cannot invent a payment reference';
  end;

  begin
    perform public.settle_shared_payment('billplz', 'bpz_ref_5', true, 250.00);
    raise exception 'FAIL: a client role settled a payment';
  exception when sqlstate '42501' then
    raise notice 'ok   nor settle one';
  end;

  begin
    perform app.shared_payment_intent(c.token, 'billplz');
    raise exception 'FAIL: a client role read an acquirer key';
  exception when sqlstate '42501' then
    raise notice 'ok   nor read the key that would let it charge one';
  end;

  -- Reading its own is the half that has to survive: a shop looking at
  -- an invoice needs to see that somebody tried to pay it.
  perform pg_temp.check_true('but may see the attempts on its own invoices',
    (select count(*) from public.sales_gateway_payments
      where org_id = c.org) > 0);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- And what the person holding the link may reach
-- ---------------------------------------------------------------------
set local role anon;

do $$
declare c record; v_doc jsonb;
begin
  select * into c from t_pay_ctx;
  perform pg_temp.check_eq('the session really is anonymous',
    current_user, 'anon');

  v_doc := public.open_shared_document(c.token);
  perform pg_temp.check_eq('the link opens', v_doc ->> 'state', 'open');
  perform pg_temp.check_eq('and says how it can be paid',
    jsonb_array_length(v_doc -> 'pay_with'), 1);
  perform pg_temp.check_eq('by name and nothing else',
    (select string_agg(k, ',' order by k)
       from jsonb_object_keys(v_doc -> 'pay_with' -> 0) k),
    'code,name');

  -- The document has to add up from its own figures, which is why
  -- `0413` put the service charge back on it.
  perform pg_temp.check_true('and the shared invoice shows the service charge',
    v_doc -> 'document' ? 'service_charge_amount');

  begin
    perform public.settle_shared_payment('billplz', 'bpz_ref_5', true, 250.00);
    raise exception
      'FAIL: the person holding a share link settled their own invoice';
  exception when sqlstate '42501' then
    raise notice 'ok   and the customer cannot mark their own invoice paid';
  end;
end $$;

reset role;

rollback;
