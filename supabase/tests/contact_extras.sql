-- =====================================================================
-- iAkauntan :: contact people and delivery address tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_extras.sql
--
-- `contact_persons` and `contact_addresses` were empty and unreachable
-- while `sales_documents.contact_person_id` and `.shipping_address_id`
-- were being carried through the transfer path and read by the
-- e-Invoice preparation — an invoice could point at a delivery address
-- that no screen was able to create.
--
-- What is asserted here is the invariant 0092 added, because it is the
-- one thing that fails quietly: `is_primary` and `is_default` were
-- plain booleans, so nothing stopped two rows carrying them. Two
-- defaults is the same as none — whichever row a query returns first
-- wins, and what it decides is where goods get delivered.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org uuid := pg_temp.test_org('Contact Extras Sdn Bhd');
  v_contact uuid; v_other uuid;
  v_aishah uuid; v_ravi uuid;
  v_warehouse uuid; v_office uuid;
begin
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-001', 'Buyer Bhd', 'customer')
  returning id into v_contact;

  insert into public.contact_persons (org_id, contact_id, name, is_primary)
  values (v_org, v_contact, 'Aishah', true) returning id into v_aishah;
  insert into public.contact_persons (org_id, contact_id, name, is_primary)
  values (v_org, v_contact, 'Ravi', false) returning id into v_ravi;

  begin
    update public.contact_persons set is_primary = true where id = v_ravi;
    raise exception 'FAIL: a contact was given two main people';
  exception when unique_violation then
    raise notice 'ok   a second main contact is refused';
  end;

  -- The path the app takes: clear the flag everywhere, then set it. The
  -- index has to permit that, or handing over the main contact would be
  -- impossible rather than merely unambiguous.
  update public.contact_persons set is_primary = false
   where contact_id = v_contact;
  update public.contact_persons set is_primary = true where id = v_ravi;
  perform pg_temp.check_eq('handing over leaves exactly one',
    (select count(*) from public.contact_persons
      where contact_id = v_contact and is_primary), 1);
  perform pg_temp.check_true('and it is the new one',
    (select is_primary from public.contact_persons where id = v_ravi));
  perform pg_temp.check_true('not the old one',
    (select not is_primary from public.contact_persons where id = v_aishah));

  insert into public.contact_addresses (org_id, contact_id, label, is_default)
  values (v_org, v_contact, 'Warehouse', true) returning id into v_warehouse;
  insert into public.contact_addresses (org_id, contact_id, label, is_default)
  values (v_org, v_contact, 'Head office', false) returning id into v_office;

  begin
    update public.contact_addresses set is_default = true where id = v_office;
    raise exception 'FAIL: a contact was given two default addresses';
  exception when unique_violation then
    raise notice 'ok   a second default address is refused';
  end;

  -- Per contact, not per organization: every customer has their own
  -- default and they do not compete.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-002', 'Other Bhd', 'customer')
  returning id into v_other;
  insert into public.contact_addresses (org_id, contact_id, label, is_default)
  values (v_org, v_other, 'Site office', true);
  perform pg_temp.check_eq('two customers, two defaults',
    (select count(*) from public.contact_addresses
      where org_id = v_org and is_default), 2);

  -- And the columns that made these tables matter in the first place
  -- accept them.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate,
     subtotal, total_amount, balance_amount, status,
     contact_person_id, shipping_address_id)
  values (v_org, 'invoice', 'INV-1', current_date, v_contact, 'MYR', 1,
          100, 100, 100, 'draft', v_ravi, v_warehouse);

  perform pg_temp.check_true('an invoice can name a person and an address',
    (select contact_person_id = v_ravi and shipping_address_id = v_warehouse
       from public.sales_documents
      where org_id = v_org and doc_no = 'INV-1'));
end $$;

rollback;
