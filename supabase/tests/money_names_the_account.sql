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
    -- Deliberately still falling back, and documented at length in
    -- `0728`: every `pos_tender_types` row has no bank account, so
    -- refusing here would stop the till rather than correct it. What is
    -- missing is where each tender's money lands, which is a question
    -- for the people running the shop.
    'app.post_receipt_internal(uuid)',
    -- Demo seeders. Data rather than rules, reseeded rather than
    -- migrated, and they are what put a bank account on the heading in
    -- the twelve companies `0729` leaves alone.
    'app.demo_assets_harta(uuid,uuid)',
    'app.demo_legal_guaman(uuid,uuid)',
    'app.demo_practice_books(uuid,uuid,text,numeric,text)',
    'app.demo_sinar_assets(uuid,uuid)',
    'app.demo_sinar_bank(uuid,uuid)',
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
