-- =====================================================================
-- iAkauntan :: a posted document is frozen
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/posted_document_is_frozen.sql
--
-- `0402`. Measured before it, as an `accountant` on a posted RM1,000
-- invoice: the line rewritten to RM1.00 (and the header recomputed to
-- match), the header rewritten directly, the lines deleted, the
-- document deleted, and `gl_entry_id` set back to null so
-- `post_sales_document` would post the same invoice a second time —
-- two journals and RM2,000 for one RM1,000 sale.
--
-- ---------------------------------------------------------------------
-- Everything that matters runs under `set local role authenticated`
--
-- `pg_temp.sign_in_as` sets `request.jwt.claims` and does not change the
-- session role, so a test that only signs in runs as the table owner,
-- which is exempt from RLS and needs no grants. The refusals here are
-- triggers and would fire for the owner too, but the *positive*
-- controls are about what an ordinary caller may still do, and those
-- are only worth anything under the real role. So the role is changed
-- and then asserted.
--
-- The two halves are equally load-bearing. A freeze that also stopped
-- `apply_allocation` writing `paid_amount`, or the MyInvois submission
-- writing `einvoice_status`, or `refresh_sales_progress` writing the
-- line counters, would break the application on the day it applied.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_doc (
  org uuid, acct uuid,
  inv uuid, inv_line uuid, free_line uuid, entry uuid,
  draft uuid, draft_line uuid,
  bill uuid, bill_line uuid, bill_entry uuid);
grant select on t_doc to authenticated;

do $$
declare
  v_org uuid; v_owner uuid := pg_temp.test_user(); v_acct uuid;
  v_cust uuid; v_supp uuid;
  v_inv uuid; v_inv_line uuid; v_free_line uuid; v_entry uuid;
  v_draft uuid; v_draft_line uuid;
  v_bill uuid; v_bill_line uuid; v_bill_entry uuid;
