-- ---------------------------------------------------------------------
-- 0435  The servers Sinar builds
-- ---------------------------------------------------------------------
-- `manufacturing` is enabled on Sinar and there has never been a bill of
-- materials, a work centre or a manufacturing order in the product.
-- `confirm_manufacturing_order`, `post_manufacturing_order`,
-- `mo_shortages`, the scrap arithmetic and the `assembly_out` /
-- `assembly_in` movement types `0422` wired up are all there, all
-- unseen.
--
-- The judgement first, because it is the whole of the decision.
-- `manufacturing` is handed out by `app.demo_modules` in the rebuild,
-- not by `app.seed_org_modules`, so by the rule `0434` used it is a
-- demo choice and could simply be turned off. It cannot be, and the
-- reason is a second assertion in `demo_rebuild.sql`: every active
-- non-core module in the catalogue has to be enabled on some demo
-- tenant. Turn it off Sinar and it is enabled nowhere, and the module
-- has no demo at all rather than a thin one. Since none of the other
-- six manufactures anything either, the choice is between an eighth
-- tenant and making the story true on the one we have.
--
-- It is true on the one we have. Sinar is a wholesaler of computers and
-- peripherals, and a Malaysian system integrator of that description
-- builds rack servers to order out of components it stocks -- that is
-- the ordinary shape of the business, not a stretch to fill a module.
-- So the seed says exactly that and no more: four components bought in,
-- a bill of materials for the 2U server it already sells, one work
-- centre for the bench the technician assembles at, and one order run
-- through to posting.
--
-- The components are bought, not conjured. A manufacturing order that
-- consumes stock the tenant never acquired issues from an empty
-- warehouse and costs the finished item against nothing, which is the
-- failure `demo_books_sinar` warned about in its own header for the
-- sales side. The bill is deliberately under RM20,000: `0434` put an
-- approval rule on Sinar's bills above that, and a components purchase
-- that silently needed clearing would be a seed depending on an
-- approval nobody in the seed gives.
--
-- Measured on a rebuild: the components bill is RM16,260, and the two
-- servers come out at RM11,000.02 of components plus RM315.00 of bench
-- time -- RM5,657.51 each against the RM6,200 the finished item was
-- already carried at and the RM8,500 it sells for. A first draft costed
-- the recipe above the carrying cost, which would have demonstrated a
-- company losing money by assembling rather than buying; the numbers
-- here are what the rebuild actually produces, not what the header
-- would like them to be.
--
-- Four mutants applied and measured; three killed, and one assertion
-- was added because a mutant survived:
--
--   * confirmed and never posted -- killed, "a build that was actually
--     run, not a draft on a screen";
--   * the scrap allowance removed from the memory line -- killed, "the
--     scrap allowance was added, not deducted". `confirm_manufacturing_order`
--     issues more than the recipe calls for; a seed writing
--     `mo_components` itself would have issued exactly eight and every
--     other assertion here would still have passed;
--   * the routing step dropped from the bill of materials -- SURVIVED
--     the first draft of the assertions. Nothing looked at the
--     conversion cost, so the bench and `work_centres.cost_per_hour`
--     were dead configuration and the finished servers would have been
--     carried at components alone. Two assertions were added and the
--     mutant now dies on "the bench time was absorbed at all";
--   * the bench charging RM0.00 an hour -- killed by that same
--     assertion.
--
-- The second of the two -- "and at the rate the work centre charges" --
-- made no kill of its own, and both mutants that move the figure trip
-- the first. It recomputes the absorption from the same rows
-- `post_manufacturing_order` used, so it cannot catch a seed error at
-- all: it guards the function's arithmetic, not this migration's. Said
-- plainly rather than counted as a kill it did not make.
--
-- One order, run to done. A draft order shows the screen and proves
-- nothing; the value of this module is what `post_manufacturing_order`
-- does -- components out at what they are carried at, the finished item
-- in at component cost plus absorbed conversion, and a journal that
-- balances. Confirmed through `confirm_manufacturing_order` so the BOM
-- is exploded into `mo_components` by the function that owns the scrap
-- arithmetic, rather than by the seed writing the components it
-- expects.
-- ---------------------------------------------------------------------

