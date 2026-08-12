-- =====================================================================
-- iAkauntan :: unrealised FX revaluation tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fx_revaluation.sql
--
-- A debtor book left at the rate it was invoiced at balances perfectly
-- and is wrong by the whole currency movement. No other check in this
-- system looks at it, so these assert the arithmetic and, just as
-- importantly, that running the revaluation twice does not double it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- An org with a fiscal year, a customer, and a rate for the dollar.
create or replace function pg_temp.fx_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- A posted foreign invoice, which is the only kind that can be
-- revalued: an unposted one is not in the ledger to restate.
create or replace function pg_temp.posted_usd_invoice(
  p_org uuid, p_amount numeric, p_rate numeric, p_on date)
returns uuid language plpgsql as $$
declare v_cust uuid; v_doc uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, 'C-'||substr(gen_random_uuid()::text,1,8), 'US Buyer', 'customer')
  returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', 'INV-'||substr(gen_random_uuid()::text,1,8), p_on,
          v_cust, 'USD', p_rate, p_amount, p_amount, p_amount, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_doc, 1, 'Export sale', 1, p_amount);

  perform public.post_sales_document(v_doc);
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- A falling rate on a receivable is a loss
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fx_org('Reval Loss Sdn Bhd');
  v_entry uuid;
  v_ar uuid;
  v_loss uuid;
begin
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70, date '2026-03-01','manual'),
         (v_org,'USD','MYR',4.20, date '2026-03-31','manual');

  perform pg_temp.posted_usd_invoice(v_org, 10000, 4.70, date '2026-03-01');

  select id into v_ar   from public.accounts where org_id = v_org and code = '1210';
  select id into v_loss from public.accounts where org_id = v_org and code = '6500';

  -- USD 10,000 booked at 4.70 is RM 47,000 in receivables. At 4.20 the
  -- same debt is worth RM 42,000. The RM 5,000 difference is a loss that
  -- has not been realised and must still be recognised.
  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_true('a revaluation was posted', v_entry is not null);

  perform pg_temp.check_eq('receivables written down',
    (select coalesce(sum(credit) - sum(debit), 0) from public.gl_lines
      where entry_id = v_entry and account_id = v_ar), 5000);
  perform pg_temp.check_eq('and the loss recognised',
    (select coalesce(sum(debit) - sum(credit), 0) from public.gl_lines
      where entry_id = v_entry and account_id = v_loss), 5000);

  perform pg_temp.check_true('it is marked as a revaluation',
    (select source = 'fx_revaluation' from public.gl_entries where id = v_entry));

  -- The whole point of the exercise: nothing about the foreign amount
  -- moved, so no fc figure may be invented for it.
  perform pg_temp.check_eq('no foreign amounts are invented',
    (select coalesce(sum(fc_debit + fc_credit), 0) from public.gl_lines
      where entry_id = v_entry), 0);
end $$;

-- ---------------------------------------------------------------------
-- Running it again does not double it
--
-- The property that separates a revaluation from a mistake. Each run
-- reverses the standing one and measures again from the booked rate, so
-- two runs at the same date leave the same balance as one.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fx_org('Reval Twice Sdn Bhd');
  v_ar uuid;
  v_first uuid;
  v_second uuid;
  v_standing numeric;
begin
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70, date '2026-03-01','manual'),
         (v_org,'USD','MYR',4.20, date '2026-03-31','manual');

  perform pg_temp.posted_usd_invoice(v_org, 10000, 4.70, date '2026-03-01');
  select id into v_ar from public.accounts where org_id = v_org and code = '1210';

  v_first  := public.revalue_foreign_balances(v_org, date '2026-03-31');
  v_second := public.revalue_foreign_balances(v_org, date '2026-03-31');

  -- The second run contras the first rather than hiding it, so all
  -- three journals stay on the page and the net below is what counts.
  perform pg_temp.check_true('the first is contra-ed by the second',
    (select status = 'posted' from public.gl_entries where id = v_first)
    and exists (select 1 from public.gl_entries r
                 where r.reversed_entry_id = v_first and r.status = 'posted'));

  -- Everything the revaluation has ever done to receivables, across all
  -- three journals: the first, its reversal, and the second.
  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_standing
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where e.org_id = v_org and e.source = 'fx_revaluation'
     and l.account_id = v_ar;

  perform pg_temp.check_eq('and the net adjustment is unchanged', v_standing, 5000);
end $$;

-- ---------------------------------------------------------------------
-- A rate that moves back the other way
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fx_org('Reval Recover Sdn Bhd');
  v_ar uuid; v_gain uuid;
  v_second uuid;
  v_standing numeric;
