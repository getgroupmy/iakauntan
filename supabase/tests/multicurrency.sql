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
    app.exchange_rate_for(v_org, 'MYR', current_date), 1);

  -- The important one. Defaulting a missing rate to 1 would post a
  -- USD 10,000 invoice as RM 10,000: balanced, four times understated,
  -- and invisible to every other assertion in this suite.
  begin
    perform app.exchange_rate_for(v_org, 'USD', current_date);
    raise exception 'FAIL: a missing rate was silently treated as 1';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a missing rate refuses to guess';
  end;

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.20,current_date - 30,'manual'),
         (v_org,'USD','MYR',4.70,current_date -  1,'manual'),
         (v_org,'USD','MYR',9.99,current_date +  5,'manual');

  -- A document is converted at the rate that was known on its own date,
  -- so a rate entered for next week must not reach back and restate it.
  perform pg_temp.check_eq('rate today',
    app.exchange_rate_for(v_org,'USD',current_date), 4.70);
  perform pg_temp.check_eq('rate for a back-dated document',
    app.exchange_rate_for(v_org,'USD',current_date - 15), 4.20);

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- What a foreign entry records
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('FX Ledger Sdn Bhd');
  v_ar uuid; v_sales uuid; v_entry uuid;
  v_base numeric; v_fc numeric;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  select id into v_ar    from public.accounts where org_id=v_org and code='1210';
  select id into v_sales from public.accounts where org_id=v_org and code='4100';

  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70,current_date,'manual');

  v_entry := app.create_gl_entry_internal(
    v_org, current_date, 'manual',
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
    v_org, current_date, 'manual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_ar,    'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 100)),
    'A ringgit invoice');
  perform pg_temp.check_eq('a base-currency entry writes no foreign amount',
    (select sum(fc_debit + fc_credit) from public.gl_lines where entry_id = v_entry), 0);

  -- A foreign entry with no usable rate would post zeroes and balance.
  begin
    perform app.create_gl_entry_internal(
      v_org, current_date, 'manual',
      jsonb_build_array(
        jsonb_build_object('account_id', v_ar, 'debit', 1, 'credit', 0),
        jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 1)),
      'no rate', null, null, null, 'USD', 0);
    raise exception 'FAIL: a USD entry posted with a zero rate';
  exception when sqlstate '23514' then
    raise notice 'ok   a foreign entry with no rate is refused';
  end;

  perform pg_temp.sign_out();
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
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  select id into v_ar from public.accounts where org_id=v_org and code='1210';

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'FXC-1', 'Overseas Buyer Inc', 'customer') returning id into v_cust;

  insert into public.bank_accounts (org_id, account_id, name)
  values (v_org, (select id from public.accounts where org_id=v_org and code='1120'),
          'Current account') returning id into v_bank;

  insert into public.exchange_rates (org_id,from_currency,to_currency,rate,rate_date,source)
  values (v_org,'USD','MYR',4.70,current_date - 10,'manual'),
         (v_org,'USD','MYR',4.50,current_date,'manual');

  -- USD 10,000 invoiced when a dollar was RM 4.70.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'invoice','FX-INV-1', current_date - 10, v_cust,'USD',4.70,
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
  values (v_org,'FX-RCP-1', current_date, v_cust, 10000, 10000,'USD',4.50, v_bank)
  returning id into v_rcp;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_inv, 10000);
  perform public.post_receipt(v_rcp);

  -- The assertion that matters: nothing left against the customer.
  select sum(g.debit - g.credit) into v_bal
    from public.gl_lines g join public.gl_entries e on e.id = g.entry_id
   where g.account_id = v_ar and e.source_id in (v_inv, v_rcp);
  perform pg_temp.check_eq('receivables clear to nothing', v_bal, 0);

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
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  select id into v_ar from public.accounts where org_id=v_org and code='1210';
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org,'FXC-2','Overseas Buyer Inc','customer') returning id into v_cust;
  insert into public.bank_accounts (org_id, account_id, name)
  values (v_org,(select id from public.accounts where org_id=v_org and code='1120'),
          'Current account') returning id into v_bank;
  insert into public.exchange_rates (org_id,from_currency,to_currency,rate,rate_date,source)
  values (v_org,'USD','MYR',4.50,current_date - 10,'manual');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'invoice','FX-INV-2', current_date - 10, v_cust,'USD',4.50,
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
  values (v_org,'FX-RCP-2', current_date, v_cust, 10000, 10000,'USD',4.70, v_bank)
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

-- Settling a USD invoice with a ringgit receipt is refused rather than
-- guessed at. It is a real thing businesses do, and it needs a stated
-- conversion; inventing one would be worse than saying so.
do $$
declare
  v_org uuid := pg_temp.test_org('FX Mismatch Sdn Bhd');
  v_cust uuid; v_bank uuid; v_inv uuid; v_rcp uuid;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org,'FXC-3','Overseas Buyer Inc','customer') returning id into v_cust;
  insert into public.bank_accounts (org_id, account_id, name)
  values (v_org,(select id from public.accounts where org_id=v_org and code='1120'),
          'Current account') returning id into v_bank;
  insert into public.exchange_rates (org_id,from_currency,to_currency,rate,rate_date,source)
  values (v_org,'USD','MYR',4.50,current_date,'manual');

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'invoice','FX-INV-3', current_date, v_cust,'USD',4.50,
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
  values (v_org,'FX-RCP-3', current_date, v_cust, 100, 100,'MYR',1, v_bank)
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
