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
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'CUST', 'Encik Rahman', 'customer', 'rahman@example.test')
  returning id into v_cust;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SVC', 'Consulting', 'service', false, 'C62', 500.00)
  returning id into v_item;

  v_bank := pg_temp.test_bank_account(v_org, 'Maybank current');

  -- An invoice, posted, so there is a receivable for a payment to come
  -- off. Nothing below asserts anything about a draft.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-PAY-1', pg_temp.today(), pg_temp.today(),
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
  v_other_bank := pg_temp.test_bank_account(v_other, 'Their account');

  -- Read by its words: the table's same-company key refuses this too,
  -- with the same SQLSTATE, so asking only for 23503 could not tell the
  -- function's check from its absence.
  perform pg_temp.check_refused('and the settlement account has to be this company''s',
    format('select public.set_org_payment_settlement(%L, %L, %L, %L, %L)',
           v_org, 'billplz', 'sandbox', v_other_bank, '03'),
    'That bank account does not belong to this company.', '23503');

  perform pg_temp.check_true('so the takings still land where they were sent',
    (select settlement_bank_account_id from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz'
        and mode = 'sandbox') = v_bank);

  -- `set_org_payment_settlement`, rule by rule. A mutation sweep
  -- (`mutants/set_org_payment_settlement.py`) left these with nothing
  -- to tell them from their absence.
  perform pg_temp.sign_in_as(pg_temp.another_user('tunai-luar@example.test'));
  perform pg_temp.check_refused('only an administrator says where the takings land',
    format('select public.set_org_payment_settlement(%L, %L, %L, %L, %L)',
           v_org, 'billplz', 'sandbox', v_bank, '03'),
    'Only an administrator can say where this company''s takings land', '42501');
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_refused('an acquirer not set up is said so',
    format('select public.set_org_payment_settlement(%L, %L, %L, %L, %L)',
           v_org, 'toyyibpay', 'sandbox', v_bank, '03'),
    'Set the toyyibpay credentials up before saying where its takings land.', 'P0002');
  perform pg_temp.check_refused('and so is the other mode of one that is',
    format('select public.set_org_payment_settlement(%L, %L, %L, %L, %L)',
           v_org, 'billplz', 'production', v_bank, '03'),
    'Set the billplz credentials up before saying where its takings land.', 'P0002');
  -- What is left out is kept; what is given is trimmed.
  -- Asked after EACH call: the second one sets the account again, so
  -- asking only at the end cannot see the first one clearing it.
  perform public.set_org_payment_settlement(v_org, 'billplz', 'sandbox', null, '  04  ');
  perform pg_temp.check_true('an account left out is kept, and a mode is trimmed',
    (select settlement_bank_account_id = v_bank and payment_mode_code = '04'
       from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'));
  perform public.set_org_payment_settlement(v_org, 'billplz', 'sandbox', v_bank, null);
  perform pg_temp.check_eq('and a mode left out is kept',
    (select payment_mode_code from public.org_payment_gateways
      where org_id = v_org and gateway_code = 'billplz' and mode = 'sandbox'), '04');
  perform public.set_org_payment_settlement(v_org, 'billplz', 'sandbox', v_bank, '03');

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
  values (v_org, 'invoice', 'INV-PAY-2', pg_temp.today(), pg_temp.today(),
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
  values (v_org, v_no, pg_temp.today(), v_cust, '03', v_bank, 'MYR', 1,
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
  values (v_org, 'invoice', 'INV-PAY-3', pg_temp.today(), pg_temp.today(),
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

-- ---------------------------------------------------------------------
-- The shapes one company with one bank account and one acquirer cannot
-- show
--
-- `settle_shared_payment` was mutated thirty ways. The company above
-- killed thirteen. Almost everything that survived needed a SECOND of
-- something -- a second acquirer, a second bank account, a second
-- company, a currency that is not the base one, or simply a settlement
-- mode code that is not the same string the code falls back to when it
-- finds no config at all.
--
-- That last one is worth naming. `coalesce(v_cfg.payment_mode_code,
-- '03')` falls back to '03', and the fixture above configures its
-- settlement with '03'. "Under the mode the shop chose" is therefore
-- an assertion that passes whether the config was read or ignored.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_them  uuid;
  v_cust  uuid;
  v_item  uuid;
  v_doc   uuid;
  v_bank_a uuid; v_bank_b uuid; v_their_bank uuid;
  v_token text;
  v_pay   uuid;
  r       record;
begin
  v_org := pg_temp.test_org('Kedai Dua Acquirer Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'CUST', 'Encik Zaki', 'customer', 'zaki@example.test')
  returning id into v_cust;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SVC', 'Consulting', 'service', false, 'C62', 500.00)
  returning id into v_item;

  -- TWO bank accounts, and the one the second acquirer settles into is
  -- NOT the one `app.post_receipt_internal` would resolve on its own.
  -- That is what makes "the takings are banked nowhere" observable:
  -- post_receipt_internal has a documented fallback that picks the
  -- settlement account of the FIRST gateway by created_at, else the
  -- default active account, else the oldest -- and writes the answer
  -- back onto the receipt. With one bank account it resolves to the
  -- same row either way, so dropping the account from the insert
  -- changed nothing anybody could see.
  v_bank_a := pg_temp.test_bank_account(v_org, 'Maybank settlement');
  v_bank_b := pg_temp.test_bank_account(v_org, 'CIMB e-wallet settlement');

  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'sandbox', 'sk_test', 'col_1', 'xsig', true);
  perform public.set_org_payment_settlement(
    v_org, 'billplz', 'sandbox', v_bank_a, '04');
  perform public.set_org_payment_gateway(
    v_org, 'toyyibpay', 'sandbox', 'tp_test', 'cat_1', 'tsig', true);
  perform public.set_org_payment_settlement(
    v_org, 'toyyibpay', 'sandbox', v_bank_b, '06');

  -- A SECOND COMPANY holding the same acquirer. Without one, inverting
  -- the config lookup's org scope merely finds nothing, which the mode
  -- code alone would catch; with one, it finds somebody else's bank.
  v_them := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  v_their_bank := pg_temp.test_bank_account(v_them, 'Their account');
  perform public.set_org_payment_gateway(
    v_them, 'toyyibpay', 'sandbox', 'tp_theirs', 'cat_9', 'tsig9', true);
  perform public.set_org_payment_settlement(
    v_them, 'toyyibpay', 'sandbox', v_their_bank, '01');
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- A payment through the SECOND acquirer
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-TWO-1', pg_temp.today(), pg_temp.today(),
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Consulting', 1, 'C62', 500.00);
  perform app.post_sales_document_internal(v_doc);
  v_token := public.share_document(v_doc);
  v_pay := public.begin_shared_payment(v_token, 'toyyibpay', 'tp_ref_1', null);

  -- The acquirer's code in the case IT sends and the reference with the
  -- whitespace a form adds. Both are folded and trimmed on the way in,
  -- and nothing asserted either: a callback that cannot find its own
  -- payment returns 'unknown' and says nothing, so the failure is a
  -- customer charged and an invoice still open.
  perform pg_temp.check_eq(
    'the acquirer''s own capitalisation still finds the payment',
    public.settle_shared_payment('ToyyibPay', 'tp_ref_1', true, 500.00),
    'paid');

  select * into r from public.receipts where org_id = v_org;
  perform pg_temp.check_true(
    'the takings land in the account THAT acquirer settles into',
    r.bank_account_id = v_bank_b);
  perform pg_temp.check_eq(
    'under the mode that acquirer was given, which is not the fallback',
    r.payment_mode_code, '06');

  select * into r from public.sales_gateway_payments where id = v_pay;
  perform pg_temp.check_true('and when it was paid is recorded',
    r.paid_at is not null);

  -- ------------------------------------------------------------------
  -- A FOREIGN-currency invoice paid online
  -- ------------------------------------------------------------------
  -- `app.shared_payment_intent` carries the document's own currency
  -- onto the payment, so this path is not ringgit-only -- but every
  -- invoice in this file was MYR at rate 1, where the currency, the
  -- rate and the literals the code could be mutated to are the same
  -- values.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-TWO-2', pg_temp.today(), pg_temp.today(),
          v_cust, 'USD', 4.2, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Consulting', 1, 'C62', 100.00);
  perform app.post_sales_document_internal(v_doc);
  v_token := public.share_document(v_doc);
  perform public.begin_shared_payment(v_token, 'billplz', 'bpz_two_1', null);
  -- The payment row first: it is what the acquirer is asked to charge,
  -- and a start that wrote MYR beside a hundred dollars would ask for a
  -- hundred ringgit.
  perform pg_temp.check_eq('the payment is started in the currency billed',
    (select currency from public.sales_gateway_payments
      where gateway_code = 'billplz' and provider_ref = 'bpz_two_1'), 'USD');

  perform pg_temp.check_eq('a payment in dollars settles',
    public.settle_shared_payment('billplz', 'bpz_two_1', true, 100.00),
    'paid');

  select * into r from public.receipts
   where org_id = v_org and reference = 'bpz_two_1';
  perform pg_temp.check_eq('the receipt is in the currency billed',
    r.currency, 'USD');
  perform pg_temp.check_eq('at the invoice''s own rate', r.exchange_rate, 4.2);
  perform pg_temp.check_eq('for the dollars that arrived', r.amount, 100.00);
  -- `base_amount` is deliberately NOT asserted off the insert. The
  -- insert writes `v_take, v_take` -- 100 and 100 -- and
  -- app.post_receipt_internal then overwrites it with
  -- `round(amount * rate, 2)` on the same row, unconditionally, inside
  -- the same branch. So the inserted value is unobservable, which
  -- makes a mutant that zeroes it EQUIVALENT rather than uncaught.
  -- What is worth asserting is the figure that survives.
  perform pg_temp.check_eq('and the books hold the ringgit it is worth',
    r.base_amount, 420.00);
  perform pg_temp.check_true('banked where billplz settles',
    r.bank_account_id = v_bank_a);

  -- ------------------------------------------------------------------
  -- An OVERPAYMENT
  -- ------------------------------------------------------------------
  -- An acquirer can confirm more than was billed -- a tip, a rounding
  -- on a foreign card, a customer who typed the amount themselves.
  -- `least(v_pay.amount, balance)` is what stops the extra becoming a
  -- receipt, and the file above only ever paid exactly or short, so
  -- taking the paid amount instead of the billed one changed nothing.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-TWO-3', pg_temp.today(), pg_temp.today(),
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Consulting', 1, 'C62', 200.00);
  perform app.post_sales_document_internal(v_doc);
  v_token := public.share_document(v_doc);
  v_pay := public.begin_shared_payment(v_token, 'billplz', 'bpz_two_2', null);

  perform pg_temp.check_eq('a payment for MORE than was billed settles',
    public.settle_shared_payment('billplz', 'bpz_two_2', true, 250.00),
    'paid');
  select * into r from public.receipts
   where org_id = v_org and reference = 'bpz_two_2';
  perform pg_temp.check_eq('and the receipt is for what was BILLED',
    r.amount, 200.00);
  perform pg_temp.check_eq('so the invoice is settled and not in credit',
    (select balance_amount from public.sales_documents where id = v_doc), 0);
  perform pg_temp.check_eq('while the payment records what really arrived',
    (select paid_amount from public.sales_gateway_payments where id = v_pay),
    250.00);
  -- What these three do NOT prove, said here so the next sweep does not
  -- re-chase it: replacing `v_pay.amount` with `p_paid_amount` inside
  -- the `least` is an EQUIVALENT mutant, not an uncaught one. The
  -- short-payment guard has already returned unless the amount paid is
  -- at least v_pay.amount, v_pay.amount was the balance when the
  -- payment began, and a posted invoice's balance never RISES -- there
  -- is no unallocate, no amend-upward, and void_sales_document refuses
  -- a document with paid_amount > 0. So paid >= v_pay.amount >= balance
  -- and both forms of the `least` return the balance. The cap that
  -- actually does the work is the balance; v_pay.amount inside it is
  -- belt-and-braces against a state this schema cannot reach.

  -- ------------------------------------------------------------------
  -- A SHORT payment, in full
  -- ------------------------------------------------------------------
  -- The file above asserted the verdict and the state. It did not
  -- assert how much arrived or what the acquirer said, so a short
  -- payment could be recorded with neither and read as refused for no
  -- stated amount.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-TWO-4', pg_temp.today(), pg_temp.today(),
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Consulting', 1, 'C62', 300.00);
  perform app.post_sales_document_internal(v_doc);
  v_token := public.share_document(v_doc);
  v_pay := public.begin_shared_payment(v_token, 'billplz', 'bpz_two_3', null);

  perform pg_temp.check_eq('a short payment is refused',
    public.settle_shared_payment('billplz', 'bpz_two_3', true, 299.99,
      jsonb_build_object('x_signature', 'secret', 'acquirer_note', 'low')),
    'underpaid');
  select * into r from public.sales_gateway_payments where id = v_pay;
  perform pg_temp.check_eq('with how much actually arrived recorded',
    r.paid_amount, 299.99);
  perform pg_temp.check_true('and what the acquirer said about it kept',
    r.provider_payload ? 'acquirer_note');
  perform pg_temp.check_true('minus the signing secret, here too',
    not (r.provider_payload ? 'x_signature'));

  -- A callback with NO amount at all is short, not full. `coalesce(
  -- p_paid_amount, 0)` is the whole of that rule, and a fixture that
  -- always sends a number cannot see it.
  v_pay := public.begin_shared_payment(v_token, 'billplz', 'bpz_two_4', null);
  perform pg_temp.check_eq('a callback naming no amount is not a payment',
    public.settle_shared_payment('billplz', 'bpz_two_4', true, null),
    'underpaid');
  perform pg_temp.check_eq('and the invoice is still owed in full',
    (select balance_amount from public.sales_documents where id = v_doc),
    300.00);

  -- ------------------------------------------------------------------
  -- A DECLINE, in full
  -- ------------------------------------------------------------------
  v_pay := public.begin_shared_payment(v_token, 'billplz', 'bpz_two_5', null);
  perform pg_temp.check_eq('a decline is a decline',
    public.settle_shared_payment('billplz', 'bpz_two_5', false, 0,
      jsonb_build_object('x_signature', 'secret',
                         'failure_reason', 'insufficient_funds')),
    'not_paid');
  select * into r from public.sales_gateway_payments where id = v_pay;
  perform pg_temp.check_eq('and is recorded as failed, not left waiting',
    r.state, 'failed');
  perform pg_temp.check_true('with the acquirer''s reason kept',
    r.provider_payload ? 'failure_reason');
  perform pg_temp.check_true('and its signing secret not kept',
    not (r.provider_payload ? 'x_signature'));

  -- A callback that says NOTHING about paying is a decline, not a
  -- payment. `coalesce(p_paid, false)` is the whole of that rule.
  v_pay := public.begin_shared_payment(v_token, 'billplz', 'bpz_two_6', null);
  perform pg_temp.check_eq('silence is not consent to settle',
    public.settle_shared_payment('billplz', 'bpz_two_6', null, 300.00),
    'not_paid');
  perform pg_temp.check_eq('so the invoice is still owed',
    (select balance_amount from public.sales_documents where id = v_doc),
    300.00);

  -- ------------------------------------------------------------------
  -- A reference with whitespace, which an acquirer's form will send
  -- ------------------------------------------------------------------
  -- `bpz_two_2` is the overpayment above, which is PAID -- so the
  -- padded reference has to come back 'already_paid'. A reference that
  -- is not found comes back 'unknown', and a declined one comes back
  -- 'not_paid' however many times it is sent, so neither of those
  -- would tell a lost reference from a found one.
  perform pg_temp.check_eq('a reference arriving padded still finds its payment',
    public.settle_shared_payment('billplz', '  bpz_two_2  ', true, 250.00),
    'already_paid');

  raise notice 'ok   the second acquirer, the second currency, and the shapes between';
end $$;

-- ---------------------------------------------------------------------
-- Starting a payment, rule by rule  (`begin_shared_payment`, 0413)
--
-- Every company above runs its acquirers in sandbox, every reference
-- was typed clean, every balance was whole ringgit, and no start had a
-- checkout page -- so a start that assumed sandbox, kept a padded
-- reference, rounded the amount, or dropped or never refreshed the
-- page built the row the assertions expected. A company that has gone
-- live, on an invoice with sen in it, asks each.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_item  uuid;
  v_doc   uuid;
  v_bank  uuid;
  v_token text;
  v_pay   uuid;
begin
  v_org := pg_temp.test_org('Kedai Sudah Live Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Puan Ani', 'customer') returning id into v_cust;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SVC', 'Alterations', 'service', false, 'C62', 123.45)
  returning id into v_item;
  v_bank := pg_temp.test_bank_account(v_org, 'Maybank current');
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'production', 'sk_live', 'col_live', 'xsig_live', true);
  perform public.set_org_payment_settlement(
    v_org, 'billplz', 'production', v_bank, '03');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-LIVE-1', pg_temp.today(), pg_temp.today(),
          v_cust, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Alterations', 1, 'C62', 123.45);
  perform app.post_sales_document_internal(v_doc);
  v_token := public.share_document(v_doc);

  perform pg_temp.check_refused('an acquirer this company has not set up is not offered',
    format('select public.begin_shared_payment(%L, %L, %L, %L)',
           v_token, 'toyyibpay', 'tp_live', null),
    'That way of paying is not available.', 'P0002');
  perform pg_temp.check_refused('a blank reference is not the acquirer''s reference',
    format('select public.begin_shared_payment(%L, %L, %L, %L)',
           v_token, 'billplz', '   ', null),
    'A payment needs the acquirer''s own reference', '23514');

  v_pay := public.begin_shared_payment(
    v_token, 'billplz', '  bpz_live_1  ', 'https://www.billplz.com/bills/live_1');
  perform pg_temp.check_true('the payment is filed under the reference trimmed',
    v_pay = (select id from public.sales_gateway_payments
              where gateway_code = 'billplz' and provider_ref = 'bpz_live_1'));
  perform pg_temp.check_eq('in the mode the company runs, which is live',
    (select mode from public.sales_gateway_payments where id = v_pay), 'production');
  perform pg_temp.check_eq('for what is owed to the sen',
    (select amount from public.sales_gateway_payments where id = v_pay), 123.45);
  perform pg_temp.check_eq('with the page the customer pays on',
    (select checkout_url from public.sales_gateway_payments where id = v_pay),
    'https://www.billplz.com/bills/live_1');

  perform pg_temp.check_true('started again, it is the same payment',
    public.begin_shared_payment(
      v_token, 'billplz', 'bpz_live_1', 'https://www.billplz.com/bills/live_1b') = v_pay);
  perform pg_temp.check_eq('pointed at the newest page',
    (select checkout_url from public.sales_gateway_payments where id = v_pay),
    'https://www.billplz.com/bills/live_1b');

  -- `0773`. Switching the sandbox back on, for a test, used to leave
  -- the live keys on too: the link then offered Billplz twice, and the
  -- next payment went to whichever row the database returned first.
  perform public.set_org_payment_gateway(
    v_org, 'billplz', 'sandbox', 'sk_test', 'col_test', 'xsig_test', true);
  perform public.set_org_payment_settlement(
    v_org, 'billplz', 'sandbox', v_bank, '03');
  perform pg_temp.check_eq('with the sandbox switched on, the acquirer is offered once',
    (select count(*) from public.shared_payment_options(v_token)), 1);
  perform pg_temp.check_eq('and the payment has one mode to start in',
    (select string_agg(mode, ',') from app.shared_payment_intent(v_token, 'billplz')),
    'sandbox');
end $$;


rollback;
