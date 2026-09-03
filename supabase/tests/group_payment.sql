-- =====================================================================
-- iAkauntan :: one payment across several companies
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/group_payment.sql
--
-- A person who owns three companies is paid once. What has to come out
-- of that is three ordinary receipts -- each numbered by its own
-- company, in its own ledger, against its own bank account -- and one
-- link saying they were the same money.
--
-- The assertions that matter most are not the arithmetic:
--
--   * a member of one company reading the batch sees their own line and
--     nothing else. The batch is shared; what it points at is not.
--   * a caller without the right to post in one of the companies is
--     told *which one*.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A company with a customer, a supplier, something to sell and a bank
-- ---------------------------------------------------------------------
create or replace function pg_temp.gp_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true
    from unnest(array['sales', 'purchases', 'accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Kumpulan Awan', 'customer');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'Pembekal Bersama', 'supplier');
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Consulting', 'service', false, 100);
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current account', 'Maybank', '512345678901', 'MYR', 0, 0, true);
  return v_org;
end $$;

create or replace function pg_temp.gp_contact(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.contacts where org_id = p_org and code = p_code;
$$;

-- The company's own account, named rather than picked: a `limit 1` with
-- no order made this file take two different paths on two runs once a
-- second account existed.
create or replace function pg_temp.gp_bank(p_org uuid)
returns uuid language sql as $$
  select id from public.bank_accounts
   where org_id = p_org and is_default order by created_at limit 1;
$$;

create or replace function pg_temp.gp_invoice(
  p_org uuid, p_no text, p_amount numeric, p_post boolean default true)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'invoice', p_no, current_date, current_date,
          pg_temp.gp_contact(p_org, 'CUST'), 'MYR', 1, 'draft')
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item',
          (select id from public.items where org_id = p_org and code = 'SVC'),
          'Work done', 1, p_amount);
  if p_post then perform public.post_sales_document(v_id); end if;
  return v_id;
end $$;

create or replace function pg_temp.gp_bill(
  p_org uuid, p_no text, p_amount numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', p_no, current_date,
          pg_temp.gp_contact(p_org, 'SUP'), 'MYR', 1, 'draft')
  returning id into v_id;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (p_org, v_id, 1, 'item',
          (select id from public.items where org_id = p_org and code = 'SVC'),
          'Work bought', 1, p_amount);
  perform public.post_purchase_document(v_id);
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- The batch itself carries no money
-- ---------------------------------------------------------------------
do $$
begin
  -- Written as an assertion and not only as an apply-time guard,
  -- because it is a decision rather than a detail: a total on the
  -- shared row tells a clerk at one company what the same payer settled
  -- at another.
  perform pg_temp.check_eq(
    'the shared row holds the day and the reference and no money',
    (select count(*)::integer from information_schema.columns
      where table_schema = 'public' and table_name = 'payment_batches'
        and column_name in ('total_amount', 'amount', 'base_amount')), 0);
end $$;

