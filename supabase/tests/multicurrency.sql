-- =====================================================================
-- iAkauntan :: multi-currency tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/multicurrency.sql
--
-- A wrong exchange rate does not make the ledger unbalanced — it makes it
-- balanced and wrong, which no other check in this system would catch. So
-- these assert the arithmetic rather than the plumbing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- Resolving a rate
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('FX Test Sdn Bhd');
begin
  perform pg_temp.check_eq('base currency resolves to 1',
    app.exchange_rate_for(v_org, 'MYR', pg_temp.today()), 1);

  -- The important one. Defaulting a missing rate to 1 would post a
  -- USD 10,000 invoice as RM 10,000: balanced, four times understated,
  -- and invisible to every other assertion in this suite.
  begin
    perform app.exchange_rate_for(v_org, 'USD', pg_temp.today());
    raise exception 'FAIL: a missing rate was silently treated as 1';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a missing rate refuses to guess';
  end;

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.20,pg_temp.today() - 30,'manual'),
         (v_org,'USD','MYR',4.70,pg_temp.today() -  1,'manual'),
         (v_org,'USD','MYR',9.99,pg_temp.today() +  5,'manual');

  -- A document is converted at the rate that was known on its own date,
  -- so a rate entered for next week must not reach back and restate it.
  perform pg_temp.check_eq('rate today',
    app.exchange_rate_for(v_org,'USD',pg_temp.today()), 4.70);
  perform pg_temp.check_eq('rate for a back-dated document',
    app.exchange_rate_for(v_org,'USD',pg_temp.today() - 15), 4.20);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What a foreign entry records
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('FX Ledger Sdn Bhd');
  v_ar uuid; v_sales uuid; v_entry uuid;
  v_base numeric; v_fc numeric; v_msg text;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  select id into v_ar    from public.accounts where org_id=v_org and code='1210';
  select id into v_sales from public.accounts where org_id=v_org and code='4100';

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70,pg_temp.today(),'manual');

  v_entry := app.create_gl_entry_internal(
    v_org, pg_temp.today(), 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,    'debit', 47000, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 47000)),
    'USD 10,000 invoice', null, null, null, 'USD', 4.70);

  select sum(debit), sum(fc_debit) into v_base, v_fc
    from public.gl_lines where entry_id = v_entry;

  -- Both halves matter: the ringgit is what the accounts are kept in,
  -- the dollars are what the customer was actually billed and what a
  -- statement in their currency has to show.
  perform pg_temp.check_eq('ringgit posted', v_base, 47000);
  perform pg_temp.check_eq('dollars remembered', v_fc, 10000);

  -- A ringgit entry leaves the foreign columns empty, so a non-zero
  -- figure there always means "this line was in another currency".
  v_entry := app.create_gl_entry_internal(
    v_org, pg_temp.today(), 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,    'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 100)),
    'A ringgit invoice');
  perform pg_temp.check_eq('a base-currency entry writes no foreign amount',
    (select sum(fc_debit + fc_credit) from public.gl_lines where entry_id = v_entry), 0);

  -- A foreign entry with no usable rate would post zeroes and balance.
  begin
    perform app.create_gl_entry_internal(
      v_org, pg_temp.today(), 'manual',
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar, 'debit', 1, 'credit', 0),
        jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 1)),
      'no rate', null, null, null, 'USD', 0);
    raise exception 'FAIL: a USD entry posted with a zero rate';
  exception when sqlstate '23514' then
    -- By the function, not by the table. `gl_entries` has its own
    -- `exchange_rate > 0` check with the SAME SQLSTATE, so catching
    -- 23514 alone passed with the function's guard deleted (the
    -- 2026-10-06 sweep) -- the row was still refused, but with a
    -- constraint name instead of a sentence that says which currency
    -- needed a rate.
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a foreign entry with no rate is refused, and says why: ' || v_msg,
      v_msg like 'A USD entry needs an exchange rate%');
  end;

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- "Foreign" means not the COMPANY'S currency, not "not ringgit"
--
-- A company may keep its books in Singapore dollars (`setBaseCurrency`
-- in the app writes `organizations.base_currency`). Every other entry in
-- this file is for a ringgit company, where "not the base" and "not
-- MYR" are the same test -- so the 2026-10-06 sweep replaced
-- `p_currency <> v_base` with `p_currency <> 'MYR'` and nothing in the
-- suite noticed. For an SGD company that books its OWN currency as
-- foreign (inventing an SGD "foreign amount" on every line) and ringgit
-- as home (dropping the foreign amount a ringgit invoice needs).
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Lion City Pte Ltd');
  v_ar uuid; v_sales uuid; v_home uuid; v_away uuid;
