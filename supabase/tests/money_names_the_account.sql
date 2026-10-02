-- =====================================================================
-- Money arrives in, or leaves, an account somebody named
-- =====================================================================
--
-- `0727` and `0728` closed five places where a posting function, handed
-- no bank account, credited or debited account 1120 instead. 1120 is
-- "Bank Accounts": postable (`is_group = false` since `0012`) but the
-- HEADING that `upsert_bank_account` hangs the real accounts beneath in
-- the range 1121-1199. An entry on the heading balances and reports and
-- reconciles against nothing.
--
-- Two kinds of assertion here, and the second is the one that was
-- missing for a year:
--
--   * the refusals themselves, by sqlstate and by message; and
--   * that the money landed on the NAMED account and that 1120 got
--     nothing.
--
-- The second kind was impossible to write before `_helpers.sql` grew
-- `test_bank_account`, because every fixture in this directory hung its
-- bank account on 1120 itself -- so "credited the account we named" and
-- "fell through to the heading" were the same observation. That is why
-- 380 files of assertions never saw this. `deposits.sql` even asserted
-- "the money leaves the bank" by checking the credit on `code = '1120'`.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/money_names_the_account.sql
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on
begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A supplier payment says which account it was paid from
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_sup   uuid;
  v_bank  uuid;
  v_gl    uuid;
  v_pay   uuid;
  v_entry uuid;
  -- Today in Kuala Lumpur, not in whatever zone the session happens to
  -- be in. `0419` pinned the product to Malaysia, and between midnight
  -- and eight in the morning there the two are a day apart --
  -- `check_test_clock.py` is the gate that keeps `current_date` out of
  -- new fixtures for that reason.
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Bayar Sdn Bhd');
  perform public.create_fiscal_year(v_org,
                                    date_trunc('year', v_today)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal', 'supplier') returning id into v_sup;

  v_bank := pg_temp.test_bank_account(v_org, 'Akaun semasa');
  select b.account_id into v_gl
    from public.bank_accounts b where b.id = v_bank;

  -- The fixture's own premise: the bank account is NOT 1120.
  perform pg_temp.check_true(
    'a fixture bank account is on an account of its own, not the heading',
    (select a.code <> '1120' from public.accounts a where a.id = v_gl));

  -- 1. No account named.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate)
  values (v_org, 'PY-NONE', v_today, v_sup, 400, 400, 'MYR', 1)
  returning id into v_pay;

  perform pg_temp.check_refused(
    'a payment that does not say where the money came from is refused',
    format('select public.post_purchase_payment(%L)', v_pay),
    '%does not say which account it was paid from%', '23514');

  perform pg_temp.check_true('and it is left unposted, not half-posted',
    (select p.gl_entry_id is null and p.status <> 'posted'
       from public.purchase_payments p where p.id = v_pay));

  -- 2. An account named: the credit lands THERE, and 1120 is untouched.
  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (v_org, 'PY-NAMED', v_today, v_sup, 400, 400, 'MYR', 1, v_bank)
  returning id into v_pay;
  v_entry := public.post_purchase_payment(v_pay);

  perform pg_temp.check_eq('the money leaves the account that was named',
    (select round(sum(l.credit), 2) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_gl), 400::numeric);
  perform pg_temp.check_eq('and the 1120 heading gets nothing',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '1120'), 0);
  perform pg_temp.check_eq('and the named account''s balance moved',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    -400::numeric);

  raise notice 'post_purchase_payment: refused without an account, posted to the named one';
end $$;

