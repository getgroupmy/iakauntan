-- =====================================================================
-- iAkauntan :: what happened to this invoice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_history.sql
--
-- `document_activity` has shown what was *sent* since 0082 — emails,
-- share links, downloads — and nothing about what happened to the
-- document. 0495 adds the three sources that were already being written
-- and never read: the audit trail per record, the money allocated
-- against the invoice, and what LHDN said.
--
-- Most of what matters here is scope. Three of the new reads join on an
-- id, and a missing clause puts another document's history — or another
-- company's — on this one's screen.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.kinds(p_doc uuid)
returns text language sql as $$
  select coalesce(string_agg(distinct kind, ',' order by kind), '')
    from public.document_activity(p_doc);
$$;

create or replace function pg_temp.details(p_doc uuid, p_kind text)
returns text language sql as $$
  select coalesce(string_agg(coalesce(detail, '') , ' | ' order by detail), '')
    from public.document_activity(p_doc) where kind = p_kind;
$$;

do $$
declare
  v_org    uuid := pg_temp.test_org('History Sdn Bhd');
  v_who    uuid := pg_temp.test_user();
  v_them   uuid;
  v_doc    uuid;
  v_other  uuid;
  v_receipt uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer', 'buyer@example.test')
  returning id into v_them;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-1', date '2026-01-15', v_them, 'MYR', 1,
          1000, 1000, 1000, 'draft')
  returning id into v_doc;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total, cost_amount)
  values (v_org, v_doc, 1, 'Consulting', 1, 1000, 1000, 400);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (v_org, 'invoice', 'INV-2', date '2026-01-15', v_them, 'MYR', 1,
          500, 500, 500, 'draft')
  returning id into v_other;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price,
     line_total, cost_amount)
  values (v_org, v_other, 1, 'Consulting', 1, 500, 500, 200);

  perform public.post_sales_document(v_doc);
  perform public.post_sales_document(v_other);

  -- ------------------------------------------------------------------
  -- What happened to it
  -- ------------------------------------------------------------------
  perform pg_temp.check_true(
    'the timeline says when it was raised and when it was posted',
    pg_temp.details(v_doc, 'change') like '%raised%'
    and pg_temp.details(v_doc, 'change') like '%posted to the ledger%');

  -- The audit trail is company-wide and indexed per record. A read that
  -- forgets either half of that key puts somebody else's history here.
  perform pg_temp.check_true(
    'and nothing that happened to another document',
    pg_temp.details(v_doc, 'change') not like '%INV-2%');

  -- `record_id` is only unique within a table: the index 0038 built is
  -- on (table_name, record_id) and both halves are the key. A row filed
  -- under this document's id against some other table has no business
  -- on this screen, so one is planted here to prove the read uses both.
  -- The trail is written by triggers, which are not what is under test;
  -- what is under test is the read.
  insert into public.audit_logs
    (org_id, table_name, record_id, action, old_data, new_data, user_id)
  values (v_org, 'purchase_documents', v_doc, 'update', '{}'::jsonb,
          jsonb_build_object('status', 'void'), v_who);
  perform pg_temp.check_true(
    'and nothing that happened to another kind of record',
    pg_temp.details(v_doc, 'change') not like '%voided%');

  -- ------------------------------------------------------------------
  -- The money
  -- ------------------------------------------------------------------
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, currency,
     exchange_rate, status)
  values (v_org, 'RCP-1', date '2026-02-01', v_them, 500, 'MYR', 1, 'posted')
  returning id into v_receipt;
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount, allocated_at)
  values (v_org, v_receipt, v_doc, 400, timestamptz '2026-02-01 10:00+08');
  insert into public.payment_allocations
    (org_id, receipt_id, invoice_id, amount, allocated_at)
  values (v_org, v_receipt, v_other, 100, timestamptz '2026-02-01 10:00+08');

  perform pg_temp.check_true('and when it was paid',
    pg_temp.details(v_doc, 'payment') like '%RCP-1%400.00%');
  perform pg_temp.check_true('and not what was paid against another one',
    pg_temp.details(v_doc, 'payment') not like '%100.00%');

  -- ------------------------------------------------------------------
  -- LHDN
  -- ------------------------------------------------------------------
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, internal_doc_no,
     issue_date, currency, supplier_name, supplier_tin, buyer_name,
     buyer_tin, total_excl_tax, total_incl_tax, payable_amount, status,
     submitted_at)
  values (v_org, 'sales_documents', v_doc, '01', 'INV-1',
          date '2026-01-15', 'MYR', 'History Sdn Bhd', 'C12345678900',
          'Buyer Bhd', 'C98765432100', 1000, 1000, 1000, 'valid',
          timestamptz '2026-01-16 09:00+08');
  -- A purchase document carrying the same id. `einvoice_documents` is
  -- keyed on (source_table, source_id) because both cycles reach it --
  -- a self-billed e-invoice is raised against a bill — so the source
  -- table is half the key and a read that drops it is a read that can
  -- put the purchase side on the sales side's screen.
  insert into public.einvoice_documents
    (org_id, source_table, source_id, einvoice_type_code, internal_doc_no,
     issue_date, currency, supplier_name, supplier_tin, buyer_name,
     buyer_tin, total_excl_tax, total_incl_tax, payable_amount, status)
  values (v_org, 'purchase_documents', v_doc, '11', 'BILL-9999',
          date '2026-01-15', 'MYR', 'History Sdn Bhd', 'C12345678900',
          'Supplier Bhd', 'C55555555500', 50, 50, 50, 'valid');

  perform pg_temp.check_true('and what LHDN said',
    pg_temp.details(v_doc, 'e-invoice') like '%INV-1%');
  perform pg_temp.check_true(
    'and not a bill that happens to share the id',
    pg_temp.details(v_doc, 'e-invoice') not like '%BILL-9999%');

  -- ------------------------------------------------------------------
  -- An edit
  -- ------------------------------------------------------------------
  update public.sales_documents
     set reference = 'PO-77', due_date = date '2026-03-01'
   where id = v_doc;
  perform pg_temp.check_true('an edit says which fields changed',
    (select count(*) from public.document_activity(v_doc)
      where kind = 'change' and status = 'update'
        and note like '%reference%' and note like '%due_date%') > 0);

  -- ------------------------------------------------------------------
  -- And what 0082 already showed
  -- ------------------------------------------------------------------
  insert into public.email_outbox
    (org_id, to_email, subject, body, document_id, template_code)
  values (v_org, 'buyer@example.test', 'Your invoice', 'Here it is.',
          v_doc, 'document_new');
  perform public.share_document(v_doc, 30, 'buyer@example.test');

  perform pg_temp.check_true('the emails and the links are still there',
    pg_temp.kinds(v_doc) like '%email%'
    and pg_temp.kinds(v_doc) like '%share link%');

  -- Newest first, which is what a person opening this screen wants.
  perform pg_temp.check_true('and the newest thing is at the top',
    (select bool_and(ordered) from (
      select at <= lag(at) over () as ordered
        from public.document_activity(v_doc)) s
     where ordered is not null));
end $$;

rollback;
