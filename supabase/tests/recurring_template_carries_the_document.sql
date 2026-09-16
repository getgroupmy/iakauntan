-- =====================================================================
-- iAkauntan :: what a schedule remembers about the document it was made
--              from
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_template_carries_the_document.sql
--
-- `app.snapshot_document` freezes a document into the template
-- `app.raise_recurring_document` replays every month. Its lines half
-- subtracts what belongs to the document; its header half lists what to
-- keep, and its own comment -- on the other half -- says why that is
-- the dangerous direction:
--
--     Listing what to keep instead would quietly drop any column added
--     after today.
--
-- It had. `service_charge_amount` (`0410`), `branch_id` (`0131`) and
-- `matter_id` (`0021`) were not in the header, so a property manager's
-- monthly bill of RM381 was raised as RM336 and landed outside its
-- branch. Every month, on every parcel, silently. `0416` carries them.
--
-- Two halves here, and the second is the one that matters in a year.
--
--   1. The money survives the round trip: a schedule made from a
--      document bills the same as the document.
--   2. **Every column of both document tables is decided about.** Each
--      is either in the snapshot or in the list below of columns not
--      replayed, with the reason. A column added to either table and
--      not thought about turns this red. That is the assertion; the
--      first half is the worked example that shows what it is for.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_cust   uuid;
  v_supp   uuid;
  v_item   uuid;
  v_st8    uuid;
  v_branch uuid;
  v_matter uuid;
  v_client uuid;
  v_doc    uuid;
  v_bill   uuid;
  v_rec    uuid;
  v_new    uuid;
  a        record;
  b        record;
  v_header jsonb;
  v_missing text;
begin
  v_org := pg_temp.test_org('Pengurusan Hartanah Empat Belas Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_st8;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'A-12-3', 'Parcel A-12-3', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S1', 'Syarikat Kebersihan', 'supplier') returning id into v_supp;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, sales_tax_code_id)
  values (v_org, 'MAINT', 'Monthly maintenance', 'service', false, 'C62',
          300.00, v_st8)
  returning id into v_item;

  insert into public.branches (org_id, code, name)
  values (v_org, 'KL', 'Kuala Lumpur') returning id into v_branch;

  -- ------------------------------------------------------------------
  -- 1. The bill a strata manager sets up once
  -- ------------------------------------------------------------------
  -- Maintenance, a delivery charge, and the monthly service charge that
  -- is the whole reason a management corporation sends a bill at all.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, shipping_amount, service_charge_amount,
     branch_id)
  values (v_org, 'invoice', 'INV-TEMPLATE', current_date, current_date,
          v_cust, 'MYR', 1, 'draft', 12.00, 45.00, v_branch)
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'item', v_item, 'Monthly maintenance', 1, 'C62',
          300.00, v_st8, 8);

  select * into a from public.sales_documents where id = v_doc;
  perform pg_temp.check_eq('the bill it is made from comes to 381',
    a.total_amount, 381.00);

  v_rec := public.create_recurring_document(
    v_doc, 'Monthly maintenance', 'monthly', current_date);
  perform app.raise_recurring_document(v_rec, current_date);

  select * into b from public.sales_documents
   where org_id = v_org and id <> v_doc
   order by created_at desc limit 1;

  -- The assertion is against the template's own total rather than
  -- against 381.00, so a change to the tax rate or the charge keeps it
  -- honest: whatever the one bills, the other bills.
  perform pg_temp.check_eq(
    'and the invoice the schedule raises bills the same as it',
    b.total_amount, a.total_amount);
  perform pg_temp.check_eq('the service charge came across',
    b.service_charge_amount, 45.00);
  perform pg_temp.check_eq('so did the delivery',
    b.shipping_amount, 12.00);
  perform pg_temp.check_true('and so did the branch',
    b.branch_id = v_branch);
  perform pg_temp.check_true('it is a draft, not something already posted',
    b.status = 'draft');
  perform pg_temp.check_true('with a number of its own',
    b.doc_no is distinct from a.doc_no);

  -- ------------------------------------------------------------------
  -- 2. A retainer against a matter
  -- ------------------------------------------------------------------
  -- A firm bills the same fee every month against one matter. Losing
  -- the matter does not change the money, so the first half would not
  -- have caught it: it puts the fee outside the ledger the client is
  -- billed from.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CL1', 'Encik Klien', 'customer') returning id into v_client;
  insert into public.matters
    (org_id, matter_no, name, client_id, status, fee_earner)
  values (v_org, 'M-1', 'Tenancy renewal', v_client, 'open',
          pg_temp.test_user())
  returning id into v_matter;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, matter_id)
  values (v_org, 'invoice', 'INV-RETAINER', current_date, current_date,
          v_client, 'MYR', 1, 'draft', v_matter)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_doc, 1, 'item', v_item, 'Monthly retainer', 1, 'C62',
          300.00, v_st8, 8);

  v_rec := public.create_recurring_document(
    v_doc, 'Monthly retainer', 'monthly', current_date);
  perform app.raise_recurring_document(v_rec, current_date);

  select * into b from public.sales_documents
   where org_id = v_org and doc_no not in ('INV-TEMPLATE', 'INV-RETAINER')
     and matter_id is not null
   order by created_at desc limit 1;
  perform pg_temp.check_true('the retainer is raised against its matter',
    b.matter_id = v_matter);

  -- ------------------------------------------------------------------
  -- 3. The buying side
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, shipping_amount, branch_id)
  values (v_org, 'bill', 'BILL-TEMPLATE', current_date, current_date,
          v_supp, 'MYR', 1, 'draft', 30.00, v_branch)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_bill, 1, 'item', v_item, 'Cleaning', 1, 'C62',
          500.00, v_st8, 8);

  select * into a from public.purchase_documents where id = v_bill;
  v_rec := public.create_recurring_document(
    v_bill, 'Monthly cleaning', 'monthly', current_date);
  perform app.raise_recurring_document(v_rec, current_date);

  select * into b from public.purchase_documents
   where org_id = v_org and id <> v_bill
   order by created_at desc limit 1;
  perform pg_temp.check_eq('the standing order for cleaning bills the same',
    b.total_amount, a.total_amount);
  perform pg_temp.check_true('and it is on the branch that buys it',
    b.branch_id = v_branch);