-- ---------------------------------------------------------------------
-- A deposit says which account it moved through
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_bank uuid;
  v_gl   uuid;
  v_dep  uuid;
  v_entry uuid;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Deposit Sdn Bhd');
  perform public.create_fiscal_year(v_org,
                                    date_trunc('year', v_today)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer') returning id into v_cust;

  v_bank := pg_temp.test_bank_account(v_org, 'Akaun semasa');
  select b.account_id into v_gl from public.bank_accounts b where b.id = v_bank;

  perform pg_temp.check_refused(
    'a deposit that names no account is refused',
    format('select public.create_deposit(%L, %L, %L, %L, 500)',
           v_org, 'customer', v_cust, v_today),
    '%Say which account the deposit moved through%', '23514');

  -- The four refusals create_deposit already had fire BEFORE the
  -- account is looked at, and have to keep doing so or the new one
  -- would mask them.
  perform pg_temp.check_refused(
    'a deposit for nothing still says so, not "name an account"',
    format('select public.create_deposit(%L, %L, %L, %L, 0)',
           v_org, 'customer', v_cust, v_today),
    'A deposit has to be for something.%');
  perform pg_temp.check_refused(
    'and a deposit for a kind that does not exist still says that',
    format('select public.create_deposit(%L, %L, %L, %L, 500)',
           v_org, 'landlord', v_cust, v_today),
    'A deposit is either taken from a customer%');

  v_dep := public.create_deposit(v_org, 'customer', v_cust, v_today,
                                 500, v_bank, '03', 'FT 1', null);
  select n.gl_entry_id into v_entry
    from public.deposit_notes n where n.id = v_dep;

  perform pg_temp.check_eq('the money arrives in the account that was named',
    (select round(sum(l.debit), 2) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_gl), 500::numeric);
  perform pg_temp.check_eq('and the 1120 heading gets nothing',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '1120'), 0);

  -- ------------------------------------------------------------------
  -- Giving it back, and keeping it, are not the same question
  -- ------------------------------------------------------------------
  -- `settle_deposit` takes the argument OR the note's own account, so a
  -- refund on a note made since `0728` can always find one -- the
  -- refusal below is unreachable through `create_deposit` now, and that
  -- is the point of it: it guards the notes written BEFORE 0728, when a
  -- deposit could be recorded against no account at all. Blanking the
  -- column is how such a row is made here, because the only function
  -- that could produce one no longer will.
  update public.deposit_notes set bank_account_id = null where id = v_dep;
  perform pg_temp.check_refused(
    'a refund with no account on the argument or the note is refused',
    format('select public.settle_deposit(%L, %L, 100)', v_dep, 'refund'),
    '%Say which account the refund is paid out of%', '23514');

  -- A forfeit moved no money, so there is nothing to name and nothing
  -- to refuse. This is the half that makes the refusal above right
  -- rather than merely strict.
  v_entry := public.settle_deposit(v_dep, 'forfeit', 100,
                                   'Cancelled inside the notice period');
  perform pg_temp.check_eq('a forfeit needs no account at all',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code like '112%'), 0);

  v_entry := public.settle_deposit(v_dep, 'refund', 100, null, v_bank);
  perform pg_temp.check_eq('and a refund leaves the account it named',
    (select round(sum(l.credit), 2) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_gl), 100::numeric);

  raise notice 'create_deposit/settle_deposit: an account named, or refused';
end $$;

