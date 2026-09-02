-- =====================================================================
-- iAkauntan :: one company, one record per role
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/contact_records.sql
--
-- The instruction 0477 was written to:
--
--     Al Hardware Sdn Bhd   supplier   S-2026-00001
--     Al Hardware Sdn Bhd   customer   C-2026-00013
--     Al Hardware Sdn Bhd   prospect   P-2026-00343
--
-- A supplier who starts buying from you is not retyped; a second record
-- is made, coded in the customer series, and the supplier record goes
-- on carrying its bills under its own code. What is asserted is each
-- half of that -- the series, the copy, the record that was not
-- touched, the link between them -- and the refusals around it.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- `create_contact_as` as the new record's code, or the reason it was
-- refused.
create or replace function pg_temp.cr_make(p_id uuid, p_as text)
returns text language plpgsql as $$
declare v_new uuid; v_msg text;
begin
  v_new := public.create_contact_as(p_id, p_as::app.contact_type);
  return (select code from public.contacts where id = v_new);
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

create or replace function pg_temp.cr_retype(p_id uuid, p_to text)
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

-- One option out of `contact_records`: the code of the record that
-- already fills the role, or 'open' when nothing does.
create or replace function pg_temp.cr_option(p_id uuid, p_as text)
returns text language sql stable as $$
  select coalesce(o -> 'existing' ->> 'code', 'open')
    from jsonb_array_elements(
           public.contact_records(p_id) -> 'options') o
   where o ->> 'as' = p_as;
$$;

-- ---------------------------------------------------------------------
-- The series
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_yr text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Nombor Siri Sdn Bhd');
  v_yr := to_char(app.today(), 'YYYY');

  perform pg_temp.check_eq('a customer is coded C-',
    public.next_contact_code(v_org, 'customer'), 'C-' || v_yr || '-00001');
  perform pg_temp.check_eq('a supplier record is coded S-',
    public.next_contact_code(v_org, 'supplier'), 'S-' || v_yr || '-00001');
  perform pg_temp.check_eq('a prospect is coded P-',
    public.next_contact_code(v_org, 'prospect'), 'P-' || v_yr || '-00001');

  -- Three counters, not one with three letters on it.
  perform pg_temp.check_eq('each series counts on its own',
    public.next_contact_code(v_org, 'supplier'), 'S-' || v_yr || '-00002');
  perform pg_temp.check_eq('and the customer series has not moved for it',
    public.next_contact_code(v_org, 'customer'), 'C-' || v_yr || '-00002');
  perform pg_temp.check_eq('Both is numbered among the customers',
    public.next_contact_code(v_org, 'both'), 'C-' || v_yr || '-00003');
end $$;

