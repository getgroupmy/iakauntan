-- ---------------------------------------------------------------------
-- The demo books keep Malaysian time too, and the rule has no exceptions
--
-- The last of the four. `0420` carries the reasoning.
--
-- The demo seeds build a year of trading backwards from today, so they
-- read the clock more than anything else in the schema. Nothing
-- statutory turns on it -- a demo tenant rebuilt eight hours early is
-- still a demo tenant -- and that is precisely why they are here rather
-- than left out. An exception is a place the next person has to know
-- about. With these done, the rule is one sentence with nothing after
-- it:
--
--   No function in `public` or `app` asks the session what day it is.
--
-- The assertion below is that sentence, and it is now the whole
-- population rather than the STABLE half. It strips comments first --
-- `0306` left the word `current_date` in a comment in
-- `module_dashboard`, explaining why it no longer reads it, and that
-- sentence is not a defect -- and it looks for every way of asking, not
-- only the obvious one: `localtimestamp`, `current_timestamp::date` and
-- `now()::date` all inherit the session's zone as surely as
-- `current_date` does.
--
-- `supabase/tests/malaysian_clock.sql` asserts the same rule
-- independently, and asserts that the pattern matches what it claims to,
-- so neither can pass by finding nothing.
-- ---------------------------------------------------------------------

