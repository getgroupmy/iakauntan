-- =====================================================================
-- iAkauntan :: LHDN's answer is not typed in (0803)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/einvoice_columns.sql
--
-- A document's `einvoice_status` and `einvoice_id` are copies of its
-- e-Invoice, which holds LHDN's answer; a bill's `requires_self_billed`
-- is decided from its supplier and changed through
-- `set_requires_self_billed`. Before `0803` a client could write all
-- three, and `void_sales_document` read the copy: an invoice LHDN had
-- validated was voided after its copied status was set back to
-- 'pending' by hand. Asked as the owner, with the role `authenticated`,
-- which is who the app is.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ec_invoice(p_org uuid, p_contact uuid, p_no text)
returns uuid language plpgsql as $$
declare v_doc uuid;
begin
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, subtotal, total_amount, balance_amount, status)
  values (p_org, 'invoice', p_no, pg_temp.today(), pg_temp.today() + 30,
          p_contact, 'MYR', 1, 100, 100, 100, 'draft')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price, line_total)
  values (p_org, v_doc, 1, 'Khidmat', 1, 100, 100);
  return v_doc;
end $$;

create or replace function pg_temp.ec_bill(p_org uuid, p_supplier uuid, p_no text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (p_org, 'bill', p_no, pg_temp.today(), p_supplier, 'MYR', 1,
          'draft', 1000, 1000, 1000, 1000)
  returning id into v_id;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, description, quantity, unit_price)
  values (p_org, v_id, 1, 'Lesen perisian', 1, 1000);
  return v_id;
end $$;

create temporary table t_ec (
  org uuid, cust uuid, foreign_supp uuid, local_supp uuid,
  inv_valid uuid, ei_valid uuid,      -- LHDN accepted it; the copy agrees
  inv_queued uuid,                    -- prepared, not yet sent
  inv_plain uuid,                     -- posted, no e-Invoice
  inv_copy uuid,                      -- accepted; the copy says 'pending'
  inv_gone uuid,                      -- the copy says 'valid'; its e-Invoice is gone
  inv_draft uuid,
  inv_new uuid,                       -- posted, for the client to prepare
  bill_local uuid, bill_foreign uuid, bill_draft uuid,
  other_org uuid);
grant select on t_ec to authenticated;

