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

  -- A gap in the middle is CHECKED ACROSS, which is `0713` and is a
  -- change from what this file asserted before it.
  --
  -- `0369` compared adjacent lines only, so the blank in the middle
  -- here broke the chain and nothing was checked at all. That reads as
  -- cautious and was not: Hong Leong prints a balance on 21 lines of a
  -- 95-line statement, so under the old rule 74 of them were checked by
  -- nothing, and a reader that dropped one of those 74 was never
  -- contradicted.
  --
  -- 10 and 10 between balances of 10 and 30 is a span that bridges, so
  -- the link across the gap is claimed BECAUSE it was verified.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-09-01','description','A',
                       'amount',10,'running_balance',10),
    jsonb_build_object('transaction_date','2026-09-02','description','B',
                       'amount',10),
    jsonb_build_object('transaction_date','2026-09-03','description','C',
                       'amount',10,'running_balance',30)));
  perform pg_temp.check_eq('a blank balance does not stop the import',
    (r->>'imported')::numeric, 3);
  perform pg_temp.check_eq('and the run across the gap is checked as one span',
    (r->>'balance_checks')::numeric, 1);

  -- And the whole point of checking it: the same shape with the middle
  -- line gone no longer bridges, and used to import in silence.
  begin
    perform public.import_bank_transactions(v_bank, jsonb_build_array(
      jsonb_build_object('transaction_date','2026-10-01','description','A',
                         'amount',10,'running_balance',10),
      jsonb_build_object('transaction_date','2026-10-03','description','C',
                         'amount',10,'running_balance',30)));
    raise exception 'FAIL: a line missing from a run was imported';
  exception when sqlstate '23514' then
    v_msg := sqlerrm;
  end;
  perform pg_temp.check_true('a line missing from the run is refused',
    v_msg like '%should come to 20.00%');
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

-- =====================================================================
-- Which document a statement line could be
--
-- `suggest_bank_matches` is what a bookkeeper actually works from: it
-- reads a statement line and offers the receipts, supplier payments and
-- expenses it might be. Until now the file called it once, against a
-- book holding a single receipt, and asserted that the receipt came
-- back. A mutation sweep put fourteen changes through it — the sign of
-- the line, the bank charge on either side, the date window, the
-- already-matched exclusion, the company, the posted-only rule and the
-- ordering — and every one of them survived. With one candidate in the
-- book, the right answer comes back whatever the filters say.
--
-- What the filters are for is a book with more than one thing in it:
--
--   * the sign. A statement credit is a receipt and a debit is a
--     payment or an expense. Offering the wrong side invites a
--     bookkeeper to tie a customer's money to a supplier's bill;
--   * the bank charge. A customer sends RM 1,000 and the bank credits
--     RM 990, keeping ten; paying a supplier RM 1,000 costs RM 1,010.
--     The statement and the document never carry the same figure, and
--     the charge is subtracted on one side and added on the other;
--   * the window. Seven days by default, so a receipt for the same
--     amount a fortnight later is a different receipt;
--   * what is already taken. A document tied to another line must not
--     be offered again, or the same money is banked twice;
--   * the company, and posted only. A draft receipt is not in the
--     ledger to reconcile against.
--
-- The block below builds one book holding all of those at once.
-- =====================================================================

create or replace function pg_temp.sug_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end; $$;

create or replace function pg_temp.sug_receipt(
  p_org uuid, p_bank uuid, p_contact uuid, p_no text, p_amount numeric,
  p_on date, p_charges numeric, p_post boolean)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id, bank_charges)
  values (p_org, p_no, p_on, p_contact, p_amount, p_amount, 'MYR', 1,
          p_bank, p_charges)
  returning id into v_id;
  if p_post then perform public.post_receipt(v_id); end if;
  return v_id;
end; $$;

create or replace function pg_temp.sug_payment(
  p_org uuid, p_bank uuid, p_contact uuid, p_no text, p_amount numeric,
  p_on date, p_charges numeric)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id, bank_charges, payment_mode_code)
  values (p_org, p_no, p_on, p_contact, p_amount, p_amount, 'MYR', 1,
          p_bank, p_charges, '02')
  returning id into v_id;
  perform public.post_purchase_payment(v_id);
  return v_id;
end; $$;

