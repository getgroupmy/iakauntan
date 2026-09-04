-- =====================================================================
-- iAkauntan :: the opening trial balance
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/opening_trial_balance.sql
--
-- One assertion carries this file: **after both halves of a migration,
-- `3900 Opening Balance Equity` is zero.**
--
-- It is worth more than the sum of the figures around it. 0150 posts the
-- receivables invoice by invoice and parks the other side in 3900; this
-- import posts everything except the control accounts and puts the
-- residual in the same place. The two meet at zero only if the old
-- system's receivables total agrees with the invoices actually brought
-- across — so a zero here is a reconciliation, and a non-zero is the
-- amount by which somebody's migration is incomplete.
--
-- Which is also why the control accounts are asserted *not* to move
-- twice. That is the failure this design exists to avoid and it is
-- silent: doubled receivables look like a healthy balance sheet.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.tb_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v;
  perform app.seed_chart_of_accounts(v);
  perform pg_temp.sign_in_as(p_owner);
  perform public.create_fiscal_year(v, date '2026-01-01');
  return v;
end; $$;

create or replace function pg_temp.balance_of(p_org uuid, p_code text)
returns numeric language sql stable as $$
  select round(coalesce(sum(l.debit - l.credit), 0), 2)
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.org_id = p_org and a.code = p_code;
$$;

-- ---------------------------------------------------------------------
-- Both halves of a migration, agreeing
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@tb.test');
  v_org uuid; v_rows jsonb; v_refused boolean; v_msg text; v_n integer;
begin
  v_org := pg_temp.tb_org('Opening TB Sdn Bhd', v_boss);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Pelanggan', 'customer'),
         (v_org, 'S-001', 'Pembekal', 'supplier');

  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-1','contact_code','C-001',
      'doc_date','2025-11-03','outstanding_amount','3000'),
    jsonb_build_object('doc_no','INV-2','contact_code','C-001',
      'doc_date','2026-06-30','outstanding_amount','1200.50')),
    date '2026-08-01', true);
  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','BILL-1','contact_code','S-001',
      'doc_date','2026-05-02','outstanding_amount','800')),
    date '2026-08-01', true);

  perform pg_temp.check_eq(
    'the open items leave the receivables less the payables in suspense',
    (select balance from public.report_opening_balance_suspense(v_org)),
    3400.50);

  v_rows := jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','5000'),
    jsonb_build_object('account_code','1210','debit','4200.50'),
    jsonb_build_object('account_code','2110','credit','800'),
    jsonb_build_object('account_code','3100','credit','1000'),
    jsonb_build_object('account_code','3200','credit','7400.50'));

  -- The preview says the control accounts are not posted, and says so
  -- because it has checked rather than because it always does.
  perform pg_temp.check_true(
    'the receivables row reports agreement with the invoices imported',
    (select message like '%they agree at 4200.50%'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));
  perform pg_temp.check_true('and is not an error',
    (select status = 'ok'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));

  perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);

  -- The assertion this file exists for.
  perform pg_temp.check_eq(
    'once both halves are in, opening balance equity is nothing',
    (select balance from public.report_opening_balance_suspense(v_org)), 0);
  perform pg_temp.check_true('and says so',
    (select settled from public.report_opening_balance_suspense(v_org)));

  -- The control accounts moved once, not twice.
  perform pg_temp.check_eq(
    'receivables are what the invoices came to, not twice that',
    pg_temp.balance_of(v_org, '1210'), 4200.50);
  perform pg_temp.check_eq('and payables likewise',
    pg_temp.balance_of(v_org, '2110'), -800);

  -- And everything else did move.
  perform pg_temp.check_eq('cash came in', pg_temp.balance_of(v_org, '1110'), 5000);
  perform pg_temp.check_eq('share capital came in',
    pg_temp.balance_of(v_org, '3100'), -1000);
  perform pg_temp.check_eq('retained earnings came in',
    pg_temp.balance_of(v_org, '3200'), -7400.50);

  select count(*) into v_n from (
    select l.entry_id from public.gl_lines l
     where l.org_id = v_org group by l.entry_id
    having round(sum(l.debit) - sum(l.credit), 2) <> 0) x;
  perform pg_temp.check_eq('every entry balances', v_n, 0);

  -- Once only. Unlike an invoice there is no document number to catch a
  -- second run, so the guard is the entry itself.
  v_refused := false;
  begin perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);
  exception when others then v_refused := true; v_msg := sqlerrm; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true(
    'a second opening trial balance is refused rather than doubled',
    v_refused);
  perform pg_temp.check_true('and says why',
    v_msg like '%already been brought into this company%');
  perform pg_temp.check_eq('nothing moved', pg_temp.balance_of(v_org, '1110'), 5000);