-- ---------------------------------------------------------------------
-- One transfer, two companies
-- ---------------------------------------------------------------------
do $$
declare
  v_a     uuid;
  v_b     uuid;
  v_inv_a uuid;
  v_inv_b uuid;
  v_batch uuid;
  v_no_a  text;
  v_no_b  text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a := pg_temp.gp_org('Awan Satu Sdn Bhd');
  v_b := pg_temp.gp_org('Awan Dua Sdn Bhd');

  v_inv_a := pg_temp.gp_invoice(v_a, 'INV-A1', 1000);
  v_inv_b := pg_temp.gp_invoice(v_b, 'INV-B1', 2500);

  v_batch := public.record_group_payment(
    current_date, 'TT-8891',
    jsonb_build_array(
      jsonb_build_object('invoice_id', v_inv_a, 'amount', 1000,
                         'bank_account_id', pg_temp.gp_bank(v_a)),
      jsonb_build_object('invoice_id', v_inv_b, 'amount', 2500,
                         'bank_account_id', pg_temp.gp_bank(v_b))),
    'One transfer, two companies');

  perform pg_temp.check_eq('one payment becomes one receipt per company',
    (select count(*)::integer from public.receipts where batch_id = v_batch), 2);

  perform pg_temp.check_eq('the first company got its share',
    (select amount from public.receipts
      where batch_id = v_batch and org_id = v_a), 1000::numeric);
  perform pg_temp.check_eq('and the second company got its own',
    (select amount from public.receipts
      where batch_id = v_batch and org_id = v_b), 2500::numeric);

  -- Each receipt is an ordinary document in its own set of books, which
  -- is why they carry the same number: each company numbers its own.
  select receipt_no into v_no_a from public.receipts
   where batch_id = v_batch and org_id = v_a;
  select receipt_no into v_no_b from public.receipts
   where batch_id = v_batch and org_id = v_b;
  perform pg_temp.check_eq(
    'each company numbers its own receipt from its own sequence',
    v_no_a, v_no_b);

  perform pg_temp.check_eq('both receipts are posted',
    (select count(*)::integer from public.receipts
      where batch_id = v_batch and status = 'posted'
        and gl_entry_id is not null), 2);

  -- The money is in each company's own bank, not pooled anywhere.
  perform pg_temp.check_eq('the money reached the first company''s bank',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
       join public.accounts ac on ac.id = gl.account_id
       join public.receipts r on r.gl_entry_id = gl.entry_id
      where r.batch_id = v_batch and r.org_id = v_a and ac.code = '1120'),
    1000::numeric);
  perform pg_temp.check_eq('and the second company''s',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
       join public.accounts ac on ac.id = gl.account_id
       join public.receipts r on r.gl_entry_id = gl.entry_id
      where r.batch_id = v_batch and r.org_id = v_b and ac.code = '1120'),
    2500::numeric);

  perform pg_temp.check_eq('the first invoice is settled',
    (select balance_amount from public.sales_documents where id = v_inv_a),
    0::numeric);
  perform pg_temp.check_eq('and so is the second',
    (select balance_amount from public.sales_documents where id = v_inv_b),
    0::numeric);

  -- Every allocation went through 0385's function, so a discount could
  -- not have been written without a journal behind it.
  perform pg_temp.check_eq('both allocations are real allocations',
    (select count(*)::integer from public.payment_allocations pa
       join public.receipts r on r.id = pa.receipt_id
      where r.batch_id = v_batch), 2);

  -- And the two receipts are the whole payment when the person holding
  -- both companies reads it back.
  perform pg_temp.check_eq('the batch reads back as both lines',
    (select count(*)::integer from public.payment_batch_lines(v_batch)), 2);
  perform pg_temp.check_eq('adding up to what arrived',
    (select sum(amount) from public.payment_batch_lines(v_batch)),
    3500::numeric);
end $$;

-- ---------------------------------------------------------------------
-- One company only, which is the other half of the question
-- ---------------------------------------------------------------------
do $$
declare
  v_a     uuid;
  v_inv   uuid;
  v_batch uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a   := pg_temp.gp_org('Awan Tunggal Sdn Bhd');
  v_inv := pg_temp.gp_invoice(v_a, 'INV-T1', 750);

  v_batch := public.record_group_payment(
    current_date, 'TT-1',
    jsonb_build_array(
      jsonb_build_object('invoice_id', v_inv, 'amount', 750)));

  perform pg_temp.check_eq('paying one company is the same operation',
    (select count(*)::integer from public.receipts where batch_id = v_batch), 1);
  perform pg_temp.check_eq('and settles the invoice',
    (select balance_amount from public.sales_documents where id = v_inv),
    0::numeric);

  -- No bank account named. It still posts, and it posts into the
  -- company's own default account rather than to cash: a receipt with
  -- no bank account leaves the bank balance where it was, which is a
  -- reconciliation that will not reconcile.
  perform pg_temp.check_true('with no bank account named it still posts',
    (select gl_entry_id is not null from public.receipts
      where batch_id = v_batch));
  perform pg_temp.check_eq('into the company''s own default account',
    (select bank_account_id from public.receipts where batch_id = v_batch),
    pg_temp.gp_bank(v_a));
  perform pg_temp.check_eq('and the bank balance moved by what arrived',
    (select current_balance from public.bank_accounts
      where id = pg_temp.gp_bank(v_a)), 750::numeric);
