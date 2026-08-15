-- =====================================================================
-- iAkauntan :: bringing open invoices and bills across
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/open_item_import.sql
--
-- Three things carry this file, and they are the three that a migration
-- gets wrong quietly rather than loudly:
--
--   * **the two dates are different**. The document is dated when it was
--     raised, so the ageing is right; the ledger entry is dated at the
--     changeover, so the trial balance moves once. A version that used
--     one date for both would look correct in every screenshot and
--     would either flatten the ageing or scatter the opening entries
--     across last year.
--   * **nothing is written when anything is wrong**. Asserted with the
--     control that matters — that the *good* file then imports — because
--     "was it refused?" passes for a function that refuses everything.
--   * **no tax**. The SST on these was declared under the old system.
--     A tax line here would put it in this system's return as well, and
--     nothing about the screen would say so.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.open_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v;
  perform app.seed_chart_of_accounts(v);
  perform pg_temp.sign_in_as(p_owner);
  perform public.create_fiscal_year(v, date '2026-01-01');
  return v;
end; $$;

-- ---------------------------------------------------------------------
-- A file that is wrong, and a file that is right
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@openitems.test');
  v_org uuid;
  v_rows jsonb; v_bad jsonb;
  v_refused boolean; v_msg text; v_n int;
  v_doc_date date; v_due date; v_entry_date date; v_source text;
  v_ar numeric; v_ap numeric; v_eq numeric; v_tax numeric;
