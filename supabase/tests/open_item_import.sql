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


-- ---------------------------------------------------------------------
-- The twenty a mutation sweep found
-- ---------------------------------------------------------------------
-- Thirty-four one-line mutants across `import_open_invoices` and the
-- validator it shares with `import_open_bills`, run against nineteen
-- test files. Twenty survived -- the largest count of anything swept in
-- this programme, and the reason is the same as for
-- import_opening_balances: a validator is all front door, and the front
-- door is the least asserted part of any function here.
--
-- Twelve of the twenty are in `app.validate_open_items`, which is one
-- long elsif chain, and eleven of its seventeen branches could be
-- deleted with the suite still green. They are asserted below one at a
-- time, and one at a time is not a style choice: the chain is checked
-- IN ORDER, so a row that breaks two rules reports the first, and a
-- fixture that is wrong in more than one way asserts the wrong branch.
--
-- The remaining eight are in the posting half, and three of those are
-- about what an opening invoice IS. It is not a sale of this year, so
-- its journal is filed under `opening_balance`; it was reported to LHDN
-- by whoever raised it, so its e-Invoice status is `not_applicable`;
-- and its other side is Opening Balance Equity rather than revenue,
-- because recognising last year's income again this year would inflate
-- the profit and loss by the whole receivable.
do $$
declare
  v_boss uuid := pg_temp.another_user('boss-sapu@openitems.test');
  v_org  uuid;
  v_doc  uuid;
  v_eq   uuid;
  v_ar2  uuid;
  v_ap2  uuid;
  v_msg  text;
