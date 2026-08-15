-- =====================================================================
-- iAkauntan :: how far a migration has got
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/migration_progress.sql
--
-- The report is six counts and a verdict, and the verdict is the only
-- part that can be wrong in a way that matters: it is what tells
-- somebody their migration is finished. So it is asserted in all four
-- states it can be in — nothing started, part way with a credit, part
-- way with a debit, and done — because "it says a number" is not the
-- claim. The claim is that the number and the sentence agree with what
-- is actually in the books.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.prog_org(p_name text)
returns uuid language plpgsql as $$
declare v_boss uuid := pg_temp.another_user(p_name || '@progress.test');
        v_org uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', v_boss)
  returning id into v_org;
  perform app.seed_chart_of_accounts(v_org);
  perform pg_temp.sign_in_as(v_boss);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer'),
         (v_org, 'S-1', 'Pembekal', 'supplier');
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_org, 'W', 'Widget', 'stock', true, 'none', 20, 10);
  return v_org;
end; $$;

create or replace function pg_temp.verdict(p_org uuid)
returns text language sql stable as $$
  select detail from public.report_migration_progress(p_org) where step_no = 7;
$$;

create or replace function pg_temp.suspense(p_org uuid)
returns numeric language sql stable as $$
  select quantity from public.report_migration_progress(p_org) where step_no = 7;
$$;

do $$
declare v_org uuid; v_n numeric;
begin
  v_org := pg_temp.prog_org('Progress Sdn Bhd');

  -- ------------------------------------------------------------------
  -- Nothing brought across
  --
  -- Distinguished from a finished migration, which also reads nil. A
  -- report that could not tell the two apart would congratulate somebody
  -- who had not started.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a company that has not started reads nil',
    pg_temp.suspense(v_org), 0);
  perform pg_temp.check_true('and says so, rather than saying it is done',
    pg_temp.verdict(v_org) like '%Nothing has been brought across yet%');

  -- The counts are of what is there, not of what was imported: the
  -- contacts above were inserted by hand.
  perform pg_temp.check_eq('the contacts are counted',
    (select quantity from public.report_migration_progress(v_org)
      where step_no = 1), 2);
  perform pg_temp.check_eq('and the items',
    (select quantity from public.report_migration_progress(v_org)
      where step_no = 2), 1);
  perform pg_temp.check_eq('and nothing has been opened yet',
    (select sum(quantity) from public.report_migration_progress(v_org)
      where step_no between 3 and 6), 0);

  -- ------------------------------------------------------------------
  -- Part way: the open items are in and the trial balance is not
  -- ------------------------------------------------------------------
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no', 'I-1', 'contact_code', 'C-1',
      'doc_date', '2026-05-01', 'outstanding_amount', '1000')),
    date '2026-08-01', true);
  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no', 'B-1', 'contact_code', 'S-1',
      'doc_date', '2026-05-01', 'outstanding_amount', '400')),
    date '2026-08-01', true);

  perform pg_temp.check_eq('the open invoice is counted',
    (select quantity from public.report_migration_progress(v_org)
      where step_no = 3), 1);
  perform pg_temp.check_eq('and the bill',
    (select quantity from public.report_migration_progress(v_org)
      where step_no = 4), 1);
  perform pg_temp.check_eq(
    'and the suspense account holds the receivables less the payables',
    pg_temp.suspense(v_org), 600);
  perform pg_temp.check_true(
    'reported as a credit, and pointing at the trial balance, which is '
    'what is missing',
    pg_temp.verdict(v_org) like '%credit balance%'
      and pg_temp.verdict(v_org) like '%trial balance is still to come%');

  -- ------------------------------------------------------------------
  -- Finished
  -- ------------------------------------------------------------------
  perform public.import_opening_balances(v_org, jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'debit', '2000'),
    jsonb_build_object('account_code', '1310', 'debit', '500'),
    jsonb_build_object('account_code', '1210', 'debit', '1000'),
    jsonb_build_object('account_code', '2110', 'credit', '400'),
    jsonb_build_object('account_code', '3100', 'credit', '3100')),
    date '2026-08-01', true);
  perform public.import_opening_stock(v_org, jsonb_build_array(
    jsonb_build_object('item_code', 'W', 'quantity', '50',
                       'unit_cost', '10')), date '2026-08-01', true);

  perform pg_temp.check_eq('the trial balance is counted once',
    (select quantity from public.report_migration_progress(v_org)
      where step_no = 5), 1);
  perform pg_temp.check_eq('and the stock line',
    (select quantity from public.report_migration_progress(v_org)
      where step_no = 6), 1);
  perform pg_temp.check_eq('and the whole thing comes to nothing',
    pg_temp.suspense(v_org), 0);
  perform pg_temp.check_true('which is what finished looks like',
    pg_temp.verdict(v_org) like '%everything from the old books is here%');
end $$;

-- ---------------------------------------------------------------------
-- The other direction
--
-- A trial balance that expects more receivables than were brought across
-- leaves a debit, and the sentence has to send somebody at the open
-- items rather than at the trial balance. Asserted separately because it
-- is the case where the wrong advice wastes the most time.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid;
begin
  v_org := pg_temp.prog_org('Short Progress Sdn Bhd');

  -- One invoice brought across, the trial balance expecting two.
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no', 'I-1', 'contact_code', 'C-1',
      'doc_date', '2026-05-01', 'outstanding_amount', '1000')),
    date '2026-08-01', true);
  perform public.import_opening_balances(v_org, jsonb_build_array(
    jsonb_build_object('account_code', '1210', 'debit', '2500'),
    jsonb_build_object('account_code', '3100', 'credit', '2500')),
    date '2026-08-01', true);

  perform pg_temp.check_eq('the difference is what was not brought across',
    pg_temp.suspense(v_org), -1500);
  perform pg_temp.check_true(
    'and the advice points at the open invoices, not at the trial balance',
    pg_temp.verdict(v_org) like '%debit balance%'
      and pg_temp.verdict(v_org) like '%open invoices and bills%');
end $$;

-- ---------------------------------------------------------------------
-- Who may read it
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_sales uuid := pg_temp.another_user('sales@progress.test');
  v_refused boolean; v_role text;
begin
  v_org := pg_temp.prog_org('Guarded Progress Sdn Bhd');

  -- Salespeople do not see the ledger, and this is a ledger figure.
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_sales, 'sales');
  perform pg_temp.sign_in_as(v_sales);

  v_refused := false;
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.report_migration_progress(v_org);
  exception when others then v_refused := true;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_sales);

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'somebody who cannot read the ledger cannot read this either — it is '
    'a balance sheet figure with a sentence attached', v_refused);
end $$;

rollback;
