-- =====================================================================
-- iAkauntan :: a closed account is still in the books (0828)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/closed_account_in_books.sql
--
-- Found in production on 12 October 2026: a bank sub-account closed
-- through `retire_account` carrying a RM90 debit, its bank account still
-- active and posting to it, and the company's trial balance RM90 out --
-- the reports left a closed account out whatever it held. Now the
-- reports show a closed account that carries lines or an opening
-- balance, and `retire_account` refuses one with a balance or a live
-- bank account. Asked as the owner, with the role `authenticated`.
--
-- The state production is in is made the way it was made before
-- `0828`: closed while carrying a balance -- here by the session, since
-- `retire_account` will no longer do it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cb (
  org uuid, y0 date, m1 uuid,
  mbb_gl uuid, cimb_gl uuid, petty uuid,
  sundry uuid, brought uuid, fees uuid, capital uuid, b_cap uuid,
  drafted uuid, rhb_gl uuid);
grant select on t_cb to authenticated;

-- A balanced manual journal of two lines, as the journal screen posts.
create or replace function pg_temp.j(p_dr uuid, p_cr uuid, p_amt numeric,
  p_matter uuid default null)
returns void language plpgsql as $$
declare d t_cb;
begin
  select * into d from t_cb;
  perform public.post_manual_journal(d.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', p_dr, 'debit', p_amt, 'credit', 0,
                         'matter_id', p_matter),
      jsonb_build_object('account_id', p_cr, 'debit', 0, 'credit', p_amt,
                         'matter_id', p_matter)),
    'Test');
end $$;
grant execute on function pg_temp.j(uuid, uuid, numeric, uuid) to authenticated;

do $$
declare
  r   t_cb;
  v_u uuid := pg_temp.test_user();
  v_c uuid;
  v_b uuid;
  v_e uuid;
begin
  perform pg_temp.sign_in_as(v_u);
  r.org := pg_temp.test_org('Buku Tertutup Sdn Bhd');
  perform public.setup_legal_module(r.org);
  r.y0 := date_trunc('year', pg_temp.today())::date;
  perform public.create_fiscal_year(r.org, r.y0);
  perform pg_temp.open_years(r.org, r.y0);

  v_b := pg_temp.test_bank_account(r.org, 'Maybank current');
  select account_id into r.mbb_gl from public.bank_accounts where id = v_b;
  v_b := pg_temp.test_bank_account(r.org, 'CIMB current');
  select account_id into r.cimb_gl from public.bank_accounts where id = v_b;
  r.petty := public.upsert_account('1198', 'Petty cash', 'asset', 'cash', p_org_id => r.org);
  r.sundry := public.upsert_account('6199', 'Sundries', 'expense', 'operating_expense', p_org_id => r.org);
  r.brought := public.upsert_account('6198', 'Brought over', 'expense', 'operating_expense', p_org_id => r.org);
  r.fees := public.upsert_account('4199', 'Other fees', 'revenue', 'other_income', p_org_id => r.org);
  r.capital := public.upsert_account('3199', 'Capital contributed', 'equity', 'share_capital', p_org_id => r.org);
  r.b_cap := public.upsert_account('3198', 'Capital brought over', 'equity', 'share_capital', p_org_id => r.org);
  -- Opening balances, which only the database writes. RM250 on the
  -- sundries' neighbour, for `retire_account`; RM30 of petty cash
  -- against RM280 of capital brought over, which will be closed with
  -- nothing else in them; and RM50 on CIMB against RM50 of capital,
  -- which will be closed with lines in them.
  update public.accounts set opening_balance = 250 where id = r.brought;
  update public.accounts set opening_balance = 30 where id = r.petty;
  update public.accounts set opening_balance = 280 where id = r.b_cap;
  update public.accounts set opening_balance = 50 where id in (r.cimb_gl, r.capital);

  -- A journal still in draft, which is not in the books.
  r.drafted := public.upsert_account('6196', 'Drafted only', 'expense', 'operating_expense', p_org_id => r.org);
  insert into public.gl_entries (org_id, entry_no, entry_date, description, status)
  values (r.org, 'JV-DRAFT', pg_temp.today(), 'Not yet', 'draft') returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (r.org, v_e, 1, r.drafted, 40, 0),
         (r.org, v_e, 2, (select id from public.accounts where org_id = r.org and code = '6100'), 0, 40);
  -- And one on the petty cash, which is closed below with nothing
  -- posted in it: a draft is not what keeps a closed account on a report.
  insert into public.gl_entries (org_id, entry_no, entry_date, description, status)
  values (r.org, 'JV-DRAFT-2', pg_temp.today(), 'Not yet either', 'draft') returning id into v_e;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id, debit, credit)
  values (r.org, v_e, 1, r.petty, 5, 0),
         (r.org, v_e, 2, (select id from public.accounts where org_id = r.org and code = '6100'), 0, 5);
  -- A bank account no longer in use.
  v_b := pg_temp.test_bank_account(r.org, 'Old RHB', p_active => false);
  select account_id into r.rhb_gl from public.bank_accounts where id = v_b;

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CL1', 'Puan Aminah', 'customer') returning id into v_c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (r.org, 'M-1', 'Sale of a house', v_c, v_u) returning id into r.m1;
  insert into t_cb select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- ---------------------------------------------------------------------
