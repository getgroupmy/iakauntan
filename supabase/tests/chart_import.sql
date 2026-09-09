-- =====================================================================
-- iAkauntan :: a chart of accounts from a file
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/chart_import.sql
--
-- 0550 imports a chart the way 0103 imports contacts: preview or
-- commit, a verdict per row, and nothing written at all unless every
-- row is good. Half a chart is worse than none -- the postings that
-- follow find some accounts and invent nothing for the rest -- so the
-- all-or-nothing rule is the one most worth asserting.
--
-- The other half of this file is a pairing nobody was checking.
-- `accounts` has carried a type and a subtype since the schema was laid
-- down and nothing has ever said which subtype belongs to which type.
-- An asset with the subtype `sales` sits in the balance sheet by type
-- and the income statement by subtype. It never happened because the
-- seeded template is consistent and the dialog filters the list; that
-- is two courtesies and no rule, and an imported file carries whatever
-- the old system called things.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.rows_of(p jsonb) returns jsonb
language sql immutable as $$ select p $$;

-- How many of the file's rows came back with each verdict.
create or replace function pg_temp.verdicts(
  p_org uuid, p_rows jsonb, p_commit boolean default false)
returns table (ok integer, bad integer, imported integer)
language sql as $$
  select count(*) filter (where status = 'ok')::integer,
         count(*) filter (where status = 'error')::integer,
         count(*) filter (where status = 'imported')::integer
    from public.import_accounts(p_org, p_rows, p_commit);
$$;

create or replace function pg_temp.first_error(p_org uuid, p_rows jsonb)
returns text language sql as $$
  select message from public.import_accounts(p_org, p_rows, false)
   where status = 'error' order by row_no limit 1;
$$;

create or replace function pg_temp.chart_size(p_org uuid)
returns integer language sql as $$
  select count(*)::integer from public.accounts
   where org_id = p_org and deleted_at is null;
$$;

do $$
declare
  v_org   uuid;
  v_before integer;
  v_rows  jsonb;
  r       record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kilang Carta Sdn Bhd', array['crm']);
  v_before := pg_temp.chart_size(v_org);
  perform pg_temp.check_true('the fixture starts with the seeded chart',
    v_before > 20);

  -- ------------------------------------------------------------------
  -- A good file
  -- ------------------------------------------------------------------
  v_rows := jsonb_build_array(
    jsonb_build_object('code', '7200', 'name', 'Workshop income',
                       'account_type', 'revenue', 'account_subtype', 'sales'),
    jsonb_build_object('code', '7300', 'name', 'Consumables',
                       'account_type', 'expense',
                       'account_subtype', 'cost_of_sales'));

  select * into r from pg_temp.verdicts(v_org, v_rows, false);
  perform pg_temp.check_eq('a good file previews clean', r.ok, 2);
  perform pg_temp.check_eq('and a preview writes nothing',
    pg_temp.chart_size(v_org), v_before);
  perform pg_temp.check_eq('nor does it report anything as imported',
    r.imported, 0);

  select * into r from pg_temp.verdicts(v_org, v_rows, true);
  perform pg_temp.check_eq('committing reports both rows imported',
    r.imported, 2);
  perform pg_temp.check_eq('and the chart has them',
    pg_temp.chart_size(v_org), v_before + 2);
  perform pg_temp.check_eq('with the type the subtype belongs to',
    (select account_type::text from public.accounts
      where org_id = v_org and code = '7200'), 'revenue');

  -- ------------------------------------------------------------------
  -- One bad row stops the file
  -- ------------------------------------------------------------------
  v_before := pg_temp.chart_size(v_org);
  v_rows := jsonb_build_array(
    jsonb_build_object('code', '7400', 'name', 'Rental income',
                       'account_type', 'revenue',
                       'account_subtype', 'other_income'),
    jsonb_build_object('code', '7401', 'name', 'No subtype at all',
                       'account_type', 'revenue'));

  select * into r from pg_temp.verdicts(v_org, v_rows, true);
  perform pg_temp.check_eq('one bad row imports nothing', r.imported, 0);
  perform pg_temp.check_eq('and the good row beside it is still reported ok',
    r.ok, 1);
  perform pg_temp.check_eq('the chart is untouched',
    pg_temp.chart_size(v_org), v_before);
  perform pg_temp.check_true('and the refusal says what is missing',
    pg_temp.first_error(v_org, v_rows) like '%No account_subtype%');
end $$;

-- ---------------------------------------------------------------------
-- What each row is refused for
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_before integer;
  r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kilang Salah Sdn Bhd', array['crm']);
  v_before := pg_temp.chart_size(v_org);

  perform pg_temp.check_true('an account with no number is refused',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('name', 'Nameless', 'account_subtype', 'sales')))
    like '%No account number%');

  perform pg_temp.check_true('and one with no name',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '9001', 'account_subtype', 'sales')))
    like '%No name%');

  -- Caught in the file rather than by the unique index, which would
  -- fail the whole import without saying which two rows clashed.
  perform pg_temp.check_true('a code twice in one file is refused',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '9002', 'name', 'One',
                         'account_subtype', 'sales'),
      jsonb_build_object('code', '9002', 'name', 'Two',
                         'account_subtype', 'sales')))
    like '%more than once%');

  -- The seeded chart has 1100. This brings new accounts in; it does not
  -- rename an account the ledger posts to by number.
  perform pg_temp.check_true('a code already in the chart is refused',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '1100', 'name', 'Something else',
                         'account_subtype', 'bank')))
    like '%already in the chart%');

  perform pg_temp.check_true('a subtype that is not one is refused',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '9003', 'name', 'Odd',
                         'account_subtype', 'wishful')))
    like '%is not an account subtype%');

  perform pg_temp.check_true('and a type that is not one',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '9004', 'name', 'Odd',
                         'account_type', 'wishful',
                         'account_subtype', 'sales')))
    like '%is not an account type%');

  -- The pairing.
  perform pg_temp.check_true('an asset cannot be a sales account',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '9005', 'name', 'Confused',
                         'account_type', 'asset',
                         'account_subtype', 'sales')))
    like '%cannot have the subtype "sales" -- that belongs to revenue%');

  perform pg_temp.check_eq('and none of that wrote anything',
    pg_temp.chart_size(v_org), v_before);