create or replace function pg_temp.sug_expense(
  p_org uuid, p_bank uuid, p_contact uuid, p_account uuid, p_no text,
  p_amount numeric, p_on date)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.expenses
    (org_id, expense_no, expense_date, contact_id, account_id, bank_account_id,
     description, currency, exchange_rate, amount, total_amount,
     payment_mode_code)
  values (p_org, p_no, p_on, p_contact, p_account, p_bank, 'Sundry', 'MYR', 1,
          p_amount, p_amount, '02')
  returning id into v_id;
  perform public.post_expense(v_id);
  return v_id;
end; $$;

create or replace function pg_temp.sug_line(
  p_bank uuid, p_on date, p_amount numeric, p_desc text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform public.import_bank_transactions(p_bank, jsonb_build_array(
    jsonb_build_object('transaction_date', p_on::text, 'description', p_desc,
                       'reference', p_desc, 'amount', p_amount)));
  select id into v_id from public.bank_transactions
   where bank_account_id = p_bank and transaction_date = p_on
     and amount = p_amount and description = p_desc
   order by created_at desc limit 1;
  return v_id;
end; $$;

create or replace function pg_temp.sug_foreign_receipt(
  p_org uuid, p_amount numeric, p_on date)
returns uuid language plpgsql as $$
declare v_acct uuid; v_bank uuid; v_c uuid; v_id uuid;
begin
  select id into v_acct from public.accounts where org_id = p_org and code = '1120';
  insert into public.bank_accounts (org_id, account_id, name, bank_name, account_number)
  values (p_org, v_acct, 'Their bank', 'CIMB', '7777') returning id into v_bank;
  insert into public.contacts (org_id, code, name, contact_type)
  values (p_org, 'C-X', 'Their buyer', 'customer') returning id into v_c;
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (p_org, 'RCP-X', p_on, v_c, p_amount, p_amount, 'MYR', 1, v_bank)
  returning id into v_id;
  perform public.post_receipt(v_id);
  return v_id;
end; $$;

do $$
declare
  v_org uuid := pg_temp.sug_org('Padan Bank Sdn Bhd');
  v_other uuid;
  v_bank uuid; v_acct uuid;
  v_cust uuid; v_supp uuid; v_exp_acct uuid;
  v_in uuid; v_out uuid; v_net uuid; v_charged uuid; v_two uuid;
  v_r1 uuid; v_r2 uuid; v_r3 uuid; v_r4 uuid; v_r7 uuid; v_r8 uuid; v_r9 uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_e1 uuid;
  v_spare uuid; v_taken uuid;
  v_n integer; r record;
begin
  select id into v_acct from public.accounts where org_id = v_org and code = '1120';
  insert into public.bank_accounts (org_id, account_id, name, bank_name, account_number)
  values (v_org, v_acct, 'Maybank current', 'Maybank', '9001')
  returning id into v_bank;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Parts Bhd', 'supplier') returning id into v_supp;
  select id into v_exp_acct from public.accounts
   where org_id = v_org and account_type = 'expense' limit 1;

  -- ------------------------------------------------------------------
  -- Money in on the tenth
  -- ------------------------------------------------------------------
  v_r1 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-1', 1000, date '2026-03-10', 0, true);
  -- Same money, a fortnight later: outside the seven-day window.
  v_r2 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-2', 1000, date '2026-03-25', 0, true);
  -- Same money, two days out, but already tied to another line.
  v_r3 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-3', 1000, date '2026-03-12', 0, true);
  -- Same money, a day out, and never posted.
  v_r4 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-4', 1000, date '2026-03-11', 0, false);
  -- The same amount going the other way on the same day.
  v_p1 := pg_temp.sug_payment(v_org, v_bank, v_supp, 'PAY-1', 1000, date '2026-03-10', 0);
  -- And another company's receipt for the same amount on the same day.
  v_other := pg_temp.sug_org('Bukan Kita Sdn Bhd');
  v_spare := pg_temp.sug_foreign_receipt(v_other, 1000, date '2026-03-10');

  v_in := pg_temp.sug_line(v_bank, date '2026-03-10', 1000, 'Transfer in');
  -- Park RCP-3 against a line of its own so it is genuinely taken.
  v_two := pg_temp.sug_line(v_bank, date '2026-03-12', 1000, 'Another transfer in');
  perform public.match_bank_transaction(v_two, 'receipts', v_r3);

  select count(*)::integer into v_n from public.suggest_bank_matches(v_in);
  perform pg_temp.check_eq(
    'one statement line, one receipt it could be', v_n, 1);
  select * into r from public.suggest_bank_matches(v_in);
  perform pg_temp.check_eq('and it is the one banked that day', r.doc_no, 'RCP-1');
  perform pg_temp.check_eq('with no days between them', r.day_gap, 0);

  -- ------------------------------------------------------------------
  -- Money out on the fifteenth
  -- ------------------------------------------------------------------
  v_p2 := pg_temp.sug_payment(v_org, v_bank, v_supp, 'PAY-2', 800, date '2026-03-15', 0);
  v_e1 := pg_temp.sug_expense(v_org, v_bank, v_supp, v_exp_acct, 'EXP-1', 800,
                              date '2026-03-15');
  perform pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-5', 800, date '2026-03-15', 0, true);

  v_out := pg_temp.sug_line(v_bank, date '2026-03-15', -800, 'Transfer out');
  perform pg_temp.check_eq('money out offers the payment and the expense',
    (select count(*)::integer from public.suggest_bank_matches(v_out)), 2);
  perform pg_temp.check_eq('and never a receipt',
    (select count(*)::integer from public.suggest_bank_matches(v_out)
      where source_table = 'receipts'), 0);
  perform pg_temp.check_eq('nor does money in offer a payment',
    (select count(*)::integer from public.suggest_bank_matches(v_in)
      where source_table <> 'receipts'), 0);

  -- A payment already tied to a line drops off the same way a receipt
  -- does. The two exclusions are written separately, one per branch, so
  -- one of them holding says nothing about the other.
  v_taken := pg_temp.sug_line(v_bank, date '2026-03-15', -800, 'Paid, and matched');
  perform public.match_bank_transaction(v_taken, 'purchase_payments', v_p2);
  perform pg_temp.check_eq('a payment already taken is not offered again',
    (select count(*)::integer from public.suggest_bank_matches(v_out)
      where source_table = 'purchase_payments'), 0);
  perform pg_temp.check_eq('and the expense is still there to choose',
    (select count(*)::integer from public.suggest_bank_matches(v_out)), 1);

  -- ------------------------------------------------------------------
  -- A line for nothing
  -- ------------------------------------------------------------------
  -- Both sides carry a sign test as well as the amount comparison, and
  -- for every non-zero line the comparison alone would do the work: a
  -- receipt and a payment are both CHECKed at nought or more, so
  -- neither can equal a debit. Nought is the one figure where the sign
  -- tests earn their place -- a zero receipt can be posted and a zero
  -- statement line can be imported, and without them a line for nothing
  -- would offer every zero document in the book, on both sides at once.
  -- One of each, because the two sign tests are written separately and
  -- a zero receipt says nothing about the payment branch.
  perform pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-NIL', 0,
                              date '2026-03-18', 0, true);
  perform pg_temp.sug_payment(v_org, v_bank, v_supp, 'PAY-NIL', 0,
                              date '2026-03-18', 0);
  v_taken := pg_temp.sug_line(v_bank, date '2026-03-18', 0, 'Nothing at all');
  perform pg_temp.check_eq('a statement line for nothing matches nothing',
    (select count(*)::integer from public.suggest_bank_matches(v_taken)), 0);

  -- ------------------------------------------------------------------
  -- What the bank kept
  -- ------------------------------------------------------------------
  -- The customer sent RM 1,000 and the bank credited RM 990, keeping ten
  -- ringgit for the transfer. The statement says 990 and the receipt
  -- says 1,000, and the ten ringgit is the whole reason the two do not
  -- look alike.
  v_r7 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-6', 1000, date '2026-03-20', 10, true);
  v_net := pg_temp.sug_line(v_bank, date '2026-03-20', 990, 'Transfer in less charge');
  perform pg_temp.check_eq('a receipt is matched net of what the bank kept',
    (select count(*)::integer from public.suggest_bank_matches(v_net)), 1);
  perform pg_temp.check_eq('and it is the receipt for the gross',
    (select doc_no from public.suggest_bank_matches(v_net)), 'RCP-6');

  -- And the other way: paying a supplier RM 1,000 costs RM 1,010,
  -- because the charge is on top rather than out of it.
  v_p3 := pg_temp.sug_payment(v_org, v_bank, v_supp, 'PAY-3', 1000, date '2026-03-22', 10);
  v_charged := pg_temp.sug_line(v_bank, date '2026-03-22', -1010, 'Transfer out plus charge');
  perform pg_temp.check_eq('a payment is matched with the charge added on',
    (select count(*)::integer from public.suggest_bank_matches(v_charged)), 1);
  perform pg_temp.check_eq('and it is the payment for the net',
    (select doc_no from public.suggest_bank_matches(v_charged)), 'PAY-3');

  -- ------------------------------------------------------------------
  -- The nearest one first
  -- ------------------------------------------------------------------
  v_r8 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-7', 500, date '2026-03-05', 0, true);
  v_r9 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-8', 500, date '2026-03-08', 0, true);
  v_two := pg_temp.sug_line(v_bank, date '2026-03-05', 500, 'Five hundred in');
  perform pg_temp.check_eq('both are offered',
    (select count(*)::integer from public.suggest_bank_matches(v_two)), 2);
  perform pg_temp.check_eq('and the closest date is first',
    (select doc_no from public.suggest_bank_matches(v_two) limit 1), 'RCP-7');

  -- ------------------------------------------------------------------
  -- Somebody else's statement
  -- ------------------------------------------------------------------
  -- The suggestions name every unmatched receipt and payment of a size,
  -- with the customer against each. That is a readable summary of a
  -- company's banking, and the membership check is the only thing
  -- between it and anybody holding a session.
  perform pg_temp.sign_in_as(pg_temp.another_user('nosy@example.test'));
  begin
    perform * from public.suggest_bank_matches(v_in);
    raise exception 'FAIL: a stranger read the suggestions';
  exception when insufficient_privilege then
    raise notice 'ok   a stranger cannot see what a company banked';
  end;
  perform pg_temp.sign_out();