end $$;

-- ---------------------------------------------------------------------
-- Both halves of a migration, disagreeing
--
-- The control account is where a migration goes wrong, so the case where
-- the two sides differ is asserted rather than assumed. This is also the
-- control for the block above: a function that reported agreement
-- unconditionally would pass every assertion there.
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss2@tb.test');
  v_org uuid; v_rows jsonb;
begin
  v_org := pg_temp.tb_org('Opening TB Dua Sdn Bhd', v_boss);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Pelanggan', 'customer');

  -- One invoice was missed out of the open items.
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-1','contact_code','C-001',
      'doc_date','2025-11-03','outstanding_amount','3000')),
    date '2026-08-01', true);

  v_rows := jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','5000'),
    jsonb_build_object('account_code','1210','debit','4200.50'),
    jsonb_build_object('account_code','3100','credit','1000'),
    jsonb_build_object('account_code','3200','credit','8200.50'));

  perform pg_temp.check_true(
    'a receivables total that does not match what was brought across is '
    'a warning, not silence',
    (select status = 'warning'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));
  perform pg_temp.check_true('naming both figures, which is the useful part',
    (select message like '%4200.50%' and message like '%3000.00%'
       from public.import_opening_balances(v_org, v_rows, date '2026-08-01', false)
      where code = '1210'));

  -- A warning does not stop the file: the migration is still worth
  -- completing, and the difference then shows up where it can be chased.
  perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);

  -- Exactly the invoice that was left out, and on the side that says so:
  -- the report gives credits less debits, so a *debit* balance means the
  -- trial balance expected more receivables than were brought across.
  -- The other sign would mean invoices imported that the old system's
  -- own receivables figure does not account for, which is a different
  -- mistake and wants a different answer.
  perform pg_temp.check_eq(
    'and the suspense account is left holding exactly the difference',
    (select balance from public.report_opening_balance_suspense(v_org)),
    -1200.50);
  perform pg_temp.check_true('reported as unsettled',
    (select not settled from public.report_opening_balance_suspense(v_org)));
end $$;

-- ---------------------------------------------------------------------
-- Files that are wrong
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss3@tb.test');
  v_clerk uuid := pg_temp.another_user('clerk@tb.test');
  v_org uuid; v_refused boolean; v_msg text; v_role text;
begin
  v_org := pg_temp.tb_org('Opening TB Tiga Sdn Bhd', v_boss);

  perform pg_temp.check_true('a heading is refused, because posting to it '
    'would double the accounts under it',
    (select message like '%heading%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','3000','credit','1000'),
         jsonb_build_object('account_code','1110','debit','1000')),
         date '2026-08-01', false)
      where code = '3000'));

  perform pg_temp.check_true('an unknown code is named rather than ignored',
    (select message like '%not an account in this company%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','9999','debit','1000'),
         jsonb_build_object('account_code','3100','credit','1000')),
         date '2026-08-01', false)
      where code = '9999'));

  -- 3900 is created on demand, so in a company that has imported nothing
  -- it does not exist — and the answer must still be the reason it is
  -- refused, not "no such account".
  perform pg_temp.check_true(
    'the suspense account itself is refused by name, even before it exists',
    (select message like '%balances *to*%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','3900','credit','1000'),
         jsonb_build_object('account_code','1110','debit','1000')),
         date '2026-08-01', false)
      where code = '3900'));

  perform pg_temp.check_true('a negative is sent to the other column',
    (select message like '%other column%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','-5')),
         date '2026-08-01', false)
      where code = '1110'));

  perform pg_temp.check_true('and a line on both sides at once is refused',
    (select message like '%one side or the other%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','5','credit','5')),
         date '2026-08-01', false)
      where code = '1110'));

  -- A trial balance that does not balance is not one.
  v_refused := false;
  begin
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1110','debit','5000'),
      jsonb_build_object('account_code','3100','credit','4000')),
      date '2026-08-01', true);
  exception when others then v_refused := true; v_msg := sqlerrm; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('a file that does not balance is refused',
    v_refused);
  perform pg_temp.check_true(
    'saying by how much, which is what somebody goes looking for',
    v_msg like '%difference of 1000.00%');

  -- The control: the same file, balanced, goes in.
  perform public.import_opening_balances(v_org, jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','5000'),
    jsonb_build_object('account_code','3100','credit','5000')),
    date '2026-08-01', true);
  perform pg_temp.check_eq('a balanced one does not',
    pg_temp.balance_of(v_org, '1110'), 5000);

  -- Posting, not preparing.
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accounts_clerk');
  perform pg_temp.sign_in_as(v_clerk);
  v_refused := false;
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1130','debit','1'),
      jsonb_build_object('account_code','3100','credit','1')),
      date '2026-08-01', true);
  exception when others then v_refused := true;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'an accounts clerk cannot bring in an opening ledger', v_refused);