-- `retire_account` closes only what holds nothing and feeds nothing
-- ---------------------------------------------------------------------
do $$
declare d t_cb;
begin
  select * into d from t_cb;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- What was found: RM90 in a bank's ledger account.
  perform pg_temp.j(d.mbb_gl, d.fees, 90);
  perform pg_temp.check_refused('an account carrying RM90 is not closed',
    format('select public.retire_account(%L)', d.mbb_gl),
    'Account 112_ still carries a balance of 90.00 debit. Journal it to another account first, then close it.',
    '23514');
  perform pg_temp.check_refused('nor one carrying a credit',
    format('select public.retire_account(%L)', d.fees),
    'Account 4199 still carries a balance of 90.00 credit.%', '23514');
  perform pg_temp.check_refused('nor one carrying only an opening balance',
    format('select public.retire_account(%L)', d.brought),
    'Account 6198 still carries a balance of 250.00 debit.%', '23514');

  -- Emptied, but the bank account still posts to it.
  perform pg_temp.j(d.sundry, d.mbb_gl, 90);
  perform pg_temp.check_eq('the bank''s ledger account is back to nothing',
    (select sum(debit - credit) from public.gl_lines where account_id = d.mbb_gl), 0::numeric);
  perform pg_temp.check_refused('nor is an empty account a live bank account posts to',
    format('select public.retire_account(%L)', d.mbb_gl),
    'Account 112_ is the ledger account of the bank account Maybank current, which still posts to it.',
    '23514');

  -- What does not count: a draft, and a bank account out of use.
  perform pg_temp.check_eq('an account with only a draft journal on it closes',
    public.retire_account(d.drafted), 'closed');
  perform pg_temp.check_eq('and so does the ledger account of a bank account out of use',
    public.retire_account(d.rhb_gl), 'closed');

  -- Journalled out, it closes, and keeps its lines.
  perform pg_temp.check_refused('the sundries are not closed holding RM90',
    format('select public.retire_account(%L)', d.sundry),
    'Account 6199 still carries a balance of 90.00 debit.%', '23514');
  perform pg_temp.j((select id from public.accounts where org_id = d.org and code = '6100'), d.sundry, 90);
  perform pg_temp.check_eq('journalled to 6100, they close',
    public.retire_account(d.sundry), 'closed');
  perform pg_temp.check_eq('and keep both lines',
    (select count(*)::integer from public.gl_lines where account_id = d.sundry), 2);

  -- The rest of the books, for the reports below: RM90 of fees and
  -- RM500 of capital into CIMB, the fees on a matter.
  perform pg_temp.j(d.cimb_gl, d.fees, 90, d.m1);
  perform pg_temp.j(d.cimb_gl, d.capital, 500);
end $$;

reset role;

-- The state production is in: accounts closed with something in them,
-- as `retire_account` closed them before 0828.
do $$
declare d t_cb;
begin
  select * into d from t_cb;
  update public.accounts set is_active = false, deleted_at = now()
   where id in (d.cimb_gl, d.capital, d.petty, d.brought, d.b_cap);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- ---------------------------------------------------------------------