-- ---------------------------------------------------------------------
-- Al Hardware Sdn Bhd
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_yr   text;
  v_cust uuid;
  v_sup  uuid;
  v_pro  uuid;
  v_item uuid;
  v_doc  uuid;
  v_old  public.contacts;
  v_new  public.contacts;
  v_r    jsonb;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Perkakasan Sdn Bhd');
  v_yr := to_char(app.today(), 'YYYY');
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, unit_price)
  values (v_org, 'SVC', 'Service', 'service', false, 100)
  returning id into v_item;

  -- The customer record, as it was filed: a code from the C- series,
  -- the company's particulars, and the terms it is sold on.
  insert into public.contacts (
    org_id, code, name, contact_type, legal_name, tin, registration_no,
    email, phone, address_line1, city, postcode, state_code, currency,
    credit_limit, credit_hold, discount_percent, tags, notes)
  values (
    v_org, 'C-' || v_yr || '-00007', 'Al Hardware Sdn Bhd', 'customer',
    'AL HARDWARE SDN. BHD.', 'C12345678900', '202001012345',
    'akaun@alhardware.test', '03-12345678', '12 Jalan Besi', 'Klang',
    '41000', '10', 'MYR',
    5000, true, 5, array['hardware'], 'Pays by the 15th')
  returning id into v_cust;

  insert into public.contact_addresses
    (org_id, contact_id, label, address_type, address_line1, city,
     postcode, state_code, is_default)
  values (v_org, v_cust, 'Delivery', 'shipping', 'Lot 3 Kawasan Perindustrian',
          'Klang', '41200', '10', true);
  insert into public.contact_persons
    (org_id, contact_id, name, designation, email, is_primary)
  values (v_org, v_cust, 'Encik Ali', 'Director', 'ali@alhardware.test', true);

  -- And an invoice on it, which is the thing that must stay put.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'invoice', 'INV-AH1', current_date, current_date, v_cust,
          'draft', 'MYR', 1)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Something sold', 1, 500);

  -- Before: the screen sees one record, and two roles open.
  v_r := public.contact_records(v_cust);
  perform pg_temp.check_eq('a company with one record has no others to show',
    jsonb_array_length(v_r -> 'records'), 0);
  perform pg_temp.check_eq('the customer role is filled by this record',
    pg_temp.cr_option(v_cust, 'customer'), 'C-' || v_yr || '-00007');
  perform pg_temp.check_eq('the supplier role is open',
    pg_temp.cr_option(v_cust, 'supplier'), 'open');
  perform pg_temp.check_eq('and would be coded S-',
    (select o ->> 'prefix' from jsonb_array_elements(v_r -> 'options') o
      where o ->> 'as' = 'supplier'), 'S-');

  -- ------------------------------------------------------------------
  -- They start selling to you
  -- ------------------------------------------------------------------
  v_sup := public.create_contact_as(v_cust, 'supplier');
  select * into v_new from public.contacts where id = v_sup;
  select * into v_old from public.contacts where id = v_cust;

  perform pg_temp.check_eq('a supplier record is coded S-',
    v_new.code, 'S-' || v_yr || '-00001');
  perform pg_temp.check_eq('and it is a supplier',
    v_new.contact_type::text, 'supplier');
  perform pg_temp.check_true('a new record, not the old one renamed',
    v_sup <> v_cust);

  -- The correction 0477 was about. 0476 would have retyped this row.
  perform pg_temp.check_eq('the customer record is still there, still C-',
    v_old.code, 'C-' || v_yr || '-00007');
  perform pg_temp.check_eq('still a customer',
    v_old.contact_type::text, 'customer');
  perform pg_temp.check_eq('and its invoice stays where it was',
    (select contact_id from public.sales_documents where id = v_doc),
    v_cust);

  -- One company: both records point at the first.
  perform pg_temp.check_eq('the customer record knows its supplier record',
    v_new.party_id, v_cust);
  perform pg_temp.check_eq('and the supplier record knows its customer record',
    v_old.party_id, v_cust);

  -- The company's particulars are the company's.
  perform pg_temp.check_eq('the name comes along', v_new.name, v_old.name);
  perform pg_temp.check_eq('the TIN', v_new.tin, 'C12345678900');
  perform pg_temp.check_eq('the registration number',
    v_new.registration_no, '202001012345');
  perform pg_temp.check_eq('the address', v_new.address_line1, '12 Jalan Besi');
  perform pg_temp.check_eq('the tags', array_to_string(v_new.tags, ','),
    'hardware');
  perform pg_temp.check_eq('the delivery address comes along',
    (select count(*) from public.contact_addresses
      where contact_id = v_sup and label = 'Delivery'
        and address_line1 = 'Lot 3 Kawasan Perindustrian'), 1);
  perform pg_temp.check_eq('and the people',
    (select string_agg(name, ',') from public.contact_persons
      where contact_id = v_sup and is_primary), 'Encik Ali');
  perform pg_temp.check_eq('while the old record keeps its own',
    (select count(*) from public.contact_persons where contact_id = v_cust), 1);

  -- The terms you sell on are not the terms you buy on.
  perform pg_temp.check_eq('and the credit terms do not',
    v_new.credit_limit, 0);
  perform pg_temp.check_true('nor the hold', not v_new.credit_hold);
  perform pg_temp.check_eq('nor the discount', v_new.discount_percent, 0);

  -- After: each record shows the other.
  v_r := public.contact_records(v_cust);
  perform pg_temp.check_eq('the customer record lists its supplier record',
    (select string_agg(r ->> 'code', ',') from jsonb_array_elements(
       v_r -> 'records') r), 'S-' || v_yr || '-00001');
  perform pg_temp.check_eq('and the supplier record lists its customer record',
    (select string_agg(r ->> 'code', ',') from jsonb_array_elements(
       public.contact_records(v_sup) -> 'records') r),
    'C-' || v_yr || '-00007');
  perform pg_temp.check_eq('the supplier role is now filled',
    pg_temp.cr_option(v_cust, 'supplier'), 'S-' || v_yr || '-00001');
  perform pg_temp.check_eq('seen from either record',
    pg_temp.cr_option(v_sup, 'customer'), 'C-' || v_yr || '-00007');

  -- ------------------------------------------------------------------
  -- One record per role
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('a second supplier record is refused',
    pg_temp.cr_make(v_cust, 'supplier') like '%already has a supplier record%');
  perform pg_temp.check_true('from the supplier record too',
    pg_temp.cr_make(v_sup, 'supplier') like '%already has a supplier record%');
  perform pg_temp.check_true('and a second customer record, from the supplier one',
    pg_temp.cr_make(v_sup, 'customer') like '%already has a customer record%');
  perform pg_temp.check_eq('with no third record made by the attempts',
    (select count(*) from public.contacts
      where org_id = v_org and party_id = v_cust), 2);

  -- ------------------------------------------------------------------
  -- A prospect record, made from the second record
  -- ------------------------------------------------------------------
  v_pro := public.create_contact_as(v_sup, 'prospect');
  select * into v_new from public.contacts where id = v_pro;
  perform pg_temp.check_eq('a prospect record is coded P-',
    v_new.code, 'P-' || v_yr || '-00001');
  perform pg_temp.check_eq('and belongs to the same company as the first record',
    v_new.party_id, v_cust);
  perform pg_temp.check_eq('so all three see each other',
    jsonb_array_length(public.contact_records(v_pro) -> 'records'), 2);
  perform pg_temp.check_eq('and nothing is left open',
    pg_temp.cr_option(v_pro, 'prospect'), 'P-' || v_yr || '-00001');

  -- ------------------------------------------------------------------
  -- What a record is created as
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('a record is created as one role, not Both',
    pg_temp.cr_make(v_cust, 'both') like '%customer, a supplier or a prospect%');
  perform pg_temp.check_true('and not as an employee',
    pg_temp.cr_make(v_cust, 'employee') like '%customer, a supplier or a prospect%');

  -- ------------------------------------------------------------------
  -- 0476's rule, pointing at the new remedy
  -- ------------------------------------------------------------------
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'bill', 'BILL-AH1', current_date, current_date, v_sup,
          'draft', 'MYR', 1)
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_doc, 1, 'item', v_item, 'Something bought', 1, 500);

  perform pg_temp.check_true(
    'a supplier with bills is still not retyped to customer',
    pg_temp.cr_retype(v_sup, 'customer') like '%still trading as a supplier%');
  perform pg_temp.check_true('and the refusal says to make a separate record',
    pg_temp.cr_retype(v_sup, 'customer')
      like '%create a separate customer record%');