end $$;

-- ---------------------------------------------------------------------
-- Bills, the same way round
-- ---------------------------------------------------------------------
do $$
declare
  v_a      uuid;
  v_b      uuid;
  v_bill_a uuid;
  v_bill_b uuid;
  v_batch  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a := pg_temp.gp_org('Bayar Satu Sdn Bhd');
  v_b := pg_temp.gp_org('Bayar Dua Sdn Bhd');

  v_bill_a := pg_temp.gp_bill(v_a, 'BILL-A1', 400);
  v_bill_b := pg_temp.gp_bill(v_b, 'BILL-B1', 600);

  v_batch := public.record_group_payment(
    current_date, 'CHQ 77',
    jsonb_build_array(
      jsonb_build_object('bill_id', v_bill_a, 'amount', 400),
      jsonb_build_object('bill_id', v_bill_b, 'amount', 600)));

  perform pg_temp.check_eq('one cheque becomes one payment per company',
    (select count(*)::integer from public.purchase_payments
      where batch_id = v_batch), 2);
  perform pg_temp.check_eq('both posted',
    (select count(*)::integer from public.purchase_payments
      where batch_id = v_batch and gl_entry_id is not null), 2);
  perform pg_temp.check_eq('the first bill is settled',
    (select balance_amount from public.purchase_documents where id = v_bill_a),
    0::numeric);
  perform pg_temp.check_eq('and the second',
    (select balance_amount from public.purchase_documents where id = v_bill_b),
    0::numeric);
end $$;

