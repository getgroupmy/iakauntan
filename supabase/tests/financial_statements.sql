-- =====================================================================
-- iAkauntan :: cash flow and changes in equity
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/financial_statements.sql
--
-- Both statements are derived rather than classified, so the thing
-- worth asserting is that the derivation lands where the ledger already
-- says it should: the cash flow on the movement in the bank and cash
-- accounts, and the closing equity on net assets in the balance sheet.
-- A statement that agrees with itself and with nothing else is the
-- failure mode here.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.fs_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

create or replace function pg_temp.acct(p_org uuid, p_code text)
returns uuid language sql as $$
  select id from public.accounts where org_id = p_org and code = p_code;
$$;

-- One line of a cash flow statement, by its label.
create or replace function pg_temp.cf(
  p_org uuid, p_label text, p_from date default date '2026-01-01',
  p_to date default date '2026-12-31')
returns numeric language sql as $$
  select coalesce((select amount from public.report_cash_flow(p_org, p_from, p_to)
                    where label = p_label), 0);
$$;

create or replace function pg_temp.cf_section(
  p_org uuid, p_section text, p_from date default date '2026-01-01',
  p_to date default date '2026-12-31')
returns numeric language sql as $$
  select coalesce((select sum(amount) from public.report_cash_flow(p_org, p_from, p_to)
                    where section = p_section), 0);
$$;

create or replace function pg_temp.invoice(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_date date)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'invoice', p_no, p_date, p_date + 30, p_contact, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Consulting', 1, p_amount);
  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

create or replace function pg_temp.bill(
  p_org uuid, p_contact uuid, p_no text, p_amount numeric, p_date date)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', p_no, p_date, p_date + 30, p_contact, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Supplies', 1, p_amount);
  perform public.post_purchase_document(v_doc);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- A year of trading, and where the cash went
--
--   invoiced 10,000, collected  6,000
--   billed    3,000, paid       2,000
--   bought a machine for        5,000
--   depreciated it by             500   (no cash)
--
-- so the bank is 1,000 down and the company is 6,500 in profit, which
-- is the gap a cash flow statement exists to explain.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fs_org('Cashflow Sdn Bhd');
  v_cust uuid; v_supp uuid; v_bank uuid; v_bank_acct uuid;
  v_inv uuid; v_bill uuid; v_rcp uuid; v_pay uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Customer Bhd', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Supplier Bhd', 'supplier') returning id into v_supp;

  insert into public.bank_accounts (org_id, name, account_id, is_active)
  values (v_org, 'Current account', pg_temp.acct(v_org, '1120'), true)
  returning id into v_bank;
  v_bank_acct := pg_temp.acct(v_org, '1120');

  v_inv := pg_temp.invoice(v_org, v_cust, 'INV-1', 10000, date '2026-02-01');
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org, 'RCP-1', date '2026-03-01', v_cust, 6000, 6000, 'MYR', 1, v_bank)
  returning id into v_rcp;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 6000);
  perform public.post_receipt(v_rcp);

  v_bill := pg_temp.bill(v_org, v_supp, 'BILL-1', 3000, date '2026-02-10');
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org, 'PAY-1', date '2026-03-05', v_supp, 2000, 2000, 'MYR', 1, v_bank)
  returning id into v_pay;
  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay, v_bill, 2000);
  perform public.post_purchase_payment(v_pay);

  -- A machine, bought outright.
  perform public.post_manual_journal(v_org, date '2026-04-01',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1510'),
                         'debit', 5000, 'credit', 0, 'description', 'Machine'),
      jsonb_build_object('account_id', v_bank_acct,
                         'debit', 0, 'credit', 5000, 'description', 'Machine')),
    'Purchase of plant');

  -- And a year of wear on it, which costs no money at all.
  perform public.post_manual_journal(v_org, date '2026-12-31',
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '6400'),
                         'debit', 500, 'credit', 0, 'description', 'Depreciation'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '1590'),
                         'debit', 0, 'credit', 500, 'description', 'Depreciation')),
    'Depreciation for the year');

  -- The bank: 6,000 in, 2,000 out, 5,000 out.
  perform pg_temp.check_eq('the bank is a thousand down over the year',
    pg_temp.cf(v_org, 'Cash and cash equivalents carried forward')
      - pg_temp.cf(v_org, 'Cash and cash equivalents brought forward'),
    -1000);

  -- The assertion the statement exists to make.
  perform pg_temp.check_eq('and the statement says so',
    pg_temp.cf(v_org, 'Net movement in cash'), -1000);

  perform pg_temp.check_eq('profit is what the profit and loss says',
    pg_temp.cf(v_org, 'Profit for the period'), 6500);
  perform pg_temp.check_eq('depreciation is added back, not spent',
    pg_temp.cf(v_org, 'Depreciation and amortisation'), 500);
  perform pg_temp.check_eq('the machine is investing, and it is an outflow',
    pg_temp.cf_section(v_org, 'investing'), -5000);
  perform pg_temp.check_eq('nothing was raised or repaid',
    pg_temp.cf_section(v_org, 'financing'), 0);

  -- Operating: 6,500 profit + 500 depreciation - 4,000 receivable
  -- + 1,000 payable = 4,000, which is the 6,000 collected less the
  -- 2,000 paid.
  perform pg_temp.check_eq('operating is the cash the trading actually made',
    pg_temp.cf_section(v_org, 'operating'), 4000);

  -- The three sections have to come to the movement, or a reader
  -- adding them up gets a different answer from the one printed.
  perform pg_temp.check_eq('and the three sections add up to it',
    pg_temp.cf_section(v_org, 'operating')
      + pg_temp.cf_section(v_org, 'investing')
      + pg_temp.cf_section(v_org, 'financing'),
    pg_temp.cf(v_org, 'Net movement in cash'));

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Money put in and taken out
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fs_org('Financed Sdn Bhd');
  v_bank uuid;
