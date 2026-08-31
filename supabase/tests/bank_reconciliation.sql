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
-- A reconciliation carries on from the last one
--
-- 0085 refused a difference and stopped there, which let the same period
-- be closed twice and let a date behind a closed one be closed again.
-- Both passed the difference test for the wrong reason: every line up to
-- that date was already reconciled, so there was nothing left to be out
-- by. Each wrote a completed reconciliation that stamped no lines at
-- all — a register reading as three months of diligence and being one.
--
-- The line count is what tells a real reconciliation from a phantom, so
-- it is asserted rather than the row count alone.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.br_org('Rec Forward Sdn Bhd');
  v_bank uuid; v_rcp uuid; v_line uuid; v_first uuid; v_second uuid;
  r jsonb;
begin
  select bank_id, receipt_id into v_bank, v_rcp
    from pg_temp.bank_with_receipt(v_org, 1000);
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date', '2026-03-06',
                       'description', 'Transfer in',
                       'reference', 'RCP-1', 'amount', 1000)));
  select id into v_line from public.bank_transactions
   where bank_account_id = v_bank;
  perform public.match_bank_transaction(v_line, 'receipts', v_rcp);

  v_first := public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);
  perform pg_temp.check_eq('the reconciliation closed over its line',
    (select h.lines from public.report_bank_reconciliations(v_org) h), 1);

  begin
    perform public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);
    raise exception 'FAIL: the same period was closed twice';
  exception when sqlstate '23514' then
    raise notice 'ok   the same statement date cannot be closed twice';
  end;

  begin
    perform public.complete_bank_reconciliation(v_bank, date '2026-03-10', 1000);
    raise exception 'FAIL: a period behind a closed one was closed';
  exception when sqlstate '23514' then
    raise notice 'ok   nor can one behind it';
  end;

  -- The refusals are only worth having if the register stayed clean.
  perform pg_temp.check_eq('and the register holds one reconciliation',
    (select count(*) from public.report_bank_reconciliations(v_org)), 1);
end $$;

-- ---------------------------------------------------------------------
-- Reopening, which is what makes refusing safe
--
-- Without a way back, one wrong date closes the account past where
-- anybody wanted it, permanently. The redo afterwards is the assertion
-- that matters: a reopen that leaves the account unable to be
-- reconciled again has not undone anything.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.br_org('Rec Reopen Sdn Bhd');
  v_bank uuid; v_rcp uuid; v_line uuid; v_first uuid; v_later uuid;
  r jsonb;
begin
  select bank_id, receipt_id into v_bank, v_rcp
    from pg_temp.bank_with_receipt(v_org, 1000);
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date', '2026-03-06',
                       'description', 'Transfer in',
                       'reference', 'RCP-1', 'amount', 1000)));
  select id into v_line from public.bank_transactions
   where bank_account_id = v_bank;
  perform public.match_bank_transaction(v_line, 'receipts', v_rcp);
  v_first := public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);

  perform public.reopen_bank_reconciliation(v_first);
  perform pg_temp.check_eq('reopening takes it out of the register',
    (select count(*) from public.report_bank_reconciliations(v_org)), 0);
  perform pg_temp.check_true('and releases the line it closed over',
    (select reconciliation_id is null from public.bank_transactions
      where id = v_line));
  -- Released, not unmatched: reopening undoes the closing, not the work.
  perform pg_temp.check_true('while leaving it matched',
    (select is_reconciled from public.bank_transactions where id = v_line));

  v_first := public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);
  perform pg_temp.check_eq('so the period can be closed again',
    (select h.lines from public.report_bank_reconciliations(v_org) h), 1);

  -- Once something later exists, the earlier one is out of reach: the
  -- later reconciliation was closed over lines this would release.
  v_later := public.complete_bank_reconciliation(v_bank, date '2026-04-30', 1000);
  begin
    perform public.reopen_bank_reconciliation(v_first);
    raise exception 'FAIL: an earlier reconciliation was reopened';
  exception when sqlstate '23514' then
    raise notice 'ok   an earlier reconciliation cannot be reopened';
  end;

  perform pg_temp.check_true('and the register says which one may be',
    (select h.can_reopen from public.report_bank_reconciliations(v_org) h
      where h.statement_date = date '2026-04-30'));
  perform pg_temp.check_true('and which may not',
    (select not h.can_reopen from public.report_bank_reconciliations(v_org) h
      where h.statement_date = date '2026-03-31'));
  perform pg_temp.check_eq('with both on file',
    (select count(*) from public.report_bank_reconciliations(v_org)), 2);
