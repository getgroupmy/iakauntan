-- ---------------------------------------------------------------------
-- 0233  A demo tenant for every module
-- ---------------------------------------------------------------------
--
-- `demo_rebuild.sql` asserts that no active module is left without a
-- demo tenant to show it in -- the same shape of gate as the one that
-- refuses a new POS business type until somewhere sells it. 0231 added
-- two modules and only one of them landed anywhere: the warung buys
-- loyalty in its own seed, and nothing bought memberships, so the gate
-- fired.
--
-- The salon is where memberships belong; it has sold a monthly facial
-- package since 0222. But its module list lives inside `app.demo_salon`,
-- which is three hundred lines, and restating that to add one word is
-- the diff nobody can check.
--
-- ## Enabled from the data, not from a list
--
-- So instead of naming modules per tenant, this asks what each demo
-- tenant actually has: an outlet means the till, a membership means
-- memberships, a ticket means the service desk. That is the same
-- mapping 0232 used to avoid withdrawing access from live companies,
-- and it is written by hand for the same reason -- which table proves a
-- module is in use is a judgement about the product, not something a
-- catalogue query knows.
--
-- The point of doing it this way is that the next module added to the
-- price list cannot quietly fail that gate: seed a tenant with data for
-- it and the entitlement follows.
--
-- `app.demo_rebuild` is restated to call it. That is the fourth copy of
-- a hundred-and-twenty-line function in this repository, which is a
-- real cost -- it is paid here because the alternative is restating a
-- three-hundred-line one, and because this change stops the class of
-- failure rather than the instance.

create or replace function app.demo_modules_in_use()
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select distinct x.org_id, x.module_code
      from (
        select org_id, 'pos'          as module_code from public.pos_outlets
        union all
        select org_id, 'loyalty'      from public.loyalty_programs
        union all
        select org_id, 'memberships'  from public.pos_memberships
        union all
        select org_id, 'ticketing'    from public.tickets
        union all
        select org_id, 'hr'           from public.employees
        union all
        select org_id, 'fixed_assets' from public.fixed_assets
        union all
        select org_id, 'inventory'    from public.warehouses
        union all
        select org_id, 'purchases'    from public.purchase_documents
      ) x
      join public.organizations g on g.id = x.org_id and g.is_demo
     where not exists (
       select 1 from public.org_modules om
        where om.org_id = x.org_id and om.module_code = x.module_code
          and om.is_enabled)
  loop
    insert into public.org_modules (org_id, module_code, is_enabled, enabled_at, notes)
    values (r.org_id, r.module_code, true, now(),
            'Enabled by app.demo_modules_in_use: the tenant has data for it.')
    on conflict (org_id, module_code) do update
      set is_enabled = true, expires_at = null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function app.demo_modules_in_use() from public, anon, authenticated;

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
    v_sinar, true, date_trunc('year', current_date)::date - 365,
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