-- The rebuild that drives the rest.
create or replace function app.demo_rebuild()
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_removed text; v_demo uuid; v_clerk uuid; v_auditor uuid;
  v_secretary uuid; v_property uuid;
  v_sinar uuid; v_amanah uuid; v_harta uuid; v_warung uuid;
  v_books text; v_books_a text; v_books_h text;
  v_cash text; v_assets text; v_pay text; v_desk text; v_fc text; v_pos text;
  v_cook uuid; v_warung_txt text;
  v_stylist uuid; v_hawker uuid;
  v_salon uuid; v_stall uuid;
  v_salon_txt text; v_stall_txt text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.com',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.com',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.com',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.com', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.com',  'Tan Chee Keong');
  v_cook      := app.demo_user('warung@iakauntan.com',    'Faridah Ismail');
  v_stylist   := app.demo_user('salon@iakauntan.com',     'Aida Zulkifli');
  v_hawker    := app.demo_user('stall@iakauntan.com',     'Hafiz Rahman');

  v_sinar := app.demo_company(
    v_demo, 'Sinar Teknologi Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201901004567', 'C20194567890', '46510',
    'Wholesale of computers and peripherals',
    '10', 'Petaling Jaya', '46200',
    'Level 8, Menara Sinar, Jalan Utara', '03-7955 1200',
    'accounts@sinartek.demo', 12::smallint);
  perform public.set_sst_registration(
    v_sinar, true, date_trunc('year', app.today())::date - 365,
    'W10-1808-31000123', 'ST8');
  perform app.demo_member(v_sinar, v_clerk,   'accounts_clerk');
  perform app.demo_member(v_sinar, v_auditor, 'auditor');
  perform app.demo_modules(v_sinar, array[
    'einvoice', 'purchases', 'inventory', 'crm', 'hr', 'payroll',
    'fixed_assets', 'approvals', 'manufacturing', 'branches',
    'timesheets', 'chat', 'mbrs']);
  v_books  := app.demo_books_sinar(v_sinar, v_demo);
  v_cash   := app.demo_sinar_bank(v_sinar, v_demo);
  v_assets := app.demo_sinar_assets(v_sinar, v_demo);
  v_pay    := app.demo_sinar_payroll(v_sinar, v_demo);
  v_desk   := app.demo_tickets_sinar(v_sinar, v_demo);
  -- After the books and the bills, because it reads both.
  v_fc     := app.demo_forecast_sinar(v_sinar, v_demo);
  -- After forecasting, because the counter sells out of the same
  -- warehouse the forecast is about.
  v_pos    := app.demo_pos_sinar(v_sinar, v_demo);
  perform app.demo_sync_bank_balance(v_sinar);

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

  -- The dining room gets its own tenant rather than more furniture on
  -- the wholesaler. A floor plan and a kitchen screen on a company that
  -- sells rack servers would demo the wrong thing about who this is for.
  v_warung := app.demo_company(
    v_cook, 'Warung Sedap Enterprise', 'sole_proprietor'::app.entity_type,
    'SA0123456-X', 'IG20191234560', '56103',
    'Restaurants and mobile food service activities',
    '10', 'Puchong', '47100',
    'Lot 12, Jalan Kebun Baru', '03-8070 2233',
    'warung@warungsedap.demo', 12::smallint);
  -- The one line 0230 adds. Without it the member holds the six points
  -- one RM6.50 sale earned, the scheme redeems from a hundred, and the
  -- tender sheet's loyalty panel demonstrates itself by refusing.
  v_warung_txt := app.demo_warung(v_warung, v_cook)
    || ' ' || app.demo_warung_loyalty(v_warung, v_cook);

  -- And the two business types that had assertions but nowhere to look
  -- at them. See 0222's header for why they are tenants rather than
  -- extra outlets on the warung.
  v_salon := app.demo_company(
    v_stylist, 'Seri Ayu Salon & Spa Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201801003344', 'C20183344556', '96021',
    'Hairdressing and other beauty treatment',
    '10', 'Bandar Baru Bangi', '43650',
    'No 7-1, Jalan Medan Pusat Bandar 8', '03-8922 7788',
    'tempahan@seriayu.demo', 12::smallint);
  v_salon_txt := app.demo_salon(v_salon, v_stylist);

  v_stall := app.demo_company(
    v_hawker, 'Roti Warisan Enterprise', 'sole_proprietor'::app.entity_type,
    'JM0456789-K', 'IG20205678901', '56103',
    'Restaurants and mobile food service activities',
    '01', 'Johor Bahru', '80100',
    'Gerai bergerak — tiada premis tetap', '07-221 4455',
    'hafiz@rotiwarisan.demo', 12::smallint);
  v_stall_txt := app.demo_stall(v_stall, v_hawker);

  -- Every module a demo tenant has data for, switched on for it.
  -- `demo_rebuild` runs after the migrations, so 0232's backfill cannot
  -- reach these tenants -- and `demo_rebuild.sql` asserts that no
  -- active module is left without somewhere to be looked at. Doing it
  -- from the data rather than by listing modules per tenant means the
  -- next module added cannot quietly fail that gate.
  perform app.demo_modules_in_use();

  perform set_config('request.jwt.claims', '', true);

  return format(
    '%s Rebuilt 6 tenants, 8 logins. %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
    v_pos, v_books_a, v_books_h, v_warung_txt, v_salon_txt, v_stall_txt);
end;
$$;

-- A year of trading for Sinar Teknologi.
create or replace function app.demo_books_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_cust        uuid[];
  v_supp        uuid[];
  v_item        uuid[];
  v_price       numeric[];
  v_cost        numeric[];
  v_st8         uuid;
  v_rev         uuid;
  v_cos         uuid;
  v_inv_acct    uuid;
  v_cogs        uuid;
  v_doc         uuid;
  v_month       date;
  v_date        date;
  v_i           integer;
  v_n           integer;
  v_invoices    integer := 0;
  v_bills       integer := 0;
  v_line_item   integer;
  v_qty         numeric;