end $$;

-- ---------------------------------------------------------------------
-- Who may read the register
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.br_org('Rec Access Sdn Bhd');
  v_owner uuid := (select user_id from public.org_members
                    where org_id = v_org and role = 'owner' limit 1);
  v_buyer uuid := pg_temp.another_user('purchaser@bankrec.test');
  v_msg text;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_buyer, 'purchaser');
  perform pg_temp.sign_in_as(v_buyer);
  begin
    perform * from public.report_bank_reconciliations(v_org);
    v_msg := null;
  exception when others then
    v_msg := sqlerrm;
  end;
  -- A caught exception unwinds the sign-in with it.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('a purchaser cannot read the register',
    v_msg = 'Insufficient privileges to read the ledger');
  perform pg_temp.check_eq('and the owner can, on an empty one',
    (select count(*) from public.report_bank_reconciliations(v_org)), 0);
end $$;

-- ---------------------------------------------------------------------
-- The running balance, which is the only figure on a statement that can
-- be checked against the rest of the statement (0369)
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.br_org('Balance Chain Sdn Bhd');
  v_bank uuid; v_rcp uuid;
  r jsonb; v_msg text; v_said text;
begin
  select bank_id, receipt_id into v_bank, v_rcp
    from pg_temp.bank_with_receipt(v_org, 1000);

  -- A statement that adds up, with two lines on its last day — which is
  -- what makes the closing figure a choice rather than a lookup.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-04-01','description','Opening',
                       'amount',500,'running_balance',500),
    jsonb_build_object('transaction_date','2026-04-02','description','Rent',
                       'amount',-200,'running_balance',300),
    jsonb_build_object('transaction_date','2026-04-03','description','Sale',
                       'amount',300,'running_balance',600),
    jsonb_build_object('transaction_date','2026-04-03','description','Fee',
                       'amount',-20,'running_balance',580)));
  perform pg_temp.check_eq('four lines imported', (r->>'imported')::numeric, 4);
  perform pg_temp.check_eq('and three links of the chain were checked',
    (r->>'balance_checks')::numeric, 3);
  perform pg_temp.check_eq('the balance is stored, not merely read',
    (select running_balance from public.bank_transactions
      where bank_account_id = v_bank and transaction_date = date '2026-04-02'),
    300);
  -- The last line of the last day, not the first one on it. Both are
  -- dated 3 April and only one of them is what the account holds.
  perform pg_temp.check_eq('and the closing figure comes back',
    (r->>'closing_balance')::numeric, 580);
  -- Compared as text: the helper has no date overload, and the JSON is
  -- what the app reads anyway.
  perform pg_temp.check_eq('dated', r->>'closing_date', '2026-04-03');

  -- The failure the whole thing exists for: a line the paste clipped.
  -- Without the chain this imports cleanly and the account is short by
  -- 200 for as long as it takes somebody to find it.
  begin
    perform public.import_bank_transactions(v_bank, jsonb_build_array(
      jsonb_build_object('transaction_date','2026-05-01','description','A',
                         'amount',100,'running_balance',700),
      jsonb_build_object('transaction_date','2026-05-03','description','C',
                         'amount',50,'running_balance',550)));
    raise exception 'FAIL: a statement with a hole in it was imported';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a missing line is refused',
    v_said like '%running balance%');
  perform pg_temp.check_true('and the message names the line to go and look at',
    v_said like '%line 2%' and v_said like '%line 1%');
  perform pg_temp.check_eq('and nothing from that statement landed',
    (select count(*) from public.bank_transactions
      where bank_account_id = v_bank and transaction_date >= date '2026-05-01'),
    0);

  -- Newest-first is an ordinary export. Checked forwards it fails on its
  -- first pair, and the message would blame a missing line for what is
  -- only the order.
  --
  -- Two lines on its top day as well, and going this way round the
  -- closing figure is the first of them rather than the last.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-06-03','description','Z2',
                       'amount',100,'running_balance',900),
    jsonb_build_object('transaction_date','2026-06-03','description','Z',
                       'amount',300,'running_balance',800),
    jsonb_build_object('transaction_date','2026-06-02','description','Y',
                       'amount',-200,'running_balance',500),
    jsonb_build_object('transaction_date','2026-06-01','description','X',
                       'amount',500,'running_balance',700)));
  perform pg_temp.check_eq('a newest-first statement imports', (r->>'imported')::numeric, 4);
  perform pg_temp.check_eq('and its chain is checked too',
    (r->>'balance_checks')::numeric, 3);
  perform pg_temp.check_eq('with the closing figure taken from the top of it',
    (r->>'closing_balance')::numeric, 900);

  -- And a hole in one running the other way is caught the same.
  begin
    perform public.import_bank_transactions(v_bank, jsonb_build_array(
      jsonb_build_object('transaction_date','2026-07-03','description','Z',
                         'amount',300,'running_balance',900),
      jsonb_build_object('transaction_date','2026-07-01','description','X',
                         'amount',500,'running_balance',100)));
    raise exception 'FAIL: a hole in a newest-first statement was imported';
  exception when sqlstate '23514' then
    v_msg := sqlerrm;
  end;
  perform pg_temp.check_true('a newest-first hole is refused too',
    v_msg like '%running balance%');

  -- A statement with no balance column at all still imports. The check
  -- is worth having; it is not worth refusing every bank that does not
  -- print one.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-08-01','description','No column',
                       'amount',75)));
  perform pg_temp.check_eq('an unbalanced statement still imports',
    (r->>'imported')::numeric, 1);
  perform pg_temp.check_eq('and claims no checks it did not make',
    (r->>'balance_checks')::numeric, 0);
  perform pg_temp.check_true('nor a closing figure it does not have',
    (r->>'closing_balance') is null);

  -- A gap in the middle breaks the chain rather than failing it: one
  -- link short, not a refusal.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-09-01','description','A',
                       'amount',10,'running_balance',10),
    jsonb_build_object('transaction_date','2026-09-02','description','B',
                       'amount',10),
    jsonb_build_object('transaction_date','2026-09-03','description','C',
                       'amount',10,'running_balance',30)));
  perform pg_temp.check_eq('a blank balance breaks the chain, not the import',
    (r->>'imported')::numeric, 3);
  perform pg_temp.check_eq('and no link is claimed across the gap',
    (r->>'balance_checks')::numeric, 0);