end $$;

-- ---------------------------------------------------------------------
-- A code typed by hand, sitting where the series lands next
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_yr text; v_c uuid; v_both uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Kod Tangan Sdn Bhd');
  v_yr := to_char(app.today(), 'YYYY');

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'KB', 'Kedai Baru', 'customer') returning id into v_c;
  -- Somebody else's supplier, filed by hand with the series' first code,
  -- after the counter was last moved.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-' || v_yr || '-00001', 'Pembekal Tangan', 'supplier');

  perform pg_temp.check_eq('a code typed by hand does not block the series',
    pg_temp.cr_make(v_c, 'supplier'), 'S-' || v_yr || '-00002');
  perform pg_temp.check_eq('and the counter is left past it',
    public.next_contact_code(v_org, 'supplier'), 'S-' || v_yr || '-00003');

  -- A record typed Both already stands for two roles.
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'DH', 'Dua Hala', 'both') returning id into v_both;
  perform pg_temp.check_true('a Both record already fills the customer role',
    pg_temp.cr_make(v_both, 'customer') like '%already has a customer record%');
  perform pg_temp.check_true('and the supplier role',
    pg_temp.cr_make(v_both, 'supplier') like '%already has a supplier record%');
  perform pg_temp.check_eq('and is offered neither',
    pg_temp.cr_option(v_both, 'customer') || ' ' ||
    pg_temp.cr_option(v_both, 'supplier'), 'DH DH');
  perform pg_temp.check_eq('but a prospect record is not either of those',
    pg_temp.cr_make(v_both, 'prospect'), 'P-' || v_yr || '-00001');
end $$;

-- ---------------------------------------------------------------------
-- Who may
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_c      uuid;
  v_viewer uuid;
  v_took   boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.test_org('Milik Orang Lain Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'X', 'Bukan Anda', 'customer') returning id into v_c;

  -- A member who may only read.
  v_viewer := pg_temp.another_user('lihat@rekod.test');
  insert into public.org_members (org_id, user_id, role, status, joined_at)
  values (v_org, v_viewer, 'viewer', 'active', now());
  perform pg_temp.sign_in_as(v_viewer);

  perform pg_temp.check_true('somebody who may only read may look',
    public.contact_records(v_c) ->> 'code' = 'X');
  perform pg_temp.check_eq('but somebody who may only read cannot',
    pg_temp.cr_make(v_c, 'supplier'), 'Insufficient privileges');
  perform pg_temp.check_eq('and no record was made',
    (select count(*) from public.contacts where org_id = v_org), 1);

  -- A stranger.
  perform pg_temp.sign_in_as(pg_temp.another_user('luar@rekod.test'));
  begin
    perform public.contact_records(v_c);
    v_took := true;
  exception when sqlstate '42501' then
    v_took := false;
  end;
  perform pg_temp.check_true(
    'a stranger is not shown somebody else''s records', not v_took);
  perform pg_temp.check_eq('nor allowed to make one',
    pg_temp.cr_make(v_c, 'supplier'), 'Insufficient privileges');
end $$;

rollback;
