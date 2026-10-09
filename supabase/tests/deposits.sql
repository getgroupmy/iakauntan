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
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
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

  v_bank := pg_temp.test_bank_account(
    v_org, 'Current account', 'current', 'MYR', 0, 0, '512345678901');

  -- ------------------------------------------------------------------
  -- 1. The assertion this migration is built around
  -- ------------------------------------------------------------------
  --
  -- Ten thousand up front for a kitchen that does not exist yet.
  v_dep := public.create_deposit(
    v_org, 'customer', v_cust, pg_temp.today(), 10000, v_bank, '02', 'CHQ 44',
    'Half up front');

  select n.gl_entry_id into v_entry from public.deposit_notes n where n.id = v_dep;

  -- The account the deposit NAMED, not the heading. This assertion read
  -- `code = '1120'` and was true either way, which is the whole reason
  -- the fallback lived for a year.
  perform pg_temp.check_eq('the bank has the money',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
     where gl.entry_id = v_entry
       and gl.account_id = pg_temp.bank_gl(v_bank)), 10000::numeric);
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
  values (v_org, 'invoice', 'INV-1', pg_temp.today(), pg_temp.today(), v_cust,
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
  values (v_org, 'invoice', 'INV-2', pg_temp.today(), pg_temp.today(), v_cust,
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
     where gl.entry_id = v_entry
       and gl.account_id = pg_temp.bank_gl(v_bank)), 1000::numeric);
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
    v_org, 'customer', v_cust, pg_temp.today(), 500, v_bank, null, null, null);
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
      public.create_deposit(v_org, 'customer', v_cust, pg_temp.today(), 100,
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
    v_org, 'supplier', v_sup, pg_temp.today(), 2000, v_bank, null, null,
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
  values (v_org, 'bill', 'BILL-1', pg_temp.today(), v_sup, 'MYR', 1, 'draft')
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
    v_org, 'supplier', v_sup, pg_temp.today(), 300, v_bank, null, null, null);
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
    v_org, 'customer', v_cust, pg_temp.today(), 100, v_bank, null, null, null);

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
  values (v_org, 'invoice', 'INV-9', pg_temp.today(), pg_temp.today(), v_sup,
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
  v_rev  uuid;
  v_owner uuid := pg_temp.test_user();
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Deposit Batal Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Puan Siti', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Pembekal Bhd', 'supplier') returning id into v_supp;
  v_bank := pg_temp.test_bank_account(
    v_org, 'Current account', 'current', 'MYR', 0, 0, '512345678999');

  -- Money in from a customer, money out to a supplier.
  v_in := public.create_deposit(v_org, 'customer', v_cust, pg_temp.today(),
                                10000, v_bank, '02', 'CHQ 45', 'Up front');
  perform pg_temp.check_eq('ten thousand in leaves ten thousand in the bank',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    10000::numeric);

  v_out := public.create_deposit(v_org, 'supplier', v_supp, pg_temp.today(),
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
  v_in  := public.create_deposit(v_org, 'customer', v_cust, pg_temp.today(),
                                 500, v_bank, '02', 'CHQ 47', null);
  v_out := public.create_deposit(v_org, 'supplier', v_supp, pg_temp.today(),
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

  -- ------------------------------------------------------------------
  -- What a void leaves on the note, and the day it is dated
  -- ------------------------------------------------------------------
  -- Every void above was of a deposit taken today, so a reversal dated
  -- the deposit's own day and one dated today were the same entry; and
  -- nothing read who voided it, when, why, or what came back. Dated
  -- today on purpose (`0421`), unlike a bank transfer's void: a deposit
  -- voided in a later month is undone in that month.
  v_in := public.create_deposit(v_org, 'customer', v_cust, pg_temp.today() - 20,
                                250, v_bank, '02', 'CHQ 49', null);
  v_rev := public.void_deposit(v_in, '  Paid twice by mistake  ');
  perform pg_temp.check_true('the void hands back the reversal it wrote',
    v_rev is not null
    and v_rev = (select n.void_entry_id from public.deposit_notes n where n.id = v_in));
  perform pg_temp.check_true('dated the day it was voided, not the day the money came',
    (select e.entry_date from public.gl_entries e where e.id = v_rev) = pg_temp.today());
  perform pg_temp.check_eq('the reason is kept, without the spaces round it',
    (select n.void_reason from public.deposit_notes n where n.id = v_in),
    'Paid twice by mistake');
  perform pg_temp.check_true('with who voided it',
    (select n.voided_by from public.deposit_notes n where n.id = v_in) = v_owner);
  perform pg_temp.check_true('and when',
    (select n.voided_at from public.deposit_notes n where n.id = v_in) = now());

  perform pg_temp.check_refused('voiding a deposit that does not exist is said so',
    format('select public.void_deposit(%L, %L)', gen_random_uuid(), 'Gone'),
    'No such deposit.', 'P0002');
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
  v_when  date := pg_temp.today() - 10;
  v_msg   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Wang Muka Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org,
    (date_trunc('year', pg_temp.today()) - interval '1 year')::date);
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
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
  v_bank := pg_temp.test_bank_account(
    v_org, 'Current account', 'current', 'MYR', 0, 0, '598765432101');

  v_dep := public.create_deposit(
    v_org, 'customer', v_cust, pg_temp.today() - 20, 5000, v_bank, '02',
    'CHQ 90', 'Up front');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-W', pg_temp.today() - 15, pg_temp.today(), v_cust,
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
  values (v_org, 'invoice', 'INV-USD', pg_temp.today() - 15, pg_temp.today(),
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
  values (v_org, 'invoice', 'INV-GONE', pg_temp.today() - 15, pg_temp.today(),
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
  perform public.create_fiscal_year(v_org2, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org2, pg_temp.today() - 30);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org2, 'CUST', 'Their customer', 'customer') returning id into v_cust2;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org2, 'KERJA', 'Site work', 'service', false, 1000)
  returning id into v_inv_other;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org2, 'invoice', 'INV-THEIRS', pg_temp.today() - 15, pg_temp.today(),
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
    v_org, 'customer', v_cust, pg_temp.today() - 20, 500, v_bank, '02',
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
  values (v_org, 'bill', 'BILL-W', pg_temp.today() - 15, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Materials on account', 1, 1200);
  perform public.post_purchase_document(v_bill);

  v_deps := public.create_deposit(
    v_org, 'supplier', v_sup, pg_temp.today() - 20, 2000, v_bank, '02',
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

-- ---------------------------------------------------------------------
-- Selesai Deposit Sdn Bhd: refunding and forfeiting, and the bank a
-- refund is allowed to come out of
--
-- Sweeping `settle_deposit` killed nine of seventeen. The money is
-- covered: which account a forfeit lands in, which way the bank
-- balance moves, the reason being kept, the balance being recomputed.
-- Every refusal was open, the caller's date could be thrown away for
-- today's, and so could the bank account the caller named.
--
-- That last one was 0505, and it was not a cosmetic gap. The account
-- was checked against the deposit's company in exactly one place -- the
-- lookup that decides which ledger account to credit -- while the event
-- row and the running balance used the raw argument. Naming another
-- company's bank account took the refund out of THEIR balance, recorded
-- THEIR account against this deposit, and posted this company's credit
-- to its own 1120 fallback, so both companies ended up wrong and
-- neither ledger said so. The function is SECURITY DEFINER, so row
-- level security never came into it.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid; v_org2 uuid;
  v_owner uuid := pg_temp.test_user();
  v_cust  uuid;
  v_bank_a uuid; v_bank_b uuid; v_bank_theirs uuid;
  v_acct_a uuid; v_acct_b uuid;
  v_dep   uuid; v_depv uuid; v_entry uuid;
  v_when  date := pg_temp.today() - 5;
  v_msg   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Selesai Deposit Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org,
    (date_trunc('year', pg_temp.today()) - interval '1 year')::date);
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Cik Farah', 'customer') returning id into v_cust;

  -- Two bank accounts with ledger accounts of their own, so paying out
  -- of the one the caller named rather than the one on the note is
  -- visible in the journal as well as in the balances.
  -- Two accounts, two ledger accounts. The second one used to be made
  -- by hand at 1125 precisely so the two could be told apart -- which
  -- was the right instinct, and the first one was still on the heading.
  v_bank_a := pg_temp.test_bank_account(
    v_org, 'First account', 'current', 'MYR', 0, 0, '511111111111');
  v_bank_b := pg_temp.test_bank_account(
    v_org, 'Second account', 'current', 'MYR', 0, 0, '522222222222',
    'CIMB', false, false);
  v_acct_a := pg_temp.bank_gl(v_bank_a);
  v_acct_b := pg_temp.bank_gl(v_bank_b);

  v_dep := public.create_deposit(
    v_org, 'customer', v_cust, pg_temp.today() - 20, 4000, v_bank_a, '02',
    'CHQ 70', 'Booking');

  -- ------------------------------------------------------------------
  -- What it will not settle
  -- ------------------------------------------------------------------
  begin
    perform public.settle_deposit(v_dep, 'transfer', 100, 'Moved it');
    raise exception 'FAIL settled a deposit as something it cannot be';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a deposit is given back or kept, nothing else',
      v_msg like '%given back or kept%');
  end;
  begin
    perform public.settle_deposit(v_dep, 'refund', 0, null, v_bank_a);
    raise exception 'FAIL refunded nothing';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a settlement has to be for something',
      v_msg like '%has to be for something%');
  end;
  begin
    perform public.settle_deposit(v_dep, 'refund', -50, null, v_bank_a);
    raise exception 'FAIL refunded a negative amount';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and minus fifty is not an amount either',
      v_msg like '%has to be for something%');
  end;

  -- A bank account belonging to somebody else. Before 0505 this took
  -- the money out of their balance and left this company crediting its
  -- own 1120 instead.
  v_org2 := pg_temp.test_org('Bank Jiran Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  v_bank_theirs := pg_temp.test_bank_account(
    v_org2, 'Their account', 'current', 'MYR', 0, 9000, '533333333333',
    'RHB');

  begin
    perform public.settle_deposit(v_dep, 'refund', 100, 'Wrong bank',
                                  v_bank_theirs);
    raise exception 'FAIL refunded out of another company''s bank account';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a refund cannot be paid from another company',
      v_msg like '%belongs to another company%');
  end;
  perform pg_temp.check_eq('and their balance is exactly where it was',
    (select b.current_balance from public.bank_accounts b
      where b.id = v_bank_theirs), 9000::numeric);

  -- ------------------------------------------------------------------
  -- Who may settle one
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-selesai@example.test'));
  begin
    perform public.settle_deposit(v_dep, 'refund', 100, null, v_bank_a);
    raise exception 'FAIL a stranger refunded another company''s deposit';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('somebody outside the company cannot settle it',
      v_msg like '%not permitted to write%');
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_eq('and all four thousand is still held',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    4000::numeric);

  v_depv := public.create_deposit(
    v_org, 'customer', v_cust, pg_temp.today() - 20, 300, v_bank_a, '02',
    'CHQ 71', 'Second booking');
  perform public.void_deposit(v_depv, 'Keyed twice');
  begin
    perform public.settle_deposit(v_depv, 'refund', 100, null, v_bank_a);
    raise exception 'FAIL settled a voided deposit';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a voided deposit has nothing to settle',
      v_msg like '%was voided%');
  end;

  -- ------------------------------------------------------------------
  -- Refunded, out of the account the caller named, on the day given
  -- ------------------------------------------------------------------
  v_entry := public.settle_deposit(
    v_dep, 'refund', 1000, 'Booking cancelled', v_bank_b, v_when);

  perform pg_temp.check_true('the journal is dated the day of the refund',
    (select e.entry_date = v_when from public.gl_entries e where e.id = v_entry));
  perform pg_temp.check_eq('the money left the account the caller named',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_acct_b), 1000::numeric);
  perform pg_temp.check_eq('not the one the deposit happened to arrive in',
    (select count(*)::integer from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_acct_a), 0);
  perform pg_temp.check_eq('so the second account is a thousand down',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank_b),
    -1000::numeric);
  -- Four thousand in, three hundred more in and voided straight back
  -- out again, and nothing since: the refund did not touch it.
  perform pg_temp.check_eq('and the first still holds what came in',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank_a),
    4000::numeric);
  perform pg_temp.check_true('the event names the account it went out of',
    (select e.bank_account_id = v_bank_b from public.deposit_events e
      where e.deposit_id = v_dep and e.kind = 'refund'));

  -- ------------------------------------------------------------------
  -- A forfeit never went through a bank, and does not pretend it did
  -- ------------------------------------------------------------------
  perform public.settle_deposit(
    v_dep, 'forfeit', 500, 'Cancelled inside the notice period', null, v_when);
  perform pg_temp.check_true('a forfeit records no bank account at all',
    (select e.bank_account_id is null from public.deposit_events e
      where e.deposit_id = v_dep and e.kind = 'forfeit'));
  perform pg_temp.check_eq('and no bank balance moved with it',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank_a),
    4000::numeric);
  perform pg_temp.check_eq('two and a half thousand of the deposit is left',
    (select n.balance_amount from public.deposit_notes n where n.id = v_dep),
    2500::numeric);

  -- ------------------------------------------------------------------
  -- And taking one IN has the same boundary
  --
  -- 0505 was found in settle_deposit; reading every function that
  -- writes bank_accounts.current_balance found the same shape in
  -- create_deposit, which is 0506. Money coming in could be booked into
  -- another company's balance, and their account recorded on this
  -- company's deposit note.
  -- ------------------------------------------------------------------
  begin
    perform public.create_deposit(
      v_org, 'customer', v_cust, pg_temp.today() - 20, 700, v_bank_theirs,
      '02', 'CHQ 99', 'Into their bank');
    raise exception 'FAIL banked a deposit into another company''s account';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a deposit cannot be banked into another company',
      v_msg like '%belongs to another company%');
  end;
  perform pg_temp.check_eq('and their balance is still untouched',
    (select b.current_balance from public.bank_accounts b
      where b.id = v_bank_theirs), 9000::numeric);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What create_deposit refuses, and the date it books the money on
