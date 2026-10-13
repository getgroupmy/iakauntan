-- =====================================================================
-- iAkauntan :: the bank's statement is the ledger's (0859)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/bank_statement_withheld.sql
--
-- `0858` withheld the bank's balance from a role that does not read
-- the ledger. Every member still read the statement it comes from --
-- `bank_transactions`, line by line with the running balance -- and
-- every reconciliation's statement and book balance. Asked with the
-- role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_bs (org uuid, other uuid, sales uuid, clerk uuid,
  bank uuid, other_bank uuid);
grant select on t_bs to authenticated;

do $$
declare r t_bs;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Penyata Bank Sdn Bhd');
  r.other := pg_temp.test_org('Penyata Lain Sdn Bhd');
  r.sales := pg_temp.another_user('sales@penyata.test');
  r.clerk := pg_temp.another_user('clerk@penyata.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.clerk, 'accounts_clerk', 'active');

  r.bank := pg_temp.test_bank_account(r.org);
  -- The statement as an import leaves it: written as the database, since
  -- no client writes this table (`0808`).
  insert into public.bank_transactions (org_id, bank_account_id, transaction_date,
    description, amount, running_balance, transaction_type)
  values (r.org, r.bank, pg_temp.today(), 'GAJI PENGARAH OKT', -45000, 98765.43, 'withdrawal'),
         (r.org, r.bank, pg_temp.today(), 'IBG FROM CUSTOMER', 12000, 110765.43, 'deposit');
  insert into public.bank_reconciliations (org_id, bank_account_id, statement_date,
    statement_balance, book_balance, difference, status)
  values (r.org, r.bank, pg_temp.today(), 110765.43, 110765.43, 0, 'completed');

  -- The owner's other company, with a statement of its own that no
  -- answer about this one may carry.
  r.other_bank := pg_temp.test_bank_account(r.other, 'Akaun lain');
  insert into public.bank_transactions (org_id, bank_account_id, transaction_date,
    description, amount, running_balance, transaction_type)
  values (r.other, r.other_bank, pg_temp.today(), 'ELSEWHERE', 555, 555, 'deposit');
  insert into t_bs select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_bs), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_bs;
begin
  select * into d from t_bs;
  perform pg_temp.check_eq('the premise: the salesman does not read the ledger, and still picks the bank',
    app.can_read_ledger(d.org)::text || ' / '
      || (select name from public.bank_accounts where id = d.bank),
    'false / Current account');

  -- What was measured.
  perform pg_temp.check_eq('the salesman reads no line of the statement',
    (select count(*) from public.bank_transactions where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('so no running balance off it',
    (select count(*) from public.bank_transactions where running_balance is not null)::int, 0);
  perform pg_temp.check_eq('nor any reconciliation''s balances',
    (select count(*) from public.bank_reconciliations where org_id = d.org)::int, 0);
end $$;

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_bs), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_bs;
begin
  select * into d from t_bs;
  perform pg_temp.check_eq('the clerk reads the statement, every line of it',
    (select string_agg(description || ' ' || amount || ' ' || running_balance, ', '
       order by running_balance)
       from public.bank_transactions where bank_account_id = d.bank),
    'GAJI PENGARAH OKT -45000.00 98765.43, IBG FROM CUSTOMER 12000.00 110765.43');
  perform pg_temp.check_eq('and the reconciliation',
    (select statement_balance || ' / ' || book_balance
       from public.bank_reconciliations where bank_account_id = d.bank),
    '110765.43 / 110765.43');
  perform pg_temp.check_eq('and nothing of a company the clerk is not in',
    (select count(*) from public.bank_transactions where org_id = d.other)::int, 0);
end $$;

reset role;

-- The owner of both, for the other company: its own lines.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_bs;
begin
  select * into d from t_bs;
  perform pg_temp.check_eq('the other company''s statement is its own',
    (select string_agg(description, ',') from public.bank_transactions where org_id = d.other),
    'ELSEWHERE');
  perform pg_temp.check_eq('and the owner reads this one''s too',
    (select count(*) from public.bank_transactions where org_id = d.org)::int, 2);
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon reads neither table',
    not has_table_privilege('anon', 'public.bank_transactions', 'select')
    and not has_table_privilege('anon', 'public.bank_reconciliations', 'select'));
  perform pg_temp.check_true('and no client writes either',
    not has_table_privilege('authenticated', 'public.bank_transactions', 'insert, update, delete')
    and not has_table_privilege('authenticated', 'public.bank_reconciliations', 'insert, update, delete'));
end $$;

rollback;
