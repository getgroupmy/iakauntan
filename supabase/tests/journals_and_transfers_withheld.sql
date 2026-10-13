-- =====================================================================
-- iAkauntan :: a recurring journal and a bank transfer are the
-- ledger's (0861)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/journals_and_transfers_withheld.sql
--
-- Every member read `recurring_journals` -- the journal each template
-- posts, with its amounts -- and `bank_transfers` between the
-- company's own banks. Asked with the role `authenticated`, as the app
-- asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_jt (org uuid, other uuid, sales uuid, clerk uuid);
grant select on t_jt to authenticated;

do $$
declare r t_jt; b1 uuid; b2 uuid; o1 uuid; o2 uuid; a uuid; e uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Jurnal Berulang Sdn Bhd');
  r.other := pg_temp.test_org('Jurnal Lain Sdn Bhd');
  r.sales := pg_temp.another_user('sales@jurnal.test');
  r.clerk := pg_temp.another_user('clerk@jurnal.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.sales, 'sales', 'active'), (r.org, r.clerk, 'accounts_clerk', 'active');

  b1 := pg_temp.test_bank_account(r.org);
  b2 := pg_temp.test_bank_account(r.org, 'Simpanan tetap');
  select id into a from public.accounts where org_id = r.org and not is_group
     and account_type = 'expense' order by code limit 1;
  select id into e from public.accounts where org_id = r.org and not is_group
     and account_type = 'equity' order by code limit 1;
  -- Written as the database: what is asserted is who reads them.
  insert into public.recurring_journals (org_id, name, frequency, start_date, next_run_date, template)
  values (r.org, 'Directors'' fees', 'monthly', pg_temp.today(), pg_temp.today(),
    jsonb_build_object('lines', jsonb_build_array(
      jsonb_build_object('account_id', a, 'debit', 25000, 'credit', 0),
      jsonb_build_object('account_id', e, 'debit', 0, 'credit', 25000))));
  insert into public.bank_transfers (org_id, transfer_no, from_account_id, to_account_id,
    amount_sent, amount_received)
  values (r.org, 'TRF-1', b1, b2, 300000, 300000);

  -- The owner's other company, with a transfer of its own.
  o1 := pg_temp.test_bank_account(r.other);
  o2 := pg_temp.test_bank_account(r.other, 'Akaun lain');
  insert into public.bank_transfers (org_id, transfer_no, from_account_id, to_account_id,
    amount_sent, amount_received)
  values (r.other, 'TRF-9', o1, o2, 555, 555);
  insert into t_jt select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_jt), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_jt;
begin
  select * into d from t_jt;
  perform pg_temp.check_true('the premise: the salesman does not read the ledger',
    not app.can_read_ledger(d.org));
  perform pg_temp.check_eq('the salesman reads no recurring journal, nor what it posts',
    (select count(*) from public.recurring_journals where org_id = d.org)::int, 0);
  perform pg_temp.check_eq('nor any transfer between the company''s banks',
    (select count(*) from public.bank_transfers where org_id = d.org)::int, 0);
end $$;

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_jt), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_jt;
begin
  select * into d from t_jt;
  perform pg_temp.check_eq('the clerk reads the journal and what it posts',
    (select name || ' / ' || (template -> 'lines' -> 0 ->> 'debit')
       from public.recurring_journals where org_id = d.org),
    'Directors'' fees / 25000');
  perform pg_temp.check_eq('and the transfer',
    (select transfer_no || ' / ' || amount_sent from public.bank_transfers
      where org_id = d.org), 'TRF-1 / 300000.00');
  perform pg_temp.check_eq('and nothing of a company the clerk is not in',
    (select count(*) from public.bank_transfers where org_id = d.other)::int, 0);
end $$;

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_jt;
begin
  select * into d from t_jt;
  perform pg_temp.check_eq('the owner of both reads the other company''s transfer as its own',
    (select transfer_no from public.bank_transfers where org_id = d.other), 'TRF-9');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon reads neither table',
    not has_table_privilege('anon', 'public.recurring_journals', 'select')
    and not has_table_privilege('anon', 'public.bank_transfers', 'select'));
end $$;

rollback;