end $$;

-- ====================================================================
-- Every column is decided about
-- ====================================================================
-- The half above names three columns. This one asks the question of
-- every column both tables have, so the fourth is covered by an
-- assertion nobody had to remember to write.
--
-- The lists are what is deliberately NOT replayed. They are grouped
-- rather than alphabetical because the grouping is the argument: a
-- schedule raises a *new* document, so it must not carry the old one's
-- identity, its numbering, its dates, the totals the triggers compute,
-- where it is in its life, or who touched it.
do $$
declare
  v_org    uuid;
  v_cust   uuid;
  v_item   uuid;
  v_doc    uuid;
  v_bill   uuid;
  v_header jsonb;
  v_undecided text;
  v_gone   text;

  -- Not replayed, and why.
  c_sales text[] := array[
    -- Identity of the row, and of the document it is.
    'id', 'org_id', 'doc_type',
    -- The new document gets its own number and its own dates.
    'doc_no', 'doc_date', 'due_date', 'valid_until', 'delivery_date',
    -- Where this one sits in a chain of documents. A raise starts a new
    -- chain; carrying the old one's parent would attach an invoice
    -- raised in March to a quotation accepted in January.
    'parent_id', 'original_invoice_id', 'opportunity_id',
    -- The triggers compute these from the lines. Copying them across
    -- would put a figure on the document that its own lines contradict.
    'exchange_rate', 'subtotal', 'tax_amount', 'rounding_amount',
    'total_amount', 'base_total_amount',
    -- What has happened to the old document since. None of it is true
    -- of a draft raised this morning.
    'paid_amount', 'balance_amount', 'applied_amount', 'status',
    'fulfilment_status', 'gl_entry_id', 'posted_at', 'posted_by',
    'einvoice_id', 'einvoice_status', 'is_consolidated',
    -- 0418's two columns were exempted here, on the reasoning that they
    -- are "derived at the till from the outlet's rate" and that
    -- "whatever raises the invoice works them out again". `0441`
    -- measured the second half and it is not true: nothing outside the
    -- POS path computes them. `app.recalc_sales_totals` adds the charge
    -- to the total and does not touch the tax on it, and only
    -- `app.recalc_pos_sale`, `public.set_pos_service_charge` and
    -- `public.complete_pos_sale` ever write it. A recurring raise is
    -- not a till.
    --
    -- So they came off this list and are carried. Measured before:
    -- template `svc=100.00 svc_tax=8.00 code_set=t`, raised
    -- `svc=100.00 svc_tax=0.00 code_set=f` -- and because
    -- `report_sst_summary` reaches the charge through an INNER JOIN on
    -- `service_charge_tax_code_id`, the whole RM100 left the return,
    -- not just the RM8.
    --
    -- The worry the exemption recorded is real and is not dismissed: a
    -- schedule replaying a tax figure asserts a tax nobody worked out
    -- this month. For a FIXED retainer -- which is what a snapshot is --
    -- the figure is the same every month and replaying it is exactly
    -- right. For a service charge that is a percentage of a bill that
    -- varies, neither carrying nor dropping is right and the answer is
    -- recomputation, which nothing outside POS can do. That is named in
    -- `0441` as a limit rather than guessed at.
    -- Ours, not the customer's, and not part of what is billed.
    'internal_notes', 'attachments',
    -- Where the row came from. `0610`. A recurring raise is this
    -- product writing a new document this morning; it did not come out
    -- of anybody's old system. Carrying the provenance would claim a
    -- twelve-month schedule's every invoice was imported from
    -- AutoCount -- and, because the triple is unique per company,
    -- the second month's raise would collide on the first month's.
    'import_source', 'import_ref', 'import_batch_id', 'imported_at',
    -- Audit. The raise writes its own.
    'created_by', 'created_at', 'updated_at', 'deleted_at'
  ];

  c_purchase text[] := array[
    'id', 'org_id', 'doc_type',
    'doc_no', 'doc_date', 'due_date', 'expected_date',
    -- The supplier's own reference for *that* bill. A standing order
    -- raising this month's bill under last month's supplier document
    -- number is how a duplicate gets paid.
    'supplier_doc_no', 'supplier_doc_date',
    'parent_id', 'original_bill_id', 'source_sales_document_id',
    'exchange_rate', 'subtotal', 'tax_amount', 'rounding_amount',
    'total_amount', 'base_total_amount',
    'paid_amount', 'balance_amount', 'status', 'fulfilment_status',
    'gl_entry_id', 'posted_at', 'posted_by',
    -- Approval is of a bill, not of a schedule.
    'approved_by', 'approved_at',
    'einvoice_id', 'einvoice_status',
    'internal_notes', 'attachments',
    -- Where the row came from. `0610`. A recurring raise is this
    -- product writing a new document this morning; it did not come out
    -- of anybody's old system. Carrying the provenance would claim a
    -- twelve-month schedule's every invoice was imported from
    -- AutoCount -- and, because the triple is unique per company,
    -- the second month's raise would collide on the first month's.
    'import_source', 'import_ref', 'import_batch_id', 'imported_at',
    'created_by', 'created_at', 'updated_at', 'deleted_at'
  ];