do $$
declare
  r    t_ec;
  v_ei uuid;
  v_c  uuid;
  v_d  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  r.org := pg_temp.test_org('Jawapan LHDN Sdn Bhd');
  r.other_org := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  perform public.create_fiscal_year(o, date_trunc('year', pg_temp.today())::date)
     from unnest(array[r.org, r.other_org]) o;
  update public.organizations
     set einvoice_enabled = true, tin = 'C12345678901',
         legal_name = name, registration_no = '202401234567',
         country_code = 'MYS'
   where id in (r.org, r.other_org);

  insert into public.contacts (org_id, code, name, contact_type, country_code, tin)
  values (r.org, 'C-1', 'Pembeli Sdn Bhd', 'customer', 'MYS', 'C88888888888')
  returning id into r.cust;
  insert into public.contacts
    (org_id, code, name, legal_name, contact_type, country_code, tin, id_type, id_value)
  values (r.org, 'F-1', 'Cloud Vendor Inc', 'Cloud Vendor Incorporated', 'supplier',
          'USA', 'EI00000000020', 'BRN', 'US-987654')
  returning id into r.foreign_supp;
  insert into public.contacts (org_id, code, name, contact_type, country_code, tin)
  values (r.org, 'L-1', 'Pembekal Tempatan Sdn Bhd', 'supplier', 'MYS', 'C99999999999')
  returning id into r.local_supp;

  r.inv_valid  := pg_temp.ec_invoice(r.org, r.cust, 'INV-E1');
  r.inv_queued := pg_temp.ec_invoice(r.org, r.cust, 'INV-E2');
  r.inv_plain  := pg_temp.ec_invoice(r.org, r.cust, 'INV-E3');
  r.inv_copy   := pg_temp.ec_invoice(r.org, r.cust, 'INV-E4');
  r.inv_gone   := pg_temp.ec_invoice(r.org, r.cust, 'INV-E5');
  r.inv_draft  := pg_temp.ec_invoice(r.org, r.cust, 'INV-E6');
  r.inv_new    := pg_temp.ec_invoice(r.org, r.cust, 'INV-E7');
  perform public.post_sales_document(d)
     from unnest(array[r.inv_valid, r.inv_queued, r.inv_plain, r.inv_copy,
                       r.inv_gone, r.inv_new]) d;

  -- What the MyInvois sweep writes when LHDN accepts one; the copy
  -- follows by `sync_einvoice_status`.
  r.ei_valid := public.prepare_einvoice(r.inv_valid);
  update public.einvoice_documents
     set status = 'valid', myinvois_uuid = 'LHDN-UUID-1', validated_at = now()
   where id = r.ei_valid;
  perform public.prepare_einvoice(r.inv_queued);

  -- The state a client could make before 0803: accepted by LHDN, the
  -- copy set back by hand.
  v_ei := public.prepare_einvoice(r.inv_copy);
  update public.einvoice_documents
     set status = 'valid', myinvois_uuid = 'LHDN-UUID-4', validated_at = now()
   where id = v_ei;
  update public.sales_documents set einvoice_status = 'pending' where id = r.inv_copy;

  -- And the other way round: the copy says valid and the e-Invoice it
  -- copied is gone (the foreign key nulls the id and leaves the status).
  v_ei := public.prepare_einvoice(r.inv_gone);
  update public.einvoice_documents
     set status = 'valid', myinvois_uuid = 'LHDN-UUID-5', validated_at = now()
   where id = v_ei;
  delete from public.einvoice_documents where id = v_ei;

  r.bill_local   := pg_temp.ec_bill(r.org, r.local_supp, 'BILL-L');
  r.bill_foreign := pg_temp.ec_bill(r.org, r.foreign_supp, 'BILL-F');
  r.bill_draft   := pg_temp.ec_bill(r.org, r.local_supp, 'BILL-D');
  update public.purchase_documents set status = 'posted'
   where id in (r.bill_local, r.bill_foreign);
  perform public.prepare_self_billed_einvoice(r.bill_foreign);

  -- Two e-Invoices that are valid and carry INV-E3's id without being
  -- its own: another company's, and one of this company's for a bill.
  -- `source_id` has no foreign key -- it names a row in whichever table
  -- `source_table` says -- and until `0804` `einvoice_documents` took a
  -- client's insert. Asked still: a function can write one wrong. Made
  -- valid first, so `sync_einvoice_status` copies the answer onto their
  -- own documents, and moved after, which it does not copy.
  insert into public.contacts (org_id, code, name, contact_type, country_code, tin)
  values (r.other_org, 'C-1', 'Pembeli Lain Sdn Bhd', 'customer', 'MYS', 'C77777777777')
  returning id into v_c;
  v_d := pg_temp.ec_invoice(r.other_org, v_c, 'INV-E3');
  perform public.post_sales_document(v_d);
  v_ei := public.prepare_einvoice(v_d);
  update public.einvoice_documents
     set status = 'valid', myinvois_uuid = 'LHDN-UUID-LAIN', validated_at = now()
   where id = v_ei;
  update public.einvoice_documents set source_id = r.inv_plain where id = v_ei;

  v_d := pg_temp.ec_bill(r.org, r.foreign_supp, 'BILL-G');
  update public.purchase_documents set status = 'posted' where id = v_d;
  v_ei := public.prepare_self_billed_einvoice(v_d);
  update public.einvoice_documents
     set status = 'valid', myinvois_uuid = 'LHDN-UUID-G', validated_at = now()
   where id = v_ei;
  update public.einvoice_documents set source_id = r.inv_plain where id = v_ei;

  insert into t_ec select r.*;
end $$;