-- ---------------------------------------------------------------------
-- What it refuses
-- ---------------------------------------------------------------------
do $$
declare
  v_a     uuid;
  v_b     uuid;
  v_inv   uuid;
  v_inv2  uuid;
  v_draft uuid;
  v_inv4  uuid;
  v_bill  uuid;
  v_bank2 uuid;
  v_msg   text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a := pg_temp.gp_org('Enggan Satu Sdn Bhd');
  v_b := pg_temp.gp_org('Enggan Dua Sdn Bhd');

  v_inv   := pg_temp.gp_invoice(v_a, 'INV-E1', 1000);
  v_inv2  := pg_temp.gp_invoice(v_b, 'INV-E2', 1000);
  v_draft := pg_temp.gp_invoice(v_a, 'INV-E3', 500, false);
  v_inv4  := pg_temp.gp_invoice(v_a, 'INV-E4', 1000);
  v_bill  := pg_temp.gp_bill(v_a, 'BILL-E1', 300);

  -- Invoices and bills together. That is a contra, and contra has party
  -- checks this does not.
  begin
    perform public.record_group_payment(current_date, 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv, 'amount', 100),
        jsonb_build_object('bill_id', v_bill, 'amount', 100)));
    perform pg_temp.check_true('money owed can be set against money due', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'setting one against the other is a contra, and says so',
      v_msg like '%contra%');
  end;

  -- A draft invoice. Its receivable is not in the ledger, so clearing
  -- its balance would clear something nobody has recorded.
  begin
    perform public.record_group_payment(current_date, 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_draft, 'amount', 100)));
    perform pg_temp.check_true('a draft invoice can be paid', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a draft invoice cannot be paid',
      v_msg like '%not a posted document%');
  end;

  -- More than is outstanding, which is how a balance goes negative and
  -- a customer starts appearing as a debtor in credit.
  begin
    perform public.record_group_payment(current_date, 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv, 'amount', 1001)));
    perform pg_temp.check_true('an invoice can be over-allocated', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'more than is outstanding is refused, and the figures are named',
      v_msg like '%More than is outstanding%' and v_msg like '%INV-E1%');
  end;

  -- The same invoice on two lines. It would add up, and it would also
  -- be somebody about to make a mistake.
  begin
    perform public.record_group_payment(current_date, 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv, 'amount', 400),
        jsonb_build_object('invoice_id', v_inv, 'amount', 600)));
    perform pg_temp.check_true('one document can be on two lines', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('one document, one line',
      v_msg like '%twice%');
  end;

  -- Another company's bank account. This is the one that would move
  -- money between two sets of books without anybody saying so.
  begin
    perform public.record_group_payment(current_date, 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv, 'amount', 100,
                           'bank_account_id', pg_temp.gp_bank(v_b))));
    perform pg_temp.check_true(
      'a receipt can land in another company''s bank', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'the bank account has to be the paid company''s',
      v_msg like '%belongs to another company%');
  end;

  -- Two bank accounts for one company's share of the payment. One
  -- company, one receipt, one place the money landed.
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_a,
          (select id from public.accounts where org_id = v_a and code = '1120'),
          'Second account', 'CIMB', '700000000001', 'MYR', 0, 0, false)
  returning id into v_bank2;

  begin
    perform public.record_group_payment(current_date, 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv, 'amount', 100,
                           'bank_account_id', pg_temp.gp_bank(v_a)),
        jsonb_build_object('invoice_id', v_inv4, 'amount', 100,
                           'bank_account_id', v_bank2)));
    perform pg_temp.check_true(
      'one company''s share can land in two banks at once', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'one company''s share lands in one bank account',
      v_msg like '%one bank account%');
  end;

  -- Nothing at all.
  begin
    perform public.record_group_payment(current_date, 'X', '[]'::jsonb);
    perform pg_temp.check_true('a payment can settle nothing', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a payment settles something',
      v_msg like '%settles something%');
  end;

  -- A line naming neither document.
  begin
    perform public.record_group_payment(current_date, 'X',
      jsonb_build_array(jsonb_build_object('amount', 100)));
    perform pg_temp.check_true('a line can name no document', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('every line names one document',
      v_msg like '%one invoice or one bill%');
  end;

  -- Nothing survived any of that. Every attempt in this block carried
  -- the reference 'X', so the payments recorded further up the file are
  -- not what is being counted.
  perform pg_temp.check_eq('and none of the refusals left a batch behind',
    (select count(*)::integer from public.payment_batches
      where reference = 'X'), 0);
end $$;

-- ---------------------------------------------------------------------
-- Being told which company said no
-- ---------------------------------------------------------------------
do $$
declare
  v_a     uuid;
  v_b     uuid;
  v_inv_a uuid;
  v_inv_b uuid;
  v_who   uuid;
  v_msg   text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a := pg_temp.gp_org('Hak Satu Sdn Bhd');
  v_b := pg_temp.gp_org('Hak Dua Sdn Bhd');
  v_inv_a := pg_temp.gp_invoice(v_a, 'INV-H1', 300);
  v_inv_b := pg_temp.gp_invoice(v_b, 'INV-H2', 300);

  -- An accountant at the first company who is only allowed to look at
  -- the second.
  v_who := pg_temp.another_user('clerk-0462@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_who, 'accountant', 'active', now()),
         (v_b, v_who, 'viewer', 'active', now());

  perform pg_temp.sign_in_as(v_who);

  begin
    perform public.record_group_payment(current_date, 'TT-9',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv_a, 'amount', 300),
        jsonb_build_object('invoice_id', v_inv_b, 'amount', 300)));
    perform pg_temp.check_true(
      'a viewer at one company can be paid there', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    -- The point of checking every company before writing anything is
    -- not atomicity -- one call is one transaction either way. It is
    -- that the refusal can name the company. Reached through
    -- `post_receipt` instead, the message is 'Insufficient privileges
    -- to post' and the operator has three companies and no idea which.
    perform pg_temp.check_true(
      'the refusal names the company that has no rights in it',
      v_msg like '%Hak Dua Sdn Bhd%');
  end;

  -- The company they can post in, on its own, still works.
  perform pg_temp.check_true('and what they can do, they can still do',
    public.record_group_payment(current_date, 'TT-10',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv_a, 'amount', 300)))
    is not null);

  -- And the other way round, which is what makes this an assertion
  -- about the LOOP rather than about one company.
  --
  -- `for v_org in select distinct org_id from pg_temp._gp loop` visits
  -- every company. Cut it to `limit 1` and it visits one, chosen by
  -- whatever order the scan happens to produce -- and the probe above
  -- passes or fails depending on which. It was caught by a mutation
  -- sweep, and then SURVIVED the same sweep after unrelated fixtures
  -- were added further down this file and the ordering changed.
  --
  -- Asserted from both ends, one company cannot satisfy both: whichever
  -- one is visited, the other is the one being refused for.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  -- Fresh documents: INV-H1 was settled by TT-10 just above, and a
  -- settled invoice is refused for being over-allocated rather than for
  -- the rights this probe is about.
  v_inv_a := pg_temp.gp_invoice(v_a, 'INV-H3', 300);
  v_inv_b := pg_temp.gp_invoice(v_b, 'INV-H4', 300);
  update public.org_members set role = 'viewer'
   where org_id = v_a and user_id = v_who;
  update public.org_members set role = 'accountant'
   where org_id = v_b and user_id = v_who;
  perform pg_temp.sign_in_as(v_who);

  begin
    perform public.record_group_payment(current_date, 'TT-11',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv_a, 'amount', 300),
        jsonb_build_object('invoice_id', v_inv_b, 'amount', 300)));
    raise exception 'a viewer at the first company was paid there';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'and names the first company when that is the one without rights',
      v_msg like '%Hak Satu Sdn Bhd%');
  end;