-- ---------------------------------------------------------------------
-- A receipt lands in an account, and the row says which -- 0731
--
-- `app.post_receipt_internal` was the last posting function with the
-- heading fallback, and `0731` does not simply refuse a null, because
-- three callers reach it without an account and none of them is a
-- person who declined to answer: a counter sale takes it from the
-- tender type, a basket cleared by loyalty points has no tender at
-- all, and `record_group_payment` finds nothing when a company's
-- default account has been closed.
--
-- So it RESOLVES one and WRITES IT ONTO THE RECEIPT. Both halves are
-- asserted, because the write-back is the whole difference from the
-- fallback it replaces: 1120 was chosen at posting time and left no
-- trace, which is how a year of entries reached the heading unnoticed.
-- ---------------------------------------------------------------------
do $$
declare
  v_org     uuid;
  v_cust    uuid;
  v_default uuid;
  v_closed  uuid;
  v_gateway uuid;
  v_rcp     uuid;
  v_entry   uuid;
  v_today   date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Resit Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', v_today)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer') returning id into v_cust;

  -- Three accounts, and the order the rule picks them in matters.
  v_closed  := pg_temp.test_bank_account(
    v_org, 'Akaun lama', 'current', 'MYR', 0, 0, '9001', 'RHB',
    false, true, false);
  v_default := pg_temp.test_bank_account(
    v_org, 'Akaun semasa', 'current', 'MYR', 0, 0, '9002', 'Maybank',
    false, true, true);
  v_gateway := pg_temp.test_bank_account(
    v_org, 'Akaun penyelesaian', 'current', 'MYR', 0, 0, '9003', 'CIMB');

  -- ------------------------------------------------------------------
  -- With no account named, the default one -- and not the closed one
  -- ------------------------------------------------------------------
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount,
     unapplied_amount, currency, exchange_rate)
  values (v_org, 'RCP-N1', v_today, v_cust, 500, 500, 'MYR', 1)
  returning id into v_rcp;
  v_entry := public.post_receipt(v_rcp);

  perform pg_temp.check_true(
    'a receipt that named no account is given the default one',
    (select bank_account_id = v_default from public.receipts
      where id = v_rcp));
  perform pg_temp.check_true(
    'and the row says so, rather than the choice living in a journal',
    (select bank_account_id is not null from public.receipts
      where id = v_rcp));
  perform pg_temp.check_eq(
    'the debit is on that account''s own ledger account',
    (select round(sum(l.debit), 2) from public.gl_lines l
      where l.entry_id = v_entry
        and l.account_id = pg_temp.bank_gl(v_default)), 500.00);
  perform pg_temp.check_eq(
    'the 1120 heading gets nothing',
    (select coalesce(round(sum(l.debit + l.credit), 2), 0)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1120'), 0);
  perform pg_temp.check_eq(
    'and the balance moved on the account the row names',
    (select current_balance from public.bank_accounts where id = v_default),
    500.00);
  perform pg_temp.check_eq(
    'while the closed account is untouched',
    (select current_balance from public.bank_accounts where id = v_closed), 0);

  -- ------------------------------------------------------------------
  -- A gateway's settlement account wins over the default
  --
  -- The user's rule for the till in so many words: card and e-wallet
  -- settle into the company's own account, or into another where one
  -- is defined. This is the "where one is defined" half.
  -- ------------------------------------------------------------------
  insert into public.org_payment_gateways
    (org_id, gateway_code, mode, api_key, settlement_bank_account_id,
     is_active)
  values (v_org, 'billplz', 'sandbox', 'sandbox-key', v_gateway, true);

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount,
     unapplied_amount, currency, exchange_rate)
  values (v_org, 'RCP-N2', v_today, v_cust, 300, 300, 'MYR', 1)
  returning id into v_rcp;
  perform public.post_receipt(v_rcp);

  perform pg_temp.check_true(
    'a defined settlement account is used ahead of the default',
    (select bank_account_id = v_gateway from public.receipts
      where id = v_rcp));

  -- ------------------------------------------------------------------
  -- And an account that WAS named is never second-guessed
  -- ------------------------------------------------------------------
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount,
     unapplied_amount, currency, exchange_rate, bank_account_id)
  values (v_org, 'RCP-N3', v_today, v_cust, 100, 100, 'MYR', 1, v_default)
  returning id into v_rcp;
  perform public.post_receipt(v_rcp);

  perform pg_temp.check_true(
    'an account the caller named is the one used, gateway or not',
    (select bank_account_id = v_default from public.receipts
      where id = v_rcp));
end $$;

-- ---------------------------------------------------------------------
-- A client account is not the firm's to bank into
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_rcp   uuid;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Guaman Resit', array['legal']);
  perform public.create_fiscal_year(v_org, date_trunc('year', v_today)::date);
  perform public.setup_legal_module(v_org);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Puan Aminah', 'customer') returning id into v_cust;

  -- `setup_legal_module` made the client account, and it is the firm's
  -- ONLY bank account at this point. Resolving to it would put a fee
  -- into money held for a client, which is the breach of rule 7 of the
  -- Solicitors' Accounts Rules 1990 that `0430` exists to show.
  perform pg_temp.check_true('the client account is the only one so far',
    (select count(*) = 1 from public.bank_accounts
      where org_id = v_org and is_active));

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount,
     unapplied_amount, currency, exchange_rate)
  values (v_org, 'RCP-CL', v_today, v_cust, 450, 450, 'MYR', 1)
  returning id into v_rcp;

  perform pg_temp.check_refused(
    'a fee is not banked into the client account for want of another',
    format($q$ select public.post_receipt(%L) $q$, v_rcp),
    '%no bank account for it to arrive in%');

  -- The control: give the firm an office account and the same receipt
  -- posts, into that one.
  perform pg_temp.test_bank_account(v_org, 'Office Current');
  perform public.post_receipt(v_rcp);
  perform pg_temp.check_true(
    'and with an office account it lands there instead',
    (select not b.is_client_account from public.receipts r
       join public.bank_accounts b on b.id = r.bank_account_id
      where r.id = v_rcp));