--
-- A mutation sweep of `create_deposit`, `void_deposit` and
-- `app.refresh_deposit` read 14 of 18 caught by the file above. These
-- are the four it did not, and two of them are only half a gap.
--
-- The contact check and the kind check are both REDUNDANT now, and
-- that was established by probe rather than by reading. With the
-- contact check removed, a deposit naming another company's customer
-- is refused by `deposit_notes_contact_same_org` -- one of the keys
-- 0512 added, which did not exist when this function was written. With
-- the kind check removed, `app.deposit_kind` refuses the cast. Neither
-- is untested in the sense of unguarded.
--
-- They are asserted anyway, and by their WHOLE message rather than a
-- fragment, because the message is the difference. A person who types
-- the wrong thing should be told "No such contact.", not
-- `insert or update on table "deposit_notes" violates foreign key
-- constraint "deposit_notes_contact_same_org"`. Comparing the whole
-- message is what makes these assertions kill their mutants: the
-- fallback refuses too, but it does not say that.
--
-- The other two are real gaps. A deposit for nothing was accepted, and
-- the journal was dated from the day it was typed rather than the day
-- the money arrived -- which puts it in the wrong period, and the
-- period lock and the trial balance both read entry_date.
-- ---------------------------------------------------------------------

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_org2  uuid;
  v_cust  uuid;
  v_theirs uuid;
  v_dep   uuid;
  v_msg   text;
  v_when  date := pg_temp.today() - 9;
  v_t     text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Wang Muka Enggan Sdn Bhd');
  perform pg_temp.allow_many_companies();
  v_org2 := pg_temp.test_org('Syarikat Jiran Deposit Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  -- Last year AND this one. The deposit below is dated nine days back,
  -- which is this year's period unless the run happens to be in the
  -- first nine days of January -- so both are created rather than
  -- reasoning about which.
  perform public.create_fiscal_year(v_org,
    (date_trunc('year', pg_temp.today()) - interval '1 year')::date);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org2, 'C-J', 'Pelanggan jiran', 'customer')
  returning id into v_theirs;

  -- A deposit for nothing is not a deposit.
  begin
    perform public.create_deposit(v_org, 'customer', v_cust, v_when, 0);
    perform pg_temp.check_true('a deposit for nothing is refused', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a deposit for nothing is refused: ' || v_msg,
      v_msg = 'A deposit has to be for something.');
  end;

  begin
    perform public.create_deposit(v_org, 'customer', v_cust, v_when, -50);
    perform pg_temp.check_true('and so is one for less than nothing', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'and so is one for less than nothing: ' || v_msg,
      v_msg = 'A deposit has to be for something.');
  end;

  -- The whole message, not a fragment. The schema refuses this too --
  -- see the note above -- but it does not say this.
  begin
    perform public.create_deposit(v_org, 'customer', v_theirs, v_when, 500);
    perform pg_temp.check_true(
      'a deposit cannot be taken for another company''s customer', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a deposit cannot be taken for another company''s customer, and it '
      'says so in words: ' || v_msg,
      v_msg = 'No such contact.');
  end;

  begin
    perform public.create_deposit(v_org, 'landlord', v_cust, v_when, 500);
    perform pg_temp.check_true(
      'a deposit is taken from a customer or paid to a supplier', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a deposit is taken from a customer or paid to a supplier, and it '
      'says which: ' || v_msg,
      v_msg = 'A deposit is either taken from a customer or paid to a '
              'supplier.');
  end;

  -- And the day the money arrived is the day it is booked on. A deposit
  -- entered on Monday for money banked the previous week belongs in the
  -- earlier period: `app.guard_period_lock` and `report_trial_balance`
  -- both read entry_date, and so does every deposit ageing.
  -- `0728` requires an account: a deposit that named none used to be
  -- posted to the 1120 heading. The four refusals above are unaffected
  -- -- each one fires before the account is looked at, which is part of
  -- what they assert.
  v_dep := public.create_deposit(v_org, 'customer', v_cust, v_when, 500,
                                 pg_temp.a_bank_account(v_org));
  select e.entry_date::text into v_t
    from public.gl_entries e
    join public.deposit_notes d on d.gl_entry_id = e.id
   where d.id = v_dep;
  perform pg_temp.check_eq(
    'the journal is dated the day the money came in, not the day it was '
    'typed', v_t, v_when::text);

  raise notice 'create_deposit: 4 refusals, and the date the money arrived';
