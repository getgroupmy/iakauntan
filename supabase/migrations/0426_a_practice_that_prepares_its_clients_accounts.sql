-- ---------------------------------------------------------------------
-- A practice that prepares its clients' accounts
--
-- `mbrs` is enabled on a demo tenant and no demo tenant has ever had a
-- set of accounts. `app.demo_rebuild` turns the module on for Sinar,
-- somebody signs in, opens Financial statements, and reads "No accounts
-- prepared yet".
--
-- Measured rather than assumed. Every module enabled on a demo tenant,
-- against a table that would hold its data:
--
--   Amanah  approvals, crm, einvoice, legal, purchases, timesheets
--   Harta   approvals, crm, einvoice, fixed_assets, purchases
--   Roti    crm, einvoice, purchases
--   Seri Ayu crm, einvoice, purchases
--   Sinar   approvals, branches, crm, einvoice, manufacturing, mbrs,
--           timesheets
--   Warung  crm, einvoice, purchases
--
-- (`attachments`, `mailbox` and `workspace_address` are left out of that
-- list: `0324` and `0329` enable them deliberately without rows, and say
-- why.)
--
-- So this is one of eleven, not the only one. It is first because three
-- pieces of work landed on it this week and none of them can be seen:
-- the s.258 countdown on the filings list, the company each set of
-- accounts belongs to, and the deadline arithmetic behind both. The
-- other ten are recorded above rather than fixed here; seeding eleven
-- modules in one migration would be a worse migration and a worse
-- review.
--
-- ## Both arrangements, because they look different
--
-- `demo_rebuild` had `mbrs` on Sinar, which keeps its own books. That is
-- the ordinary case: a company preparing its own accounts has no
-- `corp_entities` row, `report_fs_deadlines` falls back to the
-- organization's own name, and the filing screen says "This
-- organization's own accounts". One row, no company column to speak of.
-- Sinar keeps `mbrs` and gets one set of accounts, three months past its
-- year end and comfortably in hand.
--
-- Amanah is the corporate secretarial practice, and `0188` already gives
-- it three client companies -- Kilang Lestari, Pinang Holdings Berhad
-- and Bayu Digital. A practice preparing accounts for the companies
-- whose registers it keeps is what the module is for, and it is the only
-- arrangement in which the company column means anything. It is the one
-- that shows a list worth reading.
--
-- ## Three filings, in three states
--
-- Dated from `app.today()` so the demo stays sensible whenever it is
-- rebuilt, and chosen so the deadline list has something to say:
--
--   * **Kilang Lestari** -- last calendar year, audited, lodged, with an
--     MBRS reference. The settled case, and it is absent from the
--     deadline list because `report_fs_deadlines` excludes what is
--     already lodged.
--   * **Pinang Holdings Berhad** -- year ended five months ago, frozen,
--     audited. s.258 gives six months to circulate and thirty days after
--     that to lodge, so it sits about two months from its date: the
--     countdown. Measured on a rebuild, not estimated -- fifty-eight
--     days, against Bayu's sixty-five days past.
--   * **Bayu Digital** -- year ended nine months ago, still draft, and
--     audit-exempt on the dormant ground. Past its date: the red row,
--     which is the one the list exists to surface.
--
-- Each carries `corp_entity_id`. That column is the whole reason
-- `fs_set_entity` exists, and until this week nothing wrote it.
--
-- ## What is deliberately not here
--
-- No demo company has been renamed, so `0425`'s s.28(4) letterhead --
-- the former name alongside the new one for twelve months -- still
-- cannot be seen in a demo. Doing it properly means calling
-- `change_company_name`, which opens a s.28 filing with a fourteen-day
-- deadline, and a demo that shows a client company in breach of the
-- Companies Act is worse than one that does not show the letterhead.
-- Marking that filing lodged is a separate small piece of work and is
-- left as one rather than bolted on here.
-- ---------------------------------------------------------------------