end $$;

-- =====================================================================
-- Matching, and what a closed month will not do
--
-- The block above covers the suggestions -- which document a statement
-- line could be. This one covers the act: tying a line to a document,
-- and closing the month over the lines that are tied.
--
-- A sweep found the arithmetic of closing well asserted (a period
-- cannot be closed twice, a reconciliation that does not balance cannot
-- be completed) and almost everything about WHICH LINES a completed
-- reconciliation claims left open. That is the half that matters to an
-- auditor: a reconciliation stamping a line the bank has not shown, or
-- a line an earlier month already claimed, is a record of an agreement
-- that did not happen.
--
--   * a document that never reached the ledger cannot be matched --
--     there is no journal for the bank to have seen;
--   * nor one belonging to another company. The lookup is by id, and
--     the org in that lookup is the only thing scoping it;
--   * matching and closing are both posting decisions. Somebody who may
--     read the books may not decide what the bank has agreed;
--   * a line inside a completed reconciliation cannot be matched again.
--     `unmatch` was already refused; `match` was not;
--   * and a month takes its own lines and no others. March leaves
--     April's line alone -- matched already, so only its date keeps it
--     out -- and April, closing on top of March, takes one line rather
--     than both. Nor does either month stamp a line that was never
--     matched to anything: the bank's own error and its reversal stay
--     open.
-- =====================================================================

