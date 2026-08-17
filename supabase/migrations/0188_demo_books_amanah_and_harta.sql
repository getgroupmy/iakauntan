-- The other two demo tenants get their books.
--
-- `0187` filled Sinar Teknologi in. This does Amanah Setiausaha, a
-- company secretarial practice, and Harta Prima, a property manager —
-- and folds both into `app.demo_rebuild()` so the whole demo is still
-- one call.
--
-- Both earn fees rather than sell goods, so neither carries stock and
-- both invoice for services. That is the point of having three tenants:
-- Sinar shows a trading business with a costing engine behind it, and
-- these two show what the rest of the product looks like when there is
-- no warehouse in sight.
--
-- ## Amanah: a practice, and the companies it acts for
--
-- The client entities are the module's whole reason to exist — a
-- corporate secretarial firm's work is other people's statutory
-- records. So each one carries officers appointed on the day it was
-- incorporated, a share class, and an allotment, because
-- `corp_share_events` is what the register of members is computed from
-- and an entity without them shows an empty register.
--
-- The people are `corp_persons` rather than `contacts`. They are
-- directors and secretaries of client companies, not customers of
-- Amanah, and the distinction matters to every screen in the module.
-- One of them — Nurul Hakim — is the practice's own licensed secretary
-- and holds that office in all three clients, which is what a firm is
-- engaged to do.
--
-- ## Harta Prima: one strata scheme and one commercial block
--
-- `tenure` splits the property module in two and the two halves share
-- almost nothing. A strata scheme has parcels with share units and
-- raises maintenance charges against them; a non-strata block has
-- tenancies and collects rent. One demo tenant carrying both is
-- ordinary for a managing agent and is the only way to show the two
-- side by side.
--
-- The parcels' share units are unequal and sum to the scheme's
-- `total_share_units` exactly. Both facts matter: a maintenance charge
-- is apportioned by share unit, so a scheme where every parcel holds
-- the same number never shows the apportionment doing anything, and one
-- whose parcels do not add up to the declared total apportions to the
-- wrong denominator.
--
-- Parcels carry `owner_contact_id`. A parcel with no owner cannot be
-- charged, so a scheme seeded without them is a register that looks
-- complete and bills nobody.
--
-- ## Fee income posts the same way
--
-- Both practices bill through `post_sales_document()`, exactly as Sinar
-- does. `line_type` is `item` with no `item_id` — the check constraint
-- allows item, description, subtotal and discount, and a fee line is an
-- item line that names no stock record. Same ledger discipline: the
-- trial balance balances because the application computed it.
--
-- Neither is SST registered — both are under the threshold, which is
-- the commoner case for a small practice and worth showing next to
-- Sinar, which is over it. Their lines carry the `NA` code and its
-- rate, for the reason `0187` found the hard way: `tax_rate` lives on
-- the line, and naming a code without copying its rate posts a document
-- whose tax is silently zero.