begin
  perform app.demo_act_as(p_owner);

  select id into v_st8 from public.tax_codes
   where org_id = p_org and code = 'ST8';
  select id into v_rev from public.accounts where org_id = p_org and code = '4100';
  select id into v_cos from public.accounts where org_id = p_org and code = '5100';
  -- 1310 Inventory and 5200 Cost of Goods Sold. A stock item that names
  -- neither leaves the costing engine with nowhere to put the asset on
  -- receipt or the charge on sale, and the stock valuation report stops
  -- agreeing with the balance sheet.
  select id into v_inv_acct from public.accounts where org_id = p_org and code = '1310';
  select id into v_cogs from public.accounts where org_id = p_org and code = '5200';

  -- ------------------------------------------------------------------
  -- Who it trades with
  -- ------------------------------------------------------------------
  insert into public.contacts (org_id, code, name, contact_type, email, phone,
                               city, state_code, credit_limit, created_by)
  values
    (p_org,'C-001','Bumi Maju Enterprise','customer','ap@bumimaju.demo','03-8912 7700','Kajang','10',50000,p_owner),
    (p_org,'C-002','Kilang Lestari Sdn Bhd','customer','finance@lestari.demo','06-761 4400','Seremban','05',80000,p_owner),
    (p_org,'C-003','Pusat Data Nusantara','customer','ap@nusantara.demo','03-2181 9000','Kuala Lumpur','14',150000,p_owner),
    (p_org,'C-004','Sekolah Teknologi Harapan','customer','bendahari@harapan.demo','04-228 3311','George Town','07',30000,p_owner),
    (p_org,'S-001','Lim Hardware Trading','supplier','sales@limhw.demo','03-6157 2200','Rawang','10',0,p_owner),
    (p_org,'S-002','Global Components Bhd','supplier','orders@globalcomp.demo','07-861 5500','Johor Bahru','01',0,p_owner),
    (p_org,'S-003','Utara Logistik','supplier','billing@utaralog.demo','03-3344 1100','Klang','10',0,p_owner)
  on conflict (org_id, code) do nothing;

  select array_agg(id order by code) into v_cust from public.contacts
   where org_id = p_org and contact_type = 'customer';
  select array_agg(id order by code) into v_supp from public.contacts
   where org_id = p_org and contact_type = 'supplier';

  -- ------------------------------------------------------------------
  -- What it sells. Stock tracked, so the costing engine has something to
  -- do and the stock valuation report is not empty.
  -- ------------------------------------------------------------------
  -- Two things here are lookups rather than free text, and both were got
  -- wrong first time by writing what seemed obvious. `items` carries no
  -- `created_by`, unlike almost every neighbouring table. And `uom_code`
  -- is a foreign key into `ref_uom_codes`, which holds UN/ECE
  -- Recommendation 20 codes: a unit is `C62`, not `UNIT`. `DAY` and
  -- `SET` happen to be real codes, which is exactly how a guess like
  -- this survives a casual read.
  insert into public.items (org_id, code, name, item_type, track_inventory,
                            unit_price, cost_price, uom_code,
                            sales_account_id, purchase_account_id,
                            inventory_account_id, cogs_account_id,
                            sales_tax_code_id)
  values
    (p_org,'ITM-100','Rack Server 2U','stock',true, 8500, 6200,'C62',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'ITM-110','Network Switch 48-port','stock',true, 3200, 2250,'C62',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'ITM-120','UPS 3kVA','stock',true, 4100, 2950,'C62',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'ITM-130','Structured Cabling Kit','stock',true, 1450, 980,'SET',v_rev,v_cos,v_inv_acct,v_cogs,v_st8),
    (p_org,'SRV-200','Installation and Commissioning','service',false, 2500, 0,'DAY',v_rev,null,null,null,v_st8)
  on conflict (org_id, code) do nothing;

  select array_agg(id order by code) into v_item from public.items
   where org_id = p_org and track_inventory;

  -- ------------------------------------------------------------------
  -- Stock in before stock out
  --
  -- Bills first each month, so there is something on hand to sell. A
  -- demo that sells from an empty warehouse produces negative stock and
  -- a costing engine averaging over nothing.
  -- ------------------------------------------------------------------
  v_month := date_trunc('year', app.today())::date;
  while v_month <= app.today() loop

    -- One purchase a month, three lines, from a rotating supplier.
    v_date := least(v_month + 2, app.today());
    insert into public.purchase_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, created_by)
    values (p_org, 'bill',
            app.next_document_number_internal(p_org, 'bill'),
            v_date, v_date + 30,
            v_supp[1 + (extract(month from v_month)::integer % array_length(v_supp,1))],
            'draft', 'MYR', 1, p_owner)
    returning id into v_doc;

    for v_i in 1..3 loop
      v_line_item := 1 + ((extract(month from v_month)::integer + v_i)
                          % array_length(v_item,1));
      -- `tax_rate` as well as `tax_code_id`. The rate is stored on the
      -- line, not looked up from the code when totals are recalculated —
      -- so a line naming ST8 without its 8 produces an invoice with no
      -- tax on it at all. That is not a cosmetic omission on an
      -- SST-registered company: it is an invoice that understates what
      -- was charged, and the first draft of this seed produced twenty of
      -- them before the probe measured output tax and found zero.
      insert into public.purchase_document_lines
        (org_id, document_id, line_no, line_type, item_id, description,
         quantity, uom_code, unit_price, tax_code_id, tax_rate, account_id)
      select p_org, v_doc, v_i, 'item', it.id, it.name,
             4 + v_i, it.uom_code, it.cost_price, v_st8, t.rate, v_cos
        from public.items it
        cross join public.tax_codes t
       where it.id = v_item[v_line_item] and t.id = v_st8;
    end loop;

    perform public.post_purchase_document(v_doc);
    v_bills := v_bills + 1;

    -- Two or three sales a month.
    v_n := 2 + (extract(month from v_month)::integer % 2);
    for v_i in 1..v_n loop
      v_date := least(v_month + (5 * v_i), app.today());
      insert into public.sales_documents
        (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
         currency, exchange_rate, created_by)
      values (p_org, 'invoice',
              app.next_document_number_internal(p_org, 'invoice'),
              v_date, v_date + 30,
              v_cust[1 + ((extract(month from v_month)::integer + v_i)
                          % array_length(v_cust,1))],
              'draft', 'MYR', 1, p_owner)
      returning id into v_doc;

      v_line_item := 1 + ((extract(month from v_month)::integer + v_i)
                          % array_length(v_item,1));
      v_qty := 1 + (v_i % 3);
      insert into public.sales_document_lines
        (org_id, document_id, line_no, line_type, item_id, description,
         quantity, uom_code, unit_price, tax_code_id, tax_rate, account_id)
      select p_org, v_doc, 1, 'item', it.id, it.name,
             v_qty, it.uom_code, it.unit_price, v_st8, t.rate, v_rev
        from public.items it
        cross join public.tax_codes t
       where it.id = v_item[v_line_item] and t.id = v_st8;

      -- A service line on the larger ones, so not every invoice is a
      -- single box shipped.
      if v_i = 1 then
        insert into public.sales_document_lines
          (org_id, document_id, line_no, line_type, item_id, description,
           quantity, uom_code, unit_price, tax_code_id, tax_rate, account_id)
        select p_org, v_doc, 2, 'item', it.id, it.name,
               1, it.uom_code, it.unit_price, v_st8, t.rate, v_rev
          from public.items it
          cross join public.tax_codes t
         where it.org_id = p_org and it.code = 'SRV-200' and t.id = v_st8;
      end if;

      perform public.post_sales_document(v_doc);
      v_invoices := v_invoices + 1;
    end loop;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar: %s invoices and %s bills posted, %s customers, '
                '%s suppliers, %s items.',
                v_invoices, v_bills,
                array_length(v_cust,1), array_length(v_supp,1),
                (select count(*) from public.items where org_id = p_org));