do $$
declare d t_ec;
begin
  select * into d from t_ec;
  -- The fixture is what it says, or nothing below asks anything.
  perform pg_temp.check_eq('the accepted invoice''s copy says valid',
    (select einvoice_status from public.sales_documents where id = d.inv_valid), 'valid');
  perform pg_temp.check_eq('the prepared one''s says pending',
    (select einvoice_status from public.sales_documents where id = d.inv_queued), 'pending');
  perform pg_temp.check_eq('the one set back by hand says pending',
    (select einvoice_status from public.sales_documents where id = d.inv_copy), 'pending');
  perform pg_temp.check_true('while its e-Invoice is valid',
    exists (select 1 from public.einvoice_documents
             where source_id = d.inv_copy and status = 'valid'));
  perform pg_temp.check_true('the copy that outlived its e-Invoice says valid, with none',
    (select einvoice_status = 'valid' and einvoice_id is null
       from public.sales_documents where id = d.inv_gone)
    and not exists (select 1 from public.einvoice_documents where source_id = d.inv_gone));
  perform pg_temp.check_true('the foreign bill owes one and has it prepared',
    (select requires_self_billed and einvoice_status = 'pending'
       from public.purchase_documents where id = d.bill_foreign));
  perform pg_temp.check_eq('two valid e-Invoices that are not INV-E3''s carry its id',
    (select count(*)::integer from public.einvoice_documents
      where source_id = d.inv_plain and status = 'valid'
        and (org_id <> d.org or source_table <> 'sales_documents')), 2);
  perform pg_temp.check_true('and INV-E3''s own copy still says it has none',
    (select einvoice_status = 'not_applicable' and einvoice_id is null
       from public.sales_documents where id = d.inv_plain));
  perform pg_temp.check_true('the local bill owes none',
    (select not requires_self_billed and einvoice_status = 'not_applicable'
       from public.purchase_documents where id = d.bill_local));
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- The copies are not written
-- =====================================================================
do $$
declare d t_ec;
begin
  select * into d from t_ec;
  perform pg_temp.check_eq('the owner writes as a client', current_user, 'authenticated');

  -- What was measured: the copy set back so the void would not ask.
  perform pg_temp.check_refused('an accepted invoice''s status is not set back',
    format('update public.sales_documents set einvoice_status = ''pending'' where id = %L',
           d.inv_valid),
    'The e-Invoice status of INV-E1 is copied from the e-Invoice, which holds '
    'LHDN''s answer, and is not written directly (valid -> pending).%', '42501');
  perform pg_temp.check_refused('nor an invoice with none marked accepted',
    format('update public.sales_documents set einvoice_status = ''valid'' where id = %L',
           d.inv_plain),
    'The e-Invoice status of INV-E3 is copied % (not_applicable -> valid).%', '42501');
  perform pg_temp.check_refused('nor pointed at another invoice''s e-Invoice',
    format('update public.sales_documents set einvoice_id = %L where id = %L',
           d.ei_valid, d.inv_plain),
    'The e-Invoice id of INV-E3 is copied % (null -> ' || d.ei_valid || ').%', '42501');
  perform pg_temp.check_refused('nor parted from its own',
    format('update public.sales_documents set einvoice_id = null where id = %L',
           d.inv_queued),
    'The e-Invoice id of INV-E2 is copied %', '42501');
  perform pg_temp.check_refused('and the same on a bill',
    format('update public.purchase_documents set einvoice_status = ''valid'' where id = %L',
           d.bill_local),
    'The e-Invoice status of BILL-L is copied % (not_applicable -> valid).%', '42501');
  perform pg_temp.check_refused('whose e-Invoice is not swapped either',
    format('update public.purchase_documents set einvoice_id = %L where id = %L',
           d.ei_valid, d.bill_local),
    'The e-Invoice id of BILL-L is copied %', '42501');

  -- Whether a bill owes a self-billed one.
  perform pg_temp.check_refused('a bill is not made to owe a self-billed e-Invoice by hand',
    format('update public.purchase_documents set requires_self_billed = true where id = %L',
           d.bill_local),
    'Whether BILL-L owes a self-billed e-Invoice is changed with '
    'set_requires_self_billed (false -> true)%', '42501');
  perform pg_temp.check_refused('nor let off one by hand, with it prepared',
    format('update public.purchase_documents set requires_self_billed = false where id = %L',
           d.bill_foreign),
    'Whether BILL-F owes a self-billed e-Invoice is changed with '
    'set_requires_self_billed (true -> false)%', '42501');

  -- A statement that leaves them as they were is not a change.
  update public.sales_documents
     set notes = 'Hantar Isnin', einvoice_status = 'not_applicable', einvoice_id = null
   where id = d.inv_draft;
  perform pg_temp.check_eq('a draft is edited with its copies sent back unchanged',
    (select notes from public.sales_documents where id = d.inv_draft), 'Hantar Isnin');
  update public.purchase_documents
     set notes = 'Semak harga', requires_self_billed = false
   where id = d.bill_draft;
  perform pg_temp.check_eq('and a draft bill with its obligation as it was',
    (select notes from public.purchase_documents where id = d.bill_draft), 'Semak harga');
