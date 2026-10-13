-- =====================================================================
-- iAkauntan :: a commission rate is the ledger's (0866)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/commission_rates_withheld.sql
--
-- `report_sales_by_person` turns a rate into commission, and has answered
-- only a reader of the ledger since `0105`. The rate itself was read by
-- every member and written by every member who may write: a salesman
-- read his colleague's, raised his own and cut hers. Asked with the role
-- `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cr (org uuid, other uuid, ali uuid, clerk uuid,
  accountant uuid, me uuid, siti uuid, theirs uuid);
grant select on t_cr to authenticated;

do $$
declare r t_cr;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Jualan Kadar Sdn Bhd');
  r.other := pg_temp.test_org('Jualan Lain Sdn Bhd');
  r.ali        := pg_temp.another_user('ali@jualankadar.test');
  r.clerk      := pg_temp.another_user('clerk@jualankadar.test');
  r.accountant := pg_temp.another_user('akauntan@jualankadar.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.ali, 'sales', 'active'),
         (r.org, r.clerk, 'accounts_clerk', 'active'),
         (r.org, r.accountant, 'accountant', 'active');
  insert into public.salespeople (org_id, code, name, commission_rate, member_id)
  values (r.org, 'ALI', 'Ali', 2.5,
          (select id from public.org_members where org_id = r.org and user_id = r.ali))
  returning id into r.me;
  insert into public.salespeople (org_id, code, name, commission_rate)
  values (r.org, 'SITI', 'Siti', 4) returning id into r.siti;
  -- The owner's other company, with a rate of its own.
  insert into public.salespeople (org_id, code, name, commission_rate)
  values (r.other, 'LAIN', 'Lain', 9) returning id into r.theirs;
  insert into t_cr select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The salesman: names, and no rate -- his own included
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select ali from t_cr));
set local role authenticated;

do $$
declare d t_cr;
begin
  select * into d from t_cr;
  perform pg_temp.check_true('the premise: Ali writes and does not read the ledger',
    app.can_write(d.org) and not app.can_read_ledger(d.org));
  perform pg_temp.check_eq('Ali reads who sells, for the invoice''s picker',
    (select string_agg(code || ' ' || name, ', ' order by code)
       from public.salespeople where org_id = d.org),
    'ALI Ali, SITI Siti');
  perform pg_temp.check_refused('and not the rates',
    'select commission_rate from public.salespeople',
    '%permission denied%', '42501');
  -- What makes `Repo.salespeople` name its columns: a bare select is
  -- refused outright, by anybody, rather than answered without the rate.
  perform pg_temp.check_refused('nor every column at once',
    'select * from public.salespeople',
    '%permission denied%', '42501');
  perform pg_temp.check_eq('nor from the function, which gives him nothing',
    (select count(*) from public.salesperson_commission_rates(d.org))::int, 0);
  perform pg_temp.check_refused('Ali cannot raise his own rate',
    format('update public.salespeople set commission_rate = 25 where id = %L', d.me),
    'A commission rate is set by whoever would pay it%', '42501');
  perform pg_temp.check_refused('nor cut a colleague''s',
    format('update public.salespeople set commission_rate = 0 where id = %L', d.siti),
    'A commission rate is set by whoever would pay it%', '42501');
  perform pg_temp.check_refused('nor bring in somebody new on a rate',
    format($q$insert into public.salespeople (org_id, code, name, commission_rate)
              values (%L, 'BARU', 'Baru', 10)$q$, d.org),
    'A commission rate is set by whoever would pay it%', '42501');

  -- What he may still do: everything but the rate.
  update public.salespeople set email = 'ali@jualan.test' where id = d.me;
  insert into public.salespeople (org_id, code, name) values (d.org, 'BARU', 'Baru');
  perform pg_temp.check_eq('he still keeps the list: an email changed, and somebody new without a rate',
    (select string_agg(code || ' ' || coalesce(email, '-'), ', ' order by code)
       from public.salespeople where org_id = d.org),
    'ALI ali@jualan.test, BARU -, SITI -');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The clerk reads the ledger and posts nothing: reads the rates, sets
-- none
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select clerk from t_cr));
set local role authenticated;

do $$
declare d t_cr;
begin
  select * into d from t_cr;
  perform pg_temp.check_eq('the clerk reads every rate, Ali''s and Siti''s as they were',
    (select string_agg(s.code || ' ' || coalesce(r.commission_rate::text, '-'), ', ' order by s.code)
       from public.salesperson_commission_rates(d.org) r
       join public.salespeople s on s.id = r.salesperson_id),
    'ALI 2.500, BARU -, SITI 4.000');
  perform pg_temp.check_refused('and sets none',
    format('update public.salespeople set commission_rate = 3 where id = %L', d.siti),
    'A commission rate is set by whoever would pay it%', '42501');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The accountant sets them
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select accountant from t_cr));
set local role authenticated;

do $$
declare d t_cr;
begin
  select * into d from t_cr;
  update public.salespeople set commission_rate = 3 where id = d.siti;
  insert into public.salespeople (org_id, code, name, commission_rate)
  values (d.org, 'RAJ', 'Raj', 1.5);
  perform pg_temp.check_eq('the accountant changes a rate and brings somebody in on one',
    (select string_agg(s.code || ' ' || r.commission_rate, ', ' order by s.code)
       from public.salesperson_commission_rates(d.org) r
       join public.salespeople s on s.id = r.salesperson_id
      where r.commission_rate is not null),
    'ALI 2.500, RAJ 1.500, SITI 3.000');
  perform pg_temp.check_eq('and the report reads the same rates',
    (select string_agg(name || ' ' || commission_rate, ', ' order by name)
       from public.report_sales_by_person(d.org, pg_temp.today() - 30, pg_temp.today())
      where commission_rate is not null),
    'Ali 2.500, Raj 1.500, Siti 3.000');
  perform pg_temp.check_eq('and nothing of a company the accountant is not in',
    (select count(*) from public.salesperson_commission_rates(d.other))::int, 0);
end $$;

reset role;

select pg_temp.sign_in_as(pg_temp.test_user());
set local role authenticated;

do $$
declare d t_cr;
begin
  select * into d from t_cr;
  perform pg_temp.check_eq('the owner of both is given each company''s own, and only its own',
    (select string_agg(s.code, ', ' order by s.code)
       from public.salesperson_commission_rates(d.other) r
       join public.salespeople s on s.id = r.salesperson_id),
    'LAIN');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('anon calls nothing and reads nothing',
    not has_function_privilege('anon', 'public.salesperson_commission_rates(uuid)', 'execute')
    and not has_column_privilege('anon', 'public.salespeople', 'commission_rate', 'select'));
end $$;

rollback;
