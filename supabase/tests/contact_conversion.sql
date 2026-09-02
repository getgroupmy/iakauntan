-- =====================================================================
-- iAkauntan :: a contact can change what it is
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_conversion.sql
--
-- A supplier starts selling to you; a prospect places an order. What is
-- asserted here is that saying so is easy, and that the one way of
-- saying it that would quietly break something is refused.
--
-- That one way: the customer picker asks for `customer` and `both`, the
-- supplier picker for `supplier` and `both`. Retype a supplier with open
-- bills to `customer` and the bills stop appearing where they are paid.
-- Nothing errors. The money is just unreachable.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.cc_retype(p_id uuid, p_to text)
returns text language plpgsql as $$
declare v_msg text;
begin
  update public.contacts set contact_type = p_to::app.contact_type
   where id = p_id;
  return 'ok';
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

-- One option out of the advisory, as "allowed" or the reason it is not.
create or replace function pg_temp.cc_option(p_id uuid, p_to text)
returns text language sql stable as $$
  select case when (o ->> 'allowed')::boolean then 'allowed'
              else 'blocked by ' || coalesce(o ->> 'blocked_by', '?') end
    from jsonb_array_elements(
           public.contact_conversions(p_id) -> 'options') o
   where o ->> 'to' = p_to;
$$;

do $$
declare
  v_org  uuid;
  v_prospect uuid;
  v_supplier uuid;
  v_customer uuid;
  v_item uuid;
  v_doc  uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Tukar Jenis Sdn Bhd');
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Service', 'service', false, 100)
  returning id into v_item;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'P', 'Bakal Pelanggan', 'prospect'),
         (v_org, 'S', 'Pembekal Lama', 'supplier'),
         (v_org, 'C', 'Pelanggan Lama', 'customer');
  select id into v_prospect from public.contacts
   where org_id = v_org and code = 'P';
  select id into v_supplier from public.contacts
   where org_id = v_org and code = 'S';
  select id into v_customer from public.contacts
   where org_id = v_org and code = 'C';

  -- ------------------------------------------------------------------
  -- A prospect, which has traded with nobody, may become anything
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a prospect can be made a customer',
    pg_temp.cc_retype(v_prospect, 'customer'), 'ok');
  perform pg_temp.check_eq('and back again, having still sold nothing',
    pg_temp.cc_retype(v_prospect, 'prospect'), 'ok');
  perform pg_temp.check_eq('a prospect can be made a supplier',
    pg_temp.cc_retype(v_prospect, 'supplier'), 'ok');
  perform pg_temp.check_eq('and the screen was offered both',
    pg_temp.cc_option(v_prospect, 'customer'), 'allowed');

  -- ------------------------------------------------------------------
  -- A supplier with nothing on the books is just as free
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a supplier with no bills can become a customer',
    pg_temp.cc_retype(v_supplier, 'customer'), 'ok');
  perform pg_temp.check_eq('and a prospect, having bought nothing from them',
    pg_temp.cc_retype(v_supplier, 'prospect'), 'ok');
  perform pg_temp.check_eq('and back to a supplier',
    pg_temp.cc_retype(v_supplier, 'supplier'), 'ok');

  -- ------------------------------------------------------------------
  -- Now give the supplier a bill, and the answer changes
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'bill', 'BILL-1', current_date, current_date, v_supplier,
          'draft', 'MYR', 1)
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Something bought', 1, 500);

  -- The assertion this whole migration is for.
  perform pg_temp.check_true(
    'a supplier with bills cannot be made customer-only',
    pg_temp.cc_retype(v_supplier, 'customer')
      like '%still trading as a supplier%');
  perform pg_temp.check_eq('and the screen is not offered what the '
    'trigger will refuse',
    pg_temp.cc_option(v_supplier, 'customer'), 'blocked by ["supplier"]');

  -- Their own assertion: prospect drops both roles, so it is refused
  -- for the same reason -- but a trigger written to look only at
  -- `prospect` would pass the one above and fail here.
  perform pg_temp.check_true(
    'and somebody you have bought from is not a prospect',
    pg_temp.cc_retype(v_supplier, 'prospect')
      like '%still trading as a supplier%');

  -- The refusal has to point somewhere. `both` is the answer, so it has
  -- to be offered *and* work, or the message is a dead end. Asked
  -- before the change, because the advisory does not offer a contact
  -- the type it already is.
  perform pg_temp.check_eq('while Both is offered',
    pg_temp.cc_option(v_supplier, 'both'), 'allowed');
  perform pg_temp.check_eq('and, taking nothing away, works',
    pg_temp.cc_retype(v_supplier, 'both'), 'ok');

  -- ------------------------------------------------------------------
  -- The same, the other way round
  -- ------------------------------------------------------------------
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_customer,
          'draft', 'MYR', 1)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Something sold', 1, 500);

  perform pg_temp.check_true(
    'a customer with invoices cannot be made supplier-only',
    pg_temp.cc_retype(v_customer, 'supplier')
      like '%still trading as a customer%');
  perform pg_temp.check_eq('but can be made Both',
    pg_temp.cc_retype(v_customer, 'both'), 'ok');

  -- And once they are Both, with history on one side only, dropping to
  -- the side they actually use is allowed. This is the case a rule
  -- written as "you may never narrow a type" would get wrong.
  perform pg_temp.check_eq(
    'and narrowed back to the side they actually trade on',
    pg_temp.cc_retype(v_customer, 'customer'), 'ok');

  -- ------------------------------------------------------------------
  -- What a void document is worth
  -- ------------------------------------------------------------------
  --
  -- Nothing. A cancelled invoice is not a trading relationship, and
  -- counting one would strand a contact somebody created by mistake.
  update public.sales_documents set status = 'void'
   where org_id = v_org and doc_no = 'INV-1';
  perform pg_temp.check_eq('a voided invoice holds nobody to being a customer',
    pg_temp.cc_retype(v_customer, 'supplier'), 'ok');
end $$;

-- ---------------------------------------------------------------------
-- Somebody else's contact
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_c uuid; v_took boolean; v_msg text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Milik Orang Lain Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'X', 'Bukan Anda', 'customer') returning id into v_c;

  perform pg_temp.sign_in_as(pg_temp.another_user('luar@tukar.test'));
  begin
    perform public.contact_conversions(v_c);
    v_took := true;
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a stranger is not told what somebody else''s contact could become',
    not v_took);
end $$;

rollback;