begin
  v_org := pg_temp.test_org('Invois Beku Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pembeli Bhd', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal Bhd', 'supplier') returning id into v_supp;

  -- The posted invoice.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status)
  values (v_org, 'invoice', 'INV-POSTED', current_date, v_cust, 'MYR', 1,
          'draft') returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_inv, 1, 'Widget', 10, 100) returning id into v_inv_line;
  -- A second line worth nothing, and it is worth nothing on purpose.
  -- Every write to a line runs `recalc_totals`, which rewrites the
  -- header -- so a line change that moves money is refused by the
  -- header rule whether the line rule exists or not, and an assertion
  -- built on one would be measuring the wrong trigger. This line is how
  -- the line rule gets asked a question only it can answer.
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_inv, 2, 'Goodwill', 1, 0) returning id into v_free_line;
  v_entry := public.post_sales_document(v_inv);

  -- And one still being written, which is the whole of the other half:
  -- an unposted document is nobody's business but the company's.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status)
  values (v_org, 'invoice', 'INV-DRAFT', current_date, v_cust, 'MYR', 1,
          'draft') returning id into v_draft;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_draft, 1, 'Widget', 10, 100) returning id into v_draft_line;

  -- The purchase side carries the same trigger and the same argument.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     status)
  values (v_org, 'bill', 'BILL-POSTED', current_date, v_supp, 'MYR', 1,
          'draft') returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (v_org, v_bill, 1, 'Bahan', 5, 40) returning id into v_bill_line;
  v_bill_entry := public.post_purchase_document(v_bill);

  v_acct := pg_temp.another_user('beku@example.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v_org, v_acct, 'accountant', 'active');

  insert into t_doc values (v_org, v_acct, v_inv, v_inv_line, v_free_line, v_entry,
    v_draft, v_draft_line, v_bill, v_bill_line, v_bill_entry);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', (select acct from t_doc),
                    'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare c record; v_msg text; v_second uuid;
begin
  select * into c from t_doc;

  perform pg_temp.check_eq('the session really is a client role',
    current_user, 'authenticated');
  perform pg_temp.check_true('and this member really may post',
    app.can_post(c.org));
  perform pg_temp.check_eq('the invoice really is posted',
    (select gl_entry_id from public.sales_documents where id = c.inv), c.entry);
  perform pg_temp.check_eq('and its journal really is RM1,000',
    (select sum(debit) from public.gl_lines where entry_id = c.entry), 1000);

  -- ------------------------------------------------------------------
  -- The second posting
  -- ------------------------------------------------------------------
  -- First, because it is the one that costs money rather than merely
  -- confusing the books.
  begin
    update public.sales_documents set gl_entry_id = null, status = 'draft'
     where id = c.inv;
    raise exception
      'FAIL: a posted invoice was unposted by writing to its own column';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'and the refusal says what would happen next',
      v_msg like '%posted a second time%');
    raise notice 'ok   the link to the journal cannot be cleared by hand';
  end;
  perform pg_temp.check_eq('so the invoice is still posted',
    (select gl_entry_id from public.sales_documents where id = c.inv), c.entry);

  -- And the front door still refuses, which is what the cleared column
  -- was walking around.
  begin
    perform public.post_sales_document(c.inv);
    raise exception 'FAIL: a posted invoice was posted again';
  exception when others then
    raise notice 'ok   and posting it again is still refused';
  end;
  perform pg_temp.check_eq('one invoice, one journal',
    (select count(*) from public.gl_entries e
      where e.org_id = c.org and e.source = 'sales_invoice'), 1);

  -- ------------------------------------------------------------------
  -- The figures the journal was built from
  -- ------------------------------------------------------------------
  begin
    update public.sales_documents set total_amount = 5 where id = c.inv;
    raise exception 'FAIL: a posted invoice''s total was rewritten';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal names the column and both values',
      v_msg like '%total_amount%' and v_msg like '%1000.00 -> 5%');
    raise notice 'ok   a posted total cannot be rewritten';
  end;

  begin
    update public.sales_documents set doc_no = 'INV-CHANGED' where id = c.inv;
    raise exception 'FAIL: a posted invoice was renumbered';
  exception when sqlstate '42501' then
    raise notice 'ok   nor its number';
  end;

  begin
    update public.sales_documents set exchange_rate = 4.7 where id = c.inv;
    raise exception 'FAIL: a posted invoice''s exchange rate was rewritten';
  exception when sqlstate '42501' then
    raise notice 'ok   nor the rate the base amount was computed at';
  end;

  perform pg_temp.check_eq('and the invoice still says what it said',
    (select total_amount || ' ' || doc_no from public.sales_documents
      where id = c.inv), '1000.00 INV-POSTED');

  -- ------------------------------------------------------------------
  -- The lines underneath it
  -- ------------------------------------------------------------------
  begin
    update public.sales_document_lines set unit_price = 1
     where id = c.inv_line;
    raise exception 'FAIL: a line of a posted invoice was repriced';
  exception when sqlstate '42501' then
    raise notice 'ok   a posted invoice''s line cannot be repriced';
  end;

  begin
    delete from public.sales_document_lines where id = c.inv_line;
    raise exception 'FAIL: a line was deleted from a posted invoice';
  exception when sqlstate '42501' then
    raise notice 'ok   nor taken off it';
  end;

  begin
    insert into public.sales_document_lines
      (org_id, document_id, line_no, description, quantity, unit_price)
    values (c.org, c.inv, 99, 'Appended afterwards', 1, 1000000);
    raise exception 'FAIL: a line was appended to a posted invoice';
  exception when sqlstate '42501' then
    raise notice 'ok   nor added to it';
  end;

  perform pg_temp.check_eq('so the invoice still has the lines it was posted with',
    (select count(*) from public.sales_document_lines where document_id = c.inv), 2);
  perform pg_temp.check_eq('at the price it was posted at',
    (select unit_price from public.sales_document_lines where id = c.inv_line),
    100);

  -- ------------------------------------------------------------------
  -- The line rule on its own, with the header rule out of the way
  -- ------------------------------------------------------------------
  -- The three refusals above would all happen anyway: each of them
  -- moves a total, `recalc_totals` carries that to the header, and the
  -- header rule refuses it. Mutation testing said so -- taking
  -- `unit_price` out of the line rule, and even switching the line rule
  -- off altogether, left every one of them passing.
  --
  -- So these are the questions only the line rule can answer: a column
  -- the journal was built from that no total depends on, and a line
  -- worth nothing, whose arrival and departure the header would not
  -- notice.
  begin
    update public.sales_document_lines set description = 'Something else'
     where id = c.inv_line;
    raise exception
      'FAIL: a posted invoice''s line was redescribed';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal names the line and the column',
      v_msg like '%Line 1 of INV-POSTED%' and v_msg like '%description%');
    raise notice 'ok   what the line says cannot be rewritten either';
  end;

  begin
    update public.sales_document_lines
       set project_code = 'PRJ-9', department_code = 'D9'
     where id = c.inv_line;
    raise exception 'FAIL: a posted line was moved to another project';
  exception when sqlstate '42501' then
    raise notice 'ok   nor the dimensions its journal line carries';
  end;

  begin
    delete from public.sales_document_lines where id = c.free_line;
    raise exception
      'FAIL: a nil-value line was deleted from a posted invoice';
  exception when sqlstate '42501' then
    raise notice 'ok   and a line worth nothing still cannot be removed';
  end;

  begin
    insert into public.sales_document_lines
      (org_id, document_id, line_no, description, quantity, unit_price)
    values (c.org, c.inv, 98, 'Nil-value addition', 1, 0);
    raise exception 'FAIL: a nil-value line was added to a posted invoice';
  exception when sqlstate '42501' then
    raise notice 'ok   nor one added, however little it is worth';
  end;

  perform pg_temp.check_eq('still two lines, saying what they said',
    (select count(*) || ' ' || max(description)
       from public.sales_document_lines where document_id = c.inv),
    '2 Widget');

  -- ------------------------------------------------------------------
  -- Deleting the document out from under its journal
  -- ------------------------------------------------------------------
  begin
    delete from public.sales_documents where id = c.inv;
    raise exception 'FAIL: a posted invoice was deleted';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and the refusal says what the journal would be left as',
      v_msg like '%nothing to explain it%');
    raise notice 'ok   and a posted invoice cannot be deleted';
  end;
  perform pg_temp.check_eq('the invoice is still there',
    (select count(*) from public.sales_documents where id = c.inv), 1);

  -- ------------------------------------------------------------------
  -- The purchase side, which carries the same trigger
  -- ------------------------------------------------------------------
  begin
    update public.purchase_documents set total_amount = 1 where id = c.bill;
    raise exception 'FAIL: a posted bill''s total was rewritten';
  exception when sqlstate '42501' then
    raise notice 'ok   a posted bill is frozen the same way';
  end;
  begin
    update public.purchase_documents set gl_entry_id = null where id = c.bill;
    raise exception 'FAIL: a posted bill was unposted by hand';
  exception when sqlstate '42501' then
    raise notice 'ok   including its link to the journal';
  end;
  begin
    delete from public.purchase_document_lines where id = c.bill_line;
    raise exception 'FAIL: a line was deleted from a posted bill';
  exception when sqlstate '42501' then
    raise notice 'ok   and its lines';
  end;

  -- ------------------------------------------------------------------
  -- What must go on working
  -- ------------------------------------------------------------------
  -- The positive controls, and the reason this is a named list rather
  -- than a blunt freeze. Each of these is a write the application makes
  -- to a posted document every day.
  update public.sales_documents
     set paid_amount = 400, balance_amount = 600, status = 'partial'
   where id = c.inv;
  perform pg_temp.check_eq('a payment still lands on a posted invoice',
    (select paid_amount || '/' || status from public.sales_documents
      where id = c.inv), '400.00/partial');

  update public.sales_documents
     set einvoice_status = 'valid'
   where id = c.inv;
  perform pg_temp.check_eq('and LHDN''s answer still reaches it afterwards',
    (select einvoice_status::text from public.sales_documents where id = c.inv),
    'valid');

  update public.sales_documents
     set internal_notes = 'Chased 1 September', due_date = current_date + 30,
         reference = 'PO-77'
   where id = c.inv;
  perform pg_temp.check_eq('and somebody can still write on it',
    (select reference from public.sales_documents where id = c.inv), 'PO-77');

  update public.sales_documents set fulfilment_status = 'fulfilled'
   where id = c.inv;
  update public.sales_document_lines
     set quantity_invoiced = 10, quantity_fulfilled = 10
   where id = c.inv_line;
  perform pg_temp.check_eq('and progress still climbs the chain',
    (select quantity_invoiced from public.sales_document_lines
      where id = c.inv_line), 10);

  -- And the document that has not been posted is untouched by any of
  -- this: correcting one before it goes to the ledger is the ordinary
  -- business of raising it.
  update public.sales_document_lines set unit_price = 55
   where id = c.draft_line;
  perform pg_temp.check_eq('an unposted invoice is still the company''s to edit',
    (select total_amount from public.sales_documents where id = c.draft), 550);
  update public.sales_documents set doc_no = 'INV-DRAFT-2' where id = c.draft;
  delete from public.sales_document_lines where id = c.draft_line;
  perform pg_temp.check_eq('lines and all',
    (select count(*) from public.sales_document_lines
      where document_id = c.draft), 0);
  delete from public.sales_documents where id = c.draft;
  perform pg_temp.check_eq('and it can still be thrown away',
    (select count(*) from public.sales_documents where id = c.draft), 0);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The deny-list is measured against the table, not against itself