begin
  v_org := pg_temp.open_org('Open Items Sapu Sdn Bhd', v_boss);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer'),
         (v_org, 'S-1', 'Pembekal', 'supplier');
  v_eq := app.opening_balance_account(v_org);

  -- ==================================================================
  -- 1. The validator, one branch at a time
  --
  -- Each row below is wrong in EXACTLY ONE way. A row wrong in two ways
  -- reports whichever branch comes first, and would assert that rule
  -- rather than this one.
  -- ==================================================================
  perform pg_temp.check_true('a row with no document number',
    (select message like 'No document number.%'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('contact_code','C-1','doc_date','2026-01-05',
                            'outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a row with no contact code',
    (select message = 'No contact code.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-1','doc_date','2026-01-05',
                            'outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a row with no date',
    (select message = 'No date. It is what the ageing is measured from.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-2','contact_code','C-1',
                            'outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a date that is not a date',
    (select message = '"soon" is not a date. Use YYYY-MM-DD.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-3','contact_code','C-1',
                            'doc_date','soon','outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a due date that is not a date',
    (select message = '"never" is not a date. Use YYYY-MM-DD.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-4','contact_code','C-1',
           'doc_date','2026-01-05','due_date','never',
           'outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('due before it was dated',
    (select message = 'Due 2026-01-01, before it was dated (2026-01-05).'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-5','contact_code','C-1',
           'doc_date','2026-01-05','due_date','2026-01-01',
           'outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a row with no outstanding amount',
    (select message like 'No outstanding amount.%'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-6','contact_code','C-1',
                            'doc_date','2026-01-05')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('an amount that is not an amount',
    (select message = '"plenty" is not an amount.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-7','contact_code','C-1',
           'doc_date','2026-01-05','outstanding_amount','plenty')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a currency this system does not know',
    (select message = '"XYZ" is not a currency this system knows.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-8','contact_code','C-1',
           'doc_date','2026-01-05','outstanding_amount','100',
           'currency','XYZ','exchange_rate','4')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a rate that is not a rate',
    (select message = '"about four" is not an exchange rate.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','A-9','contact_code','C-1',
           'doc_date','2026-01-05','outstanding_amount','100',
           'currency','USD','exchange_rate','about four')),
         date '2026-08-01', false) where row_no = 1));

  -- ==================================================================
  -- 2. A number the ledger already has
  --
  -- Both halves, because the validator asks a different question for an
  -- invoice than for a bill and only one of the two was ever reached.
  -- An opening file re-run after a partial import would otherwise raise
  -- a second invoice under a number the customer has already paid
  -- against.
  -- ==================================================================
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-DUP','contact_code','C-1',
      'doc_date','2026-01-05','outstanding_amount','100')),
    date '2026-08-01', true);
  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','BILL-DUP','contact_code','S-1',
      'doc_date','2026-01-05','outstanding_amount','100')),
    date '2026-08-01', true);

  perform pg_temp.check_true('an invoice number the ledger already has',
    (select message = 'There is already an invoice INV-DUP here.'
       from public.import_open_invoices(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','INV-DUP','contact_code','C-1',
           'doc_date','2026-01-05','outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));
  perform pg_temp.check_true('and a bill number it already has',
    (select message = 'There is already a bill BILL-DUP here.'
       from public.import_open_bills(v_org, jsonb_build_array(
         jsonb_build_object('doc_no','BILL-DUP','contact_code','S-1',
           'doc_date','2026-01-05','outstanding_amount','100')),
         date '2026-08-01', false) where row_no = 1));

  -- ==================================================================
  -- 3. What an opening invoice is, and is not
  --
  -- Three properties, none of them arithmetic, all of which decide
  -- whether the books read correctly a year later.
  -- ==================================================================
  select id into v_doc from public.sales_documents
   where org_id = v_org and doc_no = 'INV-DUP';

  perform pg_temp.check_eq('it arrives posted, not as a draft',
    (select status::text from public.sales_documents where id = v_doc),
    'posted');
  perform pg_temp.check_true('and posted means the journal is on it',
    (select gl_entry_id is not null and posted_at is not null
       from public.sales_documents where id = v_doc));

  -- Never sent to LHDN and never to be: it was reported, if at all, by
  -- whoever raised it. `pending` would put last year's invoices in this
  -- year's submission queue.
  perform pg_temp.check_eq('it is not going to LHDN',
    (select einvoice_status::text from public.sales_documents where id = v_doc),
    'not_applicable');

  -- Its other side is Opening Balance Equity. Revenue would recognise
  -- last year's income again this year, inflating the profit and loss
  -- by the whole receivable.
  perform pg_temp.check_eq(
    'the line behind it is against Opening Balance Equity',
    (select l.account_id from public.sales_document_lines l
      where l.document_id = v_doc), v_eq);

  -- And the receivable line names the customer, or the aged receivable
  -- has a balance belonging to nobody.
  perform pg_temp.check_true('the receivable line names the customer',
    (select gl.contact_id is not null from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
       join public.sales_documents d on d.gl_entry_id = gl.entry_id
      where d.id = v_doc and a.code = '1210'));

  -- ==================================================================
  -- 4. A foreign invoice, converted where it should be
  -- ==================================================================
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-USD','contact_code','C-1',
      'doc_date','2026-01-05','outstanding_amount','1000',
      'currency','USD','exchange_rate','4.7')),
    date '2026-08-01', true);
  select id into v_doc from public.sales_documents
   where org_id = v_org and doc_no = 'INV-USD';

  perform pg_temp.check_eq('the document keeps the foreign amount',
    (select total_amount from public.sales_documents where id = v_doc),
    1000::numeric);
  -- Written twice: once by the importer's own insert and again by
  -- `recalc_sales_totals`, which fires on the line and recomputes
  -- base_total_amount from total_amount and the rate. The importer's
  -- value is therefore dead -- a sweep mutant that dropped the
  -- conversion there changed nothing. The assertion stays because the
  -- trigger's arithmetic is the one that survives, and it is the one a
  -- reader of the document sees.
  perform pg_temp.check_eq('and carries the ringgit beside it',
    (select base_total_amount from public.sales_documents where id = v_doc),
    4700::numeric);

  -- ==================================================================
  -- 5. The due date falls back to the document's own
  --
  -- A file with no due date column is the ordinary case, and a null due
  -- date parks the debt in "not yet due" for ever: report_ar_aging
  -- buckets on coalesce(due_date, doc_date), so it would age from
  -- today rather than from January.
  -- ==================================================================
  perform pg_temp.check_true('with no due date, it is due the day it was raised',
    (select due_date = date '2026-01-05'
       from public.sales_documents where id = v_doc));

  -- ==================================================================
  -- 6. And a committed row says it was imported
  -- ==================================================================
  perform pg_temp.check_true('a committed row reports itself imported',
    exists (select 1 from public.import_open_invoices(v_org,
      jsonb_build_array(jsonb_build_object('doc_no','INV-LAST',
        'contact_code','C-1','doc_date','2026-01-05',
        'outstanding_amount','50')),
      date '2026-08-01', true) where status = 'imported'));

  -- ==================================================================
  -- 7. A customer with its own receivable control account
  --
  -- THE FALLBACK IS NOT THE RULE. Both importers read the contact's own
  -- control account and fall back to 1210 / 2110, and every other row
  -- in this file uses a contact that has none -- so deleting the read
  -- and keeping only the fallback passed the whole suite. A group that
  -- keeps intercompany debt in its own account would have had last
  -- year's balances land in the ordinary one, and the two would then
  -- disagree with the aged listing for ever after.
  --
  -- Asserted on both sides, because the receivable half and the payable
  -- half are separate lines of code.
  -- ==================================================================
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '1215', 'Receivable — related parties',
          'asset', 'accounts_receivable') returning id into v_ar2;
  insert into public.accounts (org_id, code, name, account_type, account_subtype)
  values (v_org, '2115', 'Payable — related parties',
          'liability', 'accounts_payable') returning id into v_ap2;

  insert into public.contacts
    (org_id, code, name, contact_type, receivable_account_id)
  values (v_org, 'C-REL', 'Anak Syarikat', 'customer', v_ar2);
  insert into public.contacts
    (org_id, code, name, contact_type, payable_account_id)
  values (v_org, 'S-REL', 'Induk', 'supplier', v_ap2);

  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-REL','contact_code','C-REL',
      'doc_date','2026-01-05','outstanding_amount','300')),
    date '2026-08-01', true);
  perform pg_temp.check_eq(
    'the opening invoice lands in the account the customer names',
    (select sum(gl.debit) from public.gl_lines gl
       join public.sales_documents d on d.gl_entry_id = gl.entry_id
      where d.org_id = v_org and d.doc_no = 'INV-REL'
        and gl.account_id = v_ar2), 300::numeric);
  perform pg_temp.check_eq('and nothing of it in the ordinary one',
    (select coalesce(sum(gl.debit), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
       join public.sales_documents d on d.gl_entry_id = gl.entry_id
      where d.org_id = v_org and d.doc_no = 'INV-REL' and a.code = '1210'),
    0::numeric);

  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','BILL-REL','contact_code','S-REL',
      'doc_date','2026-01-05','outstanding_amount','400')),
    date '2026-08-01', true);
  perform pg_temp.check_eq(
    'and the opening bill in the account the supplier names',
    (select sum(gl.credit) from public.gl_lines gl
       join public.purchase_documents d on d.gl_entry_id = gl.entry_id
      where d.org_id = v_org and d.doc_no = 'BILL-REL'
        and gl.account_id = v_ap2), 400::numeric);
  perform pg_temp.check_eq('with nothing of it in the ordinary one',
    (select coalesce(sum(gl.credit), 0) from public.gl_lines gl
       join public.accounts a on a.id = gl.account_id
       join public.purchase_documents d on d.gl_entry_id = gl.entry_id
      where d.org_id = v_org and d.doc_no = 'BILL-REL' and a.code = '2110'),
    0::numeric);

  raise notice 'ok   open items: the twenty-one a sweep found';
end $$;

rollback;
