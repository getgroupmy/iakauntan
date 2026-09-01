-- ---------------------------------------------------------------------
-- A pipeline with something in it
--
-- `0426` measured which modules a demo tenant has enabled and has no
-- data for, and named eleven. `crm` is on every one of the six tenants
-- and there has never been a single lead in the product. Somebody signs
-- in, opens Leads, and reads an empty state -- and the pipeline, the six
-- stages, `convert_lead`, `close_lead`, `quote_opportunity` and
-- `close_opportunity` are all there and all unseen.
--
-- The scaffolding was never the gap. Every demo tenant already gets a
-- Sales Pipeline with six stages -- Qualification, Needs Analysis,
-- Proposal Sent, Negotiation, Closed Won, Closed Lost. What was missing
-- is anybody in it.
--
-- ## Sinar, and only Sinar
--
-- Sinar Teknologi sells software to businesses and already has a year of
-- invoices to four customers, so a pipeline in front of that is the
-- arrangement the module is for. A warung does not run one, and neither
-- does a salon: `crm` being enabled on all six is a separate question
-- about what `demo_modules` hands out, not something to answer by
-- writing five pipelines nobody would recognise.
--
-- So the register in `supabase/tests/demo_rebuild.sql` changes shape.
-- It was a list of module codes, which could only record "crm is empty
-- somewhere" and could never shrink by one tenant. It is now a list of
-- tenant-and-module pairs, so seeding Sinar's removes exactly one line
-- and the other five stay named. A register that cannot record partial
-- progress stops being read.
--
-- ## Through the functions, not into the tables
--
-- The leads are inserted, because a lead arriving is not a rule -- it is
-- somebody filling in a form. Everything that happens to one afterwards
-- goes through the function that owns it:
--
--   * `convert_lead` turns the qualified one into a contact and an
--     opportunity, and only it knows to set `converted_contact_id`,
--     which is what stops the same lead being converted twice.
--   * `close_lead` loses one, and refuses to without a reason: "a list
--     of dead leads with no reasons on it is a list nobody reads
--     twice".
--   * `close_opportunity` wins one and loses another, and `0373`'s
--     trigger dates the close when the stage moves.
--
-- Writing `status = 'converted'` into the row by hand would seed the
-- same letters and none of that.
--
-- ## What the pipeline looks like afterwards
--
-- Measured on a rebuild rather than described from the seed:
--
--   LEAD-000001  Kedai Runcit Maju      new, nobody has called yet
--   LEAD-000002  Klinik Sihat Bersama   converted; the deal was lost to
--                                       a named competitor
--   LEAD-000003  Logistik Tepat         converted; live in Negotiation
--   LEAD-000004  Butik Anggun           lost, with a reason
--   LEAD-000005  Sekolah Cemerlang      converted; the deal was won
--
-- Three of five leads converting is a better rate than any real sales
-- team gets, and it is deliberate: a demo trades a plausible ratio for
-- showing every state the screens can be in. A pipeline where every
-- card sits in one column teaches nothing about the pipeline.
-- ---------------------------------------------------------------------

