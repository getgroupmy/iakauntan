-- =====================================================================
-- iAkauntan :: a credit is linked by crediting (0901)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/credit_linked_by_crediting.sql
--
-- "Credit this" holds a credit to what is left uncredited; a credit note
-- written straight into the table naming its invoice was held to
-- nothing. Asked as an accountant, with the role `authenticated`, as the
-- app asks; the drafts the database itself would write are the owner's.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cl (org uuid, accountant uuid, both_c uuid, item uuid,
  inv uuid, bill uuid, linked_draft uuid);
grant select on t_cl to authenticated;

create or replace function pg_temp.cl_doc(p_kind text, p_org uuid, p_type text,
  p_no text, p_contact uuid, p_item uuid, p_amount numeric,
  p_original uuid default null, p_post boolean default true)
returns uuid language plpgsql as $$
declare v uuid;
begin
  if p_kind = 'sales' then
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
       exchange_rate, status, original_invoice_id)
    values (p_org, p_type::app.sales_doc_type, p_no, pg_temp.today(), pg_temp.today(),
            p_contact, 'MYR', 1, 'draft', p_original)
    returning id into v;
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
    values (p_org, v, 1, 'item', p_item, 'Kerja', 1, p_amount);
    if p_post then perform public.post_sales_document(v); end if;
  else
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
       status, original_bill_id)
    values (p_org, p_type::app.purchase_doc_type, p_no, pg_temp.today(), p_contact,
            'MYR', 1, 'draft', p_original)
    returning id into v;
    insert into public.purchase_document_lines
      (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
    values (p_org, v, 1, 'item', p_item, 'Sewa', 1, p_amount);
    if p_post then perform public.post_purchase_document(v); end if;
  end if;
  return v;
end $$;
grant execute on function pg_temp.cl_doc(text, uuid, text, text, uuid, uuid, numeric, uuid, boolean)
  to authenticated;

do $$
declare r t_cl;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kredit Berpaut Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  r.accountant := pg_temp.another_user('akauntan@kreditberpaut.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'BOTH', 'Rakan Niaga', 'both') returning id into r.both_c;
  insert into public.items (org_id, code, name, item_type, track_inventory, unit_price)
  values (r.org, 'KHID', 'Khidmat', 'service', false, 100) returning id into r.item;
  r.inv  := pg_temp.cl_doc('sales', r.org, 'invoice', 'INV-1', r.both_c, r.item, 1000);
  r.bill := pg_temp.cl_doc('purchases', r.org, 'bill', 'BILL-1', r.both_c, r.item, 1000);
  -- A linked draft the database could have written, for the update cases.
  r.linked_draft := pg_temp.cl_doc('sales', r.org, 'credit_note', 'CN-DRAF', r.both_c,
                      r.item, 100, r.inv, false);
  insert into t_cl select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_cl));
set local role authenticated;

do $$
declare d t_cl; v uuid;
begin
  select * into d from t_cl;

  -- -------------------------------------------------------------------
  -- Written straight in: refused
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a credit note naming its invoice is not written straight in',
    format('select pg_temp.cl_doc(%L, %L, %L, %L, %L, %L, 5000, %L, false)',
           'sales', d.org, 'credit_note', 'CN-BIG', d.both_c, d.item, d.inv),
    'A credit is tied to the invoice it credits by crediting it ("Credit this")%', '42501');
  perform pg_temp.check_refused('nor a supplier credit naming its bill',
    format('select pg_temp.cl_doc(%L, %L, %L, %L, %L, %L, 5000, %L, false)',
           'purchases', d.org, 'purchase_credit_note', 'PCN-BIG', d.both_c, d.item, d.bill),
    'A credit is tied to the bill it credits by crediting it ("Credit this")%', '42501');

  v := pg_temp.cl_doc('sales', d.org, 'credit_note', 'CN-LOOSE', d.both_c, d.item, 50, null, false);
  perform pg_temp.check_refused('nor is the link added to a note typed by hand',
    format('update public.sales_documents set original_invoice_id = %L where id = %L', d.inv, v),
    'A credit is tied to the invoice it credits%', '42501');
  perform pg_temp.check_refused('nor taken off a linked draft',
    format('update public.sales_documents set original_invoice_id = null where id = %L', d.linked_draft),
    'A credit is tied to the invoice it credits%', '42501');
  update public.sales_documents set original_invoice_id = d.inv, notes = 'Dibetulkan'
   where id = d.linked_draft;
  perform pg_temp.check_eq('a linked draft is still edited, its link written back unchanged',
    (select notes || ' / ' || (original_invoice_id = d.inv)::text
       from public.sales_documents where id = d.linked_draft), 'Dibetulkan / true');

  perform public.post_sales_document(v);
  perform pg_temp.check_eq('and a note typed by hand still posts, unlinked',
    (select (gl_entry_id is not null)::text || ' / ' || coalesce(original_invoice_id::text, 'no link')
       from public.sales_documents where id = v), 'true / no link');

  -- -------------------------------------------------------------------
  -- Crediting: linked, and capped
  -- -------------------------------------------------------------------
  v := public.credit_sales_invoice(d.inv, null, 'Tersilap');
  perform pg_temp.check_eq('"credit this" links the note to its invoice',
    (select (original_invoice_id = d.inv)::text from public.sales_documents where id = v), 'true');
  perform pg_temp.check_refused('and holds it to what is left',
    format('select public.credit_sales_invoice(%L, null, %L)', d.inv, 'Lagi'),
    'There is nothing left to credit on INV-1.', '23514');
  v := public.credit_purchase_bill(d.bill, null, 'Tersilap');
  perform pg_temp.check_eq('as "credit this" does for a bill',
    (select (original_bill_id = d.bill)::text from public.purchase_documents where id = v), 'true');
end $$;

reset role;

rollback;
