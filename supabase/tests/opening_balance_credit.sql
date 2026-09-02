-- =====================================================================
-- iAkauntan :: an opening balance is not a new sale
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/opening_balance_credit.sql
--
-- `import_open_invoices` says in a comment that the way it posts keeps
-- the credit-limit trigger out of it. Measured before 0466, it did not:
-- a customer on credit hold could not have a single line of their
-- history brought over, and one whose old debt exceeded their limit was
-- refused with advice about raising the limit or taking a payment.
--
-- What is asserted here is both halves — the exemption, and that it is
-- an exemption for opening balances and not a hole in the credit rule.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.ob_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid := pg_temp.test_org(p_name);
begin
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Service', 'service', false, 100);
  return v_org;
end $$;

create or replace function pg_temp.ob_import(
  p_org uuid, p_code text, p_no text, p_amount numeric)
returns text language plpgsql as $$
declare v_msg text;
begin
  perform * from public.import_open_invoices(
    p_org,
    jsonb_build_array(jsonb_build_object(
      'contact_code', p_code, 'doc_no', p_no,
      'doc_date', to_char(current_date - 200, 'YYYY-MM-DD'),
      'due_date',  to_char(current_date - 170, 'YYYY-MM-DD'),
      'outstanding_amount', p_amount::text)),
    current_date, true);
  return 'ok';
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

-- ---------------------------------------------------------------------
-- The customer whose history you are most likely to be migrating
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_c   uuid;
  v_out text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ob_org('Baki Awal Sdn Bhd');

  -- On hold, small limit, five thousand of old debt. Every part of that
  -- is what makes somebody worth migrating carefully.
  insert into public.contacts (org_id, code, name, contact_type,
                               credit_limit, credit_hold)
  values (v_org, 'C', 'Pelanggan Lambat', 'customer', 1000, true)
  returning id into v_c;

  v_out := pg_temp.ob_import(v_org, 'C', 'OLD-1', 5000);
  perform pg_temp.check_eq(
    'a customer on credit hold can still have their history brought over',
    v_out, 'ok');

  perform pg_temp.check_eq('and it is in the books',
    (select balance_amount from public.sales_documents
      where org_id = v_org and doc_no = 'OLD-1'), 5000::numeric);
  perform pg_temp.check_eq('as an opening balance, not a sale',
    (select e.source::text from public.gl_entries e
       join public.sales_documents d on d.gl_entry_id = e.id
      where d.org_id = v_org and d.doc_no = 'OLD-1'), 'opening_balance');

  -- And with the arithmetic switched on rather than the flag.
  update public.contacts set credit_hold = false where id = v_c;
  update public.organizations set credit_control = 'block' where id = v_org;

  v_out := pg_temp.ob_import(v_org, 'C', 'OLD-2', 5000);
  perform pg_temp.check_eq(
    'and a limit smaller than the debt does not refuse it either',
    v_out, 'ok');
  perform pg_temp.check_eq('so the receivable is what they actually owe',
    (select round(sum(balance_amount), 2) from public.sales_documents
      where org_id = v_org and contact_id = v_c), 10000::numeric);
end $$;

-- ---------------------------------------------------------------------
-- And it is an exemption, not a hole
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_c    uuid;
  v_doc  uuid;
  v_msg  text;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.ob_org('Jual Baru Sdn Bhd');
  update public.organizations set credit_control = 'block' where id = v_org;

  insert into public.contacts (org_id, code, name, contact_type,
                               credit_limit, credit_hold)
  values (v_org, 'C', 'Pelanggan Baru', 'customer', 1000, false)
  returning id into v_c;

  -- Their history comes over, all five thousand of it.
  perform pg_temp.check_eq('history first',
    pg_temp.ob_import(v_org, 'C', 'OLD-9', 5000), 'ok');

  -- A new invoice today is a new sale, and the limit is the limit. If
  -- the exemption were keyed off anything the caller controls — a note,
  -- a date, a flag on the document — this is where it would leak.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, notes)
  values (v_org, 'invoice', 'NEW-1', current_date, current_date, v_c,
          'draft', 'MYR', 1, 'Opening balance brought forward on today')
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_doc, 1, 'item',
          (select id from public.items where org_id = v_org and code = 'SVC'),
          'Work done today', 1, 200);

  begin
    perform public.post_sales_document(v_doc);
    v_took := true;
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a new sale is still held to the limit, whatever the notes say',
    not v_took);
  perform pg_temp.check_true('and the refusal is the credit one',
    v_msg like '%against a credit limit of%');

  -- The hold as well.
  update public.contacts set credit_hold = true where id = v_c;
  update public.organizations set credit_control = 'warn' where id = v_org;
  begin
    perform public.post_sales_document(v_doc);
    v_took := true;
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true('and a customer on hold is still on hold',
    not v_took and v_msg like '%on credit hold%');
end $$;

rollback;
