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

-- =====================================================================
-- Closing and reopening, rule by rule
--
-- The files above close a matter by its owner, in a company that has
-- the module, always on a date given, always with notes empty or a
-- note already trimmed, and next to no other matter holding money --
-- so a close that skipped the existence, deletion, module or posting
-- checks, refused the opening day, defaulted to the opening day,
-- counted another matter's money or billed and unbillable work, or
-- wiped, padded or replaced the notes passed. `reopen_matter` was
-- never refused anything but an open matter, and never met an
-- archived one.
-- =====================================================================
create temporary table t_mc (org uuid, held uuid, spare uuid, shut uuid);
grant select on t_mc to authenticated;

do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_clerk uuid;
  v_bank  uuid;
  v_them  uuid;
  v_held  uuid;
  v_empty uuid;
  v_pad   uuid;
  v_notes uuid;
  v_keep  uuid;
  v_gone  uuid;
  v_arch  uuid;
  v_spare uuid;
  v_shut  uuid;
  v_txn   uuid;
  r       jsonb;
begin
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Peraturan Fail & Rakan', array['legal']);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform pg_temp.sign_in_as(v_owner);
  perform public.setup_legal_module(v_org);
  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_client_account;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Encik Rahim', 'customer') returning id into v_them;

  insert into public.matters (org_id, matter_no, name, client_id, opened_date, fee_earner, notes)
  values (v_org, 'R-1', 'Holds money', v_them, date '2026-01-05', v_owner, null),
         (v_org, 'R-2', 'Nothing held, work left', v_them, date '2026-01-05', v_owner, null),
         (v_org, 'R-3', 'Closed on its first day', v_them, date '2026-01-05', v_owner, null),
         (v_org, 'R-4', 'Has notes already', v_them, date '2026-01-05', v_owner, 'Opened for the purchase.'),
         (v_org, 'R-5', 'Has notes, closed without one', v_them, date '2026-01-05', v_owner, 'Keep this.'),
         (v_org, 'R-6', 'Deleted', v_them, date '2026-01-05', v_owner, null),
         (v_org, 'R-7', 'Archived', v_them, date '2026-01-05', v_owner, null),
         (v_org, 'R-8', 'Spare', v_them, date '2026-01-05', v_owner, null),
         (v_org, 'R-9', 'Shut by hand', v_them, date '2026-01-05', v_owner, null);
  select id into v_held  from public.matters where org_id = v_org and matter_no = 'R-1';
  select id into v_empty from public.matters where org_id = v_org and matter_no = 'R-2';
  select id into v_pad   from public.matters where org_id = v_org and matter_no = 'R-3';
  select id into v_notes from public.matters where org_id = v_org and matter_no = 'R-4';
  select id into v_keep  from public.matters where org_id = v_org and matter_no = 'R-5';
  select id into v_gone  from public.matters where org_id = v_org and matter_no = 'R-6';
  select id into v_arch  from public.matters where org_id = v_org and matter_no = 'R-7';
  select id into v_spare from public.matters where org_id = v_org and matter_no = 'R-8';
  select id into v_shut  from public.matters where org_id = v_org and matter_no = 'R-9';
  update public.matters set deleted_at = now() where id = v_gone;

  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_org, v_held, 'CT-R1', date '2026-02-02', 'receipt', v_bank, 1500, 'On account')
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- Work on R-2: some the firm can still bill, some already billed,
  -- some nobody may bill.
  insert into public.time_entries
    (org_id, matter_id, entry_date, description, minutes, hourly_rate, amount, is_billable, is_billed)
  values (v_org, v_empty, date '2026-02-10', 'Advice', 90, 400, 600, true, false),
         (v_org, v_empty, date '2026-02-11', 'Drafting', 135, 400, 900, true, true),
         (v_org, v_empty, date '2026-02-12', 'Courtesy call', 45, 400, 300, false, false);
  insert into public.disbursements
    (org_id, matter_id, disbursement_date, description, amount, tax_amount, is_billable, is_billed)
  values (v_org, v_empty, date '2026-02-13', 'Search', 50, 4, true, false),
         (v_org, v_empty, date '2026-02-14', 'Courier', 70, 0, true, true);

  -- Refusals, each by what it says.
  perform pg_temp.check_refused('closing a matter that does not exist is said so',
    format('select public.close_matter(%L)', gen_random_uuid()), 'No such matter.', 'P0002');
  perform pg_temp.check_refused('a deleted matter is not there to close',
    format('select public.close_matter(%L)', v_gone), 'No such matter.', 'P0002');
  perform pg_temp.check_refused('reopening one that does not exist is said so',
    format('select public.reopen_matter(%L)', gen_random_uuid()), 'No such matter.', 'P0002');
  perform pg_temp.check_refused('nor is a deleted one there to reopen',
    format('select public.reopen_matter(%L)', v_gone), 'No such matter.', 'P0002');

  v_clerk := pg_temp.another_user('kerani@peraturanfail.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_clerk, 'sales', 'active');
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused('somebody who may not post does not close a file',
    format('select public.close_matter(%L)', v_spare), 'not permitted to close a matter', '42501');
  perform pg_temp.sign_in_as(v_owner);

  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'legal';
  perform pg_temp.check_refused('without the legal module there is no file to close',
    format('select public.close_matter(%L)', v_spare),
    'The legal module is not enabled for this organization.', '42501');
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'legal';

  -- R-1 holds money; R-2 does not, and closes. Undated, it closes today
  -- in Kuala Lumpur, and reports only the work still billable.
  r := public.close_matter(v_empty);
  perform pg_temp.check_eq('another matter''s money does not hold this one open',
    (select status::text from public.matters where id = v_empty), 'closed');
  perform pg_temp.check_eq('closed today, when no date is given',
    r ->> 'closed_date', ((now() at time zone 'Asia/Kuala_Lumpur')::date)::text);
  perform pg_temp.check_eq('reporting only the time still to bill',
    (r ->> 'unbilled_time')::numeric, 600.00);
  perform pg_temp.check_eq('and only the disbursements still to bill, with their tax',
    (r ->> 'unbilled_disbursements')::numeric, 54.00);

  -- Notes: a note given lands under any there, trimmed; none given
  -- leaves them alone.
  perform public.close_matter(v_pad, date '2026-01-05', '  Settled.  ');
  perform pg_temp.check_eq('a matter can close on the day it opened',
    (select status::text from public.matters where id = v_pad), 'closed');
  perform pg_temp.check_eq('with its closing note trimmed',
    (select notes from public.matters where id = v_pad), 'Settled.');
  perform public.close_matter(v_notes, date '2026-06-30', 'File closed.');
  perform pg_temp.check_eq('a closing note goes under the notes already there',
    (select notes from public.matters where id = v_notes),
    'Opened for the purchase.' || E'\n' || 'File closed.');
  perform public.close_matter(v_keep, date '2026-06-30');
  perform pg_temp.check_eq('and closing without one leaves them as they were',
    (select notes from public.matters where id = v_keep), 'Keep this.');

  -- A late cheque for a file already closed. `0775` asks about money
  -- only on the way INTO closed, so the file that has just received it
  -- can still have its date put right -- and reopened, which is what
  -- somebody will do next.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date, transaction_type,
     bank_account_id, amount, description)
  values (v_org, v_keep, 'CT-R5', date '2026-07-02', 'receipt', v_bank, 200, 'Late cheque')
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);
  update public.matters set closed_date = date '2026-07-01' where id = v_keep;
  perform pg_temp.check_eq('a closed file that money reached later can still be corrected',
    (select closed_date from public.matters where id = v_keep)::text, '2026-07-01');
  perform public.reopen_matter(v_keep);
  perform pg_temp.check_eq('and reopened',
    (select status::text from public.matters where id = v_keep), 'open');

  -- Reopening: the guards, and an archived file.
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused('somebody who may not post does not reopen a file',
    format('select public.reopen_matter(%L)', v_pad), 'not permitted to reopen a matter', '42501');
  perform pg_temp.sign_in_as(v_owner);
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'legal';
  perform pg_temp.check_refused('nor without the legal module',
    format('select public.reopen_matter(%L)', v_pad),
    'The legal module is not enabled for this organization.', '42501');
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'legal';

  update public.matters set status = 'archived' where id = v_arch;
  perform public.reopen_matter(v_arch);
  perform pg_temp.check_eq('an archived file reopens too',
    (select status::text from public.matters where id = v_arch), 'open');

  insert into t_mc values (v_org, v_held, v_spare, v_shut);
