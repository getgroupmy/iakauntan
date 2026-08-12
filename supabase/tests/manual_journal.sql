-- =====================================================================
-- iAkauntan :: manual journal tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/manual_journal.sql
--
-- `post_manual_journal` is the only route by which a person, rather than
-- a document, writes to the ledger. Everything it refuses it refuses on
-- somebody's behalf: the balance rule, the period lock, and — the two
-- that are easiest to leave out and hardest to notice — the account
-- belonging to this organization and being one you may post to.
--
-- `create_gl_entry`, which this replaced as the client's entry point,
-- checks none of the last three. That is why it is no longer granted to
-- `authenticated`, and the grant is asserted below.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.two_lines(
  p_debit_account uuid, p_credit_account uuid, p_amount numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('account_id', p_debit_account,
                       'debit', p_amount, 'credit', 0),
    jsonb_build_object('account_id', p_credit_account,
                       'debit', 0, 'credit', p_amount));
$$;

-- ---------------------------------------------------------------------
-- The entry a bookkeeper actually writes: an accrual
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Accrual Sdn Bhd');
  v_expense uuid; v_accrual uuid; v_entry uuid; v_row public.gl_entries;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  select id into v_expense from public.accounts
   where org_id = v_org and code = '6100';
  select id into v_accrual from public.accounts
   where org_id = v_org and code = '2120';

  v_entry := public.post_manual_journal(
    v_org, date '2026-03-31',
    pg_temp.two_lines(v_expense, v_accrual, 1250.00),
    '  Accrue March electricity  ', '  ACC-03  ');

  select * into v_row from public.gl_entries where id = v_entry;

  perform pg_temp.check_true('the journal posts', v_row.status = 'posted');
  perform pg_temp.check_true('as a manual journal', v_row.source = 'manual');
  perform pg_temp.check_true('inside a fiscal period',
    v_row.fiscal_period_id is not null);
  perform pg_temp.check_true('in the books'' own currency',
    v_row.currency = 'MYR');

  -- Whitespace is trimmed rather than stored: a description that
  -- differs from another only by a leading space reads as a duplicate
  -- in every list that shows it.
  perform pg_temp.check_true('the description is trimmed',
    v_row.description = 'Accrue March electricity');
  perform pg_temp.check_true('and so is the reference',
    v_row.reference = 'ACC-03');

  perform pg_temp.check_eq('it balances',
    (select sum(debit) from public.gl_lines where entry_id = v_entry), 1250.00);
  perform pg_temp.check_eq('both ways',
    (select sum(credit) from public.gl_lines where entry_id = v_entry), 1250.00);
end $$;

-- ---------------------------------------------------------------------
-- What it refuses
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Refusal Sdn Bhd');
  v_other uuid;
  v_expense uuid; v_accrual uuid; v_header uuid; v_dormant uuid;
  v_foreign_account uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  select id into v_expense from public.accounts
   where org_id = v_org and code = '6100';
  select id into v_accrual from public.accounts
   where org_id = v_org and code = '2120';
  -- 2100 "Current Liabilities" is the header a bookkeeper reaching for
  -- an accrual is most likely to pick by mistake.
  select id into v_header from public.accounts
   where org_id = v_org and code = '2100';

  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      jsonb_build_array(
        jsonb_build_object('account_id', v_expense, 'debit', 100, 'credit', 0),
        jsonb_build_object('account_id', v_accrual, 'debit', 0, 'credit', 90)),
      'unbalanced');
    raise exception 'FAIL: an unbalanced journal posted';
  exception when sqlstate '23514' then
    raise notice 'ok   an unbalanced journal is refused';
  end;

  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      jsonb_build_array(
        jsonb_build_object('account_id', v_expense, 'debit', 0, 'credit', 0)),
      'one line');
    raise exception 'FAIL: a one-line journal posted';
  exception when sqlstate '23514' then
    raise notice 'ok   a one-line journal is refused';
  end;

  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      pg_temp.two_lines(v_expense, v_accrual, 100), '   ');
    raise exception 'FAIL: a journal with no description posted';
  exception when sqlstate '23514' then
    raise notice 'ok   a journal with no description is refused';
  end;

  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      jsonb_build_array(
        jsonb_build_object('account_id', v_expense, 'debit', -100, 'credit', 0),
        jsonb_build_object('account_id', v_accrual, 'debit', 0, 'credit', -100)),
      'negative both sides');
    raise exception 'FAIL: a negative amount posted';
  exception when sqlstate '23514' then
    raise notice 'ok   a negative amount is refused';
  end;

  -- A line carrying both is almost always a mistyped column, and
  -- `create_gl_entry_internal` would take it: 100 and 100 on one line
  -- balances against itself and vanishes from the entry's totals.
  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      jsonb_build_array(
        jsonb_build_object('account_id', v_expense, 'debit', 100, 'credit', 100),
        jsonb_build_object('account_id', v_accrual, 'debit', 50, 'credit', 50)),
      'both columns');
    raise exception 'FAIL: a line with both a debit and a credit posted';
  exception when sqlstate '23514' then
    raise notice 'ok   a line with both a debit and a credit is refused';
  end;

  -- A header account. Every report sums a group over its children, so a
  -- line hung directly off one is counted twice or not at all depending
  -- on which report you read.
  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      pg_temp.two_lines(v_header, v_accrual, 100), 'onto a header');
    raise exception 'FAIL: posted onto a group account';
  exception when sqlstate '23514' then
    raise notice 'ok   a group account is refused';
  end;

  -- A deactivated account is deactivated for a reason.
  select id into v_dormant from public.accounts
   where org_id = v_org and code = '6200';
  update public.accounts set is_active = false where id = v_dormant;
  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      pg_temp.two_lines(v_dormant, v_accrual, 100), 'onto a dormant account');
    raise exception 'FAIL: posted onto an inactive account';
  exception when sqlstate '23514' then
    raise notice 'ok   an inactive account is refused';
  end;

  -- The one that matters most. `create_gl_entry_internal` stamps
  -- `org_id` from its own argument and never looks at where the account
  -- came from, so a crafted call could hang a line off another
  -- organization's chart — a cross-tenant write that no RLS policy on
  -- `gl_lines` would catch, because the row's own `org_id` is correct.
  v_other := pg_temp.test_org('Somebody Else Sdn Bhd');
  select id into v_foreign_account from public.accounts
   where org_id = v_other and code = '6100';
  perform pg_temp.sign_in_as(
    (select created_by from public.organizations where id = v_org));

  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      pg_temp.two_lines(v_foreign_account, v_accrual, 100),
      'another company''s account');
    raise exception 'FAIL: posted onto another organization''s account';
  exception when sqlstate '23514' then
    raise notice 'ok   another organization''s account is refused';
  end;