end $$;

-- =====================================================================
-- A module that lapsed is a deposit you can no longer read
-- =====================================================================
--
-- `deposit_history` takes an id, so it cannot filter rows out the way
-- `deposit_notes_list` and `deposits_held_for` do. Before `0601` it
-- checked the org and nothing else -- and that check could never fire,
-- because it reads
--
--     if not can_read_module(org, 'sales')
--        and not can_read_module(org, 'purchases')
--
-- and `sales` is a CORE module, so the first half is always false.
--
-- The tell was a variable: it selected `n.kind` into `v_kind` on its
-- second line and never looked at it again. The whole check, read and
-- thrown away.
--
-- What that left open is Purchases, which is not core and can lapse. A
-- supplier deposit already in the books stayed readable afterwards --
-- its events, their dates, their amounts and their free-text reasons --
-- while both list functions had already stopped showing it.
--
-- The refusal's SHAPE is asserted too, and is half the point: a deposit
-- the caller may not read must be indistinguishable from one that does
-- not exist, or the two answers are a way to find out which ids are
-- real, one guess at a time. That is the argument `0596` makes about
-- `link_group_contact`.
do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_sup   uuid;
  v_cust  uuid;
  v_dep   uuid;
  v_cdep  uuid;
  v_n     integer;
begin
  perform pg_temp.allow_many_companies();
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Luput Sdn Bhd');
  perform public.create_fiscal_year(v_org,
                                    date_trunc('year', pg_temp.today())::date);
  -- Dated five days back, which in the first days of January is last
  -- year (measured under a shifted clock).
  perform pg_temp.open_years(v_org, pg_temp.today() - 5);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Kilang Rahsia', 'supplier') returning id into v_sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'A customer', 'customer') returning id into v_cust;

  v_dep := public.create_deposit(v_org, 'supplier', v_sup,
                                 pg_temp.today() - 5, 700,
                                 pg_temp.a_bank_account(v_org));
  v_cdep := public.create_deposit(v_org, 'customer', v_cust,
                                  pg_temp.today() - 5, 900,
                                  pg_temp.a_bank_account(v_org));
  -- Something to read back. `settle_deposit` files a `deposit_events`
  -- row carrying the reason somebody typed, which is the part of this
  -- that is nobody else's business.
  perform public.settle_deposit(v_dep, 'forfeit', 700,
                                'Supplier kept the advance');

  select count(*) into v_n from public.deposit_history(v_dep);
  perform pg_temp.check_true('while Purchases is on, the history reads',
    v_n >= 1);

  -- Purchases lapses.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'purchases';

  -- The two list functions already stopped showing it, which is what
  -- made the third one a gap rather than a policy.
  -- Asked for the supplier ones specifically: the customer deposit
  -- below is still listed, on core Sales, and counting both would hide
  -- which of them went away.
  perform pg_temp.check_eq('the list stops showing it',
    (select count(*)::integer
       from public.deposit_notes_list(v_org, 'supplier', null)), 0);
  perform pg_temp.check_eq('while still showing the customer one',
    (select count(*)::integer
       from public.deposit_notes_list(v_org, 'customer', null)), 1);
  perform pg_temp.check_eq('and so does the one for the contact',
    (select count(*)::integer from public.deposits_held_for(v_sup)), 0);

  begin
    perform public.deposit_history(v_dep);
    raise exception
      'FAIL: read a supplier deposit after Purchases lapsed';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and the history stops with them';
  end;

  -- The same refusal an id that was never issued gets. If these two
  -- ever differ, the refusal becomes an oracle for which ids are real.
  begin
    perform public.deposit_history(gen_random_uuid());
    raise exception 'FAIL: a deposit that does not exist was readable';
  exception when sqlstate 'P0002' then
    raise notice 'ok   indistinguishable from an id that was never issued';
  end;

  -- And the check is about the KIND, not a blanket refusal that would
  -- pass the assertions above by refusing everything.
  perform public.deposit_history(v_cdep);
  raise notice 'ok   while the customer deposit still reads, on core Sales';

  -- Back on, and it reads again: a lapsed module hides the history, it
  -- does not destroy it.
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'purchases';
  select count(*) into v_n from public.deposit_history(v_dep);
  perform pg_temp.check_true('renewing Purchases brings it back', v_n >= 1);

  raise notice 'deposit_history: the kind is checked, and refuses like a gap';
