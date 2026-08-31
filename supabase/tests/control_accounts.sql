-- =====================================================================
-- iAkauntan :: a contact with a control account of its own
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/control_accounts.sql
--
-- `contacts.receivable_account_id` and `payable_account_id` have been
-- columns since `0003`, and `0013` reads both in four places: the
-- invoice, the bill, the receipt and the payment each fall back to
-- `1210` and `2110` only when the contact names nothing. Neither has
-- ever appeared on a screen, so every company's receivables sat in one
-- account whether or not its accounts needed them apart — and they
-- usually do, because a balance owed by a related party is disclosed
-- separately.
--
-- The arithmetic was written and correct and had never once been
-- exercised, which is the shape this whole document is about. What is
-- asserted below is that a document raised against a contact with its
-- own control account lands there, that the payment settling it comes
-- back out of the same one, and that a contact naming nothing is
-- untouched.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org     uuid;
  v_related uuid;   -- a customer whose balance is kept apart
  v_plain   uuid;   -- an ordinary one
  v_supp    uuid;   -- a supplier whose balance is kept apart
  v_item    uuid;
  v_ar2     uuid;   -- the second receivables control account
  v_ap2     uuid;   -- the second payables one
  v_bank    uuid;
  v_doc     uuid;
  v_entry   uuid;
  v_rcp     uuid;
begin
  v_org := pg_temp.test_org('Kumpulan Berkait Sdn Bhd');
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '1215', 'Receivable — related parties',
          'asset', 'accounts_receivable')
  returning id into v_ar2;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, '2115', 'Payable — related parties',
          'liability', 'accounts_payable')
  returning id into v_ap2;

  insert into public.contacts
    (org_id, code, name, contact_type, receivable_account_id)
  values (v_org, 'REL', 'Anak Syarikat Sdn Bhd', 'customer', v_ar2)
  returning id into v_related;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'ORD', 'An ordinary customer', 'customer')
  returning id into v_plain;
  insert into public.contacts
    (org_id, code, name, contact_type, payable_account_id)
  values (v_org, 'RELS', 'Induk Sdn Bhd', 'supplier', v_ap2)
  returning id into v_supp;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'SVC', 'A service', 'service', false, 'C62', 1)
  returning id into v_item;

  -- ------------------------------------------------------------------
  -- The invoice lands in the account the customer names
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-R1', v_related, date '2026-03-02', 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description, quantity, unit_price)
  values (v_org, v_doc, 1, v_item, 'Management fee', 1, 1000);
  v_entry := public.post_sales_document(v_doc);

  perform pg_temp.check_eq('a related party''s invoice debits its own account',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1215'), 1000.00);
  perform pg_temp.check_true('and not the ordinary one',
    not exists (select 1 from public.gl_lines l
                  join public.accounts a on a.id = l.account_id
                 where l.entry_id = v_entry and a.code = '1210'));

  -- ------------------------------------------------------------------
  -- And the receipt takes it back out of the same one
  -- ------------------------------------------------------------------
  -- The half that matters. An invoice into 1215 settled by a receipt
  -- out of 1210 leaves both accounts wrong and the pair balancing, so
  -- nothing complains and the related-party disclosure is nonsense.
  select b.id into v_bank from public.bank_accounts b
   where b.org_id = v_org and b.is_active limit 1;
  if v_bank is null then
    insert into public.bank_accounts
      (org_id, account_id, name, account_type, currency)
    values (v_org,
            (select id from public.accounts where org_id = v_org and code = '1110'),
            'Current', 'current', 'MYR')
    returning id into v_bank;
  end if;

  insert into public.receipts
    (org_id, receipt_no, receipt_date, contact_id, bank_account_id,
     currency, exchange_rate, amount, base_amount, status)
  values (v_org, 'RCP-R1', date '2026-03-10', v_related, v_bank,
          'MYR', 1, 1000, 1000, 'draft')
  returning id into v_rcp;
  v_entry := public.post_receipt(v_rcp);
  perform pg_temp.check_eq('the receipt credits the same account',
    (select l.credit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1215'), 1000.00);

  -- ------------------------------------------------------------------
  -- A supplier's, on the other side
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'bill', 'BIL-R1', v_supp, date '2026-03-03', 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, item_id, description, quantity, unit_price)
  values (v_org, v_doc, 1, v_item, 'Group recharge', 1, 400);
  v_entry := public.post_purchase_document(v_doc);
  perform pg_temp.check_eq('a related party''s bill credits its own account',
    (select l.credit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '2115'), 400.00);

  -- ------------------------------------------------------------------
  -- The control: a contact naming nothing is untouched
  -- ------------------------------------------------------------------
  -- Without this, every assertion above is satisfied by a posting
  -- routine that sends everything to the second account.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, contact_id, doc_date, status)
  values (v_org, 'invoice', 'INV-O1', v_plain, date '2026-03-04', 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description, quantity, unit_price)
  values (v_org, v_doc, 1, v_item, 'An ordinary sale', 1, 250);
  v_entry := public.post_sales_document(v_doc);
  perform pg_temp.check_eq('an ordinary customer still goes to 1210',
    (select l.debit from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1210'), 250.00);

  perform pg_temp.sign_out();
end $$;

rollback;