begin
  update public.organizations set base_currency = 'SGD' where id = v_org;
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  select id into v_ar    from public.accounts where org_id=v_org and code='1210';
  select id into v_sales from public.accounts where org_id=v_org and code='4100';

  -- Its own currency: no foreign amount.
  v_home := app.create_gl_entry_internal(
    v_org, pg_temp.today(), 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,    'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0,   'credit', 100)),
    'An SGD invoice', null, null, null, 'SGD', 1);
  perform pg_temp.check_eq('an SGD company''s SGD entry carries no foreign amount',
    (select sum(fc_debit + fc_credit) from public.gl_lines where entry_id = v_home),
    0.00);

  -- Ringgit is foreign to it: SGD 300 at 0.30 is MYR 1,000.
  v_away := app.create_gl_entry_internal(
    v_org, pg_temp.today(), 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,    'debit', 300, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0,   'credit', 300)),
    'A ringgit invoice', null, null, null, 'MYR', 0.30);
  perform pg_temp.check_eq('and its ringgit entry carries the ringgit amount',
    (select fc_debit from public.gl_lines
      where entry_id = v_away and account_id = v_ar), 1000.00);
end $$;

-- ---------------------------------------------------------------------
-- Realised gain and loss: the whole point of the feature
--
-- A customer who pays every dollar they were billed owes nothing. If the
-- rate moved in between, the ringgit do not agree — and the difference
-- has to leave receivables, or the AR ageing shows a debt nobody owes and
-- the balance sheet is wrong by the currency movement on every settled
-- foreign invoice.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('FX Settlement Sdn Bhd');
  v_cust uuid; v_bank uuid; v_ar uuid; v_inv uuid; v_rcp uuid;
  v_bal numeric; v_diff numeric;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  select id into v_ar from public.accounts where org_id=v_org and code='1210';

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'FXC-1', 'Overseas Buyer Inc', 'customer') returning id into v_cust;

  v_bank := pg_temp.test_bank_account(v_org, 'Current account');

  insert into public.exchange_rates (org_id,from_currency,to_currency,rate,rate_date,source)
  values (v_org,'USD','MYR',4.70,pg_temp.today() - 10,'manual'),
         (v_org,'USD','MYR',4.50,pg_temp.today(),'manual');

  -- USD 10,000 invoiced when a dollar was RM 4.70.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'invoice','FX-INV-1', pg_temp.today() - 10, v_cust,'USD',4.70,
          10000,10000,10000,'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total)
  values (v_org, v_inv, 1, 'Export sale', 1, 10000, 10000, 10000);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('receivable booked at the invoice rate',
    (select sum(debit-credit) from public.gl_lines g
       join public.gl_entries e on e.id=g.entry_id
      where g.account_id=v_ar and e.source_id=v_inv), 47000);

  -- Paid in full when a dollar is RM 4.50.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org,'FX-RCP-1', pg_temp.today(), v_cust, 10000, 10000,'USD',4.50, v_bank)
  returning id into v_rcp;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 10000);
  perform public.post_receipt(v_rcp);

  -- The assertion that matters: nothing left against the customer.
  select sum(g.debit - g.credit) into v_bal
    from public.gl_lines g join public.gl_entries e on e.id = g.entry_id
   where g.account_id = v_ar and e.source_id in (v_inv, v_rcp);
  perform pg_temp.check_eq('receivables clear to nothing', v_bal, 0);

  -- And in dollars. The RM 2,000 loss line is a ringgit adjustment with
  -- no foreign amount behind it, so `post_receipt_internal` states its
  -- fc columns as ZERO rather than letting them be derived -- its own
  -- comment: "deriving one would invent dollars that were never
  -- invoiced". The 2026-10-06 sweep made the posting function ignore a
  -- supplied fc_credit and derive it anyway, and that survived every
  -- file: the customer then shows USD 444.44 paid that nobody paid.
  perform pg_temp.check_eq('and the customer owes nothing in dollars either',
    (select sum(g.fc_debit - g.fc_credit)
       from public.gl_lines g join public.gl_entries e on e.id = g.entry_id
      where g.account_id = v_ar and e.source_id in (v_inv, v_rcp)), 0.00);

  select sum(g.debit - g.credit) into v_diff
    from public.gl_lines g join public.gl_entries e on e.id = g.entry_id
   where e.source_id = v_rcp
     and g.account_id = (select id from public.accounts where org_id=v_org and code='6500');
  perform pg_temp.check_eq('RM 2,000 booked as an exchange loss', v_diff, 2000);
  perform pg_temp.check_eq('and recorded on the receipt',
    (select fx_gain_loss from public.receipts where id=v_rcp), -2000);

  perform pg_temp.sign_out();