end $$;


-- ---------------------------------------------------------------------
-- The sixteen a mutation sweep found
-- ---------------------------------------------------------------------
-- Thirty one-line mutants of `import_opening_balances` against fourteen
-- test files. Sixteen survived, the highest proportion of any function
-- swept in this programme -- and consistent with the rest of it, because
-- this function is almost entirely FRONT DOOR. It is a validator with a
-- posting at the end, and the rule that has held on every function so
-- far is that the arithmetic gets asserted and the refusals do not.
--
-- The one that matters most is the last line of the validation:
--
--     if p_commit and v_bad > 0 then
--       raise exception 'Nothing was imported: % of % rows have a problem...'
--
-- Delete it and a file full of errors imports anyway. Not "imports
-- wrongly" -- the bad rows are skipped by the posting loop and the good
-- ones go in, so a customer's first ever trial balance lands in the
-- ledger with rows silently missing, balanced against Opening Balance
-- Equity, and nothing on the screen says which. Every one of the eight
-- individual row checks above it was asserted; the line that makes them
-- mean anything was not.
--
-- The rest fall into the usual groups. THE FRONT DOOR: no account code,
-- the same account twice, a debit or a credit that is not a number, a
-- line with nothing on it, an empty journal, and `check_open_item_run`
-- -- which is where the permission and the period lock live, so without
-- it anybody who can read the company can write its opening balances.
-- THE STATE AFTERWARDS: bank balances resynced, cash accounts resynced
-- with them, and a committed row reported as imported rather than as a
-- preview.
--
-- And one piece of arithmetic: the sign a payable's opening balance is
-- read with. A liability compared as though it were an asset makes an
-- agreeing control account look wrong and a wrong one look right.
do $$
declare
  v_boss  uuid := pg_temp.another_user('boss-sapu@tb.test');
  v_other uuid := pg_temp.another_user('outsider-sapu@tb.test');
  v_org   uuid;
  v_rows  jsonb;
  v_msg   text;
  v_n     integer;
  v_bank  uuid;
  v_cash  uuid;
  v_entry uuid;
  v_fresh uuid;
  v_fresh2 uuid;
  v_cash_ac uuid;