-- ---------------------------------------------------------------------
-- Amanah Setiausaha
-- ---------------------------------------------------------------------
create or replace function app.demo_books_amanah(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_rev      uuid;
  v_na       uuid;
  v_rate     numeric;
  v_class    uuid;
  v_doc      uuid;
  v_ent      record;
  v_client   record;
  v_month    date;
  v_date     date;
  v_fee      numeric;
  v_invoices integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_rev from public.accounts where org_id = p_org and code = '4100';
  select id, rate into v_na, v_rate from public.tax_codes
   where org_id = p_org and code = 'NA';

  -- The practice's own clients, as contacts it invoices.
  insert into public.contacts (org_id, code, name, contact_type, entity_type,
                               email, city, state_code, created_by)
  values
    (p_org,'CL-001','Kilang Lestari Sdn Bhd','customer','sdn_bhd','finance@lestari.demo','Seremban','05',p_owner),
    (p_org,'CL-002','Pinang Holdings Berhad','customer','bhd','cosec@pinang.demo','George Town','07',p_owner),
    (p_org,'CL-003','Bayu Digital Sdn Bhd','customer','sdn_bhd','admin@bayudigital.demo','Cyberjaya','10',p_owner)
  on conflict (org_id, code) do nothing;

  -- The people who hold office in those companies.
  insert into public.corp_persons (org_id, kind, full_name, nric, nationality,
                                   is_resident_in_malaysia, email)
  values
    (p_org,'individual','Lim Swee Hock',       '620814-10-5533','MY',true,'swee.hock@lestari.demo'),
    (p_org,'individual','Noraini binti Yusof', '710203-08-5122','MY',true,'noraini@lestari.demo'),
    (p_org,'individual','Tan Boon Siew',       '580919-07-5011','MY',true,'bs.tan@pinang.demo'),
    (p_org,'individual','Arun Kumar a/l Rajan','800127-14-5877','MY',true,'arun@bayudigital.demo'),
    (p_org,'individual','Nurul Hakim bin Idris','850612-14-5391','MY',true,'nurul@amanahsec.demo')
  -- The index is partial (`where nric is not null`), so the inference
  -- has to carry the predicate or Postgres cannot match it.
  on conflict (org_id, nric) where nric is not null do nothing;

  -- The client companies themselves.
  insert into public.corp_entities (org_id, name, registration_no, entity_type,
                                    status, incorporated_on, incorporated_in,
                                    financial_year_end_day,
                                    financial_year_end_month,
                                    nature_of_business, msic_code,
                                    is_audit_exempt, engaged_on, created_by)
  values
    (p_org,'Kilang Lestari Sdn Bhd','201903001234','sdn_bhd','incorporated',
     date '2019-03-14','Malaysia',31,12,'Manufacture of rubber products','22192',
     false, date '2019-03-14', p_owner),
    (p_org,'Pinang Holdings Berhad','201501009012','berhad','incorporated',
     date '2015-01-22','Malaysia',30,6,'Investment holding','64200',
     false, date '2015-01-22', p_owner),
    (p_org,'Bayu Digital Sdn Bhd','202209005678','sdn_bhd','incorporated',
     date '2022-09-08','Malaysia',31,12,'Computer programming activities','62010',
     true, date '2022-09-08', p_owner)
  on conflict (org_id, registration_no) do nothing;

  -- Officers, named rather than indexed. Every company needs a director
  -- and a secretary, and the secretary is the practice's own person.
  insert into public.corp_officers (org_id, entity_id, person_id, role,
                                    appointed_on, consent_received_on)
  select p_org, e.id, pr.id, o.role::app.corp_officer_role,
         o.appointed_on, o.appointed_on
    from (values
      ('Kilang Lestari Sdn Bhd','Lim Swee Hock',        'director', date '2019-03-14'),
      ('Kilang Lestari Sdn Bhd','Noraini binti Yusof',  'director', date '2021-06-01'),
      ('Pinang Holdings Berhad','Tan Boon Siew',        'director', date '2015-01-22'),
      ('Bayu Digital Sdn Bhd',  'Arun Kumar a/l Rajan', 'director', date '2022-09-08'),
      ('Kilang Lestari Sdn Bhd','Nurul Hakim bin Idris','secretary',date '2019-03-14'),
      ('Pinang Holdings Berhad','Nurul Hakim bin Idris','secretary',date '2015-01-22'),
      ('Bayu Digital Sdn Bhd',  'Nurul Hakim bin Idris','secretary',date '2022-09-08')
    ) as o(entity, person, role, appointed_on)
    join public.corp_entities e  on e.org_id = p_org and e.name = o.entity
    join public.corp_persons  pr on pr.org_id = p_org and pr.full_name = o.person
   where not exists (
     select 1 from public.corp_officers x
      where x.entity_id = e.id and x.person_id = pr.id
        and x.role = o.role::app.corp_officer_role);

  -- A share class and the subscribers' shares, so the register of
  -- members has something to compute from.
  for v_ent in select id, incorporated_on from public.corp_entities
                where org_id = p_org order by name loop
    insert into public.corp_share_classes (org_id, entity_id, code, name,
                                           currency, votes_per_share)
    values (p_org, v_ent.id, 'ORD', 'Ordinary', 'MYR', 1)
    on conflict (entity_id, code) do nothing;

    select id into v_class from public.corp_share_classes
     where entity_id = v_ent.id and code = 'ORD';

    insert into public.corp_share_events
      (org_id, entity_id, share_class_id, event_type, event_date,
       to_person_id, quantity, consideration_per_share, total_consideration,
       is_cash, notes, created_by)
    select p_org, v_ent.id, v_class, 'allotment', o.appointed_on,
           o.person_id, 100000, 1.00, 100000, true,
           'Subscriber shares on incorporation', p_owner
      from public.corp_officers o
     where o.entity_id = v_ent.id and o.role = 'director'
       and not exists (select 1 from public.corp_share_events s
                        where s.entity_id = v_ent.id
                          and s.to_person_id = o.person_id
                          and s.event_type = 'allotment');
  end loop;

  -- Fees, monthly, no SST: a small practice under the threshold.
  v_month := date_trunc('year', current_date)::date;
  while v_month <= current_date loop
    v_fee := 450;
    for v_client in select id from public.contacts
                     where org_id = p_org and code like 'CL-%' order by code loop
      v_fee := v_fee + 150;
      v_date := least(v_month + 4, current_date);

      insert into public.sales_documents
        (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
         currency, exchange_rate, subject, created_by)
      values (p_org, 'invoice',
              app.next_document_number_internal(p_org, 'invoice'),
              v_date, v_date + 14, v_client.id, 'draft', 'MYR', 1,
              'Corporate secretarial retainer — ' || to_char(v_month, 'Mon YYYY'),
              p_owner)
      returning id into v_doc;

      insert into public.sales_document_lines
        (org_id, document_id, line_no, line_type, description,
         quantity, unit_price, tax_code_id, tax_rate, account_id)
      values (p_org, v_doc, 1, 'item',
              'Monthly retainer and maintenance of statutory records',
              1, v_fee, v_na, v_rate, v_rev);

      perform public.post_sales_document(v_doc);
      v_invoices := v_invoices + 1;
    end loop;
    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Amanah: %s client entities, %s officers, %s allotments, '
                '%s fee invoices.',
                (select count(*) from public.corp_entities where org_id = p_org),
                (select count(*) from public.corp_officers where org_id = p_org),
                (select count(*) from public.corp_share_events where org_id = p_org),
                v_invoices);
