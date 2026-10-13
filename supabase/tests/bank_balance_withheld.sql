-- =====================================================================
-- iAkauntan :: the bank's balance is the ledger's (0858)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_balance_withheld.sql
--
-- `bank_accounts.current_balance` is the bank's running balance, kept
-- from the ledger. Every member reads `bank_accounts` -- a salesman
-- picks the account a receipt lands in -- and before `0858` every
-- member read the balance too: off the table, on the dashboard, and as
-- the opening figure of the cash forecast. Asked with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_bb (org uuid, sales uuid, clerk uuid, bank uuid, other uuid);
grant select on t_bb to authenticated;

do $$
declare r t_bb; v_gl uuid; v_eq uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Baki Bank Sdn Bhd');
  r.other := pg_temp.test_org('Bank Lain Sdn Bhd');
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  r.sales := pg_temp.another_user('sales@bakibank.test');
  r.clerk := pg_temp.another_user('clerk@bakibank.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.clerk, 'accounts_clerk', 'active');

  r.bank := pg_temp.test_bank_account(r.org);
  select account_id into v_gl from public.bank_accounts where id = r.bank;
  select id into v_eq from public.accounts where org_id = r.org and not is_group
     and account_type = 'equity' order by code limit 1;
  perform public.post_manual_journal(r.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', v_gl, 'debit', 98765.43, 'credit', 0),
      jsonb_build_object('account_id', v_eq, 'debit', 0, 'credit', 98765.43)),
    'Capital paid in');
  perform public.resync_bank_balance(r.bank);

  -- The owner's other company's bank, with a balance no answer about
  -- this one may carry.
  perform pg_temp.test_bank_account(r.other, 'Akaun lain', 'current', 'MYR', 0, 555);
  insert into t_bb select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_bb), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_bb; v_msg constant text := 'Insufficient privileges to read the ledger';
begin
  select * into d from t_bb;
  perform pg_temp.check_eq('the premise: the salesman still picks the bank a receipt lands in',
    (select name from public.bank_accounts where id = d.bank), 'Current account');

  -- What was measured.
  perform pg_temp.check_refused('the salesman does not read the bank''s balance off the table',
    format('select current_balance from public.bank_accounts where id = %L', d.bank),
    'permission denied for table bank_accounts', '42501');
  perform pg_temp.check_eq('nor through the function that serves it',
    (select count(*) from public.bank_balances(d.org))::int, 0);
  perform pg_temp.check_true('nor on the dashboard, where it is nothing rather than nought',
    (public.dashboard_summary(d.org, null, pg_temp.today()) -> 'bank_balance') = 'null'::jsonb);
  perform pg_temp.check_eq('while the rest of the dashboard is as it was',
    public.dashboard_summary(d.org, null, pg_temp.today()) ->> 'draft_invoices', '0');
  perform pg_temp.check_refused('and the cash forecast, which opens at it, is refused',
    format('select * from public.report_cash_forecast(%L)', d.org), v_msg, '42501');
end $$;

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_bb), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_bb;
begin
  select * into d from t_bb;
  perform pg_temp.check_refused('a select of every column is refused to the clerk too',
    format('select * from public.bank_accounts where id = %L', d.bank),
    'permission denied for table bank_accounts', '42501');
  -- The list `Repo.bankAccounts` names in `repository.dart`, word for
  -- word: the app's one read of the table, behind a dozen pickers.
  perform pg_temp.check_eq('while the columns the app names are read',
    (select count(*) from (
       select id, org_id, account_id, name, bank_name, bank_code,
              account_number, account_type, currency, opening_balance,
              is_default, is_active, created_at, updated_at,
              is_client_account, import_source, import_ref,
              import_batch_id, imported_at
         from public.bank_accounts where org_id = d.org) x)::int, 1);
  perform pg_temp.check_eq('and the clerk is given the balance through the function',
    (select current_balance from public.bank_balances(d.org) where bank_account_id = d.bank),
    98765.43);
  perform pg_temp.check_eq('this company''s banks, and no other''s',
    (select count(*) from public.bank_balances(d.org))::int, 1);
  perform pg_temp.check_eq('nor any of a company the clerk is not in',
    (select count(*) from public.bank_balances(d.other))::int, 0);
  perform pg_temp.check_eq('and on the dashboard',
    public.dashboard_summary(d.org, null, pg_temp.today()) ->> 'bank_balance', '98765.43');
  perform pg_temp.check_eq('and the forecast opens at it',
    (select opening from public.report_cash_forecast(d.org) where week_no = 1), 98765.43);
end $$;

reset role;

-- The owner of both, for the other company: its own figure.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_bb;
begin
  select * into d from t_bb;
  perform pg_temp.check_eq('the other company''s bank is its own',
    (select sum(current_balance) from public.bank_balances(d.other)), 555);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon may not call it',
    not has_function_privilege('anon', 'public.bank_balances(uuid)', 'execute'));
  perform pg_temp.check_true('nor read the table at all',
    not has_any_column_privilege('anon', 'public.bank_accounts', 'select'));
end $$;

rollback;