end $$;

-- ---------------------------------------------------------------------
-- Two withdrawals that look like one, and one that looks like two
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.br_org('Twice Over Sdn Bhd');
  v_bank uuid; v_rcp uuid; r jsonb;
begin
  select bank_id, receipt_id into v_bank, v_rcp
    from pg_temp.bank_with_receipt(v_org, 1000);

  -- Two RM 50 cash withdrawals on one day, same machine, same wording.
  -- Ordinary, and until 0369 the second one was dropped every time and
  -- the account was short by fifty ringgit with nothing to say so.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-04-10','description','ATM CASH',
                       'amount',-50,'running_balance',950),
    jsonb_build_object('transaction_date','2026-04-10','description','ATM CASH',
                       'amount',-50,'running_balance',900)));
  perform pg_temp.check_eq('both genuine withdrawals land',
    (r->>'imported')::numeric, 2);
  perform pg_temp.check_eq('and neither is called a duplicate',
    (r->>'skipped')::numeric, 0);

  -- The same paste again. Both balances already exist, so both are the
  -- lines already here rather than two more of them.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-04-10','description','ATM CASH',
                       'amount',-50,'running_balance',950),
    jsonb_build_object('transaction_date','2026-04-10','description','ATM CASH',
                       'amount',-50,'running_balance',900)));
  perform pg_temp.check_eq('re-importing the overlap adds nothing',
    (r->>'imported')::numeric, 0);
  perform pg_temp.check_eq('and skips both', (r->>'skipped')::numeric, 2);
  perform pg_temp.check_eq('the account holds two lines, not four',
    (select count(*) from public.bank_transactions
      where bank_account_id = v_bank and transaction_date = date '2026-04-10'),
    2);
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
  perform pg_temp.check_true('and reopening',
    not has_function_privilege('anon',
      'public.reopen_bank_reconciliation(uuid)', 'execute'));
  perform pg_temp.check_true('while the register is open to authenticated',
    has_function_privilege('authenticated',
      'public.report_bank_reconciliations(uuid, uuid)', 'execute'));
end $$;

rollback;
