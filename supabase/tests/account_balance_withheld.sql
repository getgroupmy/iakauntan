-- =====================================================================
-- iAkauntan :: an account's balance is the ledger's to show (0856)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_balance_withheld.sql
--
-- `accounts.current_balance` is the running total of every posted line.
-- Every member reads `accounts` -- a salesman picks a revenue account on
-- an invoice line -- and so, before `0856`, every member read every
-- account's balance: the trial balance one column away from the
-- reports `0855` refuses them. Asked with the role `authenticated`, as
-- the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ab (org uuid, other uuid, sales uuid, clerk uuid,
  expense uuid, capital uuid);
grant select on t_ab to authenticated;

do $$
declare r t_ab; o_exp uuid; o_eq uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Baki Akaun Sdn Bhd');
  r.other := pg_temp.test_org('Baki Lain Sdn Bhd');
  perform pg_temp.open_years(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.other, date_trunc('year', pg_temp.today())::date);
  r.sales := pg_temp.another_user('sales@bakiakaun.test');
  r.clerk := pg_temp.another_user('clerk@bakiakaun.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.clerk, 'accounts_clerk', 'active');

  select id into r.expense from public.accounts where org_id = r.org and not is_group
     and account_type = 'expense' order by code limit 1;
  select id into r.capital from public.accounts where org_id = r.org and not is_group
     and account_type = 'equity' order by code limit 1;
  perform public.post_manual_journal(r.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', r.expense, 'debit', 4321.09, 'credit', 0),
      jsonb_build_object('account_id', r.capital, 'debit', 0, 'credit', 4321.09)),
    'Directors'' remuneration');

  -- The owner's other company, with a balance of its own that no answer
  -- about this one may carry.
  select id into o_exp from public.accounts where org_id = r.other and not is_group
     and account_type = 'expense' order by code limit 1;
  select id into o_eq from public.accounts where org_id = r.other and not is_group
     and account_type = 'equity' order by code limit 1;
  perform public.post_manual_journal(r.other, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', o_exp, 'debit', 999, 'credit', 0),
      jsonb_build_object('account_id', o_eq, 'debit', 0, 'credit', 999)),
    'Elsewhere');

  -- And a retired account of this company's carrying a balance, which
  -- the chart the app reads leaves out and so must this.
  update public.accounts set deleted_at = now(), current_balance = 77
   where org_id = r.org and not is_group and account_type = 'revenue'
     and id = (select id from public.accounts where org_id = r.org and not is_group
                 and account_type = 'revenue' order by code limit 1);

  insert into t_ab select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_ab), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ab;
begin
  select * into d from t_ab;
  perform pg_temp.check_true('the premise: the salesman still reads the chart',
    (select count(*) from public.accounts where org_id = d.org and code is not null) > 0);

  -- What was measured.
  perform pg_temp.check_refused('the salesman does not read an account''s balance',
    format('select current_balance from public.accounts where id = %L', d.expense),
    'permission denied for table accounts', '42501');
  perform pg_temp.check_eq('nor are they handed it by the function that serves it',
    (select count(*) from public.account_balances(d.org))::int, 0);
end $$;

reset role;

-- Nor does anybody read it directly, the clerk included: one database
-- role for both. What the clerk has is the function.
select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_ab), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ab;
begin
  select * into d from t_ab;
  perform pg_temp.check_refused('a select of every column is refused to the clerk too',
    format('select * from public.accounts where id = %L', d.expense),
    'permission denied for table accounts', '42501');
  -- The list `Repo.accounts` names in `repository.dart`, word for word:
  -- it is the app's one read of the chart, and a column added to it that
  -- the grant does not carry would refuse every member the whole chart.
  perform pg_temp.check_eq('while the columns the app names are read',
    (select count(*) from (
       select id, code, name, account_type, account_subtype, tax_treatment,
              is_group, parent_id, is_active
         from public.accounts where org_id = d.org and deleted_at is null) x)::int,
    (select count(*) from public.account_balances(d.org))::int);
  perform pg_temp.check_eq('and the clerk is given the balance through the function',
    (select current_balance from public.account_balances(d.org) where account_id = d.expense),
    4321.09);
  perform pg_temp.check_eq('both sides of the journal, and only the accounts that moved are nonzero',
    (select string_agg(abs(current_balance)::text, ',')
       from public.account_balances(d.org) where current_balance <> 0),
    '4321.09,4321.09');
  perform pg_temp.check_eq('every live account of this company, and no other',
    (select count(*) from public.account_balances(d.org))::int,
    (select count(*) from public.accounts where org_id = d.org and deleted_at is null)::int);
  perform pg_temp.check_eq('the retired account and its balance left out, as the chart leaves them',
    (select count(*) from public.account_balances(d.org) where current_balance = 77)::int, 0);
  perform pg_temp.check_eq('nor anything of a company the clerk is not in',
    (select count(*) from public.account_balances(d.other))::int, 0);
end $$;

reset role;

-- The owner of both, for the other company: its own figure, not this one's.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ab;
begin
  select * into d from t_ab;
  perform pg_temp.check_eq('the other company''s balances are its own',
    (select string_agg(abs(current_balance)::text, ',')
       from public.account_balances(d.other) where current_balance <> 0),
    '999.00,999.00');
end $$;

reset role;

-- The function is the client's only door, and anon has none.
do $$
begin
  perform pg_temp.check_true('anon may not call it',
    not has_function_privilege('anon', 'public.account_balances(uuid)', 'execute'));
  perform pg_temp.check_true('nor read the table at all',
    not has_any_column_privilege('anon', 'public.accounts', 'select'));
end $$;

rollback;
