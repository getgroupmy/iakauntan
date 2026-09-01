-- ---------------------------------------------------------------------
-- The hours a practice bills, and a module on the wrong kind of firm
--
-- Two findings from the register `0426` started and `0428` sharpened
-- into tenant-and-module pairs. One is fixed here; the other is written
-- down because fixing it properly is a bigger piece of work than this.
--
-- ## The one that is fixed: Amanah records no time
--
-- `timesheets` says what it is for: "Chargeable time against projects
-- and clients, billing rates per person, and turning unbilled hours
-- into an invoice". That is what a company secretarial practice does
-- all day, and `0188` already gives Amanah three clients and
-- twenty-seven fee invoices to prove it bills them. There was not one
-- time entry behind any of it.
--
-- So two engagements, a rate, a fortnight of work, and one of them
-- billed:
--
--   * **Kilang Lestari, annual compliance** -- the recurring work, and
--     the one that gets invoiced. `bill_project_time` raises the
--     invoice, marks the entries billed and puts the invoice id on
--     them. Writing `is_billed = true` by hand would set the same flag
--     and leave the invoice unwritten, so the assertions check the
--     column only that function fills in.
--   * **Bayu Digital, incorporation and first year** -- left unbilled
--     on purpose, so `report_project_budget` has work in progress to
--     show. A project screen where everything is already invoiced shows
--     nothing about a project screen.
--
-- Not every hour is chargeable. Two entries are marked non-billable --
-- a file review and a fee-note query -- because a timesheet where
-- everything bills is not a timesheet, and the difference between
-- recorded and chargeable time is most of what the module is for.
--
-- ## The one that is not: `legal` is on a firm that is not a law firm
--
-- The register carries `Amanah Setiausaha Sdn Bhd -> legal`, and the
-- honest fix is not to seed it. `legal` describes itself as "Legal Firm
-- Accounting -- Matters, client account segregation and time recording
-- for law firms". Amanah is a company secretarial practice. Client
-- account segregation is the Solicitors' Accounts Rules, and those
-- apply to solicitors; seeding matters and client money for a corp-sec
-- practice would model it as something it is not.
--
-- There is no law firm among the six demo tenants, and that is why
-- `legal` was put on Amanah: `demo_rebuild.sql` asserts that "no active
-- module is left without a demo tenant to show it in", and switching
-- `legal` on satisfies it. Which is the same defect `0426` found one
-- level down -- a guard that reads as "every module can be seen" and
-- means "every module is ticked" -- except here the tick is on a tenant
-- of the wrong kind.
--
-- The fix is a seventh demo tenant that is a law firm, with real
-- matters and a client account kept under the Rules. That is its own
-- piece of work and is left as one rather than half-done here. The
-- register line stays, and now says why.
-- ---------------------------------------------------------------------

