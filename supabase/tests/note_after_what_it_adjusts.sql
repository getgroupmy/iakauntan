-- =====================================================================
-- iAkauntan :: a note never comes before what it adjusts (0889)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/note_after_what_it_adjusts.sql
--
-- "Credit this invoice" dated the credit note today, so a document dated
-- ahead was credited before it was sold; and a note typed by hand that
-- names its invoice or bill posted whatever its date. Asked as an
-- accountant, with the role `authenticated`, as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_na (org uuid, accountant uuid, both_c uuid, item uuid,
  inv_today uuid, inv_ahead uuid, inv_past uuid,
  bill_today uuid, bill_ahead uuid, bill_past uuid,
  cn_early uuid, cn_onday uuid, cn_loose uuid, pcn_early uuid, pcn_onday uuid);
grant select on t_na to authenticated;

create or replace function pg_temp.na_doc(p_kind text, p_org uuid, p_type text,
  p_no text, p_on date, p_contact uuid, p_item uuid, p_amount numeric,
  p_original uuid default null, p_post boolean default true)
returns uuid language plpgsql as $$
declare v uuid;
begin
  if p_kind = 'sales' then
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
       exchange_rate, status, original_invoice_id)
    values (p_org, p_type::app.sales_doc_type, p_no, p_on, p_on, p_contact, 'MYR', 1,
            'draft', p_original)
    returning id into v;
    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
    values (p_org, v, 1, 'item', p_item, 'Kerja', 1, p_amount);
    if p_post then perform public.post_sales_document(v); end if;
  else
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
       status, original_bill_id)
    values (p_org, p_type::app.purchase_doc_type, p_no, p_on, p_contact, 'MYR', 1,
            'draft', p_original)
    returning id into v;
    insert into public.purchase_document_lines
      (org_id, document_id, line_no, line_type, item_id, description, quantity, unit_price)
    values (p_org, v, 1, 'item', p_item, 'Sewa', 1, p_amount);
    if p_post then perform public.post_purchase_document(v); end if;
  end if;
  return v;
end $$;

-- A document's date, and whether it is in the books.
create or replace function pg_temp.na_state(p_kind text, p_id uuid)
returns text language sql as $$
  select coalesce(
    (select doc_date::text || case when gl_entry_id is null then ' unposted' else ' posted' end
       from public.sales_documents where id = p_id and p_kind = 'sales'),
    (select doc_date::text || case when gl_entry_id is null then ' unposted' else ' posted' end
       from public.purchase_documents where id = p_id and p_kind = 'purchases'));
$$;

do $$
declare r t_na;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Nota Bertarikh Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 90);
  r.accountant := pg_temp.another_user('akauntan@notabertarikh.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.accountant, 'accountant', 'active');
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'BOTH', 'Rakan Niaga', 'both') returning id into r.both_c;
  insert into public.items (org_id, code, name, item_type, track_inventory, unit_price)
  values (r.org, 'KHID', 'Khidmat', 'service', false, 100) returning id into r.item;

  r.inv_today  := pg_temp.na_doc('sales', r.org, 'invoice', 'INV-1', pg_temp.today(), r.both_c, r.item, 1000);
  r.inv_ahead  := pg_temp.na_doc('sales', r.org, 'invoice', 'INV-2', pg_temp.today() + 20, r.both_c, r.item, 700);
  r.inv_past   := pg_temp.na_doc('sales', r.org, 'invoice', 'INV-3', pg_temp.today() - 5, r.both_c, r.item, 300);
  r.bill_today := pg_temp.na_doc('purchases', r.org, 'bill', 'BILL-1', pg_temp.today(), r.both_c, r.item, 1000);
  r.bill_ahead := pg_temp.na_doc('purchases', r.org, 'bill', 'BILL-2', pg_temp.today() + 20, r.both_c, r.item, 700);
  r.bill_past  := pg_temp.na_doc('purchases', r.org, 'bill', 'BILL-3', pg_temp.today() - 5, r.both_c, r.item, 300);

  -- Notes typed by hand, left as drafts for the accountant to post.
  r.cn_early  := pg_temp.na_doc('sales', r.org, 'credit_note', 'CN-EARLY', pg_temp.today() - 10,
                   r.both_c, r.item, 100, r.inv_today, false);
  r.cn_onday  := pg_temp.na_doc('sales', r.org, 'credit_note', 'CN-ONDAY', pg_temp.today(),
                   r.both_c, r.item, 100, r.inv_today, false);
  r.cn_loose  := pg_temp.na_doc('sales', r.org, 'credit_note', 'CN-LOOSE', pg_temp.today() - 10,
                   r.both_c, r.item, 50, null, false);
  r.pcn_early := pg_temp.na_doc('purchases', r.org, 'purchase_credit_note', 'PCN-EARLY',
                   pg_temp.today() - 10, r.both_c, r.item, 100, r.bill_today, false);
  r.pcn_onday := pg_temp.na_doc('purchases', r.org, 'purchase_credit_note', 'PCN-ONDAY',
                   pg_temp.today(), r.both_c, r.item, 100, r.bill_today, false);
  insert into t_na select r.*;
