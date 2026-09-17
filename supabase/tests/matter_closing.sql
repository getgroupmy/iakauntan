-- =====================================================================
-- iAkauntan :: closing a file, and the money that stops you
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/matter_closing.sql
--
-- `app.matter_status` has had `closed` since `0021` and the matters
-- screen has had a Closed tab for as long. Both were empty and always
-- would be: nothing in the system ever wrote that value, so
-- `matters.closed_date` had never held a date and every file a practice
-- ever opened stayed on the live list.
--
-- The claim that matters is the refusal. The Legal Profession
-- (Accounts) Rules 1990 hold that money received for a client is held
-- for a purpose and paid out when the purpose is done; a matter closed
-- with a balance on it is money nobody is looking at any more, which is
-- the ordinary route to unclaimed client money.
--
-- And the claim that matters nearly as much is what is *not* refused.
-- Unbilled time and disbursements are the firm's own, and a practice
-- writing off work on a file that came to nothing is entitled to. They
-- are reported so somebody can decide, not refused so nobody can.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_bank  uuid;
  v_them  uuid;
  v_sale  uuid;
  v_quiet uuid;
  v_txn   uuid;
  v_out   uuid;
  r       jsonb;
  v_said  text;
begin
  v_org := pg_temp.test_org('Tutup Fail & Rakan', array['legal']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);
  perform public.setup_legal_module(v_org);

  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Puan Aminah', 'customer') returning id into v_them;

  insert into public.matters
    (org_id, matter_no, name, client_id, opened_date, fee_earner)
  values (v_org, 'M-1', 'Sale of a house', v_them, date '2026-01-05',
          pg_temp.test_user())
  returning id into v_sale;
  insert into public.matters
    (org_id, matter_no, name, client_id, opened_date, fee_earner)
  values (v_org, 'M-2', 'A quiet file', v_them, date '2026-01-05',
          pg_temp.test_user())
  returning id into v_quiet;

  -- Five thousand on account for the conveyance.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_org, v_sale, 'CT-1', date '2026-02-02', 'receipt',
          v_bank, 5000, 'Deposit on account')
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- ------------------------------------------------------------------
  -- The refusal
  -- ------------------------------------------------------------------
  begin
    perform public.close_matter(v_sale, date '2026-06-30');
    raise exception 'FAIL: a matter holding client money was closed';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a matter holding client money will not close',
    v_said like '%client%money%');
  perform pg_temp.check_true('and the refusal names the amount',
    v_said like '%5,000.00%');
  perform pg_temp.check_true('and says what to do with it',
    v_said like '%other matter%');
  perform pg_temp.check_eq('the matter is untouched',
    (select status::text from public.matters where id = v_sale), 'open');

  -- Paid back out, which is one of the two ways through.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_org, v_sale, 'CT-2', date '2026-06-29', 'payment',
          v_bank, -5000, 'Balance returned to client')
  returning id into v_out;
  perform public.post_client_transaction(v_out);

  r := public.close_matter(v_sale, date '2026-06-30', 'Completion done.');
  perform pg_temp.check_eq('once the money is out, the file closes',
    (select status::text from public.matters where id = v_sale), 'closed');
  perform pg_temp.check_eq('with the date it was closed on',
    (select closed_date from public.matters where id = v_sale)::text,
    '2026-06-30');
  perform pg_temp.check_true('and the closing note is kept',
    (select notes like '%Completion done.%' from public.matters
      where id = v_sale));

  -- The Closed tab, which until now could only ever be empty.
  perform pg_temp.check_eq('and it now appears as closed on the summary',
    (select count(*) from public.report_matter_summary(v_org) s
      where s.matter_id = v_sale and s.status = 'closed'), 1);

  -- Closing twice is not a second closing.
  begin
    perform public.close_matter(v_sale, date '2026-07-01');
    raise exception 'FAIL: a closed matter was closed again';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('a closed matter cannot be closed twice',
    v_said like '%already closed%');
  perform pg_temp.check_eq('and the first closing date stands',
    (select closed_date from public.matters where id = v_sale)::text,
    '2026-06-30');

  -- Before it opened.
  begin
    perform public.close_matter(v_quiet, date '2026-01-01');
    raise exception 'FAIL: a matter closed before it opened';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('and cannot close before it opened',
    v_said like '%before it opened%');

  -- ------------------------------------------------------------------
  -- Reopening
  -- ------------------------------------------------------------------
  perform public.reopen_matter(v_sale);
  perform pg_temp.check_eq('a closed file reopens',
    (select status::text from public.matters where id = v_sale), 'open');
  perform pg_temp.check_true('and the closing date goes with it',
    (select closed_date is null from public.matters where id = v_sale));

  begin
    perform public.reopen_matter(v_quiet);
    raise exception 'FAIL: an open matter was reopened';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('while an open one has nothing to reopen',
    v_said like '%not closed%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- The firm's own money, reported rather than refused
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_them  uuid;
  v_m     uuid;
  v_void  uuid;
  v_draft uuid;
  v_bank  uuid;
  r       jsonb;
  v_said  text;
begin
  v_org := pg_temp.test_org('Hapus Kira & Rakan', array['legal']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);
  perform public.setup_legal_module(v_org);

  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'A client', 'customer') returning id into v_them;
  insert into public.matters
    (org_id, matter_no, name, client_id, opened_date, fee_earner)
  values (v_org, 'M-1', 'A file that came to nothing', v_them,
          date '2026-01-05', pg_temp.test_user())
  returning id into v_m;

  -- Six hours nobody will ever bill, and a search fee.
  insert into public.time_entries
    (org_id, matter_id, entry_date, description, minutes, hourly_rate, amount)
  values (v_org, v_m, date '2026-02-10', 'Drafting', 360, 400, 2400);
  insert into public.disbursements
    (org_id, matter_id, disbursement_date, description, amount, tax_amount)
  values (v_org, v_m, date '2026-02-11', 'Land search', 100, 8);

  -- No client money, so it closes — and says what it left behind. This
  -- is the whole difference between a control and a nag: whose money it
  -- is. The firm may write off its own.
  r := public.close_matter(v_m, date '2026-03-31');
  perform pg_temp.check_eq('a file with unbilled work still closes',
    (select status::text from public.matters where id = v_m), 'closed');
  perform pg_temp.check_eq('and says what was left unbilled',
    (r->>'unbilled_time')::numeric, 2400.00);
  perform pg_temp.check_eq('disbursements with their tax',
    (r->>'unbilled_disbursements')::numeric, 108.00);
  perform pg_temp.check_eq('and the date it used',
    r->>'closed_date', '2026-03-31');

  -- ------------------------------------------------------------------
  -- Which rows the balance is over
  --
  -- `report_matter_summary` and `0021`'s deferred trigger both read
  -- `status <> 'void'`, so closing reads the same rows or the screen and
  -- the refusal disagree about the same file.
  -- ------------------------------------------------------------------
  insert into public.matters
    (org_id, matter_no, name, client_id, opened_date, fee_earner)
  values (v_org, 'M-2', 'A receipt entered twice', v_them, date '2026-01-05',
          pg_temp.test_user())
  returning id into v_void;
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description, status)
  values (v_org, v_void, 'CT-9', date '2026-02-02', 'receipt',
          v_bank, 5000, 'Keyed twice', 'void');

  perform public.close_matter(v_void, date '2026-03-31');
  perform pg_temp.check_eq('a voided receipt is not money held',
    (select status::text from public.matters where id = v_void), 'closed');

  -- And a draft one is, which is the other half of the same sentence. A
  -- receipt somebody has entered and not posted is a receipt they think
  -- they have; refusing is the safe direction to be wrong in.
  insert into public.matters
    (org_id, matter_no, name, client_id, opened_date, fee_earner)
  values (v_org, 'M-3', 'A receipt not yet posted', v_them, date '2026-01-05',
          pg_temp.test_user())
  returning id into v_draft;
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_org, v_draft, 'CT-10', date '2026-02-02', 'receipt',
          v_bank, 5000, 'On account, not yet posted');

  begin
    perform public.close_matter(v_draft, date '2026-03-31');
    raise exception 'FAIL: a matter with an unposted receipt was closed';
  exception when sqlstate '23514' then
    v_said := sqlerrm;
  end;
  perform pg_temp.check_true('while a draft receipt still counts as held',
    v_said like '%5,000.00%');

  perform pg_temp.sign_out();
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('closing a matter is closed to anon',
    not has_function_privilege('anon',
      'public.close_matter(uuid, date, text)', 'execute'));
  perform pg_temp.check_true('and so is reopening one',
    not has_function_privilege('anon',
      'public.reopen_matter(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in user may try',
    has_function_privilege('authenticated',
      'public.close_matter(uuid, date, text)', 'execute'));
end $$;

rollback;