create or replace function app.demo_amanah_accounts(
  p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_today  date := app.today();
  v_kilang uuid;
  v_pinang uuid;
  v_bayu   uuid;
  -- The year end each set of accounts is for. Kilang's is the last
  -- complete calendar year; the other two are placed by how far they
  -- are from their lodgement date rather than by the calendar, because
  -- what this demonstrates is the countdown.
  v_k_end  date := (date_trunc('year', v_today) - interval '1 day')::date;
  v_p_end  date := (date_trunc('month', v_today)
                    - interval '5 months' - interval '1 day')::date;
  v_b_end  date := (date_trunc('month', v_today)
                    - interval '9 months' - interval '1 day')::date;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  select id into v_kilang from public.corp_entities
   where org_id = p_org and name like 'Kilang%';
  select id into v_pinang from public.corp_entities
   where org_id = p_org and name like 'Pinang%';
  select id into v_bayu from public.corp_entities
   where org_id = p_org and name like 'Bayu%';

  -- Nothing to prepare accounts for. `0188` seeds all three, so this
  -- only fires if that seed changes -- and saying so is better than
  -- writing three filings with a null company on them, which is the
  -- defect this exists to demonstrate the absence of.
  if v_kilang is null or v_pinang is null or v_bayu is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Amanah accounts: skipped, the client entities are not there.';
  end if;

  insert into public.fs_filings
    (org_id, corp_entity_id, fy_start, fy_end, framework, audit_status,
     auditor_name, auditor_firm_no, auditor_signatory, audit_report_date,
     opinion, employee_count, directors_approval_date, circulated_on,
     lodged_on, mbrs_reference, status, created_by)
  values
    (p_org, v_kilang,
     (v_k_end - interval '1 year' + interval '1 day')::date, v_k_end,
     'mpers', 'audited',
     'Tan & Rekan', 'AF 1234', 'Tan Wei Ming', v_k_end + 120,
     'unmodified', 38, v_k_end + 130, v_k_end + 140, v_k_end + 160,
     'MBRS-' || to_char(v_k_end, 'YYYY') || '-004512', 'lodged', p_owner),

    (p_org, v_pinang,
     (v_p_end - interval '1 year' + interval '1 day')::date, v_p_end,
     'mfrs', 'audited',
     'Tan & Rekan', 'AF 1234', 'Tan Wei Ming', v_p_end + 110,
     'unmodified', 214, v_p_end + 120, null,
     null, null, 'frozen', p_owner),

    (p_org, v_bayu,
     (v_b_end - interval '1 year' + interval '1 day')::date, v_b_end,
     'mpers', 'audit_exempt',
     null, null, null, null,
     null, 2, null, null,
     null, null, 'draft', p_owner);

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Amanah accounts: %s sets prepared for client companies -- one '
    'lodged, one frozen and about a month from its s.258 date, one '
    'still draft and already past it.',
    (select count(*) from public.fs_filings where org_id = p_org));
end $$;

comment on function app.demo_amanah_accounts(uuid, uuid) is
  'A set of accounts for each of Amanah''s three client companies, in '
  'three states, so the MBRS module and the s.258 deadline list have '
  'something in them.';

-- ---------------------------------------------------------------------
-- And the ordinary case: a company preparing its own accounts
-- ---------------------------------------------------------------------
create or replace function app.demo_sinar_accounts(
  p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_today date := app.today();
  -- Three months back, so s.258's six months plus thirty days leaves it
  -- four months in hand. Amanah carries the late one and the lodged
  -- one; a tenant's own accounts being overdue on every demo would read
  -- as a defect in the product rather than as a state it can show.
  v_end   date := (date_trunc('month', v_today)
                   - interval '3 months' - interval '1 day')::date;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  -- No `corp_entity_id`, deliberately. Sinar has no `corp_entities` row
  -- and needs none: the fallback in `report_fs_deadlines` is written for
  -- this, and the filing screen has a sentence of its own for it.
  insert into public.fs_filings
    (org_id, fy_start, fy_end, framework, audit_status, employee_count,
     status, created_by)
  values (p_org, (v_end - interval '1 year' + interval '1 day')::date,
          v_end, 'mpers', 'audited', 4, 'draft', p_owner);

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar accounts: one set for the year ended %s, still '
                'draft and about four months from its s.258 date.',
                to_char(v_end, 'FMDD FMMon YYYY'));
end $$;

comment on function app.demo_sinar_accounts(uuid, uuid) is
  'One set of accounts for a company that keeps its own books, so the '
  'MBRS module shows the ordinary arrangement as well as a practice''s.';

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
  v_fs_a text; v_fs_s text;
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
    '%s Rebuilt 6 tenants, 8 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_books_h, v_warung_txt,
    v_salon_txt, v_stall_txt);
end;
$$;

-- ---------------------------------------------------------------------
-- The link is the point
--
-- A filing with a null `corp_entity_id` would seed the module and
-- demonstrate none of what this migration is for: `report_fs_deadlines`
-- would name Amanah on all three rows and show no registration number,
-- which is the state the product was in until this week.
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_amanah_accounts';

  if v_src !~ '\mcorp_entity_id\M' then
    raise exception
      'FAIL 0426: the seeded filings do not name a company, which is '
      'the one thing this seed exists to show.' using errcode = '23514';
  end if;

  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_rebuild';

  if v_src !~ '\mdemo_amanah_accounts\M'
     or v_src !~ '\mdemo_sinar_accounts\M' then
    raise exception
      'FAIL 0426: demo_rebuild does not call both seeds, so one of them '
      'never runs.' using errcode = '23514';
  end if;
end $$;