-- ---------------------------------------------------------------------
-- `0402` freezes a named list of columns and lets the rest through,
-- because most of a posted document must go on moving. That is only
-- safe while somebody looks at each new column and decides which side
-- of the line it is on. A list asserted against itself would not notice
-- a column added tomorrow, so this walks the real table.
do $$
declare
  v_frozen text[] := array[
    'id', 'org_id', 'doc_type', 'doc_no', 'doc_date',
    'currency', 'exchange_rate', 'subtotal', 'discount_amount',
    'discount_percent', 'tax_amount', 'shipping_amount',
    'rounding_amount', 'total_amount', 'base_total_amount',
    'branch_id', 'matter_id', 'posted_at', 'posted_by', 'gl_entry_id',
    -- `0410`. The service charge is on the journal, credited to 4250,
    -- so moving it after posting moves the ledger away from the
    -- document. This list is the reason that column could not be added
    -- quietly: the walk below refused until it was named.
    'service_charge_amount',
    -- 0418. The tax on that charge and the code it was charged under.
    -- The journal was built from the first of them -- it is inside the
    -- credit to output tax -- and the SST-02 return is built from both,
    -- so a figure that moved after posting would put the return and the
    -- ledger out of agreement with each other.
    'service_charge_tax', 'service_charge_tax_code_id',
    -- 0706. The method decides `rounding_amount` and `total_amount`,
    -- which are two lines above and frozen for the reason the journal
    -- carries them. A method that could be changed after posting would
    -- move both of them, and the rounding line is a posting of its own
    -- -- 4990 on the sales side.
    'rounding_method'];
  -- Deliberately still writable on a posted document, and why:
  --   money that moves after posting ... paid_amount, applied_amount,
  --     balance_amount, status
  --   LHDN's answer .................... einvoice_id, einvoice_status,
  --     is_consolidated, requires_self_billed
  --   progress and fulfilment .......... fulfilment_status, parent_id,
  --     original_invoice_id, original_bill_id, source_sales_document_id
  --   things people write on a document  notes, internal_notes, subject,
  --     reference, terms_conditions, attachments, custom_fields,
  --     due_date, delivery_date, expected_date, valid_until,
  --     payment_term_id, contact_person_id, shipping_address_id,
  --     salesperson_id, opportunity_id, supplier_doc_no,
  --     supplier_doc_date, approved_at, approved_by
  --   bookkeeping ...................... created_at, created_by,
  --     updated_at, deleted_at
  --   where the row came from .......... import_source, import_ref,
  --     import_batch_id, imported_at, and `0707`'s entry_source. The
  --     last one on the same reasoning as the four before it: the
  --     journal was not built from "a model read this off a PDF", and
  --     a document whose paperwork is scanned after it posts is
  --     telling the truth by saying so late. `0610`, `0707`. Open
  --     rather than frozen,
  --     and the test's own question decides it: the journal was not
  --     built from any of them. They are bookkeeping ABOUT the row
  --     rather than a figure inside it, and `import_batch_id` is
  --     `on delete set null` -- so freezing it would make deleting an
  --     import batch impossible the moment one of its documents
  --     posted, which is a foreign key the schema could not honour.
  --   who the document names ........... contact_id. `0402` explains
  --     this one at length: a counter sale posts against the outlet's
  --     walk-in contact and `request_einvoice_for_sale` puts the
  --     customer's name on it afterwards, which is what MyInvois
  --     expects. That path moves the receivable line's contact with it,
  --     which is asserted below.
  v_open text[] := array[
    'entry_source',
    'contact_id', 'paid_amount', 'applied_amount', 'balance_amount', 'status',
    'einvoice_id', 'einvoice_status', 'is_consolidated',
    'requires_self_billed', 'fulfilment_status', 'parent_id',
    'original_invoice_id', 'original_bill_id', 'source_sales_document_id',
    'notes', 'internal_notes', 'subject', 'reference', 'terms_conditions',
    'attachments', 'custom_fields', 'due_date', 'delivery_date',
    'expected_date', 'valid_until', 'payment_term_id', 'contact_person_id',
    'shipping_address_id', 'salesperson_id', 'opportunity_id',
    'supplier_doc_no', 'supplier_doc_date', 'approved_at', 'approved_by',
    'created_at', 'created_by', 'updated_at', 'deleted_at',
    'import_source', 'import_ref', 'import_batch_id', 'imported_at'];
  v_unclassified text;
  v_missing text;