end $$;

-- ---------------------------------------------------------------------
-- Where this tender's money lands -- 0731
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_till  uuid;
  v_bank  uuid;
  v_cash  uuid;
  v_card  uuid;
  v_named uuid;
begin
  v_org := pg_temp.test_org('Kedai Resit Sdn Bhd');

  v_bank := pg_temp.test_bank_account(v_org, 'Akaun semasa');
  v_till := pg_temp.test_bank_account(v_org, 'Tunai', 'cash');

  insert into public.pos_tender_types
    (org_id, code, name, kind, counts_in_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', true) returning id into v_cash;
  insert into public.pos_tender_types
    (org_id, code, name, kind)
  values (v_org, 'KAD', 'Kad', 'card') returning id into v_card;
  insert into public.pos_tender_types
    (org_id, code, name, kind, bank_account_id)
  values (v_org, 'KAD2', 'Kad lain', 'card', v_till)
  returning id into v_named;

  perform pg_temp.check_true(
    'cash lands in the drawer, which is a bank account of type cash',
    (select bank_account_id = v_till from public.pos_tender_types
      where id = v_cash));
  perform pg_temp.check_true(
    'a card settles into the bank account, days later',
    (select bank_account_id = v_bank from public.pos_tender_types
      where id = v_card));
  perform pg_temp.check_true(
    'and a tender that says where it lands is left alone',
    (select bank_account_id = v_till from public.pos_tender_types
      where id = v_named));

  -- The control for the three above: with no account of either kind,
  -- the column is left null rather than filled with something. The
  -- refusal then belongs to the posting, which is where somebody can
  -- be told to add an account.
  declare v_bare uuid; v_t uuid;
  begin
    v_bare := pg_temp.test_org('Kedai Kosong Sdn Bhd');
    insert into public.pos_tender_types (org_id, code, name, kind)
    values (v_bare, 'TUNAI', 'Tunai', 'cash') returning id into v_t;
    perform pg_temp.check_true(
      'a company with no bank account gets a tender with no account',
      (select bank_account_id is null from public.pos_tender_types
        where id = v_t));
  end;
end $$;

-- ---------------------------------------------------------------------
-- A cheque clears into an account, or it has not cleared
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_cust uuid;
  v_bank uuid;
  v_gl   uuid;
  v_pdc  uuid;
  v_entry uuid;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Cek Sdn Bhd');
  perform public.create_fiscal_year(v_org,
                                    date_trunc('year', v_today)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer') returning id into v_cust;

  v_bank := pg_temp.test_bank_account(v_org, 'Akaun semasa');
  select b.account_id into v_gl from public.bank_accounts b where b.id = v_bank;

  -- A cheque on the register with no bank account on it: `clear_pdc`
  -- takes the argument or the cheque's own column, and here there is
  -- neither.
  insert into public.post_dated_cheques
    (org_id, pdc_no, direction, contact_id, cheque_no, cheque_date, amount,
     received_on)
  values (v_org, 'PDC-NONE', 'incoming', v_cust, '700001',
          v_today + 10, 2500, v_today)
  returning id into v_pdc;

  perform pg_temp.check_refused(
    'a cheque cannot clear into no account',
    format('select public.clear_pdc(%L)', v_pdc),
    '%Say which account the cheque cleared through%', '23514');

  perform pg_temp.check_true('and the cheque is still held, not cleared',
    (select c.status::text = 'held' and c.cleared_on is null
       from public.post_dated_cheques c where c.id = v_pdc));

  v_entry := public.clear_pdc(v_pdc, v_today, v_bank);
  perform pg_temp.check_eq('named, it clears into that account',
    (select round(sum(l.debit), 2) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_gl), 2500::numeric);
  perform pg_temp.check_eq('and the 1120 heading gets nothing',
    (select count(*) from public.gl_lines l
      join public.accounts a on a.id = l.account_id
     where l.entry_id = v_entry and a.code = '1120'), 0);
  perform pg_temp.check_eq('and the balance moved by the face of the cheque',
    (select b.current_balance from public.bank_accounts b where b.id = v_bank),
    2500::numeric);

  raise notice 'clear_pdc: an account named, or it has not cleared';
end $$;

-- ---------------------------------------------------------------------
-- THE ALLOW-LIST: which functions may still mention the heading at all
-- ---------------------------------------------------------------------
--
-- This exists because a human got the count wrong. `0728` reported that
-- `app.post_receipt_internal` was the only function left containing
-- `code = '1120'`. The real number was NINE, and the evidence for "one"
-- was a query filtered to the functions already known -- it could only
-- confirm what had been put into it. Two live posting paths,
-- `dispose_fixed_asset` and `remit_withholding`, were never examined
-- and `0729` closed them.
--
-- So the question is asked the other way round here: sweep EVERY
-- function body in `public` and `app`, and require the set that mentions
-- the heading to be exactly the set named below. A tenth cannot appear
-- quietly, and fixing one of these requires deleting its line, which is
-- a visible act in a diff.
--
-- `prokind = 'f'` excludes aggregates: `pg_get_function_identity_arguments`
-- raises on one, which is a confusing error to meet from a test.
do $$
declare
  v_allowed text[] := array[
    -- `app.post_receipt_internal` came OFF this list in `0731`. It was
    -- the last posting function with the fallback, kept because every
    -- `pos_tender_types` row had no bank account and refusing would
    -- have stopped the till. The answer arrived -- card and e-wallet
    -- settle into the company's own account, cash stays in the drawer
    -- -- and the till it would have stopped turned out to be five demo
    -- companies and no real one.
    -- Demo seeders that read the heading for a JOURNAL LINE and do not
    -- hang a bank account on it. Data rather than rules, reseeded
    -- rather than migrated.
    --
    -- The three that did hang one there -- `demo_sinar_bank`,
    -- `demo_practice_books`, `demo_legal_guaman` -- came off this list
    -- in `0730`, which had to change them: a trigger refusing a bank
    -- account on the heading would otherwise have broken
    -- `app.demo_rebuild()` on the next reseed. `app.demo_purchases` did
    -- the same and was never on the list at all, because it asks for
    -- the heading through a `case` expression and the sweep below
    -- matches a literal comparison. **This list is a net with a known
    -- mesh.**
    'app.demo_assets_harta(uuid,uuid)',
    'app.demo_sinar_assets(uuid,uuid)',
    'app.demo_sinar_payroll(uuid,uuid)'
  ];
  v_found text[];
  v_new   text[];
  v_gone  text[];
begin
  -- `p.oid::regprocedure::text`, NOT
  -- `pg_get_function_identity_arguments` -- that one prints PARAMETER
  -- NAMES, so a seeder comes back as `app.demo_sinar_bank(p_org uuid,
  -- p_owner uuid)` and never matches a list written in types. The first
  -- run of this assertion failed for exactly that and named all seven
  -- allowed functions as new ones, which is a formatting failure
  -- wearing the costume of a real finding.
  --
  -- `regprocedure` also schema-qualifies only where it must, so an
  -- entry in `public` appears bare: `dispose_fixed_asset(...)`, not
  -- `public.dispose_fixed_asset(...)`. The list below is spelled the
  -- way this prints it.
  select coalesce(array_agg(fn order by fn), array[]::text[]) into v_found
    from (
      select p.oid::regprocedure::text as fn
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'app')
         and p.prokind = 'f'
         and pg_get_functiondef(p.oid) like '%code = ''1120''%'
    ) s;

  select coalesce(array_agg(f order by f), array[]::text[]) into v_new
    from unnest(v_found) f where not f = any(v_allowed);

  select coalesce(array_agg(a order by a), array[]::text[]) into v_gone
    from unnest(v_allowed) a where not a = any(v_found);

  -- A NEW one is the failure this file exists for.
  perform pg_temp.check_true(
    'no function outside the allow-list falls back to the 1120 heading'
    || case when cardinality(v_new) = 0 then ''
       else ': ' || array_to_string(v_new, ', ') end,
    cardinality(v_new) = 0);

  -- And the other direction, which is the one that rots. An allow-list
  -- entry matching nothing means somebody fixed a function and left its
  -- exemption behind, and the next person reads the list as the truth.
  perform pg_temp.check_true(
    'and every allow-list entry still matches something'
    || case when cardinality(v_gone) = 0 then ''
       else ': ' || array_to_string(v_gone, ', ') end,
    cardinality(v_gone) = 0);

  raise notice 'the 1120 allow-list holds % functions', cardinality(v_found);
end $$;

rollback;