begin
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70, date '2026-03-01','manual'),
         (v_org,'USD','MYR',4.20, date '2026-03-31','manual'),
         (v_org,'USD','MYR',4.90, date '2026-04-30','manual');

  perform pg_temp.posted_usd_invoice(v_org, 10000, 4.70, date '2026-03-01');
  select id into v_ar   from public.accounts where org_id = v_org and code = '1210';
  select id into v_gain from public.accounts where org_id = v_org and code = '4920';

  perform public.revalue_foreign_balances(v_org, date '2026-03-31');
  v_second := public.revalue_foreign_balances(v_org, date '2026-04-30');

  -- Measured from the booked 4.70, not from March's 4.20: the April
  -- entry is a RM 2,000 gain, not a RM 7,000 one.
  perform pg_temp.check_eq('April measures from the booked rate',
    (select coalesce(sum(credit) - sum(debit), 0) from public.gl_lines
      where entry_id = v_second and account_id = v_gain), 2000);

  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_standing
    from public.gl_lines l
    join public.gl_entries e on e.id = l.entry_id
   where e.org_id = v_org and e.source = 'fx_revaluation'
     and l.account_id = v_ar;

  perform pg_temp.check_eq('and receivables stand RM 2,000 higher overall',
    v_standing, 2000);
end $$;

-- ---------------------------------------------------------------------
-- A payable moves the opposite way
--
-- A liability that costs more to settle than it was booked at is a loss,
-- where the same movement on a receivable is a gain.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fx_org('Reval Payable Sdn Bhd');
  v_supp uuid; v_bill uuid; v_entry uuid; v_ap uuid; v_loss uuid;
begin
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70, date '2026-03-01','manual'),
         (v_org,'USD','MYR',4.90, date '2026-03-31','manual');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org,'S-001','US Supplier','supplier') returning id into v_supp;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org,'bill','BILL-001', date '2026-03-01', v_supp,'USD',4.70,
          10000,10000,10000,'draft')
  returning id into v_bill;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill, 1, 'Imported goods', 1, 10000);

  perform public.post_purchase_document(v_bill);

  select id into v_ap   from public.accounts where org_id = v_org and code = '2110';
  select id into v_loss from public.accounts where org_id = v_org and code = '6500';

  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');

  perform pg_temp.check_eq('the payable grows',
    (select coalesce(sum(credit) - sum(debit), 0) from public.gl_lines
      where entry_id = v_entry and account_id = v_ap), 2000);
  perform pg_temp.check_eq('and that is a loss, not a gain',
    (select coalesce(sum(debit) - sum(credit), 0) from public.gl_lines
      where entry_id = v_entry and account_id = v_loss), 2000);
end $$;

-- ---------------------------------------------------------------------
-- Nothing to do is nothing posted
-- ---------------------------------------------------------------------
do $$
declare v_org uuid := pg_temp.fx_org('Ringgit Only Sdn Bhd');
begin
  perform pg_temp.check_true('a ringgit-only book posts no revaluation',
    public.revalue_foreign_balances(v_org, date '2026-03-31') is null);
end $$;

-- ---------------------------------------------------------------------
-- A currency with no rate is refused, not priced at par
--
-- A document carries its own rate, so a euro invoice can be raised and
-- posted without `exchange_rates` ever having been told what a euro is
-- worth. Revaluation is the moment that catches up. Assuming 1 here
-- would write nearly the whole balance off as an exchange loss.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fx_org('No Rate Sdn Bhd');
  v_cust uuid;
  v_doc uuid;
  r record;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-EUR', 'Euro Buyer', 'customer') returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-EUR', date '2026-03-01', v_cust, 'EUR', 5.10,
          10000, 10000, 10000, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_doc, 1, 'Export sale', 1, 10000);

  perform public.post_sales_document(v_doc);

  begin
    perform public.revalue_foreign_balances(v_org, date '2026-03-31');
    raise exception 'FAIL: revalued a currency it could not price';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a currency with no rate is refused';
  end;

  begin
    select * into r from public.fx_revaluation_preview(v_org, date '2026-03-31');
    raise exception 'FAIL: the preview priced a currency with no rate';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and the preview refuses it too';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The preview says what the posting will do
--
-- Two separate pieces of arithmetic over the same open items. If they
-- disagree, the screen offers one figure and the ledger takes another.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.fx_org('Preview Agrees Sdn Bhd');
  r record;
  v_entry uuid;
begin
  insert into public.exchange_rates
    (org_id, from_currency, to_currency, rate, rate_date, source)
  values (v_org,'USD','MYR',4.70, date '2026-03-01','manual'),
         (v_org,'USD','MYR',4.20, date '2026-03-31','manual');

  perform pg_temp.posted_usd_invoice(v_org, 10000, 4.70, date '2026-03-01');

  select * into r from public.fx_revaluation_preview(v_org, date '2026-03-31');
  perform pg_temp.check_eq('the preview names the closing rate', r.closing_rate, 4.20);
  perform pg_temp.check_eq('and the difference', r.difference, -5000);

  v_entry := public.revalue_foreign_balances(v_org, date '2026-03-31');
  perform pg_temp.check_eq('which is what gets posted',
    (select coalesce(sum(l.debit) - sum(l.credit), 0)
       from public.gl_lines l join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '6500'), 5000);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('revaluation is closed to anon',
    not has_function_privilege('anon',
      'public.revalue_foreign_balances(uuid, date)', 'execute'));
  perform pg_temp.check_true('and the preview too',
    not has_function_privilege('anon',
      'public.fx_revaluation_preview(uuid, date)', 'execute'));
end $$;

rollback;