begin
  v_bank := pg_temp.acct(v_org, '1120');

  -- Shares issued for cash, and a term loan drawn down.
  perform public.post_manual_journal(v_org, date '2026-01-05',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 100000, 'credit', 0,
                         'description', 'Shares issued'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 100000,
                         'description', 'Shares issued')),
    'Issue of share capital');

  perform public.post_manual_journal(v_org, date '2026-02-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 50000, 'credit', 0,
                         'description', 'Term loan'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '2210'),
                         'debit', 0, 'credit', 50000, 'description', 'Term loan')),
    'Loan drawdown');

  perform pg_temp.check_eq('shares and a loan are both financing',
    pg_temp.cf_section(v_org, 'financing'), 150000);
  perform pg_temp.check_eq('and that is all the cash there is',
    pg_temp.cf(v_org, 'Net movement in cash'), 150000);
  perform pg_temp.check_eq('carried forward agrees',
    pg_temp.cf(v_org, 'Cash and cash equivalents carried forward'), 150000);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- A year-end close moves no money
--
-- The closing journal takes a year of profit out of the profit and loss
-- and puts it in retained earnings. Counting it would show the whole
-- year's earnings leaving operations and arriving as financing, for a
-- transaction where nothing left the bank.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fs_org('Closing Sdn Bhd');
  v_cust uuid; v_bank uuid; v_before numeric; v_operating numeric;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Customer Bhd', 'customer') returning id into v_cust;
  v_bank := pg_temp.acct(v_org, '1120');

  perform public.post_manual_journal(v_org, date '2026-06-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 20000, 'credit', 0,
                         'description', 'Fees'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 0, 'credit', 20000, 'description', 'Fees')),
    'Consulting fees');

  v_before := pg_temp.cf_section(v_org, 'operating');
  v_operating := pg_temp.cf(v_org, 'Profit for the period');

  -- The close itself, posted the way the rollover posts it.
  perform public.create_gl_entry(
    v_org, date '2026-12-31', 'year_end_close'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 20000, 'credit', 0,
                         'description', 'Transfer to retained earnings'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3200'),
                         'debit', 0, 'credit', 20000,
                         'description', 'Transfer to retained earnings')),
    'Year end close');

  perform pg_temp.check_eq('the close does not move operating',
    pg_temp.cf_section(v_org, 'operating'), v_before);
  perform pg_temp.check_eq('nor does it invent a financing inflow',
    pg_temp.cf_section(v_org, 'financing'), 0);
  perform pg_temp.check_eq('profit is still the whole year of profit',
    pg_temp.cf(v_org, 'Profit for the period'), v_operating);
  perform pg_temp.check_eq('and the cash still reconciles',
    pg_temp.cf(v_org, 'Net movement in cash'), 20000);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Changes in equity, against the balance sheet
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fs_org('Equity Sdn Bhd');
  v_bank uuid; v_net_assets numeric; v_equity numeric;