begin
  v_org := pg_temp.test_org('Setiap Lajur Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C1', 'Sesiapa', 'customer') returning id into v_cust;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'X', 'Anything', 'service', false, 'C62', 10.00)
  returning id into v_item;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-COLS', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Anything', 1, 'C62', 10.00);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-COLS', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_bill, 1, 'item', v_item, 'Anything', 1, 'C62', 10.00);

  -- --- sales ---------------------------------------------------------
  v_header := app.snapshot_document(v_doc, 'sales') -> 'header';
  perform pg_temp.check_true('the sales snapshot has a header at all',
    v_header is not null and jsonb_typeof(v_header) = 'object');

  select string_agg(c.column_name, ', ' order by c.column_name)
    into v_undecided
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'sales_documents'
     and not v_header ? c.column_name
     and not (c.column_name = any (c_sales));
  if v_undecided is not null then
    raise exception
      'sales_documents has a column the recurring template neither '
      'carries nor declines: %. Add it to app.snapshot_document and to '
      'app.raise_recurring_document, or add it to c_sales in this file '
      'with the reason it is not replayed.', v_undecided;
  end if;

  -- And the other direction, so the list cannot rot into a list of
  -- columns that no longer exist while claiming to have decided about
  -- them.
  select string_agg(x, ', ' order by x) into v_gone
    from unnest(c_sales) x
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public'
                        and c.table_name = 'sales_documents'
                        and c.column_name = x);
  if v_gone is not null then
    raise exception 'c_sales names columns sales_documents no longer has: %',
      v_gone;
  end if;

  -- --- purchases -----------------------------------------------------
  v_header := app.snapshot_document(v_bill, 'purchase') -> 'header';
  perform pg_temp.check_true('the purchase snapshot has a header at all',
    v_header is not null and jsonb_typeof(v_header) = 'object');

  select string_agg(c.column_name, ', ' order by c.column_name)
    into v_undecided
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'purchase_documents'
     and not v_header ? c.column_name
     and not (c.column_name = any (c_purchase));
  if v_undecided is not null then
    raise exception
      'purchase_documents has a column the recurring template neither '
      'carries nor declines: %. Add it to app.snapshot_document and to '
      'app.raise_recurring_document, or add it to c_purchase in this '
      'file with the reason it is not replayed.', v_undecided;
  end if;

  select string_agg(x, ', ' order by x) into v_gone
    from unnest(c_purchase) x
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public'
                        and c.table_name = 'purchase_documents'
                        and c.column_name = x);
  if v_gone is not null then
    raise exception
      'c_purchase names columns purchase_documents no longer has: %', v_gone;
  end if;

  -- The three `0416` put back, named so that removing one from the
  -- snapshot fails here as itself and not only as a total that is out.
  perform pg_temp.check_true(
    'and the three 0416 put back are carried, by name',
    (app.snapshot_document(v_doc, 'sales') -> 'header')
      ?& array['service_charge_amount', 'branch_id', 'matter_id']);
  perform pg_temp.check_true('branch_id on the buying side too',
    (app.snapshot_document(v_bill, 'purchase') -> 'header') ? 'branch_id');

  -- `0441`'s two, likewise by name, so removing one fails as itself.
  perform pg_temp.check_true(
    'and 0441''s two, so the service charge reaches the SST return',
    (app.snapshot_document(v_doc, 'sales') -> 'header')
      ?& array['service_charge_tax', 'service_charge_tax_code_id']);
