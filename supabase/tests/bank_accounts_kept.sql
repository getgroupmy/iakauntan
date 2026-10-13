-- =====================================================================
-- iAkauntan :: a bank account is set up by its setup (0823)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_accounts_kept.sql
--
-- `upsert_bank_account` will not point a bank account at a ledger
-- account that is not a bank or cash account. Before `0823` a client
-- could write the row instead: a bank pointed at 6400 Depreciation took
-- a RM500 receipt as an expense, and a balance typed in as RM1,000,000
-- went onto the dashboard. Asked as the owner, with the role
-- `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_bk (org uuid, bank uuid, exp uuid, cust uuid);
grant select on t_bk to authenticated;

do $$
declare
  r t_bk;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Baki Bank Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  r.exp := (select id from public.accounts where org_id = r.org and code = '6400');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Buyer', 'customer') returning id into r.cust;
  insert into t_bk select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d     t_bk;
  v_rcp uuid;
begin
  select * into d from t_bk;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');

  -- Set up through its setup, which reads as it did.
  d.bank := public.upsert_bank_account('Maybank current', 'Maybank', 'MBBEMYKL',
    '5140-1234-5678', 'current', 'MYR', null, null, d.org);
  perform pg_temp.check_true('a bank account is set up on a bank account of the chart',
    (select a.account_subtype::text = 'bank' and bb.current_balance = 0 and b.is_default
       from public.bank_accounts b join public.accounts a on a.id = b.account_id
       join public.bank_balances(d.org) bb on bb.bank_account_id = b.id
      where b.id = d.bank));

  -- The setup's own rule, as it was.
  perform pg_temp.check_refused('the setup will not point it at an expense',
    format('select public.upsert_bank_account(%L, null, null, null, %L, %L, %L, %L, null)',
           'Maybank current', 'current', 'MYR', d.exp, d.bank),
    'That is not a bank or cash account in this company.', '23514');

  -- What was measured, by hand instead.
  perform pg_temp.check_refused('nor is it pointed there by hand',
    format('update public.bank_accounts set account_id = %L where id = %L', d.exp, d.bank),
    'permission denied for table bank_accounts', '42501');
  perform pg_temp.check_refused('nor its balance typed in',
    format('update public.bank_accounts set current_balance = 1000000 where id = %L', d.bank),
    'permission denied for table bank_accounts', '42501');
  perform pg_temp.check_refused('nor one typed in whole',
    format($q$insert into public.bank_accounts (org_id, name, account_id, currency)
              values (%L, 'Kotak wang', %L, 'MYR')$q$, d.org, d.exp),
    'permission denied for table bank_accounts', '42501');
  perform pg_temp.check_refused('nor one deleted',
    format('delete from public.bank_accounts where id = %L', d.bank),
    'permission denied for table bank_accounts', '42501');

  -- So money received is money in the bank.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate, bank_account_id)
  values (d.org, 'RCP-1', date '2026-03-05', d.cust, 500, 500, 'MYR', 1, d.bank)
  returning id into v_rcp;
  perform public.post_receipt(v_rcp);
  perform pg_temp.check_eq('a RM500 receipt is a debit to the bank, not to depreciation',
    (select a.account_subtype::text || '/' || l.debit
       from public.gl_lines l
       join public.gl_entries e on e.id = l.entry_id
       join public.accounts a on a.id = l.account_id
      where e.org_id = d.org and l.debit > 0), 'bank/500.00');
  -- Read through `bank_balances`: since `0858` no client reads the
  -- column itself, and the owner reads the ledger.
  perform pg_temp.check_eq('and the cached balance is what was posted',
    (select current_balance from public.bank_balances(d.org) where bank_account_id = d.bank),
    500::numeric);

  -- Renamed through the setup, as the screen does.
  perform public.upsert_bank_account('Maybank operating', 'Maybank', 'MBBEMYKL',
    '5140-1234-5678', 'current', 'MYR', null, d.bank, null);
  perform pg_temp.check_eq('and renamed through it',
    (select name from public.bank_accounts where id = d.bank), 'Maybank operating');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('no write policy is left on the bank accounts',
    (select count(*)::integer from pg_policies
      where schemaname = 'public' and tablename = 'bank_accounts'
        and cmd <> 'SELECT'), 0);
end $$;

rollback;