end $$;

-- ---------------------------------------------------------------------
-- And by the table's own door  (`0775`)
--
-- The same two rules, asked of an UPDATE straight on `matters` as a
-- signed-in member -- the road `matters_update` leaves open. Before
-- `0775` this closed R-1 with RM1,500 of client money on it.
-- ---------------------------------------------------------------------
set local role authenticated;

do $$
declare
  c     record;
  v_msg text;
begin
  select * into c from t_mc;

  begin
    update public.matters set status = 'closed', closed_date = date '2026-06-30'
     where id = c.held;
    v_msg := null;
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('a matter holding client money is not closed by hand either',
    v_msg like 'This matter still holds 1,500.00 of the client''s money.%');

  begin
    update public.matters set status = 'archived' where id = c.held;
    v_msg := null;
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('nor archived',
    v_msg like 'This matter still holds 1,500.00 of the client''s money.%');

  begin
    update public.matters set status = 'closed', closed_date = date '2026-01-04'
     where id = c.spare;
    v_msg := null;
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
  end;
  perform pg_temp.check_true('nor closed by hand before it opened',
    v_msg = 'A matter cannot close before it opened. It was opened on 2026-01-05.');

  -- What stays open: an empty file closes by hand, a closed file's
  -- other fields stay editable, and nothing is refused on the way OUT.
  update public.matters set status = 'closed', closed_date = date '2026-06-30'
   where id = c.shut;
  update public.matters set description = 'Closed by hand' where id = c.shut;
  update public.matters set status = 'open', closed_date = null where id = c.shut;
end $$;

reset role;

do $$
declare c record;
begin
  select * into c from t_mc;
  perform pg_temp.check_eq('the money-holding matter is still open',
    (select status::text from public.matters where id = c.held), 'open');
  perform pg_temp.check_eq('and so is the one somebody tried to close early',
    (select status::text from public.matters where id = c.spare), 'open');
  perform pg_temp.check_eq('while an empty one closed by hand, was edited, and came back',
    (select status::text || ' / ' || description from public.matters where id = c.shut),
    'open / Closed by hand');
end $$;

rollback;