begin
  v_bank := pg_temp.acct(v_org, '1120');

  perform public.post_manual_journal(v_org, date '2026-01-05',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 100000, 'credit', 0,
                         'description', 'Shares issued'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3100'),
                         'debit', 0, 'credit', 100000,
                         'description', 'Shares issued')),
    'Issue of share capital');

  -- A year of profit, still sitting in the profit and loss.
  perform public.post_manual_journal(v_org, date '2026-06-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 30000, 'credit', 0,
                         'description', 'Fees'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 0, 'credit', 30000, 'description', 'Fees')),
    'Consulting fees');

  perform pg_temp.check_eq('the shares are on the statement',
    (select closing_balance from
       public.report_changes_in_equity(v_org, date '2026-01-01', date '2026-12-31')
      where code = '3100'), 100000);

  -- The profit is not in any equity account until the year is closed,
  -- and leaving it off would make the statement disagree with the
  -- balance sheet by exactly the year's earnings.
  perform pg_temp.check_eq('and so is the profit, on its own line',
    (select closing_balance from
       public.report_changes_in_equity(v_org, date '2026-01-01', date '2026-12-31')
      where name = 'Profit for the financial period'), 30000);

  select coalesce(sum(case when account_type = 'asset' then balance
                           else -balance end), 0)
    into v_net_assets
    from public.report_balance_sheet(v_org, date '2026-12-31')
   where account_type in ('asset', 'liability');

  select coalesce(sum(closing_balance), 0) into v_equity
    from public.report_changes_in_equity(v_org, date '2026-01-01', date '2026-12-31');

  -- The assertion the statement exists to make.
  perform pg_temp.check_eq('closing equity is the net assets on the balance sheet',
    v_equity, v_net_assets);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- And once the year is closed, the same total, differently arranged
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fs_org('Closed Equity Sdn Bhd');
  v_bank uuid; v_total numeric;
begin
  v_bank := pg_temp.acct(v_org, '1120');

  perform public.post_manual_journal(v_org, date '2026-06-01',
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank, 'debit', 30000, 'credit', 0,
                         'description', 'Fees'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 0, 'credit', 30000, 'description', 'Fees')),
    'Consulting fees');

  perform public.create_gl_entry(
    v_org, date '2026-12-31', 'year_end_close'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', pg_temp.acct(v_org, '4100'),
                         'debit', 30000, 'credit', 0,
                         'description', 'Transfer to retained earnings'),
      jsonb_build_object('account_id', pg_temp.acct(v_org, '3200'),
                         'debit', 0, 'credit', 30000,
                         'description', 'Transfer to retained earnings')),
    'Year end close');

  perform pg_temp.check_eq('the profit line goes to nothing of its own accord',
    (select count(*) from
       public.report_changes_in_equity(v_org, date '2026-01-01', date '2026-12-31')
      where name = 'Profit for the financial period'), 0);
  perform pg_temp.check_eq('because retained earnings has it now',
    (select closing_balance from
       public.report_changes_in_equity(v_org, date '2026-01-01', date '2026-12-31')
      where code = '3200'), 30000);

  select coalesce(sum(closing_balance), 0) into v_total
    from public.report_changes_in_equity(v_org, date '2026-01-01', date '2026-12-31');
  perform pg_temp.check_eq('and the total is unchanged either way', v_total, 30000);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Who can read the accounts
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('a stranger cannot read either statement',
    not has_function_privilege('anon',
      'public.report_cash_flow(uuid, date, date)', 'execute')
    and not has_function_privilege('anon',
      'public.report_changes_in_equity(uuid, date, date)', 'execute'));
  perform pg_temp.check_true('a member can',
    has_function_privilege('authenticated',
      'public.report_cash_flow(uuid, date, date)', 'execute')
    and has_function_privilege('authenticated',
      'public.report_changes_in_equity(uuid, date, date)', 'execute'));
end $$;

rollback;