end $$;

-- ---------------------------------------------------------------------
-- Dimensions survive the trip
--
-- `gl_lines.project_code` has existed since 0004 and the manual journal
-- is the entry most likely to carry one — a reclassification between
-- jobs is a single journal touching two projects.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Job Costing Sdn Bhd');
  v_a uuid; v_b uuid; v_entry uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_a from public.accounts where org_id = v_org and code = '6100';
  select id into v_b from public.accounts where org_id = v_org and code = '6200';

  v_entry := public.post_manual_journal(v_org, date '2026-03-31',
    jsonb_build_array(
      jsonb_build_object('account_id', v_a, 'debit', 300, 'credit', 0,
                         'project_code', 'JOB-A',
                         'description', 'moved off the wrong job'),
      jsonb_build_object('account_id', v_b, 'debit', 0, 'credit', 300,
                         'project_code', 'JOB-B')),
    'reclassify between jobs');

  perform pg_temp.check_eq('two projects on one journal',
    (select count(distinct project_code) from public.gl_lines
      where entry_id = v_entry), 2);
  perform pg_temp.check_true('and the narrative is kept',
    (select description = 'moved off the wrong job' from public.gl_lines
      where entry_id = v_entry and project_code = 'JOB-A'));

  -- And the dimension report can see it, which is the point of storing
  -- it at all.
  perform pg_temp.check_eq('the dimension report finds one side',
    (select sum(amount) from public.report_profit_loss_by_dimension(
       v_org, date '2026-01-01', date '2026-12-31', 'JOB-A')), 300);
end $$;

-- ---------------------------------------------------------------------
-- Somebody who may not post, may not post
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.test_org('Guarded Journal Sdn Bhd');
  v_a uuid; v_b uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  select id into v_a from public.accounts where org_id = v_org and code = '6100';
  select id into v_b from public.accounts where org_id = v_org and code = '2120';

  perform pg_temp.sign_out();
  begin
    perform public.post_manual_journal(v_org, date '2026-03-31',
      pg_temp.two_lines(v_a, v_b, 100), 'from nobody');
    raise exception 'FAIL: a signed-out caller posted a journal';
  exception when sqlstate '42501' then
    raise notice 'ok   a signed-out caller cannot post a journal';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The grants
--
-- `create_gl_entry` takes the journal's source, source table and source
-- id as arguments, so any signed-in user holding it could post an entry
-- claiming to have come from a payroll run. It is withdrawn, and this
-- asserts it stays withdrawn — a later migration that recreates the
-- function without repeating the revoke would hand it back, because
-- PostgreSQL grants EXECUTE to PUBLIC on every new function by default.
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('post_manual_journal is granted',
    has_function_privilege('authenticated',
      'public.post_manual_journal(uuid, date, jsonb, text, text)', 'execute'));

  perform pg_temp.check_true('create_gl_entry is not',
    not has_function_privilege('authenticated',
      'public.create_gl_entry(uuid, date, app.journal_source, jsonb, text, '
      'text, uuid, text, character, numeric)', 'execute'));

  perform pg_temp.check_true('and neither anon nor public holds it',
    not has_function_privilege('anon',
      'public.create_gl_entry(uuid, date, app.journal_source, jsonb, text, '
      'text, uuid, text, character, numeric)', 'execute'));
end $$;

rollback;