begin
  perform pg_temp.sign_in_as(v_boss);
  v_org := pg_temp.test_org('Buka Sapu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  -- Two more companies, for the two assertions about what a COMMITTED
  -- run reports: a second commit in the same company is refused, so
  -- each needs one that has not had one.
  v_fresh  := pg_temp.test_org('Buka Sapu Dua Sdn Bhd');
  perform public.create_fiscal_year(v_fresh, date '2026-01-01');
  v_fresh2 := pg_temp.test_org('Buka Sapu Tiga Sdn Bhd');
  perform public.create_fiscal_year(v_fresh2, date '2026-01-01');

  select id into v_bank from public.accounts
   where org_id = v_org and code = '1110';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance)
  values (v_org, v_bank, 'Current account', 'Maybank', '512345678901',
          'MYR', 0, 0);

  -- A cash account too, because the resync loop takes 'bank' AND 'cash'
  -- and the difference between the two is a mutation nothing else here
  -- would see.
  select id into v_cash_ac from public.accounts
   where org_id = v_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     opening_balance, current_balance)
  values (v_org, v_cash_ac, 'Petty cash', 'Cash', 'CASH-1', 'MYR', 0, 0)
  returning id into v_cash;

  -- ==================================================================
  -- 1. The row checks, one at a time
  -- ==================================================================
  perform pg_temp.check_true('a row with no account code is an error',
    (select status = 'error' and message = 'No account code.'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('debit', '100')), date '2026-08-01', false)
      where row_no = 1));

  perform pg_temp.check_true('the same account twice in one file is an error',
    (select status = 'error'
        and message = '1110 is in this file more than once.'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','100'),
         jsonb_build_object('account_code','1110','debit','100')),
         date '2026-08-01', false)
      where row_no = 2));

  perform pg_temp.check_true('a debit that is not an amount is an error',
    (select status = 'error' and message = '"lots" is not an amount.'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','lots')),
         date '2026-08-01', false)
      where row_no = 1));

  perform pg_temp.check_true('and a credit that is not an amount',
    (select status = 'error' and message = '"some" is not an amount.'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','credit','some')),
         date '2026-08-01', false)
      where row_no = 1));

  perform pg_temp.check_true('a line with nothing on it says so',
    (select message = 'Nothing on this line.'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','0','credit','0')),
         date '2026-08-01', false)
      where row_no = 1));

  -- ==================================================================
  -- 2. And the line that makes those eight checks mean anything
  --
  -- Without it, the bad rows are skipped by the posting loop and the
  -- good ones go in: a first trial balance lands in the ledger with rows
  -- silently missing, balanced to Opening Balance Equity, and nothing
  -- says which.
  -- ==================================================================
  -- The bad row carries nothing, so the file still BALANCES. A bad row
  -- with an amount on it would make the file unbalanced as well -- the
  -- rejected row's figures never reach the totals -- and the balance
  -- check fires first, so the probe would assert that rule instead of
  -- this one.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','1000'),
    jsonb_build_object('account_code','3100','credit','1000'),
    jsonb_build_object('account_code','9999','debit','0','credit','0'));

  begin
    perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);
    raise exception 'a file with a bad row was imported';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a file with a bad row imports nothing at all',
      v_msg,
      'Nothing was imported: 1 of 3 rows have a problem. Fix the file and '
      'run it again.');
  end;

  perform pg_temp.check_eq('and nothing reached the ledger',
    (select count(*)::integer from public.gl_entries
      where org_id = v_org and source = 'opening_balance'), 0);

  -- A file that does not balance says so in the PREVIEW as well, on a
  -- row of its own after the last one -- which is where somebody
  -- checking before they commit will look.
  perform pg_temp.check_true(
    'and an unbalanced file is an error in the preview too',
    (select status = 'error' and message like 'The file does not balance.%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','1110','debit','1000')),
         date '2026-08-01', false)
      where row_no = 2));

  -- ==================================================================
  -- 3. A payable is read as a payable
  --
  -- The control comparison reads an asset as debit-less-credit and
  -- everything else the other way round. Read a payable as an asset and
  -- an agreeing control account looks wrong -- and a wrong one, by the
  -- same amount the other way, looks right.
  -- ==================================================================
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Pembekal', 'supplier');
  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','BILL-S1','contact_code','S-001',
      'doc_date','2026-05-02','outstanding_amount','800')),
    date '2026-08-01', true);

  perform pg_temp.check_true(
    'a payable credited by what the bills come to agrees',
    (select message like '%they agree at 800.00%'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','2110','credit','800'),
         jsonb_build_object('account_code','3100','debit','800')),
         date '2026-08-01', false)
      where code = '2110'));
  -- And debited by the same amount it does not, which is the half that
  -- fails when the sign is read as an asset's.
  perform pg_temp.check_true('and debited by the same amount does not',
    (select status = 'warning'
       from public.import_opening_balances(v_org, jsonb_build_array(
         jsonb_build_object('account_code','2110','debit','800'),
         jsonb_build_object('account_code','3100','credit','800')),
         date '2026-08-01', false)
      where code = '2110'));

  -- ==================================================================
  -- 4. What a real import leaves behind
  -- ==================================================================
  -- 3200 carries nothing. It is not an error -- "Nothing on this line."
  -- is an ok row -- so the commit goes ahead and the posting loop is the
  -- only thing that keeps it out of the journal.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code','1110','debit','5000',
                       'description','Bank at handover'),
    jsonb_build_object('account_code','1120','debit','300'),
    jsonb_build_object('account_code','2110','credit','800'),
    jsonb_build_object('account_code','3200','debit','0','credit','0'),
    jsonb_build_object('account_code','3100','credit','4500'));

  perform public.import_opening_balances(v_org, v_rows, date '2026-08-01', true);

  perform pg_temp.check_eq('the description in the file reaches the journal',
    (select gl.description from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
      where e.org_id = v_org and e.source = 'opening_balance'
        and a.code = '1110'),
    'Bank at handover');

  perform pg_temp.check_eq('the bank account carries what was brought in',
    (select b.current_balance from public.bank_accounts b
       join public.accounts a on a.id = b.account_id
      where b.org_id = v_org and a.code = '1110'), 5000::numeric);
  -- The cash account too. The resync loop takes 'bank' and 'cash', and
  -- taking only 'bank' would leave the petty cash tin reading nought on
  -- a screen that says it holds three hundred.
  perform pg_temp.check_eq('and so does the cash account',
    (select current_balance from public.bank_accounts where id = v_cash),
    300::numeric);

  -- A committed row says it was IMPORTED; the same file previewed says
  -- 'ok'. Both directions, because the rename only happens on commit and
  -- asserting one of them alone holds for a function that always says
  -- the same word.
  perform pg_temp.check_true('a previewed row reports itself ok',
    exists (select 1 from public.import_opening_balances(
              v_org, v_rows, date '2026-08-01', false) where status = 'ok'));
  -- The committed run said 'imported' for every row it took. Asserted
  -- from the run above, whose results were returned to nobody -- so it
  -- is re-run against a company that has not had one, because a second
  -- commit here is exactly what the guard refuses.
  perform pg_temp.check_true('and a committed row reports itself imported',
    exists (select 1 from public.import_opening_balances(
              v_fresh, jsonb_build_array(
                jsonb_build_object('account_code','1110','debit','10'),
                jsonb_build_object('account_code','3100','credit','10')),
              date '2026-08-01', true) where status = 'imported'));
  perform pg_temp.check_true('and none of them says merely ok',
    not exists (select 1 from public.import_opening_balances(
              v_fresh2, jsonb_build_array(
                jsonb_build_object('account_code','1110','debit','10'),
                jsonb_build_object('account_code','3100','credit','10')),
              date '2026-08-01', true) where status = 'ok'));

  -- ==================================================================
  -- 6. A second import, and what makes it a second one
  --
  -- The guard looks for a POSTED opening entry. Reverse the first one
  -- and a second import is allowed again, which is what the refusal
  -- tells the operator to do -- so the `status = 'posted'` in that
  -- lookup is the difference between "reverse it and try again" being
  -- advice and being a dead end.
  -- ==================================================================
  begin
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1110','debit','1'),
      jsonb_build_object('account_code','3100','credit','1')),
      date '2026-08-01', true);
    raise exception 'an opening trial balance was brought in twice';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a second opening balance is refused',
      v_msg,
      'An opening trial balance has already been brought into this '
      'company. Reverse that entry before bringing in another, or the '
      'balances would be counted twice.');
  end;

  -- Filtered on source_table as the guard is. import_open_bills posts
  -- under the same SOURCE, so selecting on source alone picks whichever
  -- entry the scan reaches first and may reverse the wrong one -- which
  -- it did, leaving the trial balance standing and this probe asserting
  -- the already-imported rule instead of the one it is about.
  select ge.id into v_entry from public.gl_entries ge
   where ge.org_id = v_org and ge.source = 'opening_balance'
     and ge.source_table = 'opening_trial_balance'
     and ge.status = 'posted' and not coalesce(ge.is_reversal, false);
  perform public.reverse_gl_entry(v_entry, date '2026-08-01');

  -- ==================================================================
  -- 7. A file that validates and posts nothing
  --
  -- In the window after the reversal and before the next import, which
  -- is the only moment this company has no posted opening entry: with
  -- one, the already-imported guard above fires first and this probe
  -- asserts THAT rule instead. Two probes in this block have now had to
  -- be placed rather than merely written.
  --
  -- Only control accounts, which are compared rather than posted, so
  -- every line is skipped and there is nothing left to make a journal
  -- out of. Refused in words rather than by creating an entry with no
  -- lines, which `assert_balanced` would then pass -- nothing balances.
  --
  -- Probed here rather than earlier because the already-imported guard
  -- sits above this one and fires first: with a posted opening entry in
  -- the company, this probe asserts THAT rule instead. It runs after the
  -- reversal above, where there is none.
  -- ==================================================================
  begin
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1210','debit','800'),
      jsonb_build_object('account_code','2110','credit','800')),
      date '2026-08-01', true);
    raise exception 'an opening balance journal with no lines was created';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a file of nothing but control accounts posts nothing, and says so',
      v_msg, 'There is nothing to post.');
  end;

  perform pg_temp.check_true(
    'and once it is reversed, another may be brought in',
    public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1110','debit','1'),
      jsonb_build_object('account_code','3100','credit','1')),
      date '2026-08-01', true) is not null);

  -- And a line with nothing on it never reaches that journal: it is
  -- reported as such in the preview and skipped in the posting.
  select count(*)::integer into v_n
    from public.gl_lines gl
    join public.gl_entries e on e.id = gl.entry_id
   where e.org_id = v_org and e.source = 'opening_balance'
     and e.status = 'posted' and gl.debit = 0 and gl.credit = 0;
  perform pg_temp.check_eq('and no line for nothing is posted', v_n, 0);

  -- ==================================================================
  -- 5. And the guard on the whole run
  --
  -- app.check_open_item_run is where the permission and the period lock
  -- live. Without it anybody who can read the company can write its
  -- opening balances -- which is the one journal in the books that
  -- nothing else reconciles against.
  -- ==================================================================
  perform pg_temp.sign_in_as(v_other);
  begin
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code','1110','debit','1')),
      date '2026-08-01', false);
    raise exception
      'somebody outside the company read its opening balance import';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    -- Compared whole. `v_msg is not null` would be satisfied by the
    -- marker raised two lines up -- which is the shape the P0004 change
    -- to _helpers.sql was written for, reintroduced by hand here on the
    -- first draft and caught by the re-sweep.
    perform pg_temp.check_eq(
      'somebody outside the company cannot run the import at all',
      v_msg, 'Insufficient privileges');
  end;
  perform pg_temp.sign_in_as(v_boss);

  -- ==================================================================
  -- What the sweep could not kill, and why
  -- ==================================================================
  -- Thirty mutants; twenty-nine die against the assertions above. The
  -- thirtieth is EQUIVALENT: `and ge.status = 'posted'` in the
  -- already-imported lookup.
  --
  -- Every opening balance entry reaches gl_entries through
  -- app.create_gl_entry_internal, which posts it -- there is no path in
  -- this application that leaves one draft. And an opening balance is
  -- undone by REVERSING it, not by voiding it, which 0525 is about and
  -- which the two clauses beside this one now handle. So no entry with
  -- this source_table is ever anything but 'posted', and the clause
  -- cannot change an answer.
  --
  -- Left in place: it is the same predicate the rest of the ledger uses
  -- when it asks whether an entry counts, and dropping it would make
  -- this one lookup the odd one out. The fourth equivalent mutant this
  -- programme has recorded rather than worked around.
  perform pg_temp.check_eq(
    'no opening balance entry is ever anything but posted',
    (select count(*)::integer from public.gl_entries ge
      where ge.source_table = 'opening_trial_balance'
        and ge.status <> 'posted'), 0);

  raise notice 'ok   opening balances: the sixteen a sweep found';
end $$;

rollback;