begin
  select string_agg(t || '.' || a, ', ' order by t || '.' || a)
    into v_unclassified
    from (
      select c.relname as t, a.attname as a
        from pg_attribute a
        join pg_class c on c.oid = a.attrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and c.relname in ('sales_documents', 'purchase_documents')
         and a.attnum > 0 and not a.attisdropped
    ) cols
   where a <> all (v_frozen) and a <> all (v_open);

  if v_unclassified is not null then
    raise exception
      'FAIL: % is on a document that posts to the ledger and `0402` has '
      'no opinion about it. Add it to the frozen list in `0402` if the '
      'journal was built from it, or to the writable list here if it '
      'moves after posting -- and say which in the comment above.',
      v_unclassified;
  end if;

  -- The other direction: every frozen name has to be a real column on
  -- at least one of the two tables, or the list is protecting something
  -- that does not exist.
  select string_agg(f, ', ') into v_missing
    from unnest(v_frozen) as f
   where not exists (
     select 1 from pg_attribute a
       join pg_class c on c.oid = a.attrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname in ('sales_documents', 'purchase_documents')
        and a.attname = f and a.attnum > 0 and not a.attisdropped);
  if v_missing is not null then
    raise exception
      'FAIL: `0402` freezes %, which is not a column on either document '
      'table', v_missing;
  end if;

  raise notice
    'ok   every column on both document tables is either frozen once '
    'posted or named as one that still moves';