do $$
declare
  v_org uuid := pg_temp.sug_org('Padan Tutup Sdn Bhd');
  v_them uuid; v_acct uuid; v_bank uuid; v_cust uuid;
  v_r1 uuid; v_r2 uuid; v_draft uuid; v_theirs uuid;
  v_march uuid; v_april uuid; v_err1 uuid; v_err2 uuid; v_rec uuid;
  v_clerk uuid; v_owner uuid := pg_temp.test_user();
begin
  select id into v_acct from public.accounts where org_id = v_org and code = '1120';
  insert into public.bank_accounts (org_id, account_id, name, bank_name, account_number)
  values (v_org, v_acct, 'Maybank current', 'Maybank', '5001')
  returning id into v_bank;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer') returning id into v_cust;

  v_r1 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-1', 1000,
                              date '2026-03-10', 0, true);
  -- Banked in April, so it belongs to April's reconciliation.
  v_r2 := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-2', 500,
                              date '2026-04-05', 0, true);
  -- Never posted, so there is no journal for the bank to have seen.
  v_draft := pg_temp.sug_receipt(v_org, v_bank, v_cust, 'RCP-3', 1000,
                                 date '2026-03-10', 0, false);

  v_march := pg_temp.sug_line(v_bank, date '2026-03-10', 1000, 'March in');
  v_april := pg_temp.sug_line(v_bank, date '2026-04-05', 500, 'April in');

  -- The bank debited us in error on the twelfth and put it back the same
  -- day. Neither line answers to anything in the books, and the pair nets
  -- to nothing, so March still agrees with the statement.
  v_err1 := pg_temp.sug_line(v_bank, date '2026-03-12', -25, 'Bank error');
  v_err2 := pg_temp.sug_line(v_bank, date '2026-03-12', 25, 'Bank error put back');

  -- ------------------------------------------------------------------
  -- What cannot be matched
  -- ------------------------------------------------------------------
  begin
    perform public.match_bank_transaction(v_march, 'receipts', v_draft);
    raise exception 'FAIL: an unposted receipt was matched';
  exception when sqlstate 'P0002' then
    raise notice 'ok   a receipt that never reached the ledger cannot be matched';
  end;

  v_them := pg_temp.sug_org('Bukan Kita Sdn Bhd');
  v_theirs := pg_temp.sug_foreign_receipt(v_them, 1000, date '2026-03-10');
  begin
    perform public.match_bank_transaction(v_march, 'receipts', v_theirs);
    raise exception 'FAIL: another company''s receipt was matched';
  exception when sqlstate 'P0002' then
    raise notice 'ok   nor one belonging to another company';
  end;

  -- Matching is a posting decision, not a reading one.
  v_clerk := pg_temp.another_user('clerk@example.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now())
  on conflict (org_id, user_id) do update set role = 'viewer', status = 'active';
  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.match_bank_transaction(v_march, 'receipts', v_r1);
    raise exception 'FAIL: somebody who cannot post matched a line';
  exception when insufficient_privilege then
    raise notice 'ok   and matching needs somebody who may post';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- Closing March
  -- ------------------------------------------------------------------
  perform public.match_bank_transaction(v_march, 'receipts', v_r1);

  -- The same receipt against the same line is that match keyed twice,
  -- not a second deposit. Refusing it would make a repeated click look
  -- like money arriving twice.
  perform public.match_bank_transaction(v_march, 'receipts', v_r1);
  perform pg_temp.check_eq('keying the same match again changes nothing',
    (select count(*)::integer from public.bank_transactions
      where matched_table = 'receipts' and matched_id = v_r1), 1);

  -- April's line is matched before March closes, so nothing but its date
  -- keeps it out of March's reconciliation.
  perform public.match_bank_transaction(v_april, 'receipts', v_r2);

  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);
    raise exception 'FAIL: somebody who cannot post closed the month';
  exception when insufficient_privilege then
    raise notice 'ok   closing the month needs somebody who may post';
  end;
  perform pg_temp.sign_in_as(v_owner);

  v_rec := public.complete_bank_reconciliation(v_bank, date '2026-03-31', 1000);
  perform pg_temp.check_true('March closes', v_rec is not null);

  -- The April line is April's business. A reconciliation that swept it
  -- in would claim the bank had shown money it had not, and April would
  -- open with a line already spoken for.
  perform pg_temp.check_true('and April''s line is left for April',
    (select reconciliation_id is null from public.bank_transactions
      where id = v_april));
  perform pg_temp.check_true('while March''s is stamped with it',
    (select reconciliation_id = v_rec from public.bank_transactions
      where id = v_march));

  -- A reconciliation says which lines the bank and the books agreed on.
  -- The two the bank raised and took back agreed with nothing, so the
  -- month leaves them open rather than closing over them.
  perform pg_temp.check_eq(
    'and the lines nothing was matched to are left open',
    (select count(*)::integer from public.bank_transactions
      where id in (v_err1, v_err2)
        and not is_reconciled and reconciliation_id is null), 2);

  -- ------------------------------------------------------------------
  -- And what a closed month refuses
  -- ------------------------------------------------------------------
  begin
    perform public.match_bank_transaction(v_march, 'receipts', v_r1);
    raise exception 'FAIL: a line inside a closed reconciliation was rematched';
  exception when check_violation then
    raise notice 'ok   a line inside a closed month cannot be matched again';
  end;

  -- ------------------------------------------------------------------
  -- Closing April
  -- ------------------------------------------------------------------
  v_rec := public.complete_bank_reconciliation(v_bank, date '2026-04-30', 1500);
  perform pg_temp.check_true('April closes on top of March', v_rec is not null);
  perform pg_temp.check_true(
    'and takes only its own line, not the one March already claimed',
    (select count(*) = 1 from public.bank_transactions
      where reconciliation_id = v_rec));
