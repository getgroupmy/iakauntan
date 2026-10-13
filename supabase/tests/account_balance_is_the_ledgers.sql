-- =====================================================================
-- iAkauntan :: an account's balance is its ledger's (0844)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_balance_is_the_ledgers.sql
--
-- `accounts.current_balance` is kept by `app.apply_account_balance`, a
-- trigger on `gl_lines`, and printed by the chart export. Before `0844`
-- a client who may post could type a million ringgit onto an account
-- with nothing in the ledger behind it. Asked as the owner with the role
-- `authenticated`, as every screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ab (org uuid, cash uuid, sales uuid);
grant select on t_ab to authenticated;

do $$
declare r t_ab;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Baki Lejar Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', app.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', app.today())::date);
  select id into r.cash from public.accounts
   where org_id = r.org and account_subtype = 'bank' and not is_group
   order by code limit 1;
  select id into r.sales from public.accounts
   where org_id = r.org and account_type = 'revenue' and not is_group
   order by code limit 1;
  insert into t_ab select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_ab; v_code text;
begin
  select * into d from t_ab;
  select code into v_code from public.accounts where id = d.cash;
  perform pg_temp.check_true('the owner, asking as a client who may post',
    current_user = 'authenticated' and app.can_post(d.org));

  -- What was measured.
  perform pg_temp.check_refused('a balance is not typed onto an account',
    format('update public.accounts set current_balance = 1000000 where id = %L', d.cash),
    format('The balance of account %s is what has been posted to it%%', v_code), '42501');
  perform pg_temp.check_refused('nor an account made with one',
    format($q$insert into public.accounts
              (org_id, code, name, account_type, account_subtype, current_balance)
              values (%L, '1999', 'Wang tunai rekaan', 'asset', 'cash', 250)$q$, d.org),
    'A new account starts with nothing on it.%', '42501');

  -- What the screens do is as before: an account renamed and made, and
  -- the balance moved by posting. Read through `account_balances`: since
  -- `0856` no client reads the column itself, and the owner reads the
  -- ledger.
  update public.accounts set name = 'Maybank operating' where id = d.cash;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (d.org, '1998', 'Petty cash, front desk', 'asset', 'cash');
  perform pg_temp.check_eq('an account is still renamed, and made with nothing on it',
    (select name from public.accounts where id = d.cash) || ' / ' ||
    (select b.current_balance::text from public.account_balances(d.org) b
       join public.accounts a on a.id = b.account_id where a.code = '1998'),
    'Maybank operating / 0.00');

  perform public.post_manual_journal(d.org, app.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', d.cash, 'debit', 1200, 'credit', 0),
      jsonb_build_object('account_id', d.sales, 'debit', 0, 'credit', 1200)),
    'Cash sale', 'JV-1');
  perform pg_temp.check_eq('and posting a journal still moves the balance',
    (select current_balance from public.account_balances(d.org) where account_id = d.cash), 1200.00);
  perform pg_temp.check_eq('on both sides of it',
    (select current_balance from public.account_balances(d.org) where account_id = d.sales), 1200.00);
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- Both refusals also ask `pg_trigger_depth() = 1`, and both of those
-- mutants survive as equivalent ones: `app.apply_account_balance` is not
-- a definer, so it would be refused as a client one level down -- but no
-- road to `gl_lines` runs as a client today. Clients hold no write on it
-- (`0399`) and every function that posts is a definer, which runs as the
-- owner at any depth. The clause is there for the first road that does.
do $$
declare d t_ab;
begin
  select * into d from t_ab;
  update public.accounts set current_balance = current_balance + 0.01 where id = d.cash;
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select current_balance from public.accounts where id = d.cash), 1200.01);
end $$;

rollback;