end $$;

-- The corp-sec practice.
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
  v_month := date_trunc('year', app.today())::date;
  while v_month <= app.today() loop
    v_fee := 450;
    for v_client in select id from public.contacts
                     where org_id = p_org and code like 'CL-%' order by code loop
      v_fee := v_fee + 150;
      v_date := least(v_month + 4, app.today());

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

-- The property manager.
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
          (date_trunc('year', app.today()) + interval '1 year' - interval '1 day')::date,
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
            date_trunc('year', app.today())::date,
            (date_trunc('year', app.today()) + interval '2 years')::date - 1,
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
  v_month := date_trunc('year', app.today())::date;
  while v_month <= app.today() loop
    for v_tenant in select t.id tenancy_id, t.tenant_contact_id, t.monthly_rent,
                           u.unit_no
                      from public.tenancies t
                      join public.property_units u on u.id = t.unit_id
                     where t.org_id = p_org and t.status = 'active'
                     order by t.tenancy_no loop
      v_date := least(v_month, app.today());

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

-- Sinar's bank.
create or replace function app.demo_sinar_bank(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_bank_gl  uuid;
  v_capital  uuid;
  v_bank     uuid;
  v_doc      record;
  v_id       uuid;
  v_date     date;
  v_receipts integer := 0;
  v_payments integer := 0;
  v_in       numeric(18,2) := 0;
  v_out      numeric(18,2) := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_bank_gl from public.accounts where org_id = p_org and code = '1120';
  select id into v_capital from public.accounts where org_id = p_org and code = '3100';

  insert into public.bank_accounts (org_id, account_id, name, bank_name, bank_code,
                                    account_number, account_type, currency,
                                    opening_balance, current_balance, is_default)
  values (p_org, v_bank_gl, 'Maybank Current Account', 'Malayan Banking Berhad',
          'MBBEMYKL', '514233880011', 'current', 'MYR', 0, 0, true)
  on conflict do nothing;
  select id into v_bank from public.bank_accounts
   where org_id = p_org and account_number = '514233880011';

  perform public.create_gl_entry(
    p_org, date_trunc('year', app.today())::date + 1, 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_bank_gl,
        'description', 'Paid-up capital', 'debit', 700000, 'credit', 0),
      jsonb_build_object('account_id', v_capital,
        'description', 'Paid-up capital', 'debit', 0, 'credit', 700000)),
    'Issue of ordinary shares — paid-up capital', null, null, 'SC-2026-01');

  for v_doc in select d.id, d.doc_no, d.contact_id, d.doc_date, d.total_amount
                 from public.sales_documents d
                where d.org_id = p_org and d.doc_type = 'invoice'
                  and d.status = 'posted'
                  and d.doc_date <= app.today() - 45
                order by d.doc_date, d.doc_no loop
    v_date := least(v_doc.doc_date + 21, app.today());

    insert into public.receipts (org_id, receipt_no, receipt_date, contact_id,
                                 payment_mode_code, bank_account_id, reference,
                                 currency, exchange_rate, amount, created_by)
    values (p_org, app.next_document_number_internal(p_org, 'receipt'), v_date,
            v_doc.contact_id, '03', v_bank, 'Settlement of ' || v_doc.doc_no,
            'MYR', 1, v_doc.total_amount, p_owner)
    returning id into v_id;

    insert into public.payment_allocations (org_id, receipt_id, invoice_id, amount)
    values (p_org, v_id, v_doc.id, v_doc.total_amount);

    perform public.post_receipt(v_id);
    v_receipts := v_receipts + 1;
    v_in := v_in + v_doc.total_amount;
  end loop;

  for v_doc in select d.id, d.doc_no, d.contact_id, d.doc_date, d.total_amount
                 from public.purchase_documents d
                where d.org_id = p_org and d.doc_type = 'bill'
                  and d.status = 'posted'
                  and d.doc_date <= app.today() - 60
                order by d.doc_date, d.doc_no loop
    v_date := least(v_doc.doc_date + 35, app.today());

    insert into public.purchase_payments (org_id, payment_no, payment_date, contact_id,
                                          payment_mode_code, bank_account_id, reference,
                                          currency, exchange_rate, amount, created_by)
    values (p_org, app.next_document_number_internal(p_org, 'payment'), v_date,
            v_doc.contact_id, '03', v_bank, 'Settlement of ' || v_doc.doc_no,
            'MYR', 1, v_doc.total_amount, p_owner)
    returning id into v_id;

    insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
    values (p_org, v_id, v_doc.id, v_doc.total_amount);

    perform public.post_purchase_payment(v_id);
    v_payments := v_payments + 1;
    v_out := v_out + v_doc.total_amount;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar cash: %s receipts (%s) and %s supplier payments (%s).',
                v_receipts, v_in, v_payments, v_out);