end $$;

-- ---------------------------------------------------------------------
-- The same question asked of the lines
-- ---------------------------------------------------------------------
do $$
declare
  v_frozen text[] := array[
    'id', 'org_id', 'document_id', 'line_no', 'line_type', 'item_id',
    'description', 'quantity', 'base_quantity', 'uom_code', 'unit_price',
    'discount_amount', 'discount_percent', 'tax_code_id', 'tax_rate',
    'is_tax_inclusive', 'line_subtotal', 'tax_amount', 'line_total',
    'account_id', 'warehouse_id', 'cost_amount',
    'service_start', 'service_end', 'project_code', 'department_code',
    'matter_id'];
  -- Still writable on the line of a posted document, and why:
  --   progress ......... quantity_invoiced, quantity_fulfilled,
  --     quantity_billed, quantity_received. `app.refresh_sales_progress`
  --     and `app.refresh_purchase_progress` write these on the lines of
  --     a posted document every time something is transferred from or
  --     received against it.
  --   the chain ........ source_line_id, forecast_line_id. Links, not
  --     figures; `app.demo_forecast_sinar` sets source_line_id on a
  --     posted bill's line so the lead time has something to measure.
  --   LHDN's taxonomy .. classification_code, which the journal never
  --     read and the submission does.
  --   bookkeeping ...... created_at, updated_at, custom_fields.
  v_open text[] := array[
    'quantity_invoiced', 'quantity_fulfilled', 'quantity_billed',
    'quantity_received', 'source_line_id', 'forecast_line_id',
    'classification_code', 'created_at', 'updated_at', 'custom_fields'];
  v_unclassified text;
  v_missing text;
begin
  select string_agg(t || '.' || a, ', ' order by t || '.' || a)
    into v_unclassified
    from (
      select c.relname as t, a.attname as a
        from pg_attribute a
        join pg_class c on c.oid = a.attrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and c.relname in ('sales_document_lines', 'purchase_document_lines')
         and a.attnum > 0 and not a.attisdropped
    ) cols
   where a <> all (v_frozen) and a <> all (v_open);

  if v_unclassified is not null then
    raise exception
      'FAIL: % is on the line of a document that posts to the ledger and '
      '`0402` has no opinion about it. Add it to the frozen list in '
      '`0402` if the journal was built from it, or to the writable list '
      'here if it moves after posting -- and say which in the comment '
      'above.', v_unclassified;
  end if;

  select string_agg(f, ', ') into v_missing
    from unnest(v_frozen) as f
   where not exists (
     select 1 from pg_attribute a
       join pg_class c on c.oid = a.attrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname in ('sales_document_lines', 'purchase_document_lines')
        and a.attname = f and a.attnum > 0 and not a.attisdropped);
  if v_missing is not null then
    raise exception
      'FAIL: `0402` freezes %, which is not a column on either document '
      'line table', v_missing;
  end if;

  raise notice
    'ok   and every column on both line tables is classified too';
end $$;

-- ---------------------------------------------------------------------
-- And the triggers are actually on all four tables
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and t.tgname = 'refuse_posted_change'
     and c.relname in ('sales_documents', 'purchase_documents',
                       'sales_document_lines', 'purchase_document_lines');
  if v_n <> 4 then
    raise exception
      'FAIL: `0402` is on % of the four document tables, not 4', v_n;
  end if;
  raise notice 'ok   the rule is on the header and the lines, both sides';
end $$;

rollback;