end $$;

-- ---------------------------------------------------------------------
-- What the other company's staff can see of it
-- ---------------------------------------------------------------------
do $$
declare
  v_a     uuid;
  v_b     uuid;
  v_batch uuid;
  v_staff uuid;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a := pg_temp.gp_org('Lihat Satu Sdn Bhd');
  v_b := pg_temp.gp_org('Lihat Dua Sdn Bhd');

  v_batch := public.record_group_payment(
    current_date, 'TT-55',
    jsonb_build_array(
      jsonb_build_object('invoice_id', pg_temp.gp_invoice(v_a, 'INV-L1', 100),
                         'amount', 100),
      jsonb_build_object('invoice_id', pg_temp.gp_invoice(v_b, 'INV-L2', 900),
                         'amount', 900)));

  -- Somebody who works at the first company and nowhere else.
  v_staff := pg_temp.another_user('staff-0462@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_staff, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_staff);

  perform pg_temp.check_eq('a member of one company sees one line',
    (select count(*)::integer from public.payment_batch_lines(v_batch)), 1);
  perform pg_temp.check_eq('and it is their own',
    (select org_id from public.payment_batch_lines(v_batch)), v_a);
  perform pg_temp.check_eq(
    'so the other company''s figure is not readable through the batch',
    (select sum(amount) from public.payment_batch_lines(v_batch)),
    100::numeric);

  -- The batch row itself is readable -- it is how their receipt says it
  -- was part of something larger -- and it carries nothing but the day
  -- and the bank reference, which is why reading it discloses nothing.
  execute 'set local role authenticated';
  select count(*)::integer into v_n from public.payment_batches
   where id = v_batch;
  execute 'reset role';
  perform pg_temp.check_eq(
    'the shared row is readable by the company holding a line on it',
    v_n, 1);
end $$;

-- ---------------------------------------------------------------------
-- The list a group payment is chosen from
-- ---------------------------------------------------------------------
do $$
declare
  v_a     uuid;
  v_b     uuid;
  v_c     uuid;
  v_staff uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a := pg_temp.gp_org('Senarai Satu Sdn Bhd');
  v_b := pg_temp.gp_org('Senarai Dua Sdn Bhd');
  v_c := pg_temp.gp_org('Senarai Tiga Sdn Bhd');
  perform pg_temp.gp_invoice(v_a, 'INV-S1', 100);
  perform pg_temp.gp_invoice(v_b, 'INV-S2', 200);
  perform pg_temp.gp_invoice(v_c, 'INV-S3', 300);
  perform pg_temp.gp_invoice(v_a, 'INV-S4', 400, false);

  perform pg_temp.check_eq(
    'the owner of three companies sees what is open in all three',
    (select count(*)::integer
       from public.open_documents_across_companies('invoice')
      where doc_no like 'INV-S%'), 3);
  perform pg_temp.check_true('and a draft is not on the list',
    not exists (select 1 from public.open_documents_across_companies('invoice')
                 where doc_no = 'INV-S4'));

  -- Somebody who may only look. They can read the invoice on the
  -- invoices screen; they cannot settle it, so it is not on this list.
  v_staff := pg_temp.another_user('looker-0462@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_a, v_staff, 'viewer', 'active', now()),
         (v_b, v_staff, 'accountant', 'active', now());
  perform pg_temp.sign_in_as(v_staff);

  perform pg_temp.check_eq(
    'the list is what you may settle, not what you may see',
    (select count(*)::integer
       from public.open_documents_across_companies('invoice')
      where doc_no like 'INV-S%'), 1);
  perform pg_temp.check_eq('and it is the company they may post in',
    (select doc_no from public.open_documents_across_companies('invoice')
      where doc_no like 'INV-S%'), 'INV-S2');
end $$;


-- ---------------------------------------------------------------------
-- The ten a mutation sweep found
-- ---------------------------------------------------------------------
-- Twenty-five one-line mutants of `record_group_payment`; ten survived
-- everything this file and seven others asserted. Three shapes account
-- for all of them, and each is the kind of thing that reads as covered.
--
--   * THE SECOND BRANCH. This function is written twice -- receipts for
--     invoices, purchase payments for bills -- and the bill half was
--     asserted for what it settles but not for the date it settles on
--     or the discount it carries. Two near-duplicate branches is where
--     a fault lives longest, and `create_contra` had exactly the same
--     shape.
--
--   * THE DISCOUNT. `amount + discount` is what a document is being
--     asked to accept, and `amount` alone is what leaves the payer's
--     bank. Three mutants live in the gap between the two, and all
--     three cost money: the balance check reading only `amount` lets a
--     document be over-settled, and dropping the discount from either
--     allocation leaves an invoice open by exactly the discount the
--     customer was told they had.
--
--   * FOREIGN CURRENCY. Nothing in this file was in anything but
--     ringgit, so `v_rate` could be set to 1 outright and every
--     assertion still held. A receipt for USD 1,000 taken at par
--     records RM 1,000 against a receivable of RM 4,700.
do $$
declare
  v_a      uuid;
  v_b      uuid;
  v_inv    uuid;
  v_inv2   uuid;
  v_bill   uuid;
  v_term   uuid;
  v_usd    uuid;
  v_myr    uuid;
  v_batch  uuid;
  v_msg    text;
  v_when   date := (date_trunc('month', app.today()) - interval '1 day')::date;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_a := pg_temp.gp_org('Sapu Satu Sdn Bhd');
  v_b := pg_temp.gp_org('Sapu Dua Sdn Bhd');
  perform public.create_fiscal_year(v_a,
    (date_trunc('year', app.today()) - interval '1 year')::date);

  -- Terms that actually offer a settlement discount. Without one,
  -- allocate_with_discount refuses the discount outright -- which is
  -- correct, and would have made the three discount probes below assert
  -- that rule instead of the ones they are about.
  insert into public.payment_terms
    (org_id, code, name, days, term_type, discount_percent, discount_days)
  values (v_a, '10-30', '10% in 30 days', 30, 'net', 10, 30)
  returning id into v_term;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, payment_term_id)
  values (v_a, 'invoice', 'INV-Z1', app.today(), app.today(),
          pg_temp.gp_contact(v_a, 'CUST'), 'MYR', 1, 'draft', v_term)
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_a, v_inv, 1, 'item',
          (select id from public.items where org_id = v_a and code = 'SVC'),
          'Work done', 1, 1000);
  perform public.post_sales_document(v_inv);

  v_inv2 := pg_temp.gp_invoice(v_a, 'INV-Z2', 1000);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, payment_term_id)
  values (v_a, 'bill', 'BILL-Z1', app.today(),
          pg_temp.gp_contact(v_a, 'SUP'), 'MYR', 1, 'draft', v_term)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_a, v_bill, 1, 'item',
          (select id from public.items where org_id = v_a and code = 'SVC'),
          'Work bought', 1, 400);
  perform public.post_purchase_document(v_bill);

  -- ==================================================================
  -- 1. A payment happened on a day
  -- ==================================================================
  begin
    perform public.record_group_payment(null, 'X',
      jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 100)));
    raise exception 'a payment was recorded on no day at all';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a payment with no date is refused',
      v_msg, 'A payment happened on a day.');
  end;

  -- ==================================================================
  -- 2. An allocation is of something
  --
  -- Nought settles nothing and adds nothing; a negative one takes money
  -- back out of a document while the payer's bank shows it going in.
  -- ==================================================================
  begin
    perform public.record_group_payment(app.today(), 'X',
      jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 0)));
    raise exception 'an allocation of nothing was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('an allocation of nothing is refused',
      v_msg, 'An allocation is of something.');
  end;

  begin
    perform public.record_group_payment(app.today(), 'X',
      jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', -100)));
    raise exception 'a negative allocation was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('and so is one for less than nothing',
      v_msg, 'An allocation is of something.');
  end;

  -- ==================================================================
  -- 3. A document that is not there
  --
  -- The count check exists because the join simply drops a row it
  -- cannot match: without it, a payment naming five documents and
  -- finding four would settle the four and say nothing about the fifth.
  -- ==================================================================
  begin
    perform public.record_group_payment(app.today(), 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_inv, 'amount', 100),
        jsonb_build_object('invoice_id', gen_random_uuid(), 'amount', 100)));
    raise exception 'a payment named a document that does not exist';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a document that is not there is refused',
      v_msg, 'A document on this payment does not exist.');
  end;

  -- ==================================================================
  -- 4. What a document is asked to accept is the cash AND the discount
  --
  -- The first of the three discount gaps, and the one that lets a
  -- balance go negative. An invoice owing a thousand, offered a
  -- thousand in cash and a hundred in settlement discount, is being
  -- asked to accept eleven hundred.
  -- ==================================================================
  begin
    perform public.record_group_payment(app.today(), 'X',
      jsonb_build_array(jsonb_build_object(
        'invoice_id', v_inv, 'amount', 1000, 'discount', 100)));
    raise exception
      'a document accepted more than it owed once a discount was added';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'the discount counts towards what the document is asked to accept',
      v_msg like 'More than is outstanding: INV-Z1 owes 1,000.00 and is offered 1,100.00.');
  end;

  -- ==================================================================
  -- 5. And the discount actually reaches the allocation
  --
  -- Cash of nine hundred and a discount of a hundred settles a thousand
  -- in full. Drop the discount on the way to `allocate_with_discount`
  -- and the invoice stays open for exactly the hundred the customer was
  -- told they had -- which is then chased, and is not owed.
  -- ==================================================================
  v_batch := public.record_group_payment(app.today(), 'DISC-1',
    jsonb_build_array(jsonb_build_object(
      'invoice_id', v_inv, 'amount', 900, 'discount', 100)));
  perform pg_temp.check_eq(
    'cash and discount together settle the invoice in full',
    (select balance_amount from public.sales_documents where id = v_inv),
    0::numeric);
  perform pg_temp.check_eq('and the receipt is for the cash alone',
    (select amount from public.receipts where batch_id = v_batch),
    900::numeric);

  -- The same on the bill side, which had no discount assertion at all.
  v_batch := public.record_group_payment(app.today(), 'DISC-2',
    jsonb_build_array(jsonb_build_object(
      'bill_id', v_bill, 'amount', 360, 'discount', 40)));
  perform pg_temp.check_eq(
    'and a supplier''s discount settles the bill in full',
    (select balance_amount from public.purchase_documents where id = v_bill),
    0::numeric);
  perform pg_temp.check_eq('with the payment for the cash alone',
    (select amount from public.purchase_payments where batch_id = v_batch),
    360::numeric);

  -- ==================================================================
  -- 6. The day the money moved, on both sides
  --
  -- Every call in this file passed `current_date`, so `p_paid_on` could
  -- be replaced by `app.today()` in either branch and nothing moved. A
  -- transfer that cleared on the last day of a month belongs in that
  -- month: app.guard_period_lock and report_trial_balance both read the
  -- journal's entry_date, and so does every ageing.
  -- ==================================================================
  perform pg_temp.check_true('and the day it cleared is not today',
    v_when <> app.today());

  v_batch := public.record_group_payment(v_when, 'DATE-1',
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv2, 'amount', 1000)));
  perform pg_temp.check_true('a receipt is dated the day the money cleared',
    (select r.receipt_date = v_when from public.receipts r
      where r.batch_id = v_batch));
  perform pg_temp.check_true('and so is the journal behind it',
    (select e.entry_date = v_when
       from public.gl_entries e
       join public.receipts r on r.gl_entry_id = e.id
      where r.batch_id = v_batch));

  v_bill := pg_temp.gp_bill(v_a, 'BILL-Z2', 250);
  v_batch := public.record_group_payment(v_when, 'DATE-2',
    jsonb_build_array(jsonb_build_object('bill_id', v_bill, 'amount', 250)));
  perform pg_temp.check_true('a supplier payment likewise',
    (select p.payment_date = v_when from public.purchase_payments p
      where p.batch_id = v_batch));
  perform pg_temp.check_true('and its journal',
    (select e.entry_date = v_when
       from public.gl_entries e
       join public.purchase_payments p on p.gl_entry_id = e.id
      where p.batch_id = v_batch));

  -- ==================================================================
  -- 7. A foreign receipt at the day's rate, not at par
  --
  -- Nothing in this file was in anything but ringgit, so `v_rate` could
  -- be set to 1 outright and every assertion above still held. USD
  -- 1,000 at 4.70 is a receivable of RM 4,700; taken at par it is
  -- RM 1,000, and the difference lands as an unexplained balance on the
  -- receivable that no reconciliation will clear.
  -- ==================================================================
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_a, 'USD', 'MYR', 4.70, app.today() - 7, 'manual');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_a, 'invoice', 'INV-USD', app.today(), app.today(),
          pg_temp.gp_contact(v_a, 'CUST'), 'USD', 4.70, 'draft')
  returning id into v_usd;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_a, v_usd, 1, 'item',
          (select id from public.items where org_id = v_a and code = 'SVC'),
          'Exported work', 1, 1000);
  perform public.post_sales_document(v_usd);

  v_batch := public.record_group_payment(app.today(), 'FX-1',
    jsonb_build_array(jsonb_build_object('invoice_id', v_usd, 'amount', 1000)));

  perform pg_temp.check_eq('a foreign receipt is taken at the day''s rate',
    (select exchange_rate from public.receipts where batch_id = v_batch),
    4.70::numeric);
  perform pg_temp.check_eq('and the ringgit that reached the bank says so',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
       join public.accounts ac on ac.id = gl.account_id
       join public.receipts r on r.gl_entry_id = gl.entry_id
      where r.batch_id = v_batch and ac.code = '1120'),
    4700::numeric);

  -- ==================================================================
  -- 8. One company's share, one currency
  --
  -- The receipt carries a single rate, so two currencies under one
  -- company and one contact would have to strike an average nobody
  -- agreed. Refused rather than averaged.
  -- ==================================================================
  v_myr := pg_temp.gp_invoice(v_a, 'INV-Z3', 500);
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_a, 'invoice', 'INV-USD2', app.today(), app.today(),
          pg_temp.gp_contact(v_a, 'CUST'), 'USD', 4.70, 'draft')
  returning id into v_usd;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_a, v_usd, 1, 'item',
          (select id from public.items where org_id = v_a and code = 'SVC'),
          'More exported work', 1, 200);
  perform public.post_sales_document(v_usd);

  begin
    perform public.record_group_payment(app.today(), 'X',
      jsonb_build_array(
        jsonb_build_object('invoice_id', v_myr, 'amount', 500),
        jsonb_build_object('invoice_id', v_usd, 'amount', 200)));
    raise exception 'one receipt covered two currencies';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'one company''s share of a payment is in one currency',
      v_msg,
      'One company''s share of this payment is in two currencies. A '
      'receipt is in one, and the rate belongs to it.');
  end;

  -- None of the refusals in this block left anything behind.
  perform pg_temp.check_eq('and no refusal wrote a batch',
    (select count(*)::integer from public.payment_batches
      where reference = 'X'), 0);

  raise notice 'ok   group payment: the ten a sweep found';
end $$;

rollback;