begin
  v_org := pg_temp.open_org('Open Items Sdn Bhd', v_boss);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Pelanggan Lama', 'customer'),
         (v_org, 'S-001', 'Pembekal Lama', 'supplier');

  v_bad := jsonb_build_array(
    jsonb_build_object('doc_no','INV-2025-0912','contact_code','C-001',
      'doc_date','2025-11-03','due_date','2025-12-03',
      'outstanding_amount','3,000.00'),
    -- A customer nobody imported.
    jsonb_build_object('doc_no','INV-2025-0913','contact_code','C-999',
      'doc_date','2025-11-04','outstanding_amount','100'),
    -- A credit balance, which is a credit note and not this.
    jsonb_build_object('doc_no','INV-2025-0914','contact_code','C-001',
      'doc_date','2025-11-05','outstanding_amount','-50'),
    -- The same number twice.
    jsonb_build_object('doc_no','INV-2025-0912','contact_code','C-001',
      'doc_date','2025-11-06','outstanding_amount','10'),
    -- Dated after the changeover, so not an opening item at all.
    jsonb_build_object('doc_no','INV-2026-0001','contact_code','C-001',
      'doc_date','2026-08-15','outstanding_amount','10'));

  -- The preview names each one rather than counting them.
  perform pg_temp.check_eq('the preview passes the row that is good',
    (select count(*) from public.import_open_invoices(v_org, v_bad,
                                                      date '2026-08-01', false)
      where status = 'ok'), 1);
  perform pg_temp.check_eq('and fails the four that are not',
    (select count(*) from public.import_open_invoices(v_org, v_bad,
                                                      date '2026-08-01', false)
      where status = 'error'), 4);
  perform pg_temp.check_true('naming the contact that does not exist',
    (select message like '%C-999 is not a contact%'
       from public.import_open_invoices(v_org, v_bad, date '2026-08-01', false)
      where row_no = 2));
  perform pg_temp.check_true('and saying a credit balance is a credit note',
    (select message like '%credit note%'
       from public.import_open_invoices(v_org, v_bad, date '2026-08-01', false)
      where row_no = 3));
  perform pg_temp.check_true('and that a later document is not an opening one',
    (select message like '%after the changeover%'
       from public.import_open_invoices(v_org, v_bad, date '2026-08-01', false)
      where row_no = 5));

  v_refused := false;
  begin perform public.import_open_invoices(v_org, v_bad, date '2026-08-01', true);
  exception when others then v_refused := true; v_msg := sqlerrm; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('committing a file with a bad row is refused',
    v_refused);
  perform pg_temp.check_true('and says how many rows are wrong, not just that '
    'something is', v_msg like '%4 of 5 rows%');
  perform pg_temp.check_eq(
    'and the row that was good is not written either — all of it or none',
    (select count(*) from public.sales_documents where org_id = v_org), 0);

  -- ------------------------------------------------------------------
  -- The control. Everything above asserts a refusal, and a function that
  -- refused every file would pass all of it.
  -- ------------------------------------------------------------------
  v_rows := jsonb_build_array(
    jsonb_build_object('doc_no','INV-2025-0912','contact_code','C-001',
      'doc_date','2025-11-03','due_date','2025-12-03',
      'outstanding_amount','3,000.00','reference','PO 88'),
    jsonb_build_object('doc_no','INV-2025-0950','contact_code','C-001',
      'doc_date','2026-06-30','outstanding_amount','1200.50'));
  perform public.import_open_invoices(v_org, v_rows, date '2026-08-01', true);
  perform pg_temp.check_eq('a file that is right imports',
    (select count(*) from public.sales_documents where org_id = v_org), 2);

  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','BILL-77','contact_code','S-001',
      'doc_date','2026-05-02','outstanding_amount','800',
      'supplier_doc_no','ST-2026-4411')), date '2026-08-01', true);

  -- ------------------------------------------------------------------
  -- The two dates
  -- ------------------------------------------------------------------
  select d.doc_date, d.due_date, e.entry_date, e.source::text
    into v_doc_date, v_due, v_entry_date, v_source
    from public.sales_documents d
    join public.gl_entries e on e.id = d.gl_entry_id
   where d.org_id = v_org and d.doc_no = 'INV-2025-0912';

  perform pg_temp.check_true('the document keeps the date it was raised',
    v_doc_date = date '2025-11-03');
  perform pg_temp.check_true('and the date it fell due, which is what the '
    'ageing measures', v_due = date '2025-12-03');
  perform pg_temp.check_true(
    'while the ledger entry is dated at the changeover',
    v_entry_date = date '2026-08-01');
  perform pg_temp.check_true(
    'and is an opening balance, so a report of the year''s sales by source '
    'does not find last year''s invoices in it',
    v_source = 'opening_balance');

  -- ------------------------------------------------------------------
  -- No tax
  -- ------------------------------------------------------------------
  select coalesce(sum(l.credit - l.debit), 0) into v_tax
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where l.org_id = v_org and a.code = '2130';
  perform pg_temp.check_eq(
    'nothing reached the SST output account — it was declared under the '
    'old system and declaring it twice is the failure this avoids',
    v_tax, 0);
  perform pg_temp.check_eq('and the documents carry no tax',
    (select sum(tax_amount) from public.sales_documents where org_id = v_org), 0);

  -- ------------------------------------------------------------------
  -- The arithmetic
  -- ------------------------------------------------------------------
  select round(sum(l.debit - l.credit), 2) into v_ar
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where l.org_id = v_org and a.code = '1210';
  select round(sum(l.credit - l.debit), 2) into v_ap
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where l.org_id = v_org and a.code = '2110';
  select round(sum(l.credit - l.debit), 2) into v_eq
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where l.org_id = v_org and a.code = '3900';

  perform pg_temp.check_eq('receivables', v_ar, 4200.50);
  perform pg_temp.check_eq('payables', v_ap, 800);
  perform pg_temp.check_eq(
    'and the suspense account holds the difference, which is what makes it '
    'the migration''s own check', v_eq, 3400.50);

  select count(*) into v_n from (
    select l.entry_id from public.gl_lines l
     where l.org_id = v_org group by l.entry_id
    having round(sum(l.debit) - sum(l.credit), 2) <> 0) x;
  perform pg_temp.check_eq('every entry balances', v_n, 0);

  -- ------------------------------------------------------------------
  -- The suspense report
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the suspense report says it is not settled',
    (select not settled from public.report_opening_balance_suspense(v_org)));
  perform pg_temp.check_eq('and by how much',
    (select balance from public.report_opening_balance_suspense(v_org)), 3400.50);

  -- ------------------------------------------------------------------
  -- Running it twice
  -- ------------------------------------------------------------------
  v_refused := false;
  begin perform public.import_open_invoices(v_org, v_rows, date '2026-08-01', true);
  exception when others then v_refused := true; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true(
    'the same file a second time is refused rather than duplicated',
    v_refused);
  perform pg_temp.check_eq('and nothing was added',
    (select count(*) from public.sales_documents where org_id = v_org), 2);