end $$;

select pg_temp.sign_in_as((select accountant from t_na));
set local role authenticated;

do $$
declare d t_na; v uuid;
begin
  select * into d from t_na;

  -- -------------------------------------------------------------------
  -- Typed by hand: not before what it names
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a credit note dated before its invoice is not posted',
    format('select public.post_sales_document(%L)', d.cn_early),
    'CN-EARLY is dated %, before INV-1 which it adjusts (dated %). A note cannot come before the invoice it adjusts.',
    '23514');
  perform pg_temp.check_eq('so it stays a draft',
    pg_temp.na_state('sales', d.cn_early), (pg_temp.today() - 10) || ' unposted');
  perform public.post_sales_document(d.cn_onday);
  perform pg_temp.check_eq('one dated the invoice''s own day posts',
    pg_temp.na_state('sales', d.cn_onday), pg_temp.today() || ' posted');
  -- The mutant that drops `original_invoice_id is not null` lives, and
  -- is equivalent: with no invoice named, the subquery is null, and a
  -- date compared with null is never "before" it, so nothing is raised
  -- either way. The test reads as the rule; the outcome is the same.
  perform public.post_sales_document(d.cn_loose);
  perform pg_temp.check_eq('and one that names no invoice is not asked',
    pg_temp.na_state('sales', d.cn_loose), (pg_temp.today() - 10) || ' posted');

  perform pg_temp.check_refused('a purchase credit note dated before its bill is not posted',
    format('select public.post_purchase_document(%L)', d.pcn_early),
    'PCN-EARLY is dated %, before BILL-1 which it adjusts (dated %). A note cannot come before the bill it adjusts.',
    '23514');
  perform public.post_purchase_document(d.pcn_onday);
  perform pg_temp.check_eq('one dated the bill''s own day posts',
    pg_temp.na_state('purchases', d.pcn_onday), pg_temp.today() || ' posted');

  -- -------------------------------------------------------------------
  -- "Credit this": on the original's day if that is still to come
  -- -------------------------------------------------------------------
  v := public.credit_sales_invoice(d.inv_ahead, null, 'Tersilap');
  perform pg_temp.check_eq('an invoice dated ahead is credited on its own day',
    pg_temp.na_state('sales', v), (pg_temp.today() + 20) || ' posted');
  v := public.credit_sales_invoice(d.inv_past, null, 'Tersilap');
  perform pg_temp.check_eq('one already dated is credited today, as before',
    pg_temp.na_state('sales', v), pg_temp.today() || ' posted');
  v := public.credit_purchase_bill(d.bill_ahead, null, 'Tersilap');
  perform pg_temp.check_eq('a bill dated ahead is credited on its own day',
    pg_temp.na_state('purchases', v), (pg_temp.today() + 20) || ' posted');
  v := public.credit_purchase_bill(d.bill_past, null, 'Tersilap');
  perform pg_temp.check_eq('one already dated is credited today, as before',
    pg_temp.na_state('purchases', v), pg_temp.today() || ' posted');
end $$;

reset role;

rollback;