end $$;

-- ---------------------------------------------------------------------
-- The fourteen a mutation sweep found
--
-- Thirty-five one-line mutants of import_bank_transactions against six
-- test files. Every mutant of the RUNNING BALANCE died on the first
-- run -- the chain walked forwards and backwards, the step undone going
-- backwards, the hole refused, the count of links claimed, the closing
-- figure taken from the last line of the latest day. Fourteen survived,
-- and they are the front door and the duplicate key: the same split
-- this programme has now seen on ten functions running.
--
-- The key is the one worth explaining. A line already here is matched
-- on date, amount, description, reference and balance, and only the
-- balance half was asserted, because the one probe for it re-pasted an
-- identical statement -- under which dropping ANY single field still
-- skips the line, since the others still match. Each field is asserted
-- below with a pair that differs in exactly that field and nothing
-- else, with no balance column at all so the balance half cannot stand
-- in for the field under test. Drop the date and a standing order
-- charged monthly is imported once and then never again; drop the
-- reference and two identical transfers on one day collapse into one.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.br_org('Sweep Statement Sdn Bhd');
  v_owner uuid := (select user_id from public.org_members
                    where org_id = v_org and role = 'owner' limit 1);
  v_clerk uuid := pg_temp.another_user('reader@statement.test');
  v_bank  uuid; v_rcp uuid; r jsonb; v_msg text; v_state text;