end $$;

-- =====================================================================
-- The tax on a retainer's service charge, all the way to the return
-- =====================================================================
-- `0441`. The snapshot froze the charge and not the tax on it, and the
-- raise named the columns it inserts, so both halves had to change --
-- measured: after the snapshot alone the raised document still came out
-- `svc_tax=0.00 code_set=f`.
do $$
declare
  v_org uuid := pg_temp.test_org('Pejabat Servis Bulanan Sdn Bhd');
  v_own uuid := pg_temp.test_user();
  v_cust uuid; v_st8 uuid; v_inv uuid; v_rec uuid; v_new uuid;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_charged numeric;
begin
  perform public.create_fiscal_year(v_org, date_trunc('year', v_today)::date);

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8,
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_st8;
  perform public.set_sst_registration(
    v_org, true, date_trunc('year', v_today)::date, 'W10-1808-31000441', 'ST8');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Penyewa Sdn Bhd', 'customer') returning id into v_cust;

  -- A retainer of RM1,000 with a RM100 service charge taxed at RM8.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status, service_charge_amount, service_charge_tax,
     service_charge_tax_code_id)
  values (v_org, 'invoice', 'INV-RET', v_today, v_today + 30, v_cust,
          'MYR', 1, 'draft', 100, 8, v_st8)
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity,
     uom_code, unit_price, tax_code_id, tax_rate)
  values (v_org, v_inv, 1, 'item', 'Monthly retainer', 1, 'C62',
          1000, v_st8, 8);
  perform app.post_sales_document_internal(v_inv);

  v_rec := public.create_recurring_document(
    v_inv, 'Monthly retainer', 'monthly', v_today);
  v_new := app.raise_recurring_document(v_rec, v_today);

  perform pg_temp.check_eq('the raise carries the charge',
    (select service_charge_amount from public.sales_documents where id = v_new),
    100);
  perform pg_temp.check_eq('and the tax on it',
    (select service_charge_tax from public.sales_documents where id = v_new), 8);
  perform pg_temp.check_true('and the code it is taxed under',
    (select service_charge_tax_code_id is not null
       from public.sales_documents where id = v_new));

  -- The consequence, not only the column. `report_sst_summary` reaches
  -- the charge through an inner join on the code, so a raise without it
  -- takes the whole RM100 out of the return -- the taxable value as
  -- well as the tax.
  --
  -- Posted first: a raise produces a draft unless the schedule posts
  -- automatically, and a draft is rightly not on a return. Measured
  -- rather than assumed -- the first draft of this assertion checked
  -- the return before posting and read nothing at all.
  perform app.post_sales_document_internal(v_new);

  select coalesce(sum(taxable_amount), 0) into v_charged
    from public.report_sst_summary(v_org, v_today - 1, v_today + 1)
   where direction = 'output';

  -- RM1,000 of retainer and RM100 of service charge, twice: the
  -- template and the invoice raised from it.
  perform pg_temp.check_eq(
    'and the raised invoice''s service charge reaches the SST return',
    v_charged, 2200);
end $$;

rollback;
