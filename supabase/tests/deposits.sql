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

-- ---------------------------------------------------------------------
-- Voiding a deposit, and what the bank makes of it
-- ---------------------------------------------------------------------
-- The block above voids a deposit and checks the ledger and the note.
-- Nothing checked the bank BALANCE, which `void_deposit` moves by hand
-- rather than by posting: money taken in has to be taken back out, and
-- money paid out has to come back. Both directions and the fact that it
-- happens at all were open.
--
-- The permission assertions are made against a stranger and against a
-- company that does not hold the module, deliberately. A member with no
-- access type assigned gets module write whatever their role -- see
-- `0501` -- so a `viewer` is not refused here and asserting that they
-- are would be asserting something untrue.
do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_supp uuid;
  v_bank uuid;
  v_in   uuid;
  v_out  uuid;
  v_msg  text;
  v_owner uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Deposit Batal Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Puan Siti', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Pembekal Bhd', 'supplier') returning id into v_supp;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current account', 'Maybank', '512345678999', 'MYR', 0, 0, true)
  returning id into v_bank;

  -- Money in from a customer, money out to a supplier.
  v_in := public.create_deposit(v_org, 'customer', v_cust, current_date,
                                10000, v_bank, '02', 'CHQ 45', 'Up front');
  perform pg_temp.check_eq('ten thousand in leaves ten thousand in the bank',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    10000::numeric);

  v_out := public.create_deposit(v_org, 'supplier', v_supp, current_date,
                                 3000, v_bank, '02', 'CHQ 46', 'Deposit paid');
  perform pg_temp.check_eq('and three thousand out leaves seven',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    7000::numeric);

  -- ------------------------------------------------------------------
  -- What voiding refuses
  -- ------------------------------------------------------------------
  begin
    perform public.void_deposit(v_in, '   ');
    raise exception 'FAIL voided a deposit without saying why';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a void with no reason is refused',
      v_msg like '%Say why%');
  end;

  -- A stranger, because a member with no access type has module write
  -- whatever their role.
  perform pg_temp.sign_in_as(pg_temp.another_user('orang-luar@example.test'));
  begin
    perform public.void_deposit(v_in, 'not mine to void');
    raise exception 'FAIL a stranger voided a deposit';
  exception when insufficient_privilege then
    raise notice 'ok   somebody outside the company cannot void its deposits';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- And what it does to the bank
  -- ------------------------------------------------------------------
  perform public.void_deposit(v_in, 'Cheque bounced');
  perform pg_temp.check_eq(
    'voiding the money in takes it back out of the bank',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    -3000::numeric);
  perform pg_temp.check_eq('and the note has nothing left to spend',
    (select n.balance_amount from public.deposit_notes n where n.id = v_in),
    0::numeric);

  perform public.void_deposit(v_out, 'Never sent');
  perform pg_temp.check_eq(
    'and voiding the money out puts it back, leaving the bank where it started',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    0::numeric);

  -- Twice is a mistake, and saying so is the point.
  begin
    perform public.void_deposit(v_in, 'again');
    raise exception 'FAIL voided the same deposit twice';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a deposit is voided once',
      v_msg like '%already void%');
  end;

  -- ------------------------------------------------------------------
  -- Which module a deposit belongs to
  -- ------------------------------------------------------------------
  -- Money held for a customer is a sales matter and money paid to a
  -- supplier is a purchases one. A company that holds one module and
  -- not the other is the only fixture that can tell the two apart --
  -- with both switched on, the question never gets asked twice.
  v_in  := public.create_deposit(v_org, 'customer', v_cust, current_date,
                                 500, v_bank, '02', 'CHQ 47', null);
  v_out := public.create_deposit(v_org, 'supplier', v_supp, current_date,
                                 400, v_bank, '02', 'CHQ 48', null);
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'purchases';

  perform public.void_deposit(v_in, 'Customer changed their mind');
  perform pg_temp.check_true('a customer deposit is voided under sales',
    (select n.status = 'void' from public.deposit_notes n where n.id = v_in));

  begin
    perform public.void_deposit(v_out, 'and this one is not');
    raise exception 'FAIL voided a supplier deposit with no purchases module';
  exception when insufficient_privilege then
    raise notice 'ok   and a supplier deposit under purchases, which this company gave up';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Wang Muka Sdn Bhd: what applying a deposit refuses, and where it posts