end $$;

-- ---------------------------------------------------------------------
-- Harta Prima
-- ---------------------------------------------------------------------
create or replace function app.demo_books_harta(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  -- Unequal, and they add up to the scheme's declared total.
  c_share  constant integer[] := array[100, 105, 110, 120, 125, 135, 145, 160];
  v_rev       uuid;
  v_na        uuid;
  v_rate      numeric;
  v_strata    uuid;
  v_block     uuid;
  v_unit      uuid;
  v_owner     uuid[];
  v_tenant    record;
  v_i         integer;
  v_units     integer := 0;
  v_tenancies integer := 0;
  v_doc       uuid;
  v_month     date;
  v_date      date;
  v_invoices  integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_rev from public.accounts where org_id = p_org and code = '4100';
  select id, rate into v_na, v_rate from public.tax_codes
   where org_id = p_org and code = 'NA';

  -- Parcel owners and commercial tenants are both contacts, and the
  -- codes are what tells them apart later.
  insert into public.contacts (org_id, code, name, contact_type, entity_type,
                               email, city, state_code, created_by)
  values
    (p_org,'OW-001','Chong Wai Keong','customer','individual','wk.chong@demo.my','Shah Alam','10',p_owner),
    (p_org,'OW-002','Siti Ramlah binti Osman','customer','individual','siti.ramlah@demo.my','Shah Alam','10',p_owner),
    (p_org,'OW-003','Devan a/l Muniandy','customer','individual','devan@demo.my','Shah Alam','10',p_owner),
    (p_org,'OW-004','Lee Consolidated Sdn Bhd','customer','sdn_bhd','leeco@demo.my','Petaling Jaya','10',p_owner),
    (p_org,'T-001','Kedai Kopi Seri Muda','customer','enterprise','ops@serimuda.demo','Shah Alam','10',p_owner),
    (p_org,'T-002','Klinik Prima Sihat','customer','enterprise','admin@primasihat.demo','Shah Alam','10',p_owner),
    (p_org,'T-003','Aziz Motor Services','customer','enterprise','aziz@azizmotor.demo','Shah Alam','10',p_owner)
  on conflict (org_id, code) do nothing;

  select array_agg(id order by code) into v_owner from public.contacts
   where org_id = p_org and code like 'OW-%';

  -- The strata scheme.
  insert into public.property_sites (org_id, code, name, tenure, address_line1,
                                     city, state_code, postcode,
                                     local_authority, created_by)
  values (p_org, 'VP-01', 'Vista Prima Condominium', 'strata',
          'Jalan Vista Prima 1', 'Shah Alam', '10', '40150',
          'Majlis Bandaraya Shah Alam', p_owner)
  on conflict (org_id, code) do nothing;
  select id into v_strata from public.property_sites
   where org_id = p_org and code = 'VP-01';

  insert into public.strata_schemes (org_id, site_id, stage, mc_registration_no,
                                     established_on, first_agm_on,
                                     financial_year_end, total_share_units)
  values (p_org, v_strata, 'mc', 'MC/SEL/2021/00418',
          date '2021-04-19', date '2021-06-26',
          (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
          1000)
  on conflict (site_id) do nothing;

  -- Parcels. Share units decide each parcel's slice of the maintenance
  -- charge, so they are not decoration.
  for v_i in 1..array_length(c_share, 1) loop
    insert into public.property_units (org_id, site_id, unit_no, unit_type,
                                       floor, built_up_sqft, share_units,
                                       owner_contact_id, is_chargeable)
    values (p_org, v_strata, 'A-' || lpad(v_i::text, 2, '0'), 'parcel',
            ceil(v_i / 2.0)::text, 900 + (v_i * 75), c_share[v_i],
            v_owner[1 + ((v_i - 1) % array_length(v_owner, 1))], true)
    on conflict (site_id, unit_no) do nothing;
    v_units := v_units + 1;
  end loop;

  -- The commercial block, let rather than owned in parcels.
  insert into public.property_sites (org_id, code, name, tenure, address_line1,
                                     city, state_code, postcode,
                                     local_authority, created_by)
  values (p_org, 'HP-02', 'Harta Prima Commercial Block', 'non_strata',
          'Lot 12, Jalan Perusahaan', 'Shah Alam', '10', '40200',
          'Majlis Bandaraya Shah Alam', p_owner)
  on conflict (org_id, code) do nothing;
  select id into v_block from public.property_sites
   where org_id = p_org and code = 'HP-02';

  v_i := 0;
  for v_tenant in select id, code from public.contacts
                   where org_id = p_org and code like 'T-%' order by code loop
    v_i := v_i + 1;

    insert into public.property_units (org_id, site_id, unit_no, unit_type,
                                       floor, built_up_sqft, is_chargeable)
    values (p_org, v_block, 'G-' || v_i, 'shop', 'G', 1200, true)
    on conflict (site_id, unit_no) do nothing;
    select id into v_unit from public.property_units
     where site_id = v_block and unit_no = 'G-' || v_i;
    v_units := v_units + 1;

    insert into public.tenancies (org_id, unit_id, tenant_contact_id,
                                  tenancy_no, start_date, end_date,
                                  monthly_rent, rent_due_day,
                                  security_deposit, utility_deposit,
                                  deposit_held, status, created_by)
    values (p_org, v_unit, v_tenant.id,
            'TEN-' || lpad(v_i::text, 3, '0'),
            date_trunc('year', current_date)::date,
            (date_trunc('year', current_date) + interval '2 years')::date - 1,
            3200 + (400 * v_i), 1,
            (3200 + (400 * v_i)) * 2, 500,
            (3200 + (400 * v_i)) * 2 + 500, 'active', p_owner)
    on conflict (org_id, tenancy_no) do nothing;
    v_tenancies := v_tenancies + 1;
  end loop;

  -- Rent invoiced monthly. The strata side's maintenance charges are
  -- raised by the charge run, which is a screen worth leaving something
  -- for — the parcels, their share units and their owners are all there
  -- for it to work from.
  v_month := date_trunc('year', current_date)::date;
  while v_month <= current_date loop
    for v_tenant in select t.id tenancy_id, t.tenant_contact_id, t.monthly_rent,
                           u.unit_no
                      from public.tenancies t
                      join public.property_units u on u.id = t.unit_id
                     where t.org_id = p_org and t.status = 'active'
                     order by t.tenancy_no loop
      v_date := least(v_month, current_date);

      insert into public.sales_documents
        (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
         currency, exchange_rate, subject, created_by)
      values (p_org, 'invoice',
              app.next_document_number_internal(p_org, 'invoice'),
              v_date, v_date + 7, v_tenant.tenant_contact_id, 'draft',
              'MYR', 1,
              'Rental — ' || v_tenant.unit_no || ' — ' || to_char(v_month, 'Mon YYYY'),
              p_owner)
      returning id into v_doc;

      insert into public.sales_document_lines
        (org_id, document_id, line_no, line_type, description,
         quantity, unit_price, tax_code_id, tax_rate, account_id)
      values (p_org, v_doc, 1, 'item',
              'Monthly rent for unit ' || v_tenant.unit_no,
              1, v_tenant.monthly_rent, v_na, v_rate, v_rev);

      perform public.post_sales_document(v_doc);
      v_invoices := v_invoices + 1;
    end loop;
    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Harta Prima: 2 sites, %s units, %s tenancies, %s rent invoices.',
                v_units, v_tenancies, v_invoices);
end $$;

-- ---------------------------------------------------------------------
-- One call still rebuilds the whole demo
-- ---------------------------------------------------------------------
create or replace function app.demo_rebuild()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_removed text; v_demo uuid; v_clerk uuid; v_auditor uuid;
  v_secretary uuid; v_property uuid;
  v_sinar uuid; v_amanah uuid; v_harta uuid;
  v_books text; v_books_a text; v_books_h text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.my',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.my',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.my',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.my', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.my',  'Tan Chee Keong');

  v_sinar := app.demo_company(
    v_demo, 'Sinar Teknologi Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201901004567', 'C20194567890', '46510',
    'Wholesale of computers and peripherals',
    '10', 'Petaling Jaya', '46200',
    'Level 8, Menara Sinar, Jalan Utara', '03-7955 1200',
    'accounts@sinartek.demo', 12::smallint);
  perform public.set_sst_registration(
    v_sinar, true, date_trunc('year', current_date)::date - 365,
    'W10-1808-31000123', 'ST8');
  perform app.demo_member(v_sinar, v_clerk,   'accounts_clerk');
  perform app.demo_member(v_sinar, v_auditor, 'auditor');
  perform app.demo_modules(v_sinar, array[
    'einvoice', 'purchases', 'inventory', 'crm', 'hr', 'payroll',
    'fixed_assets', 'approvals', 'manufacturing', 'branches',
    'timesheets', 'chat', 'mbrs']);
  v_books := app.demo_books_sinar(v_sinar, v_demo);

  v_amanah := app.demo_company(
    v_secretary, 'Amanah Setiausaha Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201501002345', 'C20152345678', '69202',
    'Company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Suite 12-3, Wisma Amanah, Jalan Ampang', '03-2166 8800',
    'practice@amanahsec.demo', 12::smallint);
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'legal', 'approvals', 'einvoice', 'timesheets', 'chat']);
  v_books_a := app.demo_books_amanah(v_amanah, v_secretary);

  v_harta := app.demo_company(
    v_property, 'Harta Prima Management Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '202101007890', 'C20217890123', '68201',
    'Property management on a fee or contract basis',
    '10', 'Shah Alam', '40150',
    'Ground Floor, Blok A, Pusat Perniagaan Harta', '03-5511 4400',
    'admin@hartaprima.demo', 12::smallint);
  perform app.demo_modules(v_harta, array[
    'property_strata', 'property_nonstrata', 'purchases', 'fixed_assets',
    'approvals', 'chat']);
  v_books_h := app.demo_books_harta(v_harta, v_property);

  perform set_config('request.jwt.claims', '', true);

  return format('%s Rebuilt 3 tenants, 5 logins. %s %s %s',
                v_removed, v_books, v_books_a, v_books_h);
end $$;

revoke all on function app.demo_books_amanah(uuid, uuid) from public, anon, authenticated;
revoke all on function app.demo_books_harta(uuid, uuid)  from public, anon, authenticated;