create or replace function app.demo_amanah_time(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_today date := app.today();
  -- A fortnight back, so both engagements have a run of days behind
  -- them and the billed period is closed rather than still open.
  v_from  date := (v_today - interval '14 days')::date;
  v_kilang uuid;
  v_bayu   uuid;
  v_p1 uuid; v_p2 uuid;
  v_rate  numeric(18, 2) := 250.00;
  v_inv   uuid;
  v_mins  integer;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  select id into v_kilang from public.contacts
   where org_id = p_org and code = 'CL-001';
  select id into v_bayu from public.contacts
   where org_id = p_org and code = 'CL-003';
  if v_kilang is null or v_bayu is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Amanah time: skipped, the client contacts are not there.';
  end if;

  insert into public.projects
    (org_id, code, name, description, contact_id, start_date,
     budget_amount, is_active)
  values
    (p_org, 'ENG-001', 'Annual compliance — Kilang Lestari',
     'Annual return, financial statements lodgement and registers',
     v_kilang, (v_today - interval '3 months')::date, 12000, true),
    (p_org, 'ENG-002', 'Incorporation and first year — Bayu Digital',
     'Incorporation, constitution and the first annual cycle',
     v_bayu, (v_today - interval '2 months')::date, 8000, true);

  select id into v_p1 from public.projects
   where org_id = p_org and code = 'ENG-001';
  select id into v_p2 from public.projects
   where org_id = p_org and code = 'ENG-002';

  insert into public.billing_rates
    (org_id, user_id, project_id, effective_from, hourly_rate, notes)
  values (p_org, p_owner, null, (v_today - interval '1 year')::date,
          v_rate, 'Standard partner rate');

  -- Chargeable work on both engagements, and two hours that are not.
  -- A timesheet where everything bills is not a timesheet: the gap
  -- between recorded and chargeable time is most of what the module is
  -- for.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, activity_code,
     minutes, hourly_rate, amount, is_billable)
  values
    (p_org, v_p1, p_owner, v_from + 1,
     'Drafting the annual return and checking the register of members',
     'ADMIN', 150, v_rate, round(150 / 60.0 * v_rate, 2), true),
    (p_org, v_p1, p_owner, v_from + 2,
     'Directors'' resolution and circulation of the accounts',
     'ADMIN', 90, v_rate, round(90 / 60.0 * v_rate, 2), true),
    (p_org, v_p1, p_owner, v_from + 5,
     'Lodgement with SSM and filing the acknowledgement',
     'FILING', 60, v_rate, round(60 / 60.0 * v_rate, 2), true),
    (p_org, v_p1, p_owner, v_from + 6,
     'Internal file review before closing the year', 'ADMIN',
     45, v_rate, round(45 / 60.0 * v_rate, 2), false),
    (p_org, v_p2, p_owner, v_from + 3,
     'Name search and incorporation documents', 'ADMIN',
     120, v_rate, round(120 / 60.0 * v_rate, 2), true),
    (p_org, v_p2, p_owner, v_from + 8,
     'Constitution drafted and adopted', 'ADVICE',
     180, v_rate, round(180 / 60.0 * v_rate, 2), true),
    (p_org, v_p2, p_owner, v_from + 11,
     'First board meeting papers', 'ADMIN',
     75, v_rate, round(75 / 60.0 * v_rate, 2), true),
    (p_org, v_p2, p_owner, v_from + 12,
     'Query from the client about the fee note', 'ADMIN',
     30, v_rate, round(30 / 60.0 * v_rate, 2), false);

  -- Billed through the function that owns it. It writes the invoice,
  -- marks the entries billed and puts the invoice id on them; setting
  -- `is_billed` by hand would set the same flag and leave no invoice.
  v_inv := public.bill_project_time(v_p1, v_from, v_today, v_today + 30);

  select coalesce(sum(minutes), 0) into v_mins
    from public.time_entries where org_id = p_org;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Amanah time: %s hours recorded across two engagements, %s of them '
    'chargeable; the compliance engagement is invoiced and the '
    'incorporation one is still work in progress.',
    to_char(v_mins / 60.0, 'FM990.0'),
    to_char((select coalesce(sum(minutes), 0) from public.time_entries
              where org_id = p_org and is_billable) / 60.0, 'FM990.0'));
end $$;

comment on function app.demo_amanah_time(uuid, uuid) is
  'Two engagements, a rate, a fortnight of work and one invoice raised '
  'from it, so the timesheets module is not an empty screen for the '
  'tenant whose whole business is billing time.';

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
  v_time_a  := app.demo_amanah_time(v_amanah, v_secretary);

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
    '%s Rebuilt 6 tenants, 8 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc, v_crm,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_name_a, v_time_a, v_books_h,
    v_warung_txt, v_salon_txt, v_stall_txt);
end;
$$;

-- ---------------------------------------------------------------------
-- Billed by the function that raises the invoice
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_amanah_time';

  if v_src !~ '\mbill_project_time\M' then
    raise exception
      'FAIL 0429: the time is marked billed without raising an invoice, '
      'which is the whole of what the module does.' using errcode = '23514';
  end if;

  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_rebuild';
  if v_src !~ '\mdemo_amanah_time\M' then
    raise exception
      'FAIL 0429: demo_rebuild does not call demo_amanah_time, so the '
      'seed never runs.' using errcode = '23514';
  end if;
end $$;
