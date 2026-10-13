-- =====================================================================
-- iAkauntan :: each side writes its own (0878)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/each_side_writes_its_own.sql
--
-- A purchaser raised sales invoices and a salesperson supplier bills.
-- Each writes its own side now, reads both, and an access type is how a
-- company lets one person do both. Asked with the role `authenticated`,
-- as the app asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_es (org uuid, seller uuid, buyer uuid, both_sides uuid,
  accountant uuid, customer uuid, supplier uuid, invoice uuid, bill uuid);
grant select on t_es to authenticated;

do $$
declare r t_es; v_type uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Dua Belah Sdn Bhd');
  r.seller     := pg_temp.another_user('jual@duabelah.test');
  r.buyer      := pg_temp.another_user('beli@duabelah.test');
  r.both_sides := pg_temp.another_user('kedua@duabelah.test');
  r.accountant := pg_temp.another_user('akaun@duabelah.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (r.org, r.seller, 'sales', 'active'),
         (r.org, r.buyer, 'purchaser', 'active'),
         (r.org, r.both_sides, 'purchaser', 'active'),
         (r.org, r.accountant, 'accountant', 'active');

  -- A purchaser the company has given the sales side as well.
  insert into public.access_types (org_id, name)
  values (r.org, 'Buys and sells') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'sales', 'write'), (v_type, 'purchases', 'write'),
         (v_type, 'contacts', 'write');
  update public.org_members set access_type_id = v_type
   where org_id = r.org and user_id = r.both_sides;

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C1', 'Pelanggan', 'customer') returning id into r.customer;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'S1', 'Pembekal', 'supplier') returning id into r.supplier;
  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id)
  values (r.org, 'invoice', 'INV-1', r.customer) returning id into r.invoice;
  insert into public.purchase_documents (org_id, doc_type, doc_no, contact_id)
  values (r.org, 'bill', 'BILL-1', r.supplier) returning id into r.bill;
  insert into t_es select r.*;
end $$;

-- ---------------------------------------------------------------------
-- The purchaser: the purchases side, and not the sales side
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select buyer from t_es));
set local role authenticated;

do $$
declare d t_es;
begin
  select * into d from t_es;
  perform pg_temp.check_refused('a purchaser raises no invoice',
    format($q$insert into public.sales_documents (org_id, doc_type, doc_no, contact_id)
              values (%L, 'invoice', 'INV-B', %L)$q$, d.org, d.customer),
    'A purchaser does not write sales documents or receipts.%', '42501');
  perform pg_temp.check_refused('nor changes one',
    format('update public.sales_documents set notes = %L where id = %L', 'x', d.invoice),
    'A purchaser does not write sales documents%', '42501');
  perform pg_temp.check_refused('nor adds a line to it',
    format('insert into public.sales_document_lines (org_id, document_id, line_no) values (%L, %L, 1)',
           d.org, d.invoice),
    'A purchaser does not write sales documents%', '42501');
  perform pg_temp.check_eq('and still reads it',
    (select doc_no from public.sales_documents where id = d.invoice), 'INV-1');

  insert into public.purchase_documents (org_id, doc_type, doc_no, contact_id)
  values (d.org, 'purchase_order', 'PO-B', d.supplier);
  insert into public.purchase_document_lines (org_id, document_id, line_no)
  values (d.org, d.bill, 1);
  perform pg_temp.check_eq('and writes the purchases side: an order, a line on the bill',
    (select count(*) from public.purchase_documents where org_id = d.org and doc_no = 'PO-B') || ' / '
      || (select count(*) from public.purchase_document_lines where document_id = d.bill),
    '1 / 1');
end $$;

reset role;

-- ---------------------------------------------------------------------
-- The salesperson: the reverse
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select seller from t_es));
set local role authenticated;

do $$
declare d t_es;
begin
  select * into d from t_es;
  perform pg_temp.check_refused('a salesperson raises no bill',
    format($q$insert into public.purchase_documents (org_id, doc_type, doc_no, contact_id)
              values (%L, 'bill', 'BILL-S', %L)$q$, d.org, d.supplier),
    'A salesperson does not write purchase documents or supplier payments.%', '42501');
  perform pg_temp.check_refused('nor deletes one',
    format('delete from public.purchase_documents where id = %L', d.bill),
    'A salesperson does not write purchase documents%', '42501');
  perform pg_temp.check_eq('and still reads it',
    (select doc_no from public.purchase_documents where id = d.bill), 'BILL-1');

  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id)
  values (d.org, 'invoice', 'INV-S', d.customer);
  perform pg_temp.check_eq('and raises an invoice',
    (select count(*) from public.sales_documents where org_id = d.org and doc_no = 'INV-S')::int, 1);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- An access type decides instead; a writer of both writes both
-- ---------------------------------------------------------------------
select pg_temp.sign_in_as((select both_sides from t_es));
set local role authenticated;

do $$
declare d t_es;
begin
  select * into d from t_es;
  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id)
  values (d.org, 'invoice', 'INV-K', d.customer);
  perform pg_temp.check_eq('a purchaser given the sales side by an access type raises an invoice',
    (select count(*) from public.sales_documents where org_id = d.org and doc_no = 'INV-K')::int, 1);
end $$;

reset role;

select pg_temp.sign_in_as((select accountant from t_es));
set local role authenticated;

do $$
declare d t_es;
begin
  select * into d from t_es;
  insert into public.sales_documents (org_id, doc_type, doc_no, contact_id)
  values (d.org, 'invoice', 'INV-A', d.customer);
  insert into public.purchase_documents (org_id, doc_type, doc_no, contact_id)
  values (d.org, 'bill', 'BILL-A', d.supplier);
  perform pg_temp.check_eq('and an accountant writes both, as before',
    (select count(*) from public.sales_documents where org_id = d.org and doc_no = 'INV-A') || ' / '
      || (select count(*) from public.purchase_documents where org_id = d.org and doc_no = 'BILL-A'),
    '1 / 1');
end $$;

reset role;

-- And the six tables carry the trigger, each for its own side.
do $$
begin
  perform pg_temp.check_eq('each side''s documents, lines and payments carry the guard',
    (select string_agg(c.relname || ':'
                       || substring(pg_get_triggerdef(t.oid)
                                    from 'each_side_writes_its_own\(''(\w+)''\)'),
                       ', ' order by c.relname)
       from pg_trigger t join pg_class c on c.oid = t.tgrelid
      where t.tgname = 'each_side_writes_its_own'),
    'purchase_document_lines:purchases, purchase_documents:purchases, '
    || 'purchase_payments:purchases, receipts:sales, sales_document_lines:sales, '
    || 'sales_documents:sales');
end $$;

rollback;