end $$;

-- ---------------------------------------------------------------------
-- create_deposit: the ten things a mutation sweep found nothing on
--
-- Five definitions, the most-redefined money mover in the schema, and
-- 14 of 25 mutants killed across the three files that reach it
-- (`deposits.sql` 13, `money_names_the_account.sql` one more,
-- `idempotency.sql` one already counted). These are the other ten, each
-- with the mutant it exists to kill.
--
-- The theme is the same one the whole sweep keeps finding: the three
-- arguments a deposit carries for a person to read later -- the mode,
-- the reference, the date -- are the ones nothing read back, and the
-- journal's own shape is the one nothing counted. None of them can
-- unbalance anything.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_sgd   uuid;
  v_cust  uuid; v_supp uuid; v_sgd_cust uuid;
  v_bank  uuid; v_gl uuid; v_sgd_bank uuid;
  v_held  uuid;
  v_dep   uuid; v_entry uuid;
  v_clerk uuid; v_type uuid;
  v_msg   text;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Wang Muka Celah Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);

  v_bank := pg_temp.test_bank_account(v_org, 'Maybank current');
  v_gl   := pg_temp.bank_gl(v_bank);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'PEL', 'Puan Hasnah', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'PEM', 'Pembekal Jaya', 'supplier') returning id into v_supp;

  -- ------------------------------------------------------------------
  -- 1. THE CENTS, 2. THE MODE, 3. THE REFERENCE, 4. THE DATE,
  --    5-6. WHO it is held for, on BOTH legs, 7. the link back
  -- ------------------------------------------------------------------
  -- Every deposit in this file is a round hundred or thousand taken
  -- today, so `round(p_amount, 2)` had no cents to lose and
  -- `coalesce(p_date, app.today())` had nothing to distinguish from
  -- today. One deposit with an odd sum on a past date, with a mode and
  -- a reference, closes seven mutants at once.
  v_dep := public.create_deposit(
    v_org, 'customer', v_cust, pg_temp.today() - 9, 1234.56, v_bank,
    '02', 'CHQ 900241', 'Half the fit-out, up front');
  perform pg_temp.check_eq('a deposit keeps its cents',
    (select amount from public.deposit_notes where id = v_dep), 1234.56);
  perform pg_temp.check_eq('and all of them are available to spend',
    (select balance_amount from public.deposit_notes where id = v_dep),
    1234.56);
  perform pg_temp.check_eq('it is dated the day the money came in',
    (select deposit_date from public.deposit_notes where id = v_dep)::text,
    (pg_temp.today() - 9)::text);
  perform pg_temp.check_eq('and records HOW it arrived',
    (select payment_mode_code from public.deposit_notes where id = v_dep),
    '02');
  perform pg_temp.check_eq('and the reference it arrived with',
    (select reference from public.deposit_notes where id = v_dep),
    'CHQ 900241');
  perform pg_temp.check_eq('and what was said about it',
    (select notes from public.deposit_notes where id = v_dep),
    'Half the fit-out, up front');

  select gl_entry_id into v_entry from public.deposit_notes where id = v_dep;
  v_held := app.deposit_account(v_org, 'customer');
  perform pg_temp.check_eq('the journal takes the cents too',
    (select debit from public.gl_lines
      where entry_id = v_entry and account_id = v_gl), 1234.56);
  -- The contact on BOTH legs, separately. `report_contact_statement`
  -- reads gl_lines.contact_id, so a leg without one is money held for
  -- nobody -- and the two legs are built in two different
  -- jsonb_build_object calls, so either can lose it on its own.
  perform pg_temp.check_eq('the bank''s leg says who the money came from',
    (select contact_id from public.gl_lines
      where entry_id = v_entry and account_id = v_gl), v_cust);
  perform pg_temp.check_eq('and the held leg says who it is held for',
    (select contact_id from public.gl_lines
      where entry_id = v_entry and account_id = v_held), v_cust);
  -- And the journal points back at the note, which is how a void finds
  -- what to reverse.
  perform pg_temp.check_eq('the journal names the note it came from',
    (select source_id from public.gl_entries where id = v_entry), v_dep);
  perform pg_temp.check_eq('and which table that note is in',
    (select source_table from public.gl_entries where id = v_entry),
    'deposit_notes');

  -- ------------------------------------------------------------------
  -- 8. THE WRITE GUARD, and 9. WHICH RIGHT each direction needs
  -- ------------------------------------------------------------------
  -- `app.can_write_module(p_org, v_module)` with v_module DERIVED from
  -- the kind -- 'sales' for a customer, 'purchases' for a supplier. Two
  -- separate claims in one call, and a company holding both rights can
  -- test neither. Nothing asserted even that the guard exists.
  --
  -- A stranger first, for the guard itself.
  v_clerk := pg_temp.another_user('muka-celah@iakauntan.test');
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'purchaser') on conflict do nothing;
  select at.id into v_type from public.access_types at
   where at.org_id = v_org or at.org_id is null
   order by at.org_id nulls last limit 1;
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-muka@iakauntan.test'));
  begin
    perform public.create_deposit(v_org, 'customer', v_cust,
                                  pg_temp.today(), 100, v_bank, null, null, null);
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.sign_in_as(v_owner);
  -- The WHOLE message: the foreign-bank guard four lines below also
  -- raises 42501, and so does the contact check's neighbour.
  perform pg_temp.check_eq('somebody outside the company cannot take a deposit',
    v_msg, 'not permitted to write for this organization');
  perform pg_temp.check_eq('and nothing of theirs was recorded',
    (select count(*) from public.deposit_notes
      where org_id = v_org and amount = 100), 0);

  -- Then the DERIVATION, which needs a company holding one side and not
  -- the other. `sales` is a core module every company has; `purchases`
  -- is not -- so switching purchases off refuses a SUPPLIER deposit and
  -- must still allow a CUSTOMER one. If the derivation were swapped the
  -- customer deposit would ask for purchases and be refused, which is
  -- the half a stranger could never prove.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'purchases';
  perform pg_temp.check_refused(
    'a company that gave up Purchases cannot pay a supplier a deposit',
    format('select public.create_deposit(%L, %L, %L, %L, 250, %L, null, null, null)',
           v_org, 'supplier', v_supp, pg_temp.today(), v_bank),
    'not permitted to write for this organization', '42501');
  perform pg_temp.check_true(
    'while a customer deposit still goes through, on core Sales',
    public.create_deposit(v_org, 'customer', v_cust, pg_temp.today(),
                          250, v_bank, null, null, null) is not null);
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'purchases';

  -- ------------------------------------------------------------------
  -- 10. THE COMPANY'S OWN CURRENCY
  -- ------------------------------------------------------------------
  -- `v_cur := app.base_currency(p_org)` reads the company; every
  -- company in this suite is MYR, so hardcoding 'MYR' in its place
  -- changed nothing. A deposit is refused in any currency but the base
  -- one (0272's reason), which makes "the base one" the only thing
  -- worth asserting -- and it is only assertable against a company
  -- whose base is not the default.
  v_sgd := pg_temp.test_org('Syarikat Singa Pte Ltd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_sgd, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_sgd, pg_temp.today() - 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_sgd, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);
  update public.organizations set base_currency = 'SGD' where id = v_sgd;
  v_sgd_bank := pg_temp.test_bank_account(
    v_sgd, 'DBS current', 'current', 'SGD', 0, 0, '8801');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_sgd, 'SG1', 'Tan & Sons Pte Ltd', 'customer')
  returning id into v_sgd_cust;

  v_dep := public.create_deposit(v_sgd, 'customer', v_sgd_cust,
                                 pg_temp.today(), 600, v_sgd_bank,
                                 null, null, null);
  perform pg_temp.check_eq(
    'a deposit is held in the COMPANY''S base currency, not the suite''s',
    (select currency from public.deposit_notes where id = v_dep), 'SGD');
  perform pg_temp.check_eq('at a rate of one, because it is the base one',
    (select exchange_rate from public.deposit_notes where id = v_dep), 1);

  -- What this block does NOT prove, said here so the next sweep does
  -- not re-chase it: the ledger lookup's own `and b.org_id = p_org`
  -- (the `select a.id into v_bank ... join accounts` a few lines below
  -- the foreign-bank guard) is an EQUIVALENT mutation target. By the
  -- time it runs, p_bank has already been refused if it is null and
  -- refused if it belongs to another company, so the conjunct cannot
  -- exclude a row. It is belt-and-braces, and correct to keep -- the
  -- function's own comment says the row written and the balance
  -- updated once used p_bank raw, which is the defect it guards
  -- against returning.
  raise notice 'ok   the cents, the mode, the reference, the date, the party, the currency';
end $$;



-- ---------------------------------------------------------------------
-- Settling a deposit, rule by rule
--
-- A sweep of `settle_deposit` (0728) left five mutants alive. Nothing
-- settled a deposit that is not there; every refund named its account,
-- so neither the deposit's own account as the default nor the refusal
-- when there is none (a row from before 0728) was ever reached; nobody
-- with purchases but not sales settled a supplier's deposit; and no
-- SUPPLIER deposit was refunded, so the money coming back INTO the bank
-- was never read.
-- ---------------------------------------------------------------------
do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_clerk uuid := pg_temp.another_user('kerani-deposit@example.test');
  v_org uuid; v_cust uuid; v_sup uuid; v_bank uuid; v_type uuid;
  v_cdep uuid; v_sdep uuid; v_old uuid;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Deposit Rules Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['sales','purchases','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;
  perform pg_temp.sign_in_as(v_owner);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'Encik Rahim', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'Kilang Pintu', 'supplier') returning id into v_sup;
  v_bank := pg_temp.test_bank_account(v_org, 'Current account', 'current', 'MYR', 0, 0, '512345670000');

  v_cdep := public.create_deposit(v_org, 'customer', v_cust, pg_temp.today(), 1000, v_bank);
  v_sdep := public.create_deposit(v_org, 'supplier', v_sup, pg_temp.today(), 600, v_bank);

  perform pg_temp.check_refused('a deposit that is not there settles nothing',
    format('select public.settle_deposit(%L, %L, 100, null)', gen_random_uuid(), 'refund'),
    '%No such deposit%', 'P0002');

  -- No account named: the deposit's own is the one the refund leaves.
  perform pg_temp.sign_in_as(v_owner);
  perform public.settle_deposit(v_cdep, 'refund', 300, null);
  perform pg_temp.check_eq('a refund naming no account leaves the deposit''s own',
    (select current_balance from public.bank_accounts where id = v_bank), 1000 - 600 - 300);

  -- A supplier giving our money back: it comes INTO the bank.
  perform public.settle_deposit(v_sdep, 'refund', 200, null);
  perform pg_temp.check_eq('a supplier''s refund puts the money back in the bank',
    (select current_balance from public.bank_accounts where id = v_bank), 1000 - 600 - 300 + 200);

  -- A row from before 0728, when a deposit could name no account.
  v_old := public.create_deposit(v_org, 'customer', v_cust, pg_temp.today(), 50, v_bank);
  update public.deposit_notes set bank_account_id = null where id = v_old;
  perform pg_temp.check_refused('and one that names no account at all asks which',
    format('select public.settle_deposit(%L, %L, 50, null)', v_old, 'refund'),
    '%Say which account the refund is paid out of%', '23514');

  -- Purchases, and sales read only: a supplier's deposit, not a customer's.
  insert into public.org_members (org_id, user_id, role) values (v_org, v_clerk, 'sales');
  insert into public.access_types (org_id, name)
  values (v_org, 'Purchases only') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'sales', 'read'), (v_type, 'purchases', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_clerk;
  perform pg_temp.sign_in_as(v_clerk);
  perform public.settle_deposit(v_sdep, 'refund', 100, null);
  perform pg_temp.check_eq('somebody on purchases settles a supplier''s deposit',
    (select refunded_amount from public.deposit_notes where id = v_sdep), 300);
  perform pg_temp.check_refused('but not a customer''s',
    format('select public.settle_deposit(%L, %L, 100, null)', v_cdep, 'refund'),
    '%not permitted to write%', '42501');
  perform pg_temp.sign_out();
end $$;

rollback;