end $$;

-- A rate that moves the other way is a gain, and lands in 4920.
do $$
declare
  v_org uuid := pg_temp.test_org('FX Gain Sdn Bhd');
  v_cust uuid; v_bank uuid; v_ar uuid; v_inv uuid; v_rcp uuid; v_bal numeric;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  select id into v_ar from public.accounts where org_id=v_org and code='1210';
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org,'FXC-2','Overseas Buyer Inc','customer') returning id into v_cust;
  v_bank := pg_temp.test_bank_account(v_org, 'Current account');
  insert into public.exchange_rates (org_id,from_currency,to_currency,rate,rate_date,source)
  values (v_org,'USD','MYR',4.50,pg_temp.today() - 10,'manual');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'invoice','FX-INV-2', pg_temp.today() - 10, v_cust,'USD',4.50,
          10000,10000,10000,'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total)
  values (v_org, v_inv, 1, 'Export sale', 1, 10000, 10000, 10000);
  perform public.post_sales_document(v_inv);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org,'FX-RCP-2', pg_temp.today(), v_cust, 10000, 10000,'USD',4.70, v_bank)
  returning id into v_rcp;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 10000);
  perform public.post_receipt(v_rcp);

  select sum(g.debit - g.credit) into v_bal
    from public.gl_lines g join public.gl_entries e on e.id = g.entry_id
   where g.account_id = v_ar and e.source_id in (v_inv, v_rcp);
  perform pg_temp.check_eq('receivables clear to nothing', v_bal, 0);
  perform pg_temp.check_eq('RM 2,000 booked as an exchange gain',
    (select sum(g.credit - g.debit) from public.gl_lines g
       join public.gl_entries e on e.id=g.entry_id
      where e.source_id=v_rcp
        and g.account_id=(select id from public.accounts where org_id=v_org and code='4920')),
    2000);
  perform pg_temp.check_eq('and recorded on the receipt',
    (select fx_gain_loss from public.receipts where id=v_rcp), 2000);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- And the same on the side that pays