create or replace function app.demo_crm_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_today  date := app.today();
  v_pipe   uuid;
  v_nego   uuid;
  v_l1 uuid; v_l2 uuid; v_l3 uuid; v_l4 uuid; v_l5 uuid;
  v_o1 uuid; v_o2 uuid; v_o3 uuid;
  v_n  integer := 0;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  select id into v_pipe from public.pipelines
   where org_id = p_org and is_default order by created_at limit 1;
  if v_pipe is null then
    select id into v_pipe from public.pipelines
     where org_id = p_org order by created_at limit 1;
  end if;
  if v_pipe is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Sinar pipeline: skipped, there is no pipeline to put it in.';
  end if;
  select id into v_nego from public.pipeline_stages
   where pipeline_id = v_pipe and name = 'Negotiation';

  -- A lead arriving is somebody filling in a form, not a rule, so these
  -- are written directly. Everything that happens to one afterwards
  -- goes through the function that owns it.
  insert into public.leads
    (org_id, lead_no, company_name, first_name, last_name, designation,
     email, phone, city, state_code, source, industry, status, rating,
     estimated_value, owner_id, created_by, created_at)
  values
    (p_org, 'LEAD-000001', 'Kedai Runcit Maju Sdn Bhd', 'Faridah', 'Osman',
     'Owner', 'faridah@majuruncit.demo', '03-7788 1200', 'Petaling Jaya',
     '10', 'Website', 'Retail', 'new', 'warm', 18000, p_owner, p_owner,
     (v_today - 4)::timestamptz),
    (p_org, 'LEAD-000002', 'Klinik Sihat Bersama', 'Dr Nurul', 'Hakim',
     'Practice manager', 'admin@kliniksihat.demo', '03-6201 9900',
     'Kuala Lumpur', '14', 'Referral', 'Healthcare', 'contacted', 'warm',
     26000, p_owner, p_owner, (v_today - 12)::timestamptz),
    (p_org, 'LEAD-000003', 'Logistik Tepat Sdn Bhd', 'Chandran', 'Menon',
     'Operations director', 'chandran@logistiktepat.demo', '03-5522 3311',
     'Shah Alam', '10', 'Trade show', 'Logistics', 'qualified', 'hot',
     84000, p_owner, p_owner, (v_today - 40)::timestamptz),
    (p_org, 'LEAD-000004', 'Butik Anggun', 'Siti', 'Rahmah', 'Proprietor',
     'siti@butikanggun.demo', '09-514 7788', 'Kuantan', '06', 'Website',
     'Retail', 'contacted', 'cold', 7000, p_owner, p_owner,
     (v_today - 55)::timestamptz),
    (p_org, 'LEAD-000005', 'Sekolah Cemerlang', 'Encik Zulkifli', 'Ahmad',
     'Bursar', 'bursar@cemerlang.demo', '04-733 2200', 'Alor Setar', '02',
     'Cold call', 'Education', 'contacted', 'warm', 42000, p_owner,
     p_owner, (v_today - 70)::timestamptz);

  -- Five rows and one variable: `returning ... into` on a multi-row
  -- insert raises "query returned more than one row", so the ids are
  -- read back by number instead.
  select id into v_l1 from public.leads
   where org_id = p_org and lead_no = 'LEAD-000001';

  select id into v_l2 from public.leads
   where org_id = p_org and lead_no = 'LEAD-000002';
  select id into v_l3 from public.leads
   where org_id = p_org and lead_no = 'LEAD-000003';
  select id into v_l4 from public.leads
   where org_id = p_org and lead_no = 'LEAD-000004';
  select id into v_l5 from public.leads
   where org_id = p_org and lead_no = 'LEAD-000005';

  -- Converted through the function: only it sets
  -- `converted_contact_id`, which is what stops the same lead becoming
  -- two customers.
  v_o1 := (public.convert_lead(v_l3, true, v_pipe, 84000,
                               v_today + 20) ->> 'opportunity_id')::uuid;

  -- And two more to close, so the funnel has a won one and a lost one
  -- rather than a single card in a single column.
  v_o2 := (public.convert_lead(v_l5, true, v_pipe, 42000,
                               v_today - 15) ->> 'opportunity_id')::uuid;
  v_o3 := (public.convert_lead(v_l2, true, v_pipe, 26000,
                               v_today - 30) ->> 'opportunity_id')::uuid;

  perform public.close_opportunity(v_o2, 'won', 'Signed the annual plan',
                                   null, v_today - 12);
  perform public.close_opportunity(v_o3, 'lost', 'Went with the incumbent',
                                   'Sistem Awan Bhd', v_today - 25);

  -- The live one sits in Negotiation rather than where `convert_lead`
  -- put it, because a pipeline where everything is in the first stage
  -- is not a pipeline.
  if v_nego is not null then
    update public.opportunities
       set stage_id = v_nego, probability = 75, updated_at = now()
     where id = v_o1;
  end if;

  -- Lost, with a reason, because `close_lead` refuses without one.
  perform public.close_lead(v_l4,
    'Bought a till from somebody else before we called back');

  select count(*) into v_n from public.leads where org_id = p_org;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Sinar pipeline: %s leads -- one untouched, three converted, one '
    'lost with a reason -- and %s opportunities: one won, one lost to a '
    'named competitor, one live in Negotiation.',
    v_n, (select count(*) from public.opportunities where org_id = p_org));
end $$;

comment on function app.demo_crm_sinar(uuid, uuid) is
  'A sales pipeline for Sinar with one of everything in it, so the CRM '
  'module is not an empty screen. Leads are inserted; everything that '
  'happens to one afterwards goes through convert_lead, close_lead or '
  'close_opportunity.';

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
  v_fs_a text; v_fs_s text; v_name_a text; v_crm text;
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
  v_crm    := app.demo_crm_sinar(v_sinar, v_demo);
  -- After forecasting, because the counter sells out of the same
  -- warehouse the forecast is about.
  v_pos    := app.demo_pos_sinar(v_sinar, v_demo);
  v_fs_s   := app.demo_sinar_accounts(v_sinar, v_demo);
  perform app.demo_sync_bank_balance(v_sinar);

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
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'legal', 'approvals', 'einvoice', 'timesheets', 'chat',
    'mbrs']);
  v_books_a := app.demo_books_amanah(v_amanah, v_secretary);
  v_fs_a    := app.demo_amanah_accounts(v_amanah, v_secretary);
  v_name_a  := app.demo_amanah_name_change(v_amanah, v_secretary);

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
    '%s Rebuilt 6 tenants, 8 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc, v_crm,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_name_a, v_books_h, v_warung_txt,
    v_salon_txt, v_stall_txt);
end;
$$;

-- ---------------------------------------------------------------------
-- Through the functions
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_crm_sinar';

  -- Setting `status = 'converted'` and `converted_contact_id` by hand
  -- would seed the same letters and skip the guard that stops a lead
  -- becoming two customers. Same for losing one without a reason, which
  -- `close_lead` refuses in as many words.
  if v_src !~ '\mconvert_lead\M' or v_src !~ '\mclose_lead\M'
     or v_src !~ '\mclose_opportunity\M' then
    raise exception
      'FAIL 0428: the pipeline is seeded by writing rows rather than by '
      'calling the functions that own them.' using errcode = '23514';
  end if;

  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_rebuild';
  if v_src !~ '\mdemo_crm_sinar\M' then
    raise exception
      'FAIL 0428: demo_rebuild does not call demo_crm_sinar, so the '
      'seed never runs.' using errcode = '23514';
  end if;
end $$;
