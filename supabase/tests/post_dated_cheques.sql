-- =====================================================================
-- The cheque dated next month
--
-- One assertion matters more than the rest: the bank balance does not
-- move. A post-dated cheque recorded as a receipt puts six weeks of
-- money into the bank on the day it is handed over, and every cash flow
-- decision taken on that balance is wrong by the whole post-dated book.
--
-- The rest: the receivable going when the cheque is handed over, the
-- money arriving only when it clears, a bounce putting the invoice back
-- into the aged listing, a cheque that could be banked today being
-- refused, and the maturity list finding the one somebody forgot.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_cust   uuid;
  v_sup    uuid;
  v_item   uuid;
  v_bank   uuid;
  v_bank_a uuid;

  v_inv    uuid;
  v_bill   uuid;
  v_pdc    uuid;
  v_out    uuid;
  v_entry  uuid;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Perniagaan Cek Lambat Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'A contractor', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'A merchant', 'supplier') returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'KERJA', 'Work done', 'service', false, 1)
  returning id into v_item;

  select id into v_bank_a from public.accounts where org_id = v_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org, v_bank_a, 'Current account', 'Maybank', '512345678901',
          'MYR', 0, 0, true)
  returning id into v_bank;

  -- Forty thousand of work, invoiced.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Work', 40000, 1);
  perform public.post_sales_document(v_inv);

  -- ------------------------------------------------------------------
  -- 1. The assertion this migration is built around
  -- ------------------------------------------------------------------
  v_pdc := public.record_pdc(
    v_org, 'incoming', v_cust, '123456', current_date + 45, 40000,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 40000)),
    v_bank, 'CIMB', current_date, 'Dated the fifteenth of next month');

  perform pg_temp.check_eq(
    'the bank balance has not moved, because no money has arrived',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    0::numeric);
  select c.gl_entry_id into v_entry
    from public.post_dated_cheques c where c.id = v_pdc;
  perform pg_temp.check_eq('and nothing was posted to the bank account',
    (select count(*) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1120'), 0::numeric);

  -- But he has discharged the debt with a negotiable instrument, so the
  -- receivable goes and the aged listing stops chasing him.
  perform pg_temp.check_eq('the invoice is settled',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    0::numeric);
  perform pg_temp.check_eq('and says so',
    (select d.status::text from public.sales_documents d where d.id = v_inv),
    'completed');
  perform pg_temp.check_eq('the receivable is credited',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1210'), 40000::numeric);
  perform pg_temp.check_eq('and it is sitting in cheques on hand',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1140'), 40000::numeric);
  perform pg_temp.check_eq('1140 is an asset, and a current one',
    (select a.account_subtype::text from public.accounts a
      where a.org_id = v_org and a.code = '1140'), 'current_asset');

  -- ------------------------------------------------------------------
  -- 2. Banking it is not clearing it
  -- ------------------------------------------------------------------
  perform public.deposit_pdc(v_pdc, current_date + 44);
  perform pg_temp.check_eq('paid in',
    (select c.status::text from public.post_dated_cheques c where c.id = v_pdc),
    'deposited');
  perform pg_temp.check_eq(
    'and still not in the bank, because it has not cleared',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    0::numeric);

  -- ------------------------------------------------------------------
  -- 3. Now it is money
  -- ------------------------------------------------------------------
  v_entry := public.clear_pdc(v_pdc, current_date + 46);
  perform pg_temp.check_eq('the bank has it at last',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    40000::numeric);
  perform pg_temp.check_eq('debited to the bank',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1120'), 40000::numeric);
  perform pg_temp.check_eq('out of cheques on hand',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1140'), 40000::numeric);
  perform pg_temp.check_eq('and 1140 is empty again',
    (select round(coalesce(sum(gl.debit - gl.credit), 0), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where a.org_id = v_org and a.code = '1140'), 0::numeric);

  -- ------------------------------------------------------------------
  -- 4. One that bounces puts the invoice back
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-2', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'More work', 5000, 1);
  perform public.post_sales_document(v_inv);

  v_pdc := public.record_pdc(
    v_org, 'incoming', v_cust, '123457', current_date + 30, 5000,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 5000)),
    v_bank, 'CIMB');
  perform pg_temp.check_eq('settled again, for now',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    0::numeric);

  v_entry := public.bounce_pdc(v_pdc, 'Refer to drawer', current_date + 31);

  perform pg_temp.check_eq('he owes it again',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    5000::numeric);
  -- This is the one that would have failed silently before 0272: a
  -- fully unallocated document used to keep saying `completed`, which
  -- would have dropped a bounced cheque out of the chasing for ever.
  perform pg_temp.check_eq('and is back in the aged listing, not marked paid',
    (select d.status::text from public.sales_documents d where d.id = v_inv),
    'posted');
  perform pg_temp.check_eq('the receivable is debited back',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1210'), 5000::numeric);
  perform pg_temp.check_eq('and the cheques account emptied',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1140'), 5000::numeric);
  perform pg_temp.check_eq('the reason is kept, because it decides what next',
    (select c.bounce_reason from public.post_dated_cheques c where c.id = v_pdc),
    'Refer to drawer');
  perform pg_temp.check_eq('and the bank never saw any of it',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    40000::numeric);

  -- ------------------------------------------------------------------
  -- 5. The other direction: one we write
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Materials', 8000, 1);
  perform public.post_purchase_document(v_bill);

  v_out := public.record_pdc(
    v_org, 'outgoing', v_sup, '990001', current_date + 60, 8000,
    jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 8000)),
    v_bank, 'Maybank');
  select c.gl_entry_id into v_entry
    from public.post_dated_cheques c where c.id = v_out;

  perform pg_temp.check_eq('the bill is settled by the cheque we wrote',
    (select d.balance_amount from public.purchase_documents d where d.id = v_bill),
    0::numeric);
  perform pg_temp.check_eq('the payable is debited',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2110'), 8000::numeric);
  perform pg_temp.check_eq('and what we owe is now a cheque outstanding',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2115'), 8000::numeric);
  perform pg_temp.check_eq('2115 is a liability',
    (select a.account_type::text from public.accounts a
      where a.org_id = v_org and a.code = '2115'), 'liability');
  perform pg_temp.check_eq('and the bank still has what it had',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    40000::numeric);

  perform public.clear_pdc(v_out, current_date + 61);
  perform pg_temp.check_eq('until he presents it',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    32000::numeric);

  -- ------------------------------------------------------------------
  -- 6. The morning list
  -- ------------------------------------------------------------------
  --
  -- One dated a week out and one whose date went by while nobody was
  -- looking. The second is the whole reason to read this list.
  perform public.record_pdc(
    v_org, 'incoming', v_cust, '123458', current_date + 7, 100,
    '[]'::jsonb, v_bank, 'CIMB');
  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date,
     amount, received_on, bank_account_id)
  values (v_org, 'PDC-FORGOTTEN', 'incoming', v_cust, '123459',
          current_date - 5, 250, current_date - 40, v_bank);

  perform pg_temp.check_eq('the week ahead has one in it',
    (select count(*) from public.pdc_maturing(v_org, current_date, current_date + 7)
      where not overdue), 1::numeric);
  perform pg_temp.check_eq('and the one nobody banked is on it too',
    (select count(*) from public.pdc_maturing(v_org, current_date, current_date + 7)
      where overdue), 1::numeric);
  perform pg_temp.check_eq('a cleared cheque is not on the list at all',
    (select count(*) from public.pdc_maturing(v_org, current_date - 90, current_date + 90)
      where status = 'cleared'), 0::numeric);

  -- ------------------------------------------------------------------
  -- 7. What it refuses
  -- ------------------------------------------------------------------
  begin
    perform public.record_pdc(
      v_org, 'incoming', v_cust, '123460', current_date, 100,
      '[]'::jsonb, v_bank);
    perform pg_temp.check_true('a cheque dated today is post-dated', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a cheque that can be banked today is a receipt, not this',
      v_msg like '%is a receipt, not a post-dated cheque%');
  end;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-3', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Work', 3000, 1);
  perform public.post_sales_document(v_inv);

  begin
    perform public.record_pdc(
      v_org, 'incoming', v_cust, '123461', current_date + 10, 3000,
      jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 1000)),
      v_bank);
    perform pg_temp.check_true('a cheque can half-settle and half-float', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a cheque settling less than its face value is two facts as one',
      v_msg like '%two facts pretending to be one%');
  end;

  begin
    perform public.record_pdc(
      v_org, 'incoming', v_cust, '123462', current_date + 10, 3000,
      jsonb_build_array(jsonb_build_object('document', v_bill, 'amount', 3000)),
      v_bank);
    perform pg_temp.check_true('an incoming cheque can settle our own bill', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an incoming cheque settles an invoice',
      v_msg like '%No such invoice%');
  end;

  v_pdc := public.record_pdc(
    v_org, 'incoming', v_cust, '123463', current_date + 10, 3000,
    jsonb_build_array(jsonb_build_object('document', v_inv, 'amount', 3000)),
    v_bank);
  begin
    perform public.bounce_pdc(v_pdc, '   ');
    perform pg_temp.check_true('a bounce with no reason is allowed', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a bounce says why, because it decides what next',
      v_msg like '%Say why%');
  end;

  -- Handed back before anything happened to it: the entry is reversed
  -- and the invoice is outstanding again.
  perform public.cancel_pdc(v_pdc, 'He asked for it back and paid cash');
  perform pg_temp.check_eq('a cancelled cheque leaves the invoice owing',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    3000::numeric);
  perform pg_temp.check_eq('and nothing is left in cheques on hand for it',
    (select count(*) from public.payment_allocations a where a.pdc_id = v_pdc),
    0::numeric);

  begin
    perform public.clear_pdc(v_pdc);
    perform pg_temp.check_true('a cancelled cheque can still clear', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a cancelled cheque cannot clear',
      v_msg like '%is cancelled%');
  end;

  raise notice 'ok   post_dated_cheques';
end $$;

rollback;