--
-- A payable moves the opposite way from a receivable: when the ringgit
-- weakens, a customer's dollars are worth more and a supplier's cost
-- more, so what is a gain on one side is a loss on the other. That
-- asymmetry is one sign in `app.realised_fx_on_settlement`, and until
-- this block every assertion about it was a receipt. Flipping the sign
-- on the payment branch — booking every foreign supplier settlement's
-- gain as a loss and every loss as a gain — changed nothing that failed.
--
-- Found by changing it and re-running.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('FX Payable Sdn Bhd');
  v_sup uuid; v_bank uuid; v_ap uuid; v_bill uuid; v_pay uuid;
  v_bal numeric; v_diff numeric;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  select id into v_ap from public.accounts where org_id=v_org and code='2110';

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'FXS-1', 'Overseas Supplier Inc', 'supplier')
  returning id into v_sup;
  v_bank := pg_temp.test_bank_account(v_org, 'Current account');

  insert into public.exchange_rates (org_id,from_currency,to_currency,rate,rate_date,source)
  values (v_org,'USD','MYR',4.70,pg_temp.today() - 10,'manual'),
         (v_org,'USD','MYR',4.50,pg_temp.today(),'manual');

  -- USD 10,000 billed when a dollar was RM 4.70.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'bill','FX-BILL-1', pg_temp.today() - 10, v_sup,'USD',4.70,
          10000,10000,10000,'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total)
  values (v_org, v_bill, 1, 'Imported goods', 1, 10000, 10000, 10000);
  perform public.post_purchase_document(v_bill);

  perform pg_temp.check_eq('the payable is booked at the bill rate',
    (select sum(credit-debit) from public.gl_lines g
       join public.gl_entries e on e.id=g.entry_id
      where g.account_id=v_ap and e.source_id=v_bill), 47000);

  -- Paid in full when a dollar is RM 4.50, so RM 45,000 settles a
  -- RM 47,000 payable. The company owed dollars and the dollars got
  -- cheaper: that is a gain, where the same movement on a receivable
  -- was a loss.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org,'FX-PAY-1', pg_temp.today(), v_sup, 10000, 10000,'USD',4.50, v_bank)
  returning id into v_pay;
  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay, v_bill, 10000);
  perform public.post_purchase_payment(v_pay);

  select sum(g.debit - g.credit) into v_bal
    from public.gl_lines g join public.gl_entries e on e.id = g.entry_id
   where g.account_id = v_ap and e.source_id in (v_bill, v_pay);
  perform pg_temp.check_eq('payables clear to nothing', v_bal, 0);

  -- 4920 is the gain account; 6500 the loss. Which one it lands in is
  -- the assertion, because a sign flip puts the right number in the
  -- wrong one and the ledger still balances.
  select sum(g.credit - g.debit) into v_diff
    from public.gl_lines g join public.gl_entries e on e.id = g.entry_id
   where e.source_id = v_pay
     and g.account_id = (select id from public.accounts
                          where org_id=v_org and code='4920');
  perform pg_temp.check_eq('RM 2,000 booked as an exchange gain, not a loss',
    v_diff, 2000);
  perform pg_temp.check_eq('and nothing reaches the loss account',
    coalesce((select sum(g.debit - g.credit)
                from public.gl_lines g
                join public.gl_entries e on e.id = g.entry_id
               where e.source_id = v_pay
                 and g.account_id = (select id from public.accounts
                                      where org_id=v_org and code='6500')), 0), 0);
  perform pg_temp.check_eq('and it is recorded on the payment',
    (select fx_gain_loss from public.purchase_payments where id=v_pay), 2000);

  -- THE PAYMENT'S OWN VALUE IN RINGGIT, which nothing read. A sweep of
  -- post_purchase_payment found `base_amount` unasserted across all
  -- fourteen files that reach it: USD 10,000 at 4.50 is RM 45,000, and
  -- without the conversion the row says 10,000 while the ledger says
  -- 45,000.
  perform pg_temp.check_eq('the payment is worth its ringgit on the row',
    (select base_amount from public.purchase_payments where id=v_pay), 45000);

  -- AND THE GAIN IS ATTRIBUTED TO THE SUPPLIER IT AROSE ON. The fx
  -- pair's payable-side leg carries a contact and the gain-account leg
  -- does not, which is right -- a statement is per party and the gain
  -- account is not -- and neither was read.
  perform pg_temp.check_eq('the gain''s payable leg names the supplier',
    (select g.contact_id from public.gl_lines g
      where g.entry_id = (select gl_entry_id from public.purchase_payments
                           where id = v_pay)
        and g.account_id = v_ap and g.debit = 2000), v_sup);

  -- And the refusal, which the receipt side asserts and this one did
  -- not: a ringgit payment cannot settle a dollar bill.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'bill','FX-BILL-2', pg_temp.today() - 10, v_sup,'USD',4.70,
          1000,1000,1000,'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total)
  values (v_org, v_bill, 1, 'More goods', 1, 1000, 1000, 1000);
  perform public.post_purchase_document(v_bill);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org,'FX-PAY-2', pg_temp.today(), v_sup, 4500, 4500,'MYR',1, v_bank)
  returning id into v_pay;
  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay, v_bill, 1000);
  begin
    perform public.post_purchase_payment(v_pay);
    raise exception 'FAIL: a ringgit payment settled a dollar bill';
  exception when sqlstate '22023' then
    raise notice 'ok   a ringgit payment cannot settle a dollar bill';
  end;

  -- ------------------------------------------------------------------
  -- The other direction, and a charge in dollars
  -- ------------------------------------------------------------------
  -- Everything above is a GAIN, so `app.fx_account(org, false)` -- the
  -- loss account -- was never chosen on the purchase side: swapping the
  -- two accounts put the right number in the wrong one for a loss and
  -- nothing noticed, which is the failure the comment above warns
  -- about, in the half the file did not build.
  --
  -- And a bank charge is in the payment's CURRENCY, so it converts too.
  -- Every charge in the suite was on a ringgit payment at rate 1, where
  -- `round(bank_charges * v_rate, 2)` and `bank_charges` are the same
  -- number.
  --
  -- A bill at 4.50 paid at 4.70: the company owed dollars and the
  -- dollars got DEARER, which is a loss of RM 200 on USD 1,000. Plus
  -- USD 50 of telegraphic transfer fee, RM 235 at 4.70.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'bill','FX-BILL-3', pg_temp.today() - 10, v_sup,'USD',4.50,
          1000,1000,1000,'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total)
  values (v_org, v_bill, 1, 'Goods that got dearer', 1, 1000, 1000, 1000);
  perform public.post_purchase_document(v_bill);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id, bank_charges)
  values (v_org,'FX-PAY-3', pg_temp.today(), v_sup, 1000, 1000,'USD',4.70,
          v_bank, 50)
  returning id into v_pay;
  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  values (v_org, v_pay, v_bill, 1000);
  perform public.post_purchase_payment(v_pay);

  perform pg_temp.check_eq('a dollar that got dearer is a LOSS of two hundred',
    (select sum(g.debit - g.credit) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.source_id = v_pay
        and g.account_id = (select id from public.accounts
                             where org_id = v_org and code = '6500')), 200);
  perform pg_temp.check_eq('and nothing reaches the gain account',
    coalesce((select sum(g.credit - g.debit) from public.gl_lines g
                join public.gl_entries e on e.id = g.entry_id
               where e.source_id = v_pay
                 and g.account_id = (select id from public.accounts
                                      where org_id = v_org and code = '4920')),
             0), 0);
  perform pg_temp.check_eq('the loss is recorded on the payment as negative',
    (select fx_gain_loss from public.purchase_payments where id = v_pay), -200);
  perform pg_temp.check_eq('and the payment is worth its ringgit on the row',
    (select base_amount from public.purchase_payments where id = v_pay), 4700);

  -- The charge, converted: USD 50 at 4.70.
  perform pg_temp.check_eq('a charge in dollars is expensed in ringgit',
    (select sum(g.debit) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
       join public.accounts a on a.id = g.account_id
      where e.source_id = v_pay and a.code = '6300'), 235);
  -- And the bank is credited the payment AND the charge, both
  -- converted: (1000 + 50) * 4.70.
  perform pg_temp.check_eq('and the bank is credited gross and converted',
    (select sum(g.credit) from public.gl_lines g
       join public.gl_entries e on e.id = g.entry_id
      where e.source_id = v_pay
        and g.account_id = (select account_id from public.bank_accounts
                             where id = v_bank)), 4935);

  perform pg_temp.sign_out();