end $$;

-- ---------------------------------------------------------------------
-- Foreign currency, and who may run it
-- ---------------------------------------------------------------------
do $$
declare
  v_boss  uuid := pg_temp.another_user('boss2@openitems.test');
  v_clerk uuid := pg_temp.another_user('clerk@openitems.test');
  v_org uuid; v_refused boolean; v_role text; v_base numeric;
begin
  v_org := pg_temp.open_org('Open Items Dua Sdn Bhd', v_boss);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-USD', 'Overseas Buyer', 'customer');

  -- A currency that is not the company's, with no rate to put it in the
  -- ledger with.
  v_refused := false;
  begin
    perform public.import_open_invoices(v_org, jsonb_build_array(
      jsonb_build_object('doc_no','USD-1','contact_code','C-USD',
        'doc_date','2026-05-01','outstanding_amount','1000',
        'currency','USD')), date '2026-08-01', true);
  exception when others then v_refused := true; end;
  perform pg_temp.sign_in_as(v_boss);
  perform pg_temp.check_true('a foreign amount with no rate is refused',
    v_refused);

  -- With one, it reaches the ledger in ringgit.
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','USD-1','contact_code','C-USD',
      'doc_date','2026-05-01','outstanding_amount','1000',
      'currency','USD','exchange_rate','4.25')), date '2026-08-01', true);

  select round(sum(l.debit - l.credit), 2) into v_base
    from public.gl_lines l join public.accounts a on a.id = l.account_id
   where l.org_id = v_org and a.code = '1210';
  perform pg_temp.check_eq(
    'and 1,000 dollars at 4.25 is 4,250 in the receivables control',
    v_base, 4250);
  perform pg_temp.check_eq('while the document still says a thousand dollars',
    (select total_amount from public.sales_documents
      where org_id = v_org and doc_no = 'USD-1'), 1000);

  -- ------------------------------------------------------------------
  -- Somebody who prepares but does not post
  -- ------------------------------------------------------------------
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accounts_clerk');
  perform pg_temp.sign_in_as(v_clerk);

  v_refused := false;
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.import_open_invoices(v_org, jsonb_build_array(
      jsonb_build_object('doc_no','SNEAK-1','contact_code','C-USD',
        'doc_date','2026-05-01','outstanding_amount','1')),
      date '2026-08-01', true);
  exception when others then v_refused := true;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_clerk);

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true(
    'an accounts clerk cannot bring in opening balances — this posts to '
    'the ledger, and preparing is not posting', v_refused);
  perform pg_temp.check_eq('and wrote nothing',
    (select count(*) from public.sales_documents
      where org_id = v_org and doc_no = 'SNEAK-1'), 0);
end $$;

-- ---------------------------------------------------------------------
-- A company that has never migrated
-- ---------------------------------------------------------------------
do $$
declare
  v_boss uuid := pg_temp.another_user('boss3@openitems.test');
  v_org uuid;
begin
  v_org := pg_temp.open_org('Never Migrated Sdn Bhd', v_boss);

  -- The account is created on demand, so a company that never brings
  -- anything across does not carry a suspense account it will never use.
  perform pg_temp.check_eq('no opening balance account until one is needed',
    (select count(*) from public.accounts
      where org_id = v_org and code = '3900'), 0);
  perform pg_temp.check_true(
    'and the report says settled rather than failing on the missing account',
    (select settled from public.report_opening_balance_suspense(v_org)));
  perform pg_temp.check_eq('with no entries, so the two cases are '
    'distinguishable from the answer',
    (select entries from public.report_opening_balance_suspense(v_org)), 0);
end $$;

rollback;