end $$;

-- Sinar's payroll.
create or replace function app.demo_sinar_payroll(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_bank    uuid;
  v_net     uuid;
  v_epf     uuid;
  v_socso   uuid;
  v_eis     uuid;
  v_pcb     uuid;
  v_month   date;
  v_end     date;
  v_period  uuid;
  v_run     uuid;
  v_r       record;
  v_due     date;
  v_lines   jsonb;
  v_total   numeric(18,2);
  v_runs    integer := 0;
  v_paid    integer := 0;
  v_remits  integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_bank  from public.accounts where org_id = p_org and code = '1120';
  select id into v_net   from public.accounts where org_id = p_org and code = '2145';
  select id into v_epf   from public.accounts where org_id = p_org and code = '2150';
  select id into v_socso from public.accounts where org_id = p_org and code = '2160';
  select id into v_eis   from public.accounts where org_id = p_org and code = '2170';
  select id into v_pcb   from public.accounts where org_id = p_org and code = '2180';

  insert into public.employees
    (org_id, employee_no, full_name, email, nric, nationality, residency_status,
     date_of_birth, gender, marital_status, spouse_is_working,
     employment_type, employment_status, hire_date, confirmation_date,
     pay_frequency, basic_salary, bank_name, bank_account_no, bank_account_holder,
     epf_no, socso_no, income_tax_no, city, state_code, created_by)
  values
    (p_org,'EMP-001','Aisyah binti Rahman','aisyah@sinartek.demo','880412-14-5210','MY','citizen',
     date '1988-04-12','F','married',true,'full_time','active',
     date '2021-02-01', date '2021-08-01','monthly', 9500,
     'Maybank','114422335566','Aisyah binti Rahman','E1140221','S8804125','SG10245678901',
     'Petaling Jaya','10', p_owner),
    (p_org,'EMP-002','Wong Mei Ling','meiling@sinartek.demo','930817-10-5388','MY','citizen',
     date '1993-08-17','F','single',false,'full_time','active',
     date '2022-06-15', date '2022-12-15','monthly', 5200,
     'CIMB Bank','800455119922','Wong Mei Ling','E1220615','S9308175','SG10245678902',
     'Shah Alam','10', p_owner),
    (p_org,'EMP-003','Ravi a/l Subramaniam','ravi@sinartek.demo','900225-08-5471','MY','citizen',
     date '1990-02-25','M','married',false,'full_time','active',
     date '2023-01-09', date '2023-07-09','monthly', 4300,
     'Public Bank','331299887744','Ravi a/l Subramaniam','E1230109','S9002255','SG10245678903',
     'Klang','10', p_owner),
    (p_org,'EMP-004','Muhammad Faiz bin Osman','faiz@sinartek.demo','990703-14-5029','MY','citizen',
     date '1999-07-03','M','single',false,'full_time','active',
     date '2024-03-04', date '2024-09-04','monthly', 2900,
     'Bank Islam','770011223344','Muhammad Faiz bin Osman','E1240304','S9907035','SG10245678904',
     'Petaling Jaya','10', p_owner)
  on conflict (org_id, employee_no) do nothing;

  v_month := date_trunc('year', app.today())::date;
  while v_month < date_trunc('month', app.today())::date loop
    v_end := (v_month + interval '1 month')::date - 1;

    insert into public.pay_periods (org_id, code, period_start, period_end,
                                    pay_date, frequency)
    values (p_org, to_char(v_month, 'YYYY-MM'), v_month, v_end, v_end, 'monthly')
    on conflict (org_id, code) do nothing;
    select id into v_period from public.pay_periods
     where org_id = p_org and code = to_char(v_month, 'YYYY-MM');

    if not exists (select 1 from public.payroll_runs
                    where org_id = p_org and period_id = v_period) then
      v_run := public.create_payroll_run(
        p_org, v_period, 'Monthly payroll — ' || to_char(v_month, 'Mon YYYY'));
      perform public.calculate_payroll_run(v_run);
      perform public.post_payroll_run(v_run);
      perform public.mark_payroll_paid(v_run);
      v_runs := v_runs + 1;

      select * into v_r from public.payroll_runs where id = v_run;

      -- Staff are actually paid. post_payroll_run credits net pay to
      -- 2145 and stops there, which is right — the bank transfer is a
      -- separate act — but a demo that never makes it leaves four
      -- months of wages owing to people who were paid.
      if v_r.total_net > 0 then
        perform public.create_gl_entry(
          p_org, v_end, 'manual'::app.journal_source,
          jsonb_build_array(
            jsonb_build_object('account_id', v_net,
              'description', 'Net salaries paid', 'debit', v_r.total_net, 'credit', 0),
            jsonb_build_object('account_id', v_bank,
              'description', 'Net salaries paid', 'debit', 0, 'credit', v_r.total_net)),
          'Salary payment — ' || to_char(v_month, 'Mon YYYY'),
          null, null, 'SAL-' || to_char(v_month, 'YYYYMM'));
        v_paid := v_paid + 1;
      end if;

      -- EPF, SOCSO, EIS and PCB are remitted by the fifteenth of the
      -- following month. Months whose deadline has not arrived stay
      -- outstanding, which is what the statutory payables screen is for.
      v_due := (v_month + interval '1 month')::date + 14;
      if v_due <= app.today() then
        v_lines := '[]'::jsonb;
        v_total := 0;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_epf, 'description', 'EPF remitted',
          'debit', v_r.total_epf_employee + v_r.total_epf_employer, 'credit', 0));
        v_total := v_total + v_r.total_epf_employee + v_r.total_epf_employer;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_socso, 'description', 'SOCSO remitted',
          'debit', v_r.total_socso_employee + v_r.total_socso_employer, 'credit', 0));
        v_total := v_total + v_r.total_socso_employee + v_r.total_socso_employer;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_eis, 'description', 'EIS remitted',
          'debit', v_r.total_eis_employee + v_r.total_eis_employer, 'credit', 0));
        v_total := v_total + v_r.total_eis_employee + v_r.total_eis_employer;

        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'account_id', v_pcb, 'description', 'PCB / MTD remitted',
          'debit', v_r.total_pcb, 'credit', 0));
        v_total := v_total + v_r.total_pcb;

        if v_total > 0 then
          v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_bank, 'description', 'Statutory remittance',
            'debit', 0, 'credit', v_total));
          perform public.create_gl_entry(
            p_org, v_due, 'manual'::app.journal_source, v_lines,
            'Statutory remittance for ' || to_char(v_month, 'Mon YYYY'),
            null, null, 'STAT-' || to_char(v_month, 'YYYYMM'));
          v_remits := v_remits + 1;
        end if;
      end if;
    end if;

    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar payroll: %s employees, %s runs posted and paid, '
                '%s salary payments, %s statutory remittances.',
                (select count(*) from public.employees where org_id = p_org),
                v_runs, v_paid, v_remits);