end $$;

-- Settling a USD invoice with a ringgit receipt is refused rather than
-- guessed at. It is a real thing businesses do, and it needs a stated
-- conversion; inventing one would be worse than saying so.
do $$
declare
  v_org uuid := pg_temp.test_org('FX Mismatch Sdn Bhd');
  v_cust uuid; v_bank uuid; v_inv uuid; v_rcp uuid;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(v_org, pg_temp.today() - 30);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org,'FXC-3','Overseas Buyer Inc','customer') returning id into v_cust;
  v_bank := pg_temp.test_bank_account(v_org, 'Current account');
  insert into public.exchange_rates (org_id,from_currency,to_currency,rate,rate_date,source)
  values (v_org,'USD','MYR',4.50,pg_temp.today(),'manual');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'invoice','FX-INV-3', pg_temp.today(), v_cust,'USD',4.50,
          100,100,100,'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_subtotal, line_total)
  values (v_org, v_inv, 1, 'Export sale', 1, 100, 100, 100);
  perform public.post_sales_document(v_inv);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org,'FX-RCP-3', pg_temp.today(), v_cust, 100, 100,'MYR',1, v_bank)
  returning id into v_rcp;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 100);

  begin
    perform public.post_receipt(v_rcp);
    raise exception 'FAIL: a ringgit receipt settled a dollar invoice';
  exception when sqlstate '22023' then
    raise notice 'ok   a cross-currency settlement is refused, not guessed';
  end;

  perform pg_temp.sign_out();
end $$;

rollback;