create or replace function app.demo_manufacturing_sinar(
  p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_wh      uuid;
  v_supp    uuid;
  v_cos     uuid;
  v_st8     uuid;
  v_bom     uuid;
  v_bench   uuid;
  v_mo      uuid;
  v_doc     uuid;
  v_server  uuid;
  v_today   date := app.today();
  v_made    numeric;
  v_cost    numeric(18,2);
begin
  perform app.demo_act_as(p_owner);

  select id into v_wh from public.warehouses
   where org_id = p_org and is_active order by code limit 1;
  select id into v_cos from public.accounts
   where org_id = p_org and code = '5100';
  select id into v_st8 from public.tax_codes
   where org_id = p_org and code = 'ST8';
  select id into v_supp from public.contacts
   where org_id = p_org and contact_type in ('supplier', 'both')
   order by code limit 1;
  select id into v_server from public.items
   where org_id = p_org and code = 'ITM-100';

  -- What a 2U server is made of. Costed so the four together come to
  -- less than the RM6,200 the finished item is carried at, because a
  -- recipe that costs more than the product is a demo that teaches the
  -- wrong thing about margin.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, purchase_account_id, sales_tax_code_id)
  values
    (p_org, 'CMP-CHS', '2U Rack Chassis with Backplane', 'stock', true,
     'C62', 1250, 950, v_cos, v_st8),
    (p_org, 'CMP-CPU', 'Xeon Silver Processor', 'stock', true,
     'C62', 2300, 1750, v_cos, v_st8),
    (p_org, 'CMP-MEM', '32GB ECC Memory Module', 'stock', true,
     'C62', 500, 380, v_cos, v_st8),
    (p_org, 'CMP-PSU', 'Redundant 800W Power Supply', 'stock', true,
     'C62', 780, 600, v_cos, v_st8)
  on conflict (org_id, code) do nothing;

  -- Bought in, through the same posting function every other bill in
  -- this demo goes through, so the components are on hand at a cost the
  -- ledger agrees with. Quantities for two servers plus a spare set:
  -- 3 chassis, 3 CPUs, 12 memory modules, 6 supplies -- RM16,260, under
  -- 0434's RM20,000 approval threshold.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'bill', app.next_document_number_internal(p_org, 'bill'),
          v_today - 30, v_today, v_supp, 'draft', 'MYR', 1, p_owner)
  returning id into v_doc;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, account_id)
  select p_org, v_doc,
         row_number() over (order by i.code), 'item', i.id, i.name,
         case i.code when 'CMP-CHS' then 3 when 'CMP-CPU' then 3
                     when 'CMP-MEM' then 12 else 6 end,
         i.uom_code, i.cost_price, v_cos
    from public.items i
   where i.org_id = p_org and i.code like 'CMP-%';

  perform public.post_purchase_document(v_doc);

  -- The bench the technician works at. One work centre, because Sinar
  -- has one bench; a demo with four routing steps would be describing
  -- a factory this company is not.
  insert into public.work_centres
    (org_id, code, name, cost_per_hour, capacity_hours_per_day)
  values (p_org, 'WC-BENCH', 'Assembly and Burn-in Bench', 45.00, 8)
  on conflict (org_id, code) do nothing;
  select id into v_bench from public.work_centres
   where org_id = p_org and code = 'WC-BENCH';

  insert into public.bills_of_materials
    (org_id, item_id, code, name, output_quantity)
  values (p_org, v_server, 'BOM-ITM100', 'Rack Server 2U -- build to order', 1)
  on conflict (org_id, code) do nothing;
  select id into v_bom from public.bills_of_materials
   where org_id = p_org and code = 'BOM-ITM100';

  -- Two per server, and a scrap allowance on the memory because a
  -- module that fails burn-in is thrown away. `confirm_manufacturing_order`
  -- adds scrap rather than deducting it -- needing four and losing one
  -- in twenty means issuing more than four -- and a seed with no scrap
  -- anywhere would leave that arithmetic unexercised.
  delete from public.bom_lines where bom_id = v_bom;
  insert into public.bom_lines
    (org_id, bom_id, line_no, item_id, quantity, scrap_percent)
  select p_org, v_bom,
         case i.code when 'CMP-CHS' then 1 when 'CMP-CPU' then 2
                     when 'CMP-MEM' then 3 else 4 end,
         i.id,
         case i.code when 'CMP-CHS' then 1 when 'CMP-CPU' then 1
                     when 'CMP-MEM' then 4 else 2 end,
         case i.code when 'CMP-MEM' then 5 else 0 end
    from public.items i
   where i.org_id = p_org and i.code like 'CMP-%';

  delete from public.bom_operations where bom_id = v_bom;
  insert into public.bom_operations
    (org_id, bom_id, step_no, work_centre_id, name, minutes)
  values (p_org, v_bom, 1, v_bench, 'Assemble, image and burn in', 210);

  insert into public.manufacturing_orders
    (org_id, order_no, bom_id, item_id, warehouse_id, quantity,
     status, planned_start, planned_finish, notes, created_by)
  values (p_org, 'MO-000001', v_bom, v_server, v_wh, 2, 'draft',
          v_today - 12, v_today - 5,
          'Two servers for the Logistik Tepat rollout', p_owner)
  returning id into v_mo;

  perform public.confirm_manufacturing_order(v_mo);
  perform public.post_manufacturing_order(v_mo);

  select quantity_done, component_cost + conversion_cost
    into v_made, v_cost
    from public.manufacturing_orders where id = v_mo;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Sinar build: components bought in, a bill of materials with a '
    'scrap allowance, and %s servers assembled at RM%s.',
    v_made, v_cost);