end $$;

-- And Sinar's assets.
create or replace function app.demo_sinar_assets(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_ppe    uuid;
  v_veh    uuid;
  v_accum  uuid;
  v_exp    uuid;
  v_bank   uuid;
  v_a      record;
  v_month  date;
  v_end    date;
  v_runs   integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_ppe   from public.accounts where org_id = p_org and code = '1510';
  select id into v_veh   from public.accounts where org_id = p_org and code = '1520';
  select id into v_accum from public.accounts where org_id = p_org and code = '1590';
  select id into v_exp   from public.accounts where org_id = p_org and code = '6400';
  select id into v_bank  from public.accounts where org_id = p_org and code = '1120';

  insert into public.fixed_assets
    (org_id, asset_no, name, description, category, asset_account_id,
     accumulated_account_id, expense_account_id, acquisition_date, cost,
     residual_value, method, useful_life_months, location, created_by)
  values
    (p_org,'FA-001','Delivery van (WXY 4412)','Nissan NV200 panel van',
     'Motor vehicles', v_veh, v_accum, v_exp,
     date_trunc('year', app.today())::date + 24, 96000, 12000,
     'straight_line', 60, 'Petaling Jaya', p_owner),
    (p_org,'FA-002','Warehouse racking','Six bays of pallet racking',
     'Plant and equipment', v_ppe, v_accum, v_exp,
     date_trunc('year', app.today())::date + 52, 38500, 0,
     'straight_line', 120, 'Petaling Jaya', p_owner),
    (p_org,'FA-003','Server and network cabinet','Rack, switch and UPS',
     'Office equipment', v_ppe, v_accum, v_exp,
     date_trunc('year', app.today())::date + 96, 27400, 2000,
     'straight_line', 48, 'Petaling Jaya', p_owner),
    (p_org,'FA-004','Office fit-out','Partitions, desks and lighting',
     'Furniture and fittings', v_ppe, v_accum, v_exp,
     date_trunc('year', app.today())::date + 140, 61200, 0,
     'straight_line', 120, 'Petaling Jaya', p_owner)
  on conflict (org_id, asset_no) do nothing;

  for v_a in select asset_no, name, asset_account_id, acquisition_date, cost
               from public.fixed_assets fa
              where fa.org_id = p_org and fa.deleted_at is null
                and not exists (select 1 from public.gl_entries e
                                 where e.org_id = p_org
                                   and e.reference = 'ACQ-' || fa.asset_no)
              order by fa.asset_no loop
    perform public.create_gl_entry(
      p_org, v_a.acquisition_date, 'manual'::app.journal_source,
      jsonb_build_array(
        jsonb_build_object('account_id', v_a.asset_account_id,
          'description', v_a.name, 'debit', v_a.cost, 'credit', 0),
        jsonb_build_object('account_id', v_bank,
          'description', v_a.name, 'debit', 0, 'credit', v_a.cost)),
      'Acquisition of ' || v_a.name, null, null, 'ACQ-' || v_a.asset_no);
  end loop;

  v_month := date_trunc('year', app.today())::date;
  while v_month < date_trunc('month', app.today())::date loop
    v_end := (v_month + interval '1 month')::date - 1;
    if public.run_depreciation(p_org, v_end) is not null then
      v_runs := v_runs + 1;
    end if;
    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar assets: %s assets costing %s, %s monthly depreciation runs.',
                (select count(*) from public.fixed_assets where org_id = p_org),
                (select coalesce(sum(cost),0) from public.fixed_assets where org_id = p_org),
                v_runs);
end $$;

-- ---------------------------------------------------------------------
-- The rule, closed
-- ---------------------------------------------------------------------
do $$
declare
  v_left text[];
begin
  select array_agg(n.nspname || '.' || p.proname order by 1)
    into v_left
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~*
         '(\mcurrent_date\M)|(\mlocaltimestamp\M)'
         '|(\mcurrent_timestamp\M\s*::\s*date)|(\mnow\M\s*\(\s*\)\s*::\s*date)';

  if v_left is not null then
    raise exception
      'FAIL 0423 left % function(s) reading the session clock: %. '
      'The rule is that none do. Pin them to app.today(), or -- if one '
      'truly wants the caller''s clock -- say so where it reads it and '
      'widen this assertion to name the exception.',
      cardinality(v_left), array_to_string(v_left, ', ')
      using errcode = '23514';
  end if;
end $$;
