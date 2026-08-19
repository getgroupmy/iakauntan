-- A demo tenant for the till, brought forward.
--
-- `demo_rebuild.sql` asserts that no active module is left without a
-- demo tenant to show it in, and 0206 registered `pos` in the
-- catalogue eight migrations before anything was going to enable it.
-- So CI went red on the module's very first commit — the same mistake,
-- in the same place, as the forecasting module made at 0197. Twice now
-- I have registered a module and then written the demo for it later,
-- and both times the gate that exists precisely to catch that caught
-- it. The rule is: a module joins the catalogue in the same breath as
-- somewhere to look at it.
--
-- ## What there is to look at, honestly
--
-- A till, and nothing sold through it yet. `pos_sales` arrives in the
-- next migration. That is a thin demo and it is a true one: an outlet
-- with a warehouse behind it and two registers you can open a drawer
-- on is exactly what 0206 built, and this seeder grows a stage at a
-- time along with the module rather than pretending to be finished.
--
-- ## Two registers, deliberately
--
-- A counter and a tablet, because the difference between them is the
-- whole point of the form-factor question: same outlet, same stock,
-- same shift discipline, different screen. A single register would
-- demonstrate a till; two demonstrate that the register is a thing in
-- its own right.
--
-- ## The walk-in
--
-- An ordinary contact named for what it is, because
-- `sales_documents.contact_id` is not null and most shop sales are to
-- somebody who will never be on the customer list. Marked as a
-- customer so it ages and posts like any other, and given a code that
-- says plainly what it is for — somebody will find it in the contact
-- list one day and needs to not delete it.

create or replace function app.demo_pos_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_wh      uuid;
  v_walkin  uuid;
  v_outlet  uuid;
  v_tills   integer := 0;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array['pos']);

  insert into public.pos_settings (org_id, round_cash_to_5sen, variance_tolerance)
  values (p_org, true, 5.00)
  on conflict (org_id) do update
     set round_cash_to_5sen = excluded.round_cash_to_5sen,
         variance_tolerance = excluded.variance_tolerance;

  select w.id into v_wh
    from public.warehouses w
   where w.org_id = p_org and w.is_active
   order by w.code
   limit 1;

  insert into public.contacts (org_id, code, name, contact_type, is_active)
  values (p_org, 'WALK-IN', 'Counter sales (walk-in)', 'customer', true)
  on conflict (org_id, code) do nothing;

  select c.id into v_walkin
    from public.contacts c where c.org_id = p_org and c.code = 'WALK-IN';

  insert into public.pos_outlets (
    org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
    receipt_header, receipt_footer, prices_include_tax)
  values (
    p_org, 'SHOP', 'Sinar Trade Counter', 'retail', v_wh, v_walkin,
    'Sinar Teknologi Sdn Bhd — Trade Counter',
    'Goods sold are not returnable after 7 days. Thank you.',
    -- Wholesale quotes before tax; the trade counter follows the
    -- company rather than the high street.
    false)
  on conflict (org_id, code) do update
     set warehouse_id = excluded.warehouse_id,
         walk_in_contact_id = excluded.walk_in_contact_id
  returning id into v_outlet;

  if v_outlet is null then
    select o.id into v_outlet
      from public.pos_outlets o where o.org_id = p_org and o.code = 'SHOP';
  end if;

  -- A counter terminal and a tablet on the same outlet. Same stock,
  -- same shift discipline, different screen.
  insert into public.pos_registers (org_id, outlet_id, code, name, device_note)
  values
    (p_org, v_outlet, 'T1', 'Front counter',
     'Counter terminal by the door, cash drawer under the till'),
    (p_org, v_outlet, 'T2', 'Roaming tablet',
     'Tablet used on the warehouse floor for trade pick-ups')
  on conflict (org_id, code) do nothing;

  select count(*) into v_tills
    from public.pos_registers r where r.org_id = p_org and r.outlet_id = v_outlet;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Sinar counter: 1 outlet selling from warehouse %s, %s register(s), '
    'walk-in customer set up. No sale has been rung through it yet.',
    coalesce((select w.code from public.warehouses w where w.id = v_wh), 'none'),
    v_tills);
end;
$$;

revoke all on function app.demo_pos_sinar(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Into the rebuild
-- ---------------------------------------------------------------------
--
-- Restated in full rather than patched, for the reason 0201 gives: a
-- `create or replace` that only somebody's memory says matches the
-- previous body is how a rebuild quietly loses a tenant. The only
-- additions are the counter and its place in the summary.
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
  v_cash text; v_assets text; v_pay text; v_desk text; v_fc text; v_pos text;
begin
  v_removed := app.demo_teardown();

  v_demo      := app.demo_user('demo@iakauntan.com',      'Aisyah Rahman');
  v_clerk     := app.demo_user('clerk@iakauntan.com',     'Wong Mei Ling');
  v_auditor   := app.demo_user('auditor@iakauntan.com',   'Ravi Subramaniam');
  v_secretary := app.demo_user('secretary@iakauntan.com', 'Nurul Hakim');
  v_property  := app.demo_user('property@iakauntan.com',  'Tan Chee Keong');

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

  perform set_config('request.jwt.claims', '', true);

  return format('%s Rebuilt 3 tenants, 5 logins. %s %s %s %s %s %s %s %s %s',
                v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
                v_pos, v_books_a, v_books_h);
end;
$$;