end $$;

comment on function app.demo_manufacturing_sinar(uuid, uuid) is
  'One build-to-order run for Sinar: four components purchased, a BOM '
  'with a scrap allowance, one work centre, and a manufacturing order '
  'confirmed and posted so the assembly movements and the journal are '
  'real rather than a draft on a screen.';

revoke all on function app.demo_manufacturing_sinar(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The rebuild, restated
-- ---------------------------------------------------------------------
-- Verified against the live `pg_get_functiondef` before editing.

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
  v_fs_a text; v_fs_s text; v_name_a text; v_crm text; v_time_a text;
  v_cash text; v_assets text; v_pay text; v_desk text; v_fc text; v_pos text;
  v_cook uuid; v_warung_txt text;
  v_stylist uuid; v_hawker uuid;
  v_salon uuid; v_stall uuid;
  v_salon_txt text; v_stall_txt text;
  v_lawyer uuid; v_guaman uuid; v_legal_txt text;
  v_buy text := '';
  v_ask text := '';
  v_appr text := '';
  v_make text := '';
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
  v_lawyer    := app.demo_user('legal@iakauntan.com',     'Sharifah Aziz');

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
  v_crm    := app.demo_crm_sinar(v_sinar, v_demo);
  -- After forecasting, because the counter sells out of the same
  -- warehouse the forecast is about.
  v_pos    := app.demo_pos_sinar(v_sinar, v_demo);
  v_fs_s   := app.demo_sinar_accounts(v_sinar, v_demo);
  perform app.demo_sync_bank_balance(v_sinar);
  -- After the books, because the rule refuses an unapproved posting and
  -- a year of bills was posted above without one.
  v_appr := app.demo_approvals_sinar(v_sinar, v_demo, v_clerk);
  -- After the approval rule, so the components bill meets the same
  -- RM20,000 threshold every other Sinar bill now does.
  v_make := app.demo_manufacturing_sinar(v_sinar, v_demo);

  v_amanah := app.demo_company(
    v_secretary, 'Amanah Setiausaha Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201501002345', 'C20152345678', '69202',
    'Company secretarial services',
    '14', 'Kuala Lumpur', '50450',
    'Suite 12-3, Wisma Amanah, Jalan Ampang', '03-2166 8800',
    'practice@amanahsec.demo', 12::smallint);
  -- `mbrs` joins the list. A practice that keeps three companies'
  -- statutory registers is the one that prepares their accounts, and
  -- `report_fs_deadlines` was written for exactly that question: which
  -- of my clients is about to miss a s.258 date.
  -- `legal` is gone from this list. It is "Legal Firm Accounting --
  -- Matters, client account segregation and time recording for law
  -- firms", and Amanah is a company secretarial practice; it was on
  -- here only because no demo tenant was a law firm and the assertion
  -- in `demo_rebuild.sql` is satisfied by a tick. `0430` adds the firm
  -- the module was written for, so the tick can come off the tenant of
  -- the wrong kind.
  -- `approvals` is gone from this list. `decide_approval` refuses to
  -- let the person who raised a document approve it, and Amanah has one
  -- member; every document it raises is one nobody in the tenant may
  -- clear. `0434` took it off rather than seeding a chain that can only
  -- refuse.
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'einvoice', 'timesheets', 'chat', 'mbrs']);
  v_books_a := app.demo_books_amanah(v_amanah, v_secretary);
  -- A practice that files for other people still pays a printer.
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_amanah, v_secretary, 'Percetakan Ampang Sdn Bhd', 'SUP-AMP',
    'Cetakan buku daftar berkanun dan cop syarikat', '6230', 1850.00,
    'Maybank Current Account', 'Malayan Banking Berhad',
    '514088120077', 'current');
  -- Incorporations and retainers.
  v_ask := v_ask || ' ' || app.demo_crm(v_amanah, v_secretary, $j$
    [
      {
        "company": "Restoran Nasi Kandar Aziz",
        "first_name": "Aziz",
        "last_name": "Kader",
        "role": "Owner",
        "email": "aziz@nasikandaraziz.demo",
        "phone": "03-4023 7788",
        "city": "Kuala Lumpur",
        "state_code": "14",
        "source": "Walk-in",
        "industry": "Food and beverage",
        "value": 3500,
        "fate": "new",
        "note": null,
        "age": 6
      },
      {
        "company": "Kilang Perabot Melaka Sdn Bhd",
        "first_name": "Tan",
        "last_name": "Wei Ling",
        "role": "Finance manager",
        "email": "weiling@perabotmelaka.demo",
        "phone": "06-282 4411",
        "city": "Melaka",
        "state_code": "04",
        "source": "Referral",
        "industry": "Manufacturing",
        "value": 9600,
        "fate": "live",
        "note": null,
        "age": 24
      },
      {
        "company": "Teknologi Hijau Sdn Bhd",
        "first_name": "Nurhaliza",
        "last_name": "Ismail",
        "role": "Director",
        "email": "nur@teknologihijau.demo",
        "phone": "03-8912 3344",
        "city": "Cyberjaya",
        "state_code": "10",
        "source": "Website",
        "industry": "Technology",
        "value": 7200,
        "fate": "won",
        "note": "Signed the annual secretarial retainer",
        "age": 48
      },
      {
        "company": "Sara Enterprise",
        "first_name": "Sarah",
        "last_name": "Lim",
        "role": "Proprietor",
        "email": "sarah@saraent.demo",
        "phone": "03-7726 5500",
        "city": "Petaling Jaya",
        "state_code": "10",
        "source": "Website",
        "industry": "Retail",
        "value": 2800,
        "fate": "dead",
        "note": "Decided to stay a sole proprietor for another year",
        "age": 62
      }
    ]
  $j$::jsonb);
  v_fs_a    := app.demo_amanah_accounts(v_amanah, v_secretary);
  v_name_a  := app.demo_amanah_name_change(v_amanah, v_secretary);
  v_time_a  := app.demo_amanah_time(v_amanah, v_secretary);

  v_harta := app.demo_company(
    v_property, 'Harta Prima Management Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '202101007890', 'C20217890123', '68201',
    'Property management on a fee or contract basis',
    '10', 'Shah Alam', '40150',
    'Ground Floor, Blok A, Pusat Perniagaan Harta', '03-5511 4400',
    'admin@hartaprima.demo', 12::smallint);
  -- And off Harta, for the same reason and the same single member.
  perform app.demo_modules(v_harta, array[
    'property_strata', 'property_nonstrata', 'purchases', 'fixed_assets',
    'chat']);
  v_books_h := app.demo_books_harta(v_harta, v_property);
  -- The largest single thing a managing agent buys is somebody to keep
  -- the common property clean.
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_harta, v_property, 'Sinaran Kebersihan Sdn Bhd', 'SUP-SIN',
    'Kontrak pencucian dan landskap kawasan bersama', '6240', 7400.00,
    'CIMB Current Account', 'CIMB Bank Berhad',
    '800251330044', 'current');
  -- A managing agent wins work by pitching to a JMB.
  v_ask := v_ask || ' ' || app.demo_crm(v_harta, v_property, $j$
    [
      {
        "company": "JMB Residensi Damai",
        "first_name": "Kamarul",
        "last_name": "Bahrin",
        "role": "Chairman",
        "email": "jmb@residensidamai.demo",
        "phone": "03-5122 6600",
        "city": "Shah Alam",
        "state_code": "10",
        "source": "Referral",
        "industry": "Property",
        "value": 48000,
        "fate": "new",
        "note": null,
        "age": 9
      },
      {
        "company": "Perbadanan Pengurusan Vista Impian",
        "first_name": "Rajesh",
        "last_name": "Kumar",
        "role": "Secretary",
        "email": "mc@vistaimpian.demo",
        "phone": "03-5566 1122",
        "city": "Klang",
        "state_code": "10",
        "source": "Tender",
        "industry": "Property",
        "value": 132000,
        "fate": "live",
        "note": null,
        "age": 30
      },
      {
        "company": "JMB Menara Seri",
        "first_name": "Halimah",
        "last_name": "Yusof",
        "role": "Treasurer",
        "email": "jmb@menaraseri.demo",
        "phone": "03-3344 8899",
        "city": "Shah Alam",
        "state_code": "10",
        "source": "Tender",
        "industry": "Property",
        "value": 96000,
        "fate": "won",
        "note": "Appointed managing agent for two years",
        "age": 54
      },
      {
        "company": "Persatuan Penduduk Taman Sri Muda",
        "first_name": "Lim",
        "last_name": "Chee Keong",
        "role": "Chairman",
        "email": "ppt@srimuda.demo",
        "phone": "03-5191 2020",
        "city": "Shah Alam",
        "state_code": "10",
        "source": "Walk-in",
        "industry": "Property",
        "value": 18000,
        "fate": "dead",
        "note": "Residents voted to keep managing the estate themselves",
        "age": 70
      }
    ]
  $j$::jsonb);

  -- The dining room gets its own tenant rather than more furniture on
  -- the wholesaler. A floor plan and a kitchen screen on a company that
  -- sells rack servers would demo the wrong thing about who this is for.
  -- ------------------------------------------------------------------
  -- A law firm, because `legal` was written for one
  -- ------------------------------------------------------------------
  v_guaman := app.demo_company(
    v_lawyer, 'Guaman Aziz & Rakan', 'partnership'::app.entity_type,
    '202303006789', 'C20236789012', '69101',
    'Legal activities',
    '14', 'Kuala Lumpur', '50200',
    'Tingkat 5, Wisma Guaman, Jalan Raja Laut', '03-2694 5500',
    'firm@guamanaziz.demo', 12::smallint);
  perform app.demo_modules(v_guaman, array[
    'legal', 'timesheets', 'einvoice', 'chat']);
  v_legal_txt := app.demo_legal_guaman(v_guaman, v_lawyer);
  -- Out of the office account. `app.demo_purchases` excludes
  -- `is_client_account` when it looks for somewhere to pay from, which
  -- on this tenant is the whole point of the exclusion.
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_guaman, v_lawyer, 'Pustaka Undang-Undang Sdn Bhd', 'SUP-PUU',
    'Langganan tahunan pangkalan data undang-undang', '6220', 3600.00,
    null, null, null, 'current');
  -- Instructions, panels and a retainer.
  v_ask := v_ask || ' ' || app.demo_crm(v_guaman, v_lawyer, $j$
    [
      {
        "company": "Pembinaan Setia Jaya Sdn Bhd",
        "first_name": "Zulkarnain",
        "last_name": "Hashim",
        "role": "Managing director",
        "email": "zul@setiajaya.demo",
        "phone": "03-2711 4400",
        "city": "Kuala Lumpur",
        "state_code": "14",
        "source": "Referral",
        "industry": "Construction",
        "value": 55000,
        "fate": "new",
        "note": null,
        "age": 5
      },
      {
        "company": "Koperasi Guru Selangor Berhad",
        "first_name": "Norazlin",
        "last_name": "Abdullah",
        "role": "General manager",
        "email": "gm@koperasiguru.demo",
        "phone": "03-5510 7733",
        "city": "Shah Alam",
        "state_code": "10",
        "source": "Panel application",
        "industry": "Financial services",
        "value": 80000,
        "fate": "live",
        "note": null,
        "age": 26
      },
      {
        "company": "Sinaran Logistik Sdn Bhd",
        "first_name": "Devi",
        "last_name": "Subramaniam",
        "role": "Head of HR",
        "email": "hr@sinaranlogistik.demo",
        "phone": "03-8066 5511",
        "city": "Puchong",
        "state_code": "10",
        "source": "Referral",
        "industry": "Logistics",
        "value": 36000,
        "fate": "won",
        "note": "Retained for employment matters",
        "age": 44
      },
      {
        "company": "Rahim Hardware Trading",
        "first_name": "Abdul",
        "last_name": "Rahim",
        "role": "Proprietor",
        "email": "rahim@rahimhardware.demo",
        "phone": "03-9101 3300",
        "city": "Cheras",
        "state_code": "14",
        "source": "Walk-in",
        "industry": "Retail",
        "value": 12000,
        "fate": "dead",
        "note": "Settled with the other side before we were instructed",
        "age": 58
      }
    ]
  $j$::jsonb);

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
  -- Wang Tunai, not a current account. A warung buys its vegetables at
  -- the wholesale market and pays in notes, and giving it a Maybank
  -- account to make the seed uniform would be showing the customer
  -- somebody else's business.
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_warung, v_cook, 'Pasar Borong Selayang', 'SUP-PBS',
    'Sayur, ayam dan barang basah mingguan', '5100', 980.00,
    'Wang Tunai', null, 'TUNAI-01', 'cash');
  -- Catering, which is what a warung is asked for.
  v_ask := v_ask || ' ' || app.demo_crm(v_warung, v_cook, $j$
    [
      {
        "company": "Pejabat Daerah Puchong",
        "first_name": "Suhaimi",
        "last_name": "Yaacob",
        "role": "Administrative officer",
        "email": "pentadbiran@pdpuchong.demo",
        "phone": "03-8060 1234",
        "city": "Puchong",
        "state_code": "10",
        "source": "Walk-in",
        "industry": "Government",
        "value": 1200,
        "fate": "new",
        "note": null,
        "age": 4
      },
      {
        "company": "Kilang Elektronik Ampang Sdn Bhd",
        "first_name": "Chong",
        "last_name": "Mei Yee",
        "role": "HR executive",
        "email": "hr@elektronikampang.demo",
        "phone": "03-4270 9900",
        "city": "Ampang",
        "state_code": "10",
        "source": "Referral",
        "industry": "Manufacturing",
        "value": 4800,
        "fate": "live",
        "note": null,
        "age": 20
      },
      {
        "company": "Majlis Perkahwinan Puan Zaleha",
        "first_name": "Zaleha",
        "last_name": "Mohd Noor",
        "role": "Host",
        "email": "zaleha.majlis@warungsedap.demo",
        "phone": "012-334 5566",
        "city": "Puchong",
        "state_code": "10",
        "source": "Word of mouth",
        "industry": "Events",
        "value": 2600,
        "fate": "won",
        "note": "Catered the reception for two hundred",
        "age": 36
      },
      {
        "company": "Sekolah Menengah Kebangsaan Puchong",
        "first_name": "Faizal",
        "last_name": "Ramli",
        "role": "Canteen committee",
        "email": "kantin@smkpuchong.demo",
        "phone": "03-8075 4422",
        "city": "Puchong",
        "state_code": "10",
        "source": "Tender",
        "industry": "Education",
        "value": 9000,
        "fate": "dead",
        "note": "The canteen tender went to a bigger operator",
        "age": 52
      }
    ]
  $j$::jsonb);

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
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_salon, v_stylist, 'Kosmetik Indah Trading', 'SUP-KIT',
    'Bekalan produk rambut dan kecantikan', '5100', 2450.00,
    'Bank Islam Current Account', 'Bank Islam Malaysia Berhad',
    '120330554400', 'current');
  -- Bridal work, a hotel partnership and a group package.
  v_ask := v_ask || ' ' || app.demo_crm(v_salon, v_stylist, $j$
    [
      {
        "company": "Majlis Perkahwinan Puan Hasnah",
        "first_name": "Hasnah",
        "last_name": "Ibrahim",
        "role": "Bride''s mother",
        "email": "hasnah.majlis@seriayu.demo",
        "phone": "019-228 7744",
        "city": "Bandar Baru Bangi",
        "state_code": "10",
        "source": "Instagram",
        "industry": "Events",
        "value": 3200,
        "fate": "new",
        "note": null,
        "age": 3
      },
      {
        "company": "Hotel Bangi Resort",
        "first_name": "Sharifah",
        "last_name": "Aminah",
        "role": "Guest services manager",
        "email": "gsm@bangiresort.demo",
        "phone": "03-8925 1100",
        "city": "Bandar Baru Bangi",
        "state_code": "10",
        "source": "Referral",
        "industry": "Hospitality",
        "value": 14000,
        "fate": "live",
        "note": null,
        "age": 22
      },
      {
        "company": "Persatuan Wanita Bangi",
        "first_name": "Rohani",
        "last_name": "Salleh",
        "role": "Secretary",
        "email": "wanita@pwbangi.demo",
        "phone": "03-8926 3322",
        "city": "Bandar Baru Bangi",
        "state_code": "10",
        "source": "Word of mouth",
        "industry": "Community",
        "value": 4500,
        "fate": "won",
        "note": "Group package for twenty members",
        "age": 40
      },
      {
        "company": "Butik Pengantin Delima",
        "first_name": "Delima",
        "last_name": "Kassim",
        "role": "Owner",
        "email": "delima@butikdelima.demo",
        "phone": "03-8927 8811",
        "city": "Kajang",
        "state_code": "10",
        "source": "Walk-in",
        "industry": "Retail",
        "value": 6000,
        "fate": "dead",
        "note": "Wanted a commission split the salon does not offer",
        "age": 56
      }
    ]
  $j$::jsonb);

  v_stall := app.demo_company(
    v_hawker, 'Roti Warisan Enterprise', 'sole_proprietor'::app.entity_type,
    'JM0456789-K', 'IG20205678901', '56103',
    'Restaurants and mobile food service activities',
    '01', 'Johor Bahru', '80100',
    'Gerai bergerak — tiada premis tetap', '07-221 4455',
    'hafiz@rotiwarisan.demo', 12::smallint);
  v_stall_txt := app.demo_stall(v_stall, v_hawker);
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_stall, v_hawker, 'Kilang Tepung Johor Sdn Bhd', 'SUP-KTJ',
    'Tepung gandum, mentega dan susu pekat', '5100', 1320.00,
    'Wang Tunai', null, 'TUNAI-02', 'cash');
  -- Wholesale enquiries, which is how a gerai grows.
  v_ask := v_ask || ' ' || app.demo_crm(v_stall, v_hawker, $j$
    [
      {
        "company": "Kedai Kopi Pak Din",
        "first_name": "Shamsuddin",
        "last_name": "Osman",
        "role": "Owner",
        "email": "pakdin@kedaikopipakdin.demo",
        "phone": "07-223 1100",
        "city": "Johor Bahru",
        "state_code": "01",
        "source": "Word of mouth",
        "industry": "Food and beverage",
        "value": 900,
        "fate": "new",
        "note": null,
        "age": 5
      },
      {
        "company": "Pasar Raya Segar JB Sdn Bhd",
        "first_name": "Ganesh",
        "last_name": "Pillai",
        "role": "Buyer",
        "email": "buyer@segarjb.demo",
        "phone": "07-232 4455",
        "city": "Johor Bahru",
        "state_code": "01",
        "source": "Cold call",
        "industry": "Retail",
        "value": 5200,
        "fate": "live",
        "note": null,
        "age": 18
      },
      {
        "company": "Kafe Santai JB",
        "first_name": "Nadia",
        "last_name": "Zainal",
        "role": "Manager",
        "email": "nadia@kafesantai.demo",
        "phone": "07-224 6677",
        "city": "Johor Bahru",
        "state_code": "01",
        "source": "Word of mouth",
        "industry": "Food and beverage",
        "value": 1800,
        "fate": "won",
        "note": "Weekly pastry supply, Tuesdays and Fridays",
        "age": 34
      },
      {
        "company": "Hotel Tebrau Sdn Bhd",
        "first_name": "Vincent",
        "last_name": "Ooi",
        "role": "Purchasing manager",
        "email": "purchasing@hoteltebrau.demo",
        "phone": "07-355 2200",
        "city": "Johor Bahru",
        "state_code": "01",
        "source": "Cold call",
        "industry": "Hospitality",
        "value": 11000,
        "fate": "dead",
        "note": "Wanted a daily volume one oven cannot bake",
        "age": 50
      }
    ]
  $j$::jsonb);

  -- Every module a demo tenant has data for, switched on for it.
  -- `demo_rebuild` runs after the migrations, so 0232's backfill cannot
  -- reach these tenants -- and `demo_rebuild.sql` asserts that no
  -- active module is left without somewhere to be looked at. Doing it
  -- from the data rather than by listing modules per tenant means the
  -- next module added cannot quietly fail that gate.
  perform app.demo_modules_in_use();

  perform set_config('request.jwt.claims', '', true);

  return format(
    '%s Rebuilt 7 tenants, 9 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc, v_crm,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_name_a, v_time_a, v_books_h,
    v_legal_txt, v_warung_txt, v_salon_txt, v_stall_txt) || v_buy || v_ask || ' ' || v_appr || ' ' || v_make;
end;
$$;
-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = 'app.demo_rebuild()'::regprocedure;

  if v_src !~ 'demo_manufacturing_sinar' then
    raise exception
      'FAIL 0435: nothing builds anything, so manufacturing is still an '
      'empty screen on the only tenant that has the module';
  end if;

  -- Order matters here and is not obvious from reading the function:
  -- the components bill is posted by this seed and 0434 put an approval
  -- rule on Sinar''s bills. Seeded before the rule, it would post
  -- unapproved and the seed would break the day somebody lowers the
  -- threshold.
  if position('demo_approvals_sinar' in v_src)
     > position('demo_manufacturing_sinar' in v_src) then
    raise exception
      'FAIL 0435: the build is seeded before the approval rule, so its '
      'components bill escapes a rule every other Sinar bill meets';
  end if;

  if v_src !~ 'app.demo_purchases\(' or v_src !~ 'app.demo_crm\(' then
    raise exception
      'FAIL 0435: 0432 or 0433 has been dropped from the rebuild';
  end if;

  raise notice '0435: Sinar builds the servers it sells';
end
$do$;
