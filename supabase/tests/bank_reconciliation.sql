-- =====================================================================
-- iAkauntan :: bank reconciliation tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_reconciliation.sql
--
-- Two things here are worth more than the rest put together: importing
-- the same statement twice must not double the lines, and a
-- reconciliation that does not balance must not be closable. Both are
-- silent failures — the first leaves a bank account overstated, the
-- second buries whatever the difference was.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.br_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- A bank account with one posted receipt into it.
create or replace function pg_temp.bank_with_receipt(
  p_org uuid, p_amount numeric, out bank_id uuid, out receipt_id uuid)
language plpgsql as $$
declare v_acct uuid; v_cust uuid; v_inv uuid;
begin
  select id into v_acct from public.accounts where org_id = p_org and code = '1120';
  insert into public.bank_accounts (org_id, account_id, name, bank_name, account_number)
  values (p_org, v_acct, 'Maybank current', 'Maybank', '1234')
  returning id into bank_id;

  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, 'C-001', 'Buyer', 'customer') returning id into v_cust;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', 'INV-1', date '2026-03-01', v_cust, 'MYR', 1,
          p_amount, p_amount, p_amount, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_inv, 1, 'Sale', 1, p_amount);
  perform public.post_sales_document(v_inv);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (p_org, 'RCP-1', date '2026-03-05', v_cust, p_amount, p_amount,
          'MYR', 1, bank_id)
  returning id into receipt_id;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (p_org, receipt_id, v_inv, p_amount);
  perform public.post_receipt(receipt_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Import, match, complete
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.br_org('Bank Rec Sdn Bhd');
  v_bank uuid; v_rcp uuid; v_line uuid;
  r jsonb; v_st jsonb; v_rec uuid; v_sugg record;
begin
  select bank_id, receipt_id into v_bank, v_rcp
    from pg_temp.bank_with_receipt(v_org, 1000);

  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-03-06','description','Transfer in',
                       'reference','RCP-1','amount',1000)));
  perform pg_temp.check_eq('one line imported', (r->>'imported')::numeric, 1);

  -- The ordinary mistake: months overlap and the same days are imported
  -- again. Every shared line would otherwise be counted twice.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-03-06','description','Transfer in',
                       'reference','RCP-1','amount',1000)));
  perform pg_temp.check_eq('the repeat is skipped', (r->>'skipped')::numeric, 1);
  perform pg_temp.check_eq('and nothing was added', (r->>'imported')::numeric, 0);

  select id into v_line from public.bank_transactions where bank_account_id = v_bank;

  -- Before matching, the books are ahead of the bank by the whole receipt.
  v_st := public.bank_reconciliation_status(v_bank, date '2026-03-31', 1000);
  perform pg_temp.check_eq('book balance', (v_st->>'book_balance')::numeric, 1000);
  perform pg_temp.check_eq('all of it unpresented',
    (v_st->>'unpresented')::numeric, 1000);
  perform pg_temp.check_eq('so the statement should read nothing',
    (v_st->>'expected_statement')::numeric, 0);
  perform pg_temp.check_eq('and it is out by the receipt',
    (v_st->>'difference')::numeric, -1000);

  begin
    perform public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);
    raise exception 'FAIL: completed a reconciliation that did not balance';
  exception when sqlstate '23514' then
    raise notice 'ok   an unbalanced reconciliation cannot be completed';
  end;

  select * into v_sugg from public.suggest_bank_matches(v_line);
  perform pg_temp.check_true('the receipt is suggested',
    v_sugg.source_table = 'receipts' and v_sugg.source_id = v_rcp);

  perform public.match_bank_transaction(v_line, 'receipts', v_rcp);

  v_st := public.bank_reconciliation_status(v_bank, date '2026-03-31', 1000);
  perform pg_temp.check_eq('nothing unpresented once matched',
    (v_st->>'unpresented')::numeric, 0);
  perform pg_temp.check_eq('and it balances', (v_st->>'difference')::numeric, 0);

  v_rec := public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);
  perform pg_temp.check_true('a reconciliation was recorded', v_rec is not null);
  perform pg_temp.check_true('and the line is stamped with it',
    (select reconciliation_id = v_rec from public.bank_transactions where id = v_line));

  -- A completed reconciliation that can still be edited underneath is
  -- not a record of anything.
  begin
    perform public.unmatch_bank_transaction(v_line);
    raise exception 'FAIL: a completed line was unmatched';
  exception when sqlstate '23514' then
    raise notice 'ok   a completed line cannot be unpicked';
  end;
end $$;

-- ---------------------------------------------------------------------
-- One book item, one statement line
--
-- Matching the same receipt to two deposits reconciles both and leaves
-- the account short by one of them.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.br_org('Double Match Sdn Bhd');
  v_bank uuid; v_rcp uuid; v_a uuid; v_b uuid;
begin
  select bank_id, receipt_id into v_bank, v_rcp
    from pg_temp.bank_with_receipt(v_org, 500);

  perform public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-03-05','description','In A','amount',500),
    jsonb_build_object('transaction_date','2026-03-06','description','In B','amount',500)));

  select id into v_a from public.bank_transactions
   where bank_account_id = v_bank and description = 'In A';
  select id into v_b from public.bank_transactions
   where bank_account_id = v_bank and description = 'In B';

  perform public.match_bank_transaction(v_a, 'receipts', v_rcp);
  begin
    perform public.match_bank_transaction(v_b, 'receipts', v_rcp);
    raise exception 'FAIL: one receipt was matched to two statement lines';
  exception when sqlstate '23514' then
    raise notice 'ok   a document can only satisfy one line';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('import is closed to anon',
    not has_function_privilege('anon',
      'public.import_bank_transactions(uuid, jsonb)', 'execute'));
  perform pg_temp.check_true('and completing is too',
    not has_function_privilege('anon',
      'public.complete_bank_reconciliation(uuid, date, numeric)', 'execute'));
end $$;

rollback;
