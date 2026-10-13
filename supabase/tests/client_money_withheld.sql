-- =====================================================================
-- iAkauntan :: client money is the ledger's, and the fee earner's (0862)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/client_money_withheld.sql
--
-- Every member of a law firm read its client account, line by line,
-- and what each matter held. Now a member who reads the ledger does,
-- and the member named as a matter's fee earner does for that matter;
-- everybody else still sees the matter, with its money blank. Asked
-- with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cm (org uuid, other uuid, earner uuid, sales uuid,
  clerk uuid, mine uuid, theirs uuid, elsewhere uuid);
grant select on t_cm to authenticated;

do $$
declare r t_cm; c uuid; oc uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Peguam Amanah');
  r.other := pg_temp.test_org('Peguam Lain');
  -- A fee earner who holds the sales role, a salesman who earns on no
  -- file, and a clerk.
  r.earner := pg_temp.another_user('earner@peguam.test');
  r.sales := pg_temp.another_user('sales@peguam.test');
  r.clerk := pg_temp.another_user('clerk@peguam.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.earner, 'sales', 'active'), (r.org, r.sales, 'sales', 'active'),
         (r.org, r.clerk, 'accounts_clerk', 'active');

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Puan Aminah', 'customer') returning id into c;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (r.org, 'M-1', 'Sale of a house', c, r.earner) returning id into r.mine;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (r.org, 'M-2', 'A tenancy dispute', c, pg_temp.test_user()) returning id into r.theirs;
  -- Written as the database: no client writes this table.
  insert into public.client_account_transactions (org_id, matter_id, transaction_no,
    transaction_type, amount, status, description)
  values (r.org, r.mine, 'CR-1', 'receipt', 850000, 'posted', 'Purchase price, held in trust'),
         (r.org, r.theirs, 'CR-2', 'receipt', 12000, 'posted', 'Deposit on account');

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.other, 'C-9', 'Encik Lain', 'customer') returning id into oc;
  insert into public.matters (org_id, matter_no, name, client_id, fee_earner)
  values (r.other, 'M-9', 'Elsewhere', oc, pg_temp.test_user()) returning id into r.elsewhere;
  insert into public.client_account_transactions (org_id, matter_id, transaction_no,
    transaction_type, amount, status)
  values (r.other, r.elsewhere, 'CR-9', 'receipt', 555, 'posted');
  insert into t_cm select r.*;
end $$;

-- The salesman, who earns on no file.
select set_config('request.jwt.claims',
  json_build_object('sub', (select sales from t_cm), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_cm;
begin
  select * into d from t_cm;
  perform pg_temp.check_eq('the salesman reads no line of client money',
    (select count(*) from public.client_account_transactions where org_id = d.org)::int, 0);
  perform pg_temp.check_true('nor what any matter holds -- nothing, not nought',
    public.matter_client_balance(d.mine) is null
    and public.matter_client_balance(d.theirs) is null);
  perform pg_temp.check_eq('while the matters are still listed for them',
    (select string_agg(matter_no, ',' order by matter_no)
       from public.report_matter_summary(d.org)), 'M-1,M-2');
  perform pg_temp.check_eq('with the money held blank on every one',
    (select count(*) from public.report_matter_summary(d.org)
      where client_funds is not null)::int, 0);
end $$;

reset role;

-- The fee earner, who also holds the sales role.
select set_config('request.jwt.claims',
  json_build_object('sub', (select earner from t_cm), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_cm;
begin
  select * into d from t_cm;
  perform pg_temp.check_true('the premise: the fee earner does not read the ledger',
    not app.can_read_ledger(d.org));
  perform pg_temp.check_eq('the fee earner reads the client money on their own file',
    (select string_agg(transaction_no || ' ' || amount, ',')
       from public.client_account_transactions where org_id = d.org),
    'CR-1 850000.00');
  perform pg_temp.check_eq('and what it holds',
    public.matter_client_balance(d.mine), 850000.00);
  perform pg_temp.check_true('but not what another matter holds',
    public.matter_client_balance(d.theirs) is null);
  perform pg_temp.check_eq('and in the summary, their file''s and nobody else''s',
    (select string_agg(matter_no || '=' || coalesce(client_funds::text, 'blank'), ','
       order by matter_no) from public.report_matter_summary(d.org)),
    'M-1=850000.00,M-2=blank');
end $$;

reset role;

-- The clerk reads the ledger, so all of it.
select set_config('request.jwt.claims',
  json_build_object('sub', (select clerk from t_cm), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_cm;
begin
  select * into d from t_cm;
  perform pg_temp.check_eq('the clerk reads every line of this firm''s client money',
    (select count(*) from public.client_account_transactions where org_id = d.org)::int, 2);
  perform pg_temp.check_eq('and every matter''s balance',
    public.matter_client_balance(d.theirs), 12000.00);
  perform pg_temp.check_eq('in the summary too',
    (select sum(client_funds) from public.report_matter_summary(d.org)), 862000.00);
  perform pg_temp.check_eq('and nothing of a firm the clerk is not in',
    (select count(*) from public.client_account_transactions where org_id = d.other)::int, 0);
  perform pg_temp.check_true('nor its balance',
    public.matter_client_balance(d.elsewhere) is null);
end $$;

reset role;

-- A fee earner suspended from the firm is no longer told.
do $$
declare d t_cm;
begin
  select * into d from t_cm;
  update public.org_members set status = 'suspended'
   where org_id = d.org and user_id = d.earner;
  perform set_config('request.jwt.claims',
    json_build_object('sub', d.earner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform pg_temp.check_eq('a suspended fee earner reads nothing of their file',
    (select count(*) from public.client_account_transactions where org_id = d.org)::int, 0);
  reset role;
end $$;

do $$
begin
  perform pg_temp.check_true('anon calls neither function nor the rule',
    not has_function_privilege('anon', 'public.matter_client_balance(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.report_matter_summary(uuid)', 'execute')
    and not has_function_privilege('anon', 'app.can_read_client_money(uuid)', 'execute'));
end $$;

rollback;