begin
  select bank_id, receipt_id into v_bank, v_rcp
    from pg_temp.bank_with_receipt(v_org, 1000);

  -- ==================================================================
  -- 1. The front door
  -- ==================================================================
  begin
    perform public.import_bank_transactions(gen_random_uuid(),
      jsonb_build_array(jsonb_build_object(
        'transaction_date','2026-05-01','description','X','amount',10)));
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('a statement for an account we do not hold',
    v_msg like 'Bank account % not found');

  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'purchaser');
  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.import_bank_transactions(v_bank,
      jsonb_build_array(jsonb_build_object(
        'transaction_date','2026-05-01','description','X','amount',10)));
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.sign_in_as(v_owner);
  -- The WHOLE message, not merely that something was raised: the marker
  -- above would satisfy a null check on its own.
  perform pg_temp.check_eq('somebody who may not post may not import',
    v_msg, 'Insufficient privileges');
  perform pg_temp.check_eq('and nothing of theirs reached the account',
    (select count(*) from public.bank_transactions
      where bank_account_id = v_bank and transaction_date = date '2026-05-01'),
    0);

  -- A date and an amount are the two things a line cannot do without.
  -- Asserted separately, because one guard covers both and either half
  -- of it can be cut on its own.
  begin
    perform public.import_bank_transactions(v_bank,
      jsonb_build_array(jsonb_build_object(
        'transaction_date','2026-05-01','description','No amount')));
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('a line with no amount is refused',
    v_msg like 'Every line needs a date and an amount%');

  begin
    perform public.import_bank_transactions(v_bank,
      jsonb_build_array(jsonb_build_object(
        'description','No date','amount',10)));
    v_msg := null;
  exception when others then get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('and a line with no date',
    v_msg like 'Every line needs a date and an amount%');

  -- ==================================================================
  -- 2. What makes a line the same line, one field at a time
  --
  -- No running_balance on any of these. With one the balance half of
  -- the key distinguishes the pair by itself, and the field under test
  -- is never reached.
  -- ==================================================================
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-06-01','description','TNG RELOAD',
                       'reference','R1','amount',-30)));
  perform pg_temp.check_eq('the first of them lands', (r->>'imported')::numeric, 1);

  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-06-02','description','TNG RELOAD',
                       'reference','R1','amount',-30)));
  perform pg_temp.check_eq('the same charge on another day is another charge',
    (r->>'imported')::numeric, 1);

  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-06-01','description','TNG RELOAD',
                       'reference','R1','amount',-31)));
  perform pg_temp.check_eq('a different amount is a different line',
    (r->>'imported')::numeric, 1);

  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-06-01','description','TNG TOPUP',
                       'reference','R1','amount',-30)));
  perform pg_temp.check_eq('so is a different description',
    (r->>'imported')::numeric, 1);

  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-06-01','description','TNG RELOAD',
                       'reference','R2','amount',-30)));
  perform pg_temp.check_eq('and so is a different reference',
    (r->>'imported')::numeric, 1);

  perform pg_temp.check_eq('five lines, none of them each other',
    (select count(*) from public.bank_transactions
      where bank_account_id = v_bank
        and transaction_date between date '2026-06-01' and date '2026-06-02'),
    5);

  -- And the control: with every field the same it IS the same line.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-06-01','description','TNG RELOAD',
                       'reference','R1','amount',-30)));
  perform pg_temp.check_eq('while the same line again is the same line',
    (r->>'skipped')::numeric, 1);

  -- ==================================================================
  -- 3. Which way the money went, and what the row carries
  --
  -- transaction_type is what the register colours and what a cash-flow
  -- summary groups on. Reversed, every statement reads as its own
  -- mirror image while every figure on it stays right -- which is why
  -- nothing else in this file would notice.
  -- ==================================================================
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-07-01','description','Money in',
                       'amount',120.50),
    jsonb_build_object('transaction_date','2026-07-01','description','Money out',
                       'amount',-45),
    -- A bank charge waived, or a reversal that nets to nothing. It is
    -- not money leaving.
    jsonb_build_object('transaction_date','2026-07-01','description','Nothing',
                       'amount',0),
    jsonb_build_object('transaction_date','2026-07-02','description','   ',
                       'amount',5,'reference','   ')));

  perform pg_temp.check_eq('money coming in is a deposit',
    (select transaction_type from public.bank_transactions
      where bank_account_id = v_bank and description = 'Money in'), 'deposit');
  perform pg_temp.check_eq('and money going out a withdrawal',
    (select transaction_type from public.bank_transactions
      where bank_account_id = v_bank and description = 'Money out'), 'withdrawal');
  perform pg_temp.check_eq('a line for nothing is not money leaving',
    (select transaction_type from public.bank_transactions
      where bank_account_id = v_bank and description = 'Nothing'), 'deposit');

  -- A column of spaces is an empty column, not a description of spaces.
  -- Stored as a blank it would defeat the duplicate key, which compares
  -- coalesce(description, '') -- and it would print as a blank line in
  -- the register rather than as one with nothing to say.
  perform pg_temp.check_eq('a description of spaces is no description',
    (select count(*) from public.bank_transactions
      where bank_account_id = v_bank and transaction_date = date '2026-07-02'
        and description is null and reference is null), 1);

  -- Every row of one import carries that import's batch, which is what
  -- lets a statement pasted into the wrong account be taken back out.
  perform pg_temp.check_eq('every line of the import carries its batch',
    (select count(*) from public.bank_transactions
      where bank_account_id = v_bank
        and import_batch_id = (r->>'batch_id')::uuid), 4);

  -- The sen. `round(amount, 2)` is EQUIVALENT -- bank_transactions.amount
  -- is numeric(18, 2) and rounds identically on the way in -- and is
  -- recorded here as the sixth equivalent mutant of this programme
  -- rather than removed: it is what makes the figure compared against
  -- the running balance the same figure that is stored.
  r := public.import_bank_transactions(v_bank, jsonb_build_array(
    jsonb_build_object('transaction_date','2026-07-03','description','Interest',
                       'amount',10.567)));
  perform pg_temp.check_eq('a figure with more than sen on it is rounded',
    (select amount from public.bank_transactions
      where bank_account_id = v_bank and description = 'Interest'), 10.57);

  raise notice 'ok   bank statements: the fourteen a sweep found';
end $$;


rollback;