-- And the reports show what a closed account holds
-- ---------------------------------------------------------------------
do $$
declare
  d        t_cb;
  v_unused uuid;
begin
  select * into d from t_cb;

  -- The trial balance.
  perform pg_temp.check_eq('the trial balance balances with five accounts closed',
    (select sum(closing_balance) from public.report_trial_balance(d.org)), 0::numeric);
  perform pg_temp.check_eq('CIMB''s RM640 is on it, closed: RM590 of lines and RM50 brought in',
    (select closing_balance from public.report_trial_balance(d.org) where account_id = d.cimb_gl),
    640::numeric);
  -- A closed account with nothing but a typed opening balance stays
  -- off, as `general_ledger.sql` and `financial_statements.sql` have it.
  perform pg_temp.check_eq('a closed account with only an opening balance is not',
    (select count(*)::integer from public.report_trial_balance(d.org) where account_id = d.brought), 0);
  perform pg_temp.check_eq('the sundries, closed with two lines netting to nothing, at nil',
    (select closing_balance from public.report_trial_balance(d.org) where account_id = d.sundry),
    0::numeric);
  v_unused := public.upsert_account('6197', 'Never used', 'expense', 'operating_expense',
    p_org_id => d.org);
  perform public.retire_account(v_unused);
  perform pg_temp.check_eq('a closed account with nothing in it is not on it',
    (select count(*)::integer from public.report_trial_balance(d.org) where account_id = v_unused), 0);

  -- The balance sheet.
  perform pg_temp.check_eq('the balance sheet has CIMB''s RM640',
    (select balance from public.report_balance_sheet(d.org) where account_id = d.cimb_gl),
    640::numeric);
  perform pg_temp.check_eq('and the RM550 of capital',
    (select balance from public.report_balance_sheet(d.org) where account_id = d.capital),
    550::numeric);
  perform pg_temp.check_eq('but not the petty cash, closed with only an opening balance',
    (select count(*)::integer from public.report_balance_sheet(d.org) where account_id = d.petty), 0);

  -- The general ledger.
  perform pg_temp.check_eq('the general ledger lists CIMB''s two lines',
    (select count(*)::integer from public.report_general_ledger(d.org, null, null, d.cimb_gl)
      where not is_opening), 2);
  perform pg_temp.check_eq('and not the petty cash, which has only a draft',
    (select count(*)::integer from public.report_general_ledger(d.org, null, null, d.petty)), 0);

  -- Changes in equity.
  perform pg_temp.check_eq('changes in equity has the RM500 of capital moved',
    (select movement from public.report_changes_in_equity(d.org, d.y0, pg_temp.today())
      where account_id = d.capital), 500::numeric);
  perform pg_temp.check_eq('and opens at its RM50',
    (select opening_balance from public.report_changes_in_equity(d.org, d.y0, pg_temp.today())
      where account_id = d.capital), 50::numeric);
  perform pg_temp.check_eq('but not the RM280 brought over, closed with nothing else',
    (select count(*)::integer from public.report_changes_in_equity(d.org, d.y0, pg_temp.today())
      where account_id = d.b_cap), 0);

  -- The matter's own trial balance.
  perform pg_temp.check_eq('the matter''s trial balance has its RM90 in CIMB',
    (select debit from public.report_matter_trial_balance(d.org, d.m1)
      where account_id = d.cimb_gl), 90::numeric);

  -- The cash flow: cash brought forward is CIMB's RM50 -- not the
  -- petty cash's RM30, which is closed with nothing else in it -- and
  -- carried forward adds CIMB's RM590 and Maybank's nothing.
  perform pg_temp.check_eq('the cash flow brings forward closed CIMB''s RM50',
    (select amount from public.report_cash_flow(d.org, d.y0, pg_temp.today())
      where label = 'Cash and cash equivalents brought forward'), 50::numeric);
  perform pg_temp.check_eq('and carries forward RM640',
    (select amount from public.report_cash_flow(d.org, d.y0, pg_temp.today())
      where label = 'Cash and cash equivalents carried forward'), 640::numeric);
end $$;

rollback;
