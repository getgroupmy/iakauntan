-- =====================================================================
-- Money before there is anything to bill
--
-- One assertion matters more than the rest: a customer's deposit is a
-- liability. Until now the only place to put it was an unapplied
-- receipt, and a receipt credits Accounts Receivable — so a customer
-- who owes nothing appeared in the aged listing in credit, and money
-- the company would have to give back never showed on the balance sheet
-- as owed to anybody.
--
-- The rest: the deposit being drawn down over two invoices, the
-- remainder given back, a forfeited customer deposit becoming income
-- while one we lose becomes an expense, and the balance being
-- recomputed rather than counted down.
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

  v_dep    uuid;
  v_dep2   uuid;
  v_inv    uuid;
  v_inv2   uuid;
  v_bill   uuid;
  v_entry  uuid;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Dapur Impian Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Puan Salmah', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'Kilang Kabinet', 'supplier') returning id into v_sup;

  -- A service, so this file is about the money and nothing else.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'DAPUR', 'Fitted kitchen', 'service', false, 1000)
  returning id into v_item;

  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current account', 'Maybank', '512345678901', 'MYR', 0, 0, true)
  returning id into v_bank;

  -- ------------------------------------------------------------------
  -- 1. The assertion this migration is built around
  -- ------------------------------------------------------------------
  --
  -- Ten thousand up front for a kitchen that does not exist yet.
  v_dep := public.create_deposit(
    v_org, 'customer', v_cust, current_date, 10000, v_bank, '02', 'CHQ 44',
    'Half up front');

  select n.gl_entry_id into v_entry from public.deposit_notes n where n.id = v_dep;

  perform pg_temp.check_eq('the bank has the money',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1120'), 10000::numeric);
  perform pg_temp.check_eq(
    'and it is owed back to her, as a liability',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2125'), 10000::numeric);
  perform pg_temp.check_eq(
    'not sitting in receivables making her look like a debtor in credit',
    (select count(*) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1210'), 0::numeric);
  perform pg_temp.check_eq('2125 is a liability, and says so',
    (select a.account_type::text from public.accounts a
      where a.org_id = v_org and a.code = '2125'), 'liability');
  perform pg_temp.check_eq('the bank balance moved with it',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    10000::numeric);
  perform pg_temp.check_eq('and all of it is still there to use',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    10000::numeric);

  -- ------------------------------------------------------------------
  -- 2. Drawn down over two invoices
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Stage one', 6, 1000);
  perform public.post_sales_document(v_inv);

  v_entry := public.apply_deposit(v_dep, v_inv, 6000);

  perform pg_temp.check_eq('the invoice is settled by the deposit',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    0::numeric);
  perform pg_temp.check_eq('and says so, without a receipt ever being written',
    (select d.status::text from public.sales_documents d where d.id = v_inv),
    'completed');
  perform pg_temp.check_eq('the liability is discharged by that much',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2125'), 6000::numeric);
  perform pg_temp.check_eq('and the receivable with it',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1210'), 6000::numeric);
  perform pg_temp.check_eq('four thousand is left',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    4000::numeric);
  perform pg_temp.check_eq('and the note is still open',
    (select n.status::text from public.deposit_notes n where n.id = v_dep),
    'open');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-2', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv2;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv2, 1, 'item', v_item, 'Stage two', 3, 1000);
  perform public.post_sales_document(v_inv2);

  perform public.apply_deposit(v_dep, v_inv2, 3000);
  perform pg_temp.check_eq('one thousand left after the second',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    1000::numeric);
  perform pg_temp.check_eq('and what she has drawn is what was applied',
    (select n.applied_amount from public.deposit_notes n where n.id = v_dep),
    9000::numeric);

  -- ------------------------------------------------------------------
  -- 3. The remainder given back
  -- ------------------------------------------------------------------
  v_entry := public.settle_deposit(v_dep, 'refund', 1000, null, v_bank);
  perform pg_temp.check_eq('the money leaves the bank',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1120'), 1000::numeric);
  perform pg_temp.check_eq('the bank balance is what is left of it',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    9000::numeric);
  perform pg_temp.check_eq('nothing of the deposit is left',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    0::numeric);
  perform pg_temp.check_eq('and the note is settled',
    (select n.status::text from public.deposit_notes n where n.id = v_dep),
    'settled');
  perform pg_temp.check_eq('nothing is owed back to her any more',
    (select round(coalesce(sum(gl.credit - gl.debit), 0), 2)
       from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where a.org_id = v_org and a.code = '2125'), 0::numeric);

  -- ------------------------------------------------------------------
  -- 4. Kept rather than given back
  -- ------------------------------------------------------------------
  v_dep2 := public.create_deposit(
    v_org, 'customer', v_cust, current_date, 500, v_bank, null, null, null);
  v_entry := public.settle_deposit(
    v_dep2, 'forfeit', 500, 'She cancelled inside the fortnight');
  perform pg_temp.check_eq('a forfeited deposit is income',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '4930'), 500::numeric);
  perform pg_temp.check_eq('and 4930 is revenue, not a negative expense',
    (select a.account_type::text from public.accounts a
      where a.org_id = v_org and a.code = '4930'), 'revenue');
  perform pg_temp.check_eq('the reason is kept with it',
    (select e.reason from public.deposit_events e where e.deposit_id = v_dep2),
    'She cancelled inside the fortnight');

  begin
    perform public.settle_deposit(
      public.create_deposit(v_org, 'customer', v_cust, current_date, 100,
                            v_bank, null, null, null),
      'forfeit', 100, '  ');
    perform pg_temp.check_true('a deposit can be kept for no reason', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and not without saying why',
      v_msg like '%Say why%');
  end;

  -- ------------------------------------------------------------------
  -- 5. The other direction: money we paid a supplier
  -- ------------------------------------------------------------------
  v_dep2 := public.create_deposit(
    v_org, 'supplier', v_sup, current_date, 2000, v_bank, null, null,
    'Before he books the container');
  select n.gl_entry_id into v_entry from public.deposit_notes n where n.id = v_dep2;

  perform pg_temp.check_eq('a deposit we paid is an asset, not an expense',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1235'), 2000::numeric);
  perform pg_temp.check_eq('and 1235 is an asset',
    (select a.account_type::text from public.accounts a
      where a.org_id = v_org and a.code = '1235'), 'asset');

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Cabinets', 5, 1000);
  perform public.post_purchase_document(v_bill);

  v_entry := public.apply_deposit(v_dep2, v_bill, 2000);
  perform pg_temp.check_eq('the bill is three thousand lighter',
    (select d.balance_amount from public.purchase_documents d where d.id = v_bill),
    3000::numeric);
  perform pg_temp.check_eq('the payable is debited by what was already paid',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '2110'), 2000::numeric);
  perform pg_temp.check_eq('and the asset is used up',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1235'), 2000::numeric);

  -- A deposit we pay and lose is our loss, not our income.
  v_dep2 := public.create_deposit(
    v_org, 'supplier', v_sup, current_date, 300, v_bank, null, null, null);
  v_entry := public.settle_deposit(
    v_dep2, 'forfeit', 300, 'He went under owing it');
  perform pg_temp.check_eq('a deposit we lose is an expense',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '6610'), 300::numeric);
  perform pg_temp.check_eq('and it is an expense, not negative income',
    (select a.account_type::text from public.accounts a
      where a.org_id = v_org and a.code = '6610'), 'expense');

  -- ------------------------------------------------------------------
  -- 6. What it refuses
  -- ------------------------------------------------------------------
  v_dep2 := public.create_deposit(
    v_org, 'customer', v_cust, current_date, 100, v_bank, null, null, null);

  begin
    perform public.apply_deposit(v_dep2, v_inv, 100);
    perform pg_temp.check_true('a settled invoice can take more', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a deposit settles an outstanding document, not a closed one',
      v_msg like '%a deposit settles an outstanding document%');
  end;

  begin
    perform public.apply_deposit(v_dep2, v_bill, 100);
    perform pg_temp.check_true('a customer deposit can pay our own bill', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a customer deposit cannot be spent on a supplier bill',
      v_msg like '%No such invoice%');
  end;

  begin
    perform public.settle_deposit(v_dep2, 'refund', 500, null, v_bank);
    perform pg_temp.check_true('more can be given back than was taken', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('nothing more can come out than went in',
      v_msg like '%has 100.00 left and this would take 500.00%');
  end;

  -- Somebody else's deposit.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-9', current_date, current_date, v_sup,
          'MYR', 1, 'draft')
  returning id into v_inv2;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv2, 1, 'item', v_item, 'Something', 1, 1000);
  perform public.post_sales_document(v_inv2);
  begin
    perform public.apply_deposit(v_dep2, v_inv2, 100);
    perform pg_temp.check_true('one customer pays another customer bill', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a deposit only settles its own party''s document',
      v_msg like '%is not INV-9''s%');
  end;

  -- ------------------------------------------------------------------
  -- 7. Voiding, only while nothing has happened to it
  -- ------------------------------------------------------------------
  perform public.void_deposit(v_dep2, 'Typed twice');
  perform pg_temp.check_eq('a void deposit holds nothing',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep2),
    0::numeric);
  perform pg_temp.check_true('and its entry is reversed rather than deleted',
    (select n.void_entry_id is not null from public.deposit_notes n
      where n.id = v_dep2));

  begin
    perform public.void_deposit(v_dep, 'too late');
    perform pg_temp.check_true('a spent deposit can be made to vanish', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a deposit that has been used cannot be voided from under it',
      v_msg like '%has already been used%');
  end;

  -- ------------------------------------------------------------------
  -- 8. What the lists say
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('the history says what happened to it',
    (select count(*) from public.deposit_history(v_dep)), 3::numeric);
  perform pg_temp.check_eq(
    'and what is held for a party is only what is left',
    (select count(*) from public.deposits_held_for(v_cust)), 0::numeric);
  perform pg_temp.check_true('the list separates the two kinds',
    (select count(*) filter (where l.kind = 'supplier') > 0
        and count(*) filter (where l.kind = 'customer') > 0
       from public.deposit_notes_list(v_org) l));

  raise notice 'ok   deposits';
end $$;

rollback;
