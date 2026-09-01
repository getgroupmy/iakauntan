-- ---------------------------------------------------------------------
-- A client company that changed its name, and the twelve months after
--
-- `0426` said what it left out and why: no demo company has ever been
-- renamed, so `0425`'s letterhead -- the former name alongside the new
-- one, which s.28(4) requires for twelve months -- could not be seen in
-- a demo. The reason it was left out was the fourteen-day filing that
-- `change_company_name` opens, and a demo that shows a client company
-- in breach of the Companies Act is worse than one that shows nothing.
--
-- That reason is answered rather than avoided: the filing is opened,
-- and then lodged, because that is what a competent secretary does and
-- it is what the demo should show.
--
-- ## Through the door, not around it
--
-- `0377` refuses a rename typed over the name, and the refusal is the
-- point: a change of name is an event with a date and a twelve-month
-- obligation, and a typo correction is neither. So this seed calls
-- `public.change_company_name`, which writes `former_names`, sets
-- `name_changed_on`, and returns the `corp_filings` row it opened under
-- s.28. Setting the three columns by hand would seed the data and skip
-- the rule that makes it mean anything.
--
-- ## Kilang Lestari, four months ago
--
-- Kilang is the client whose accounts are already lodged, so the rename
-- is the only live thing about it and the two do not compete for
-- attention. Four months back is inside the twelve, so
-- `corp_display_name` returns both names and every document Amanah
-- generates for it carries them:
--
--     Kilang Lestari Bersatu Sdn Bhd (formerly Kilang Lestari Sdn Bhd)
--
-- The s.28 filing is lodged ten days after the resolution, four days
-- inside its fourteen. The corporate secretarial deadline list shows a
-- practice that filed on time rather than one that did not.
--
-- ## What this does not do
--
-- It does not generate a document. `corp_generate_document` is a user
-- action and the demo has never pre-generated one; the letterhead
-- appears when somebody asks for a resolution, which is where they
-- would meet it. Seeding a document to prove a merge field would be
-- asserting the seed rather than the rule.
-- ---------------------------------------------------------------------

create or replace function app.demo_amanah_name_change(
  p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_today  date := app.today();
  v_on     date := (v_today - interval '4 months')::date;
  v_entity uuid;
  v_old    text;
  v_filing uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  select id, name into v_entity, v_old
    from public.corp_entities
   where org_id = p_org and name like 'Kilang%';

  -- `0188` seeds it. Saying so beats renaming whatever happens to be
  -- first, which would make the demo depend on row order.
  if v_entity is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Amanah name change: skipped, Kilang Lestari is not there.';
  end if;

  v_filing := public.change_company_name(
    v_entity, 'Kilang Lestari Bersatu Sdn Bhd', v_on);

  -- Lodged four days inside the fourteen s.28 allows. Left open, the
  -- demo would show a client in breach on every screen that counts
  -- statutory deadlines, which is the reason `0426` left this out.
  update public.corp_filings
     set status      = 'lodged',
         lodged_on   = v_on + 10,
         lodged_by   = p_owner,
         ssm_reference = 'SSM-' || to_char(v_on, 'YYYYMMDD') || '-KL',
         updated_at  = now()
   where id = v_filing;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Amanah name change: %s became Kilang Lestari Bersatu Sdn Bhd on '
    '%s, so its documents carry both names until %s, and the s.28 '
    'filing is lodged.',
    v_old, to_char(v_on, 'FMDD FMMon YYYY'),
    to_char((v_on + interval '12 months')::date, 'FMDD FMMon YYYY'));
end $$;

comment on function app.demo_amanah_name_change(uuid, uuid) is
  'One client company renamed four months ago, through the proper door, '
  'with its s.28 filing lodged -- so the twelve-month letterhead s.28(4) '
  'requires can be seen in a demo without also showing a breach.';

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
  v_fs_a text; v_fs_s text; v_name_a text;
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
    '%s Rebuilt 6 tenants, 8 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_name_a, v_books_h, v_warung_txt,
    v_salon_txt, v_stall_txt);
end;
$$;

-- ---------------------------------------------------------------------
-- Through the door
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_amanah_name_change';

  -- Writing `former_names` directly would seed the same three columns
  -- and skip the rule that gives them meaning, which is exactly what
  -- `0377` built two functions to stop.
  if v_src !~ '\mchange_company_name\M' then
    raise exception
      'FAIL 0427: the demo renames a company without going through '
      'change_company_name, so it demonstrates the data and not the '
      'rule.' using errcode = '23514';
  end if;

  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_rebuild';
  if v_src !~ '\mdemo_amanah_name_change\M' then
    raise exception
      'FAIL 0427: demo_rebuild does not call demo_amanah_name_change, '
      'so the seed never runs.' using errcode = '23514';
  end if;
end $$;