end $$;

-- =====================================================================
-- Nor written on the way in
-- =====================================================================
do $$
declare d t_ec;
begin
  select * into d from t_ec;
  perform pg_temp.check_refused('an invoice is not created accepted',
    format($q$insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
       subtotal, total_amount, balance_amount, status, einvoice_status)
      values (%L, 'invoice', 'INV-X1', pg_temp.today(), %L, 'MYR', 1, 0, 0, 0,
              'draft', 'valid')$q$, d.org, d.cust),
    'A document is created with no e-Invoice on it (this one said valid, '
    'e-Invoice none).%', '42501');
  perform pg_temp.check_refused('nor holding another''s e-Invoice',
    format($q$insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
       subtotal, total_amount, balance_amount, status, einvoice_id)
      values (%L, 'invoice', 'INV-X2', pg_temp.today(), %L, 'MYR', 1, 0, 0, 0,
              'draft', %L)$q$, d.org, d.cust, d.ei_valid),
    'A document is created with no e-Invoice on it (this one said '
    'not_applicable, e-Invoice ' || d.ei_valid || ').%', '42501');
  perform pg_temp.check_refused('nor a bill created with one',
    format($q$insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
       subtotal, total_amount, balance_amount, status, einvoice_status)
      values (%L, 'bill', 'BILL-X1', pg_temp.today(), %L, 'MYR', 1, 0, 0, 0,
              'draft', 'pending')$q$, d.org, d.local_supp),
    'A document is created with no e-Invoice on it (this one said pending, %', '42501');
  perform pg_temp.check_refused('nor created owing a self-billed one it does not',
    format($q$insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
       subtotal, total_amount, balance_amount, status, requires_self_billed)
      values (%L, 'bill', 'BILL-X2', pg_temp.today(), %L, 'MYR', 1, 0, 0, 0,
              'draft', true)$q$, d.org, d.local_supp),
    'A bill owes a self-billed e-Invoice because its supplier is abroad, or '
    'because somebody said so with set_requires_self_billed%', '42501');

  -- What the app writes: none of the three.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (d.org, 'invoice', 'INV-X3', pg_temp.today(), d.cust, 'MYR', 1, 0, 0, 0, 'draft');
  perform pg_temp.check_eq('an invoice is created owing nothing yet',
    (select einvoice_status from public.sales_documents
      where org_id = d.org and doc_no = 'INV-X3'), 'not_applicable');
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status, requires_self_billed)
  values (d.org, 'bill', 'BILL-X3', pg_temp.today(), d.local_supp, 'MYR', 1, 0, 0, 0,
          'draft', false);
  perform pg_temp.check_true('a bill is created saying it owes none, which it does not',
    (select not requires_self_billed from public.purchase_documents
      where org_id = d.org and doc_no = 'BILL-X3'));
  -- The guard fires before `suggest_self_billed`: asked after it, the
  -- supplier's own answer would be refused as the client's.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status)
  values (d.org, 'bill', 'BILL-X4', pg_temp.today(), d.foreign_supp, 'MYR', 1, 0, 0, 0,
          'draft');
  perform pg_temp.check_true('and a bill from abroad is created owing one, from its supplier',
    (select requires_self_billed from public.purchase_documents
      where org_id = d.org and doc_no = 'BILL-X4'));
