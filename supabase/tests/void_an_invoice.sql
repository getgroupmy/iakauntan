-- =====================================================================
-- iAkauntan :: voiding an invoice
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/void_an_invoice.sql
--
-- `reversal.sql` asserts what voiding does to the ledger, and does it
-- well: the revenue comes off and the receivable comes off, and neither
-- is left holding its own opposite. What nothing asserted is what
-- voiding REFUSES, and which document it lands on.
--
-- Eight mutants were put through `void_sales_document`; six lived. The
-- one worth stopping the day for: changing `where id = p_id` to `where
-- org_id = v_doc.org_id` voids every sales document the company has
-- ever raised, and the suite stayed green. Everything below is the
-- other half of the function.
--
--   * a void is a posting decision, so somebody who may only read is
--     refused;
--   * an invoice with money against it cannot be voided. The money went
--     somewhere: void the invoice and the receipt is allocated to a
--     document that no longer exists, so the customer's statement and
--     the bank stop agreeing. A credit note is the answer, and the
--     message says so;
--   * an invoice LHDN has validated cannot be quietly dropped either.
--     The submission is a filing, and it is cancelled with LHDN or not
--     at all;
--   * the reversal is dated TODAY, not the day the invoice was raised.
--     Back-dating it would move a figure inside a period that may be
--     closed and reported, which is the difference between a correction
--     and a rewrite;
--   * and it voids ONE document.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.void_invoice(
  p_org uuid, p_cust uuid, p_no text, p_amount numeric, p_on date)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'invoice', p_no, p_on, p_on + 30, p_cust, 'MYR', 1, 'draft')
  returning id into v_id;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_id, 1, 'Consulting', 1, p_amount);
  perform public.post_sales_document(v_id);
  return v_id;
end;
$$;

do $$
declare
  v_org   uuid;
  v_cust  uuid;
  v_a     uuid;
  v_b     uuid;
  v_paid  uuid;
  v_filed uuid;
  v_draft uuid;
  v_rcp   uuid;
  v_clerk uuid;
  v_owner uuid := pg_temp.test_user();
  v_msg   text;
begin
  v_org := pg_temp.test_org('Batal Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Pelanggan Bhd', 'customer') returning id into v_cust;

  v_a     := pg_temp.void_invoice(v_org, v_cust, 'INV-A', 1000, date '2026-03-01');
  v_b     := pg_temp.void_invoice(v_org, v_cust, 'INV-B', 2000, date '2026-03-02');
  v_paid  := pg_temp.void_invoice(v_org, v_cust, 'INV-C', 3000, date '2026-03-03');
  v_filed := pg_temp.void_invoice(v_org, v_cust, 'INV-D', 4000, date '2026-03-04');

  -- ------------------------------------------------------------------
  -- Who may void
  -- ------------------------------------------------------------------
  v_clerk := pg_temp.another_user('pembaca@example.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_clerk, 'viewer', 'active', now())
  on conflict (org_id, user_id) do update set role = 'viewer', status = 'active';
  -- Against a DRAFT, deliberately. A posted invoice has a journal, and
  -- `reverse_gl_entry` asks `app.can_post` too and raises the same
  -- words, so on a posted invoice the two guards are indistinguishable
  -- and either one alone would refuse. A draft has no journal to
  -- reverse, so this function's own guard is the only thing here.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-E', date '2026-03-05', date '2026-04-04',
          v_cust, 'MYR', 1, 'draft')
  returning id into v_draft;

  perform pg_temp.sign_in_as(v_clerk);
  begin
    perform public.void_sales_document(v_draft, 'no');
    raise exception 'FAIL a viewer voided an invoice';
  exception when insufficient_privilege then
    raise notice 'ok   voiding is a posting decision, not a reading one';
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and the draft is untouched',
    (select status = 'draft' from public.sales_documents where id = v_draft));

  -- ------------------------------------------------------------------
  -- What cannot be voided
  -- ------------------------------------------------------------------
  -- A hundred ringgit against a three thousand ringgit invoice. Part
  -- paid is paid: the receipt is allocated to this document, and
  -- voiding it would leave that allocation pointing at nothing.
  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, amount, unapplied_amount,
     currency, exchange_rate)
  values (v_org, 'RCP-1', date '2026-03-10', v_cust, 100, 100, 'MYR', 1)
  returning id into v_rcp;
  insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
  values (v_org, v_rcp, v_paid, 100);
  perform public.post_receipt(v_rcp);

  begin
    perform public.void_sales_document(v_paid, 'changed my mind');
    raise exception 'FAIL voided an invoice that has been paid against';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'an invoice with money against it says so rather than vanishing',
      v_msg like '%payments have been applied%');
  end;

  -- Filed with LHDN. Cancelling a submission is a conversation with
  -- them, not a status change here.
  update public.sales_documents set einvoice_status = 'valid' where id = v_filed;
  begin
    perform public.void_sales_document(v_filed, 'oops');
    raise exception 'FAIL voided an invoice LHDN has validated';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('and a filed e-Invoice is cancelled with LHDN first',
      v_msg like '%cancel the e-Invoice with LHDN first%');
  end;

  -- ------------------------------------------------------------------
  -- And what voiding one does to the others
  -- ------------------------------------------------------------------
  perform public.void_sales_document(v_a, 'raised in error');

  perform pg_temp.check_true('the invoice is void', (select status = 'void'
    from public.sales_documents where id = v_a));
  perform pg_temp.check_true('and the next one is not',
    (select status <> 'void' from public.sales_documents where id = v_b));
  perform pg_temp.check_eq('exactly one document in the company is void',
    (select count(*)::integer from public.sales_documents
      where org_id = v_org and status = 'void'), 1);

  -- The reversal belongs to the day the decision was made. Dated back
  -- to the invoice it would rewrite March, which may already have been
  -- closed, reported and filed.
  perform pg_temp.check_eq('one reversing entry was raised',
    (select count(*)::integer from public.gl_entries e
      where e.org_id = v_org and e.is_reversal), 1);
  perform pg_temp.check_true('the reversal is dated today, not March',
    (select e.entry_date = app.today() from public.gl_entries e
      where e.org_id = v_org and e.is_reversal
        and e.reversed_entry_id = (select gl_entry_id
                                     from public.sales_documents where id = v_a)));
end $$;

rollback;