--
-- Sweeping `apply_deposit` killed five of seventeen mutants. What the
-- journal does with a good application is covered — the liability is
-- discharged, the allocation is written, the balance is recomputed.
-- Almost every way of getting there wrongly was not.
--
-- Nine of the twelve survivors were refusals: a stranger, a voided
-- deposit, nothing applied, more than the deposit holds, more than the
-- invoice owes, another company's invoice, a deleted one, and one in a
-- currency the deposit is not in. The other three were where the money
-- lands: a contact with a control account of its own had it ignored in
-- favour of 1210 and 2110 without a single assertion noticing, and the
-- date somebody typed could be thrown away for today's.
--
-- The control accounts are the ones worth the trouble. A company that
-- keeps its intercompany or its retail debtors in a separate control
-- account gets its trial balance quietly wrong on every deposit
-- applied, and the ledger still balances, so nothing says so.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid; v_org2 uuid;
  v_owner uuid := pg_temp.test_user();
  v_cust  uuid; v_sup uuid; v_cust2 uuid;
  v_ar    uuid; v_ap uuid; v_held_c uuid; v_held_s uuid;
  v_item  uuid; v_bank uuid;
  v_dep   uuid; v_depv uuid; v_deps uuid;
  v_inv   uuid; v_inv_usd uuid; v_inv_gone uuid; v_inv_other uuid;
  v_bill  uuid; v_entry uuid;
  v_when  date := current_date - 10;
  v_msg   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Wang Muka Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org,
    (date_trunc('year', current_date) - interval '1 year')::date);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  -- Control accounts of their own at both ends, so falling through to
  -- 1210 and 2110 is visible.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group,
     parent_id, sort_order)
  values (v_org, '1215', 'Trade debtors, projects', 'asset', 'accounts_receivable',
          false, (select parent_id from public.accounts
                   where org_id = v_org and code = '1210'), 1500)
  returning id into v_ar;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group,
     parent_id, sort_order)
  values (v_org, '2115', 'Trade creditors, projects', 'liability', 'accounts_payable',
          false, (select parent_id from public.accounts
                   where org_id = v_org and code = '2110'), 1500)
  returning id into v_ap;

  insert into public.contacts
    (org_id, code, name, contact_type, receivable_account_id)
  values (v_org, 'CUST', 'Encik Rahman', 'customer', v_ar)
  returning id into v_cust;
  insert into public.contacts
    (org_id, code, name, contact_type, payable_account_id)
  values (v_org, 'SUP', 'Pembekal Jaya', 'supplier', v_ap)
  returning id into v_sup;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'KERJA', 'Site work', 'service', false, 1000)
  returning id into v_item;
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance, is_default)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1120'),
          'Current account', 'Maybank', '598765432101', 'MYR', 0, 0, true)
  returning id into v_bank;

  v_dep := public.create_deposit(
    v_org, 'customer', v_cust, current_date - 20, 5000, v_bank, '02',
    'CHQ 90', 'Up front');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-W', current_date - 15, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv, 1, 'item', v_item, 'Stage one', 3, 1000);
  perform public.post_sales_document(v_inv);

  -- ------------------------------------------------------------------
  -- Amounts it will not take
  -- ------------------------------------------------------------------
  begin
    perform public.apply_deposit(v_dep, v_inv, 0);
    raise exception 'FAIL applied nothing';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an application has to be for something',
      v_msg like '%has to be for something%');
  end;
  begin
    perform public.apply_deposit(v_dep, v_inv, -100);
    raise exception 'FAIL applied a negative amount';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and minus a hundred is not an amount',
      v_msg like '%has to be for something%');
  end;
  begin
    perform public.apply_deposit(v_dep, v_inv, 6000);
    raise exception 'FAIL applied more than the deposit holds';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a deposit cannot give more than it holds',
      v_msg like '%left and this would take%');
  end;
  -- Four thousand is inside the deposit and outside the invoice, so the
  -- two ceilings are tested separately rather than one masking the other.
  begin
    perform public.apply_deposit(v_dep, v_inv, 4000);
    raise exception 'FAIL applied more than the invoice owes';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('nor more than the invoice actually owes',
      v_msg like '%outstanding and this would apply%');
  end;

  -- ------------------------------------------------------------------
  -- Documents it will not settle
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-USD', current_date - 15, current_date,
          v_cust, 'USD', 4.5, 'draft')
  returning id into v_inv_usd;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv_usd, 1, 'item', v_item, 'Export stage', 1, 1000);
  perform public.post_sales_document(v_inv_usd);
  begin
    perform public.apply_deposit(v_dep, v_inv_usd, 100);
    raise exception 'FAIL settled a foreign invoice from a ringgit deposit';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a ringgit deposit does not settle a dollar invoice',
      v_msg like '%Settle it with a receipt%');
  end;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-GONE', current_date - 15, current_date,
          v_cust, 'MYR', 1, 'draft')
  returning id into v_inv_gone;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_inv_gone, 1, 'item', v_item, 'Cancelled stage', 1, 1000);
  perform public.post_sales_document(v_inv_gone);
  update public.sales_documents set deleted_at = now() where id = v_inv_gone;
  begin
    perform public.apply_deposit(v_dep, v_inv_gone, 100);
    raise exception 'FAIL settled an invoice that had been deleted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a deleted invoice is not there to settle';
  end;

  -- Another company's invoice, with the same fixture user in both, so
  -- what is being tested is the org filter on the lookup rather than
  -- who is signed in.
  v_org2 := pg_temp.test_org('Syarikat Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  perform public.create_fiscal_year(v_org2, date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org2, 'CUST', 'Their customer', 'customer') returning id into v_cust2;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org2, 'KERJA', 'Site work', 'service', false, 1000)
  returning id into v_inv_other;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org2, 'invoice', 'INV-THEIRS', current_date - 15, current_date,
          v_cust2, 'MYR', 1, 'draft')
  returning id into v_inv_other;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org2, v_inv_other, 1, 'item',
          (select id from public.items where org_id = v_org2 and code = 'KERJA'),
          'Their stage', 1, 1000);
  perform public.post_sales_document(v_inv_other);
  begin
    perform public.apply_deposit(v_dep, v_inv_other, 100);
    raise exception 'FAIL settled another company''s invoice';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a deposit cannot reach into another company''s ledger';
  end;

  -- ------------------------------------------------------------------
  -- Deposits it will not draw on
  -- ------------------------------------------------------------------
  v_depv := public.create_deposit(
    v_org, 'customer', v_cust, current_date - 20, 500, v_bank, '02',
    'CHQ 91', 'Returned');
  perform public.void_deposit(v_depv, 'Cheque bounced');
  begin
    perform public.apply_deposit(v_depv, v_inv, 100);
    raise exception 'FAIL drew on a voided deposit';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a voided deposit has nothing to give',
      v_msg like '%was voided%');
  end;

  perform pg_temp.sign_in_as(pg_temp.another_user('luar-muka@example.test'));
  begin
    perform public.apply_deposit(v_dep, v_inv, 100);
    raise exception 'FAIL a stranger spent another company''s deposit';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('somebody outside the company cannot spend it',
      v_msg like '%not permitted to write%');
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and every sen of it is still there',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    5000::numeric);

  -- ------------------------------------------------------------------
  -- Applied, on the day it was applied, to the accounts they name
  -- ------------------------------------------------------------------
  v_entry := public.apply_deposit(v_dep, v_inv, 3000, v_when);

  perform pg_temp.check_true('the journal is dated the day it was applied',
    (select e.entry_date = v_when from public.gl_entries e where e.id = v_entry));
  perform pg_temp.check_eq('the customer''s own control account is relieved',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_ar), 3000::numeric);
  perform pg_temp.check_eq('and the default one is not touched',
    (select count(*)::integer from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '1210'), 0);
  perform pg_temp.check_eq('the invoice is settled',
    (select d.balance_amount from public.sales_documents d where d.id = v_inv),
    0::numeric);
  perform pg_temp.check_eq('and two thousand of the deposit is left',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    2000::numeric);

  -- ------------------------------------------------------------------
  -- The supplier side names its own control account too
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-W', current_date - 15, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Materials on account', 1, 1200);
  perform public.post_purchase_document(v_bill);

  v_deps := public.create_deposit(
    v_org, 'supplier', v_sup, current_date - 20, 2000, v_bank, '02',
    'CHQ 92', 'Paid up front');
  v_entry := public.apply_deposit(v_deps, v_bill, 1200, v_when);

  perform pg_temp.check_eq('the supplier''s own control account is charged',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_ap), 1200::numeric);
  perform pg_temp.check_eq('and 2110 is left alone',
    (select count(*)::integer from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
      where gl.entry_id = v_entry and a.code = '2110'), 0);
  perform pg_temp.check_eq('the bill is paid off the money already advanced',
    (select d.balance_amount from public.purchase_documents d where d.id = v_bill),
    0::numeric);

  perform pg_temp.sign_out();
end $$;

rollback;