end $$;

-- =====================================================================
-- The functions are the road, and pass
-- =====================================================================
do $$
declare
  d    t_ec;
  v_ei uuid;
begin
  select * into d from t_ec;
  v_ei := public.prepare_einvoice(d.inv_new);
  perform pg_temp.check_true('an e-Invoice prepared through its function marks the invoice',
    (select einvoice_status = 'pending' and einvoice_id = v_ei
       from public.sales_documents where id = d.inv_new));

  perform public.set_requires_self_billed(d.bill_local, true);
  perform pg_temp.check_true('a bill is made to owe one through set_requires_self_billed',
    (select requires_self_billed from public.purchase_documents where id = d.bill_local));
  perform public.set_requires_self_billed(d.bill_foreign, false);
  perform pg_temp.check_true(
    'and let off one, its prepared e-Invoice withdrawn and the bill unmarked',
    (select not requires_self_billed and einvoice_status = 'not_applicable'
            and einvoice_id is null
       from public.purchase_documents where id = d.bill_foreign));
end $$;

reset role;

-- LHDN's answer, as the MyInvois function writes it: onto the
-- e-Invoice, and copied by `sync_einvoice_status` one trigger down.
-- Written as the session, which owns the table: the function runs as
-- `service_role`, which the hosted project grants the table and the CLI
-- stack CI runs on does not (run 38100240247). What is asked is that
-- the copy follows a write that is not a client's.
update public.einvoice_documents set status = 'submitted'
 where source_id = (select inv_new from t_ec);

do $$
begin
  perform pg_temp.check_eq('LHDN''s answer is copied onto the invoice',
    (select einvoice_status from public.sales_documents
      where id = (select inv_new from t_ec)), 'submitted');
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- The void asks the e-Invoice, not the copy
-- =====================================================================
do $$
declare d t_ec;
begin
  select * into d from t_ec;
  perform pg_temp.check_refused('an accepted invoice is not voided',
    format('select public.void_sales_document(%L, ''salah'')', d.inv_valid),
    'Cannot void INV-E1: cancel the e-Invoice with LHDN first');
  -- The measured case: the copy says pending, LHDN says valid.
  perform pg_temp.check_refused('nor one whose copy was set back, asked of LHDN''s copy',
    format('select public.void_sales_document(%L, ''salah'')', d.inv_copy),
    'Cannot void INV-E4: cancel the e-Invoice with LHDN first');
  perform pg_temp.check_refused('nor one whose copy says valid with its e-Invoice gone',
    format('select public.void_sales_document(%L, ''salah'')', d.inv_gone),
    'Cannot void INV-E5: cancel the e-Invoice with LHDN first');
  perform pg_temp.check_true('and each is still posted',
    (select bool_and(status = 'posted') from public.sales_documents
      where id in (d.inv_valid, d.inv_copy, d.inv_gone)));

  -- Another invoice's accepted e-Invoice is not this one's -- nor
  -- another company's, nor a bill's, that carry its id.
  perform public.void_sales_document(d.inv_plain, 'salah pelanggan');
  perform pg_temp.check_eq(
    'an invoice with none is voided beside accepted ones that are not its own',
    (select status::text from public.sales_documents where id = d.inv_plain), 'void');
  -- And one LHDN never had is voided and its e-Invoice withdrawn (0770).
  perform public.void_sales_document(d.inv_queued, 'salah pelanggan');
  perform pg_temp.check_true('one prepared and not sent is voided and withdrawn',
    (select s.status = 'void' and e.status = 'cancelled' and s.einvoice_status = 'cancelled'
       from public.sales_documents s
       join public.einvoice_documents e on e.source_id = s.id
      where s.id = d.inv_queued));
end $$;

reset role;

do $$
begin
  perform pg_temp.check_eq('the rule is on both tables',
    (select count(*)::integer from pg_trigger
      where tgname = 'a_einvoice_state_is_lhdns'
        and tgrelid in ('public.sales_documents'::regclass,
                        'public.purchase_documents'::regclass)), 2);
end $$;

rollback;