end $$;

-- ---------------------------------------------------------------------
-- Headings, and the order they have to come in
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_before integer;
  r record;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kilang Tajuk Sdn Bhd', array['crm']);
  v_before := pg_temp.chart_size(v_org);

  -- A heading and two accounts under it, in that order.
  select * into r from pg_temp.verdicts(v_org, jsonb_build_array(
    jsonb_build_object('code', '8000', 'name', 'Motor vehicle expenses',
                       'account_type', 'expense',
                       'account_subtype', 'operating_expense',
                       'is_group', 'true'),
    jsonb_build_object('code', '8010', 'name', 'Fuel',
                       'account_type', 'expense',
                       'account_subtype', 'operating_expense',
                       'parent_code', '8000'),
    jsonb_build_object('code', '8020', 'name', 'Road tax and insurance',
                       'account_type', 'expense',
                       'account_subtype', 'operating_expense',
                       'parent_code', '8000')), true);
  perform pg_temp.check_eq('a heading and its accounts import together',
    r.imported, 3);
  perform pg_temp.check_eq('and the children hang off it',
    (select count(*)::integer from public.accounts c
      join public.accounts p on p.id = c.parent_id
     where c.org_id = v_org and p.code = '8000'), 2);

  -- The other order. A child written before its parent would hang off
  -- nothing, so the file is refused rather than half-applied.
  v_before := pg_temp.chart_size(v_org);
  perform pg_temp.check_true(
    'a parent has to come before the account that uses it',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '7010', 'name', 'Child first',
                         'account_type', 'expense',
                         'account_subtype', 'operating_expense',
                         'parent_code', '7000'),
      jsonb_build_object('code', '7000', 'name', 'Heading second',
                         'account_type', 'expense',
                         'account_subtype', 'operating_expense',
                         'is_group', 'true')))
    like '%has to come before%');

  -- And a parent that exists but is not a heading.
  perform pg_temp.check_true('a parent has to be a heading',
    pg_temp.first_error(v_org, jsonb_build_array(
      jsonb_build_object('code', '8011', 'name', 'Under an ordinary account',
                         'account_type', 'expense',
                         'account_subtype', 'operating_expense',
                         'parent_code', '8010')))
    like '%is not a heading%');

  perform pg_temp.check_eq('neither wrote anything',
    pg_temp.chart_size(v_org), v_before);
end $$;

-- ---------------------------------------------------------------------
-- The other door asks the same question
-- ---------------------------------------------------------------------
-- `upsert_account` is where one account at a time is added, and it
-- would otherwise be able to write the pairing the file cannot.
do $$
declare
  v_org uuid;
  v_id  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kilang Pintu Sdn Bhd', array['crm']);

  perform pg_temp.check_refused(
    'the account dialog cannot write a mismatched pairing either',
    format('select public.upsert_account(%L, %L, %L::app.account_type, '
           '%L::app.account_subtype, null, null, false, null, %L)',
           '9100', 'An asset that reports as revenue', 'asset', 'sales',
           v_org),
    '%cannot have the subtype "sales"%', '23514');

  -- And the pairing it does accept is written.
  v_id := public.upsert_account(
    p_code => '9101', p_name => 'Workshop income',
    p_type => 'revenue'::app.account_type,
    p_subtype => 'sales'::app.account_subtype,
    p_org_id => v_org);
  perform pg_temp.check_true('a matching pairing is accepted', v_id is not null);

  -- An existing row may still be renamed. The check looks at the
  -- pairing only when the pairing is what is moving.
  perform public.upsert_account(
    p_code => '9101', p_name => 'Workshop and yard income',
    p_type => 'revenue'::app.account_type,
    p_subtype => 'sales'::app.account_subtype,
    p_id => v_id);
  perform pg_temp.check_eq('and renaming one is not refused',
    (select name from public.accounts where id = v_id),
    'Workshop and yard income');
end $$;

-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_clerk  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kilang Kebenaran Sdn Bhd', array['crm']);

  -- A viewer may read the books and may not decide what the books are
  -- made of.
  v_clerk := pg_temp.another_user('pelihat-0550@iakauntan.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now())
  on conflict (org_id, user_id) do update set role = 'viewer';

  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_refused(
    'somebody who may not post cannot import a chart',
    format('select public.import_accounts(%L, %L::jsonb, false)', v_org,
           '[{"code":"9200","name":"X","account_subtype":"sales"}]'),
    '%may post the books%', '42501');
end $$;

rollback;
