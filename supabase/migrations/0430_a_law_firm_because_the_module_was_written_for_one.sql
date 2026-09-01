-- ---------------------------------------------------------------------
-- A law firm, because the legal module was written for one
--
-- `0429` found this and left it as its own piece of work. The `legal`
-- module describes itself as "Legal Firm Accounting -- Matters, client
-- account segregation and time recording for law firms", and it was
-- switched on at Amanah Setiausaha, a company secretarial practice.
-- Not because anybody thought a corp-sec practice holds client money
-- under the Solicitors' Accounts Rules, but because
-- `supabase/tests/demo_rebuild.sql` asserts that "no active module is
-- left without a demo tenant to show it in" and a tick satisfies it.
--
-- Which is `0426`'s finding one level up. There, a module was enabled
-- with nothing in it; here, a module is enabled on a tenant of the
-- wrong kind. Seeding matters and client money for Amanah would have
-- satisfied both assertions and modelled the practice as something it
-- is not.
--
-- So: Guaman Aziz & Rakan, advocates and solicitors, a partnership in
-- Kuala Lumpur. `legal` comes off Amanah in the same migration, because
-- leaving it on would leave the wrong answer in place beside the right
-- one.
--
-- ## What the module actually has to show
--
-- `supabase/tests/client_account.sql` opens by stating the two rules
-- this is all built around, and neither has ever been visible in a
-- demo:
--
--   1. Client money is kept in a client account, separate from the
--      firm's own, and never mixed with office money.
--   2. Money held for one client is not used for another. A client
--      ledger cannot go into debit, however healthy the account is
--      overall -- enforced by `app.assert_client_funds`, a deferred
--      constraint trigger.
--
-- So the seed is built around the client-money cycle rather than around
-- matters as a list:
--
--   * **Sale of a house** (conveyancing, Puan Aminah). RM 50,000 comes
--     in on account. RM 42,300 goes out to the vendor's solicitors on
--     completion. The firm bills its fee and takes it from client to
--     office by `transfer_to_office`, which is the only lawful way the
--     money crosses. What is left is still the client's.
--   * **A tenancy dispute** (litigation, Encik Rajan). No money held;
--     time recorded and billed with `bill_matter_time`, so the matter
--     shows the other half of a firm's income.
--   * **Shareholders' agreement** (corporate, Lim Holdings). An agreed
--     fixed fee with more time recorded against it than the fee
--     covers, so `report_matters_over_agreed_fee` -- which exists to
--     tell a partner a job has gone over -- has something to say.
--
-- Every client-money movement goes through `post_client_transaction`,
-- which is what writes the double entry to 1150 and 2300 and moves the
-- bank balance. Writing the ledger by hand would seed the same numbers
-- and skip the rule that client money is a liability and never income
-- -- if it ever landed in revenue the firm would be paying tax on money
-- it does not own.
--
-- ## What is not here
--
-- No breach. The demo does not show a client ledger in debit or client
-- money in the office account, because both are refused and a demo of a
-- refusal is a test, not a demo. `client_account.sql` asserts both, and
-- that is where they belong.
-- ---------------------------------------------------------------------

create or replace function app.demo_legal_guaman(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp as $$
declare
  v_today  date := app.today();
  v_client uuid;
  v_office uuid;
  v_office_acct uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_m1 uuid; v_m2 uuid; v_m3 uuid;
  v_txn uuid;
  v_rate numeric(18, 2) := 450.00;
  v_inv2 uuid;
  v_held numeric(18, 2);
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_owner, 'role', 'authenticated')::text, true);

  -- The client account, 1150 and 2300, all from the setup function
  -- rather than by hand: a client account this seed created itself
  -- might not be one `is_client_account` recognises, and then the whole
  -- demo would be office money wearing a label.
  perform public.setup_legal_module(p_org);
  select b.id into v_client from public.bank_accounts b
   where b.org_id = p_org and b.is_client_account;
  if v_client is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Guaman Aziz: skipped, the legal setup made no client account.';
  end if;

  select id into v_office_acct from public.accounts
   where org_id = p_org and code = '1120';
  insert into public.bank_accounts
    (org_id, account_id, name, bank_name, account_number, currency,
     account_type, is_client_account, opening_balance, current_balance,
     is_default, is_active)
  values (p_org, v_office_acct, 'Office Current', 'Maybank', '514022331',
          'MYR', 'current', false, 0, 0, true, true)
  returning id into v_office;

  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-001', 'Puan Aminah Yusof', 'customer',
          'aminah@guamanaziz.demo') returning id into v_c1;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-002', 'Encik Rajan Menon', 'customer',
          'rajan@guamanaziz.demo') returning id into v_c2;
  insert into public.contacts (org_id, code, name, contact_type, email)
  values (p_org, 'CL-003', 'Lim Holdings Sdn Bhd', 'customer',
          'accounts@limholdings.demo') returning id into v_c3;

  v_m1 := public.open_matter(
    p_org, 'M-2026-001', 'Sale of a house at Taman Seri',
    v_c1, 'Chong Wei Seng', 'conveyancing', p_owner, p_owner,
    null, v_rate, null);
  v_m2 := public.open_matter(
    p_org, 'M-2026-002', 'Tenancy dispute — Lot 14 Jalan Ampang',
    v_c2, 'Harta Sewa Sdn Bhd', 'litigation', p_owner, p_owner,
    null, v_rate, null);
  v_m3 := public.open_matter(
    p_org, 'M-2026-003', 'Shareholders'' agreement',
    v_c3, null, 'corporate', p_owner, p_owner,
    6000, v_rate, null);

  -- ------------------------------------------------------------------
  -- The client-money cycle, on the conveyancing matter
  -- ------------------------------------------------------------------
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     created_by)
  values (p_org, v_m1, 'CT-2026-001', v_today - 45, 'receipt',
          v_client, 50000, 'MYR',
          'Deposit and completion money on account', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- Negative, because `post_client_transaction` takes the amount as the
  -- caller signs it: `v_amount := v_txn.amount` and the double entry is
  -- built from `greatest(v_amount, 0)` and `greatest(-v_amount, 0)`.
  -- Money out written as a positive number would debit the client bank
  -- again -- the demo would show RM96,800 held against RM50,000 ever
  -- received, and the books would still balance.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     payee, created_by)
  values (p_org, v_m1, 'CT-2026-002', v_today - 20, 'payment',
          v_client, -42300, 'MYR',
          'Balance purchase price to the vendor''s solicitors',
          'Tetuan Chong & Co', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- The only lawful way the firm's fee crosses from client to office.
  insert into public.client_account_transactions
    (org_id, matter_id, transaction_no, transaction_date,
     transaction_type, bank_account_id, amount, currency, description,
     created_by)
  values (p_org, v_m1, 'CT-2026-003', v_today - 12, 'transfer_to_office',
          v_client, -4500, 'MYR',
          'Fees and disbursements on the completed sale', p_owner)
  returning id into v_txn;
  perform public.post_client_transaction(v_txn);

  -- ------------------------------------------------------------------
  -- Time, on the two matters that are billed by the hour
  -- ------------------------------------------------------------------
  insert into public.time_entries
    (org_id, matter_id, user_id, entry_date, description, activity_code,
     minutes, hourly_rate, amount, is_billable)
  values
    (p_org, v_m2, p_owner, v_today - 30,
     'Client attendance and review of the tenancy agreement', 'ATTEND',
     90, v_rate, round(90 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 26,
     'Letter of demand drafted and sent', 'DRAFT',
     120, v_rate, round(120 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 18,
     'Telephone attendance on the opposing solicitors', 'ATTEND',
     30, v_rate, round(30 / 60.0 * v_rate, 2), true),
    (p_org, v_m2, p_owner, v_today - 15,
     'Internal file note after the without-prejudice call', 'ADMIN',
     20, v_rate, round(20 / 60.0 * v_rate, 2), false),
    -- More hours than the agreed fee covers, which is what
    -- `report_matters_over_agreed_fee` exists to say out loud.
    (p_org, v_m3, p_owner, v_today - 40,
     'First draft of the shareholders'' agreement', 'DRAFT',
     360, v_rate, round(360 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 33,
     'Two rounds of amendments after the board meeting', 'DRAFT',
     300, v_rate, round(300 / 60.0 * v_rate, 2), true),
    (p_org, v_m3, p_owner, v_today - 22,
     'Completion meeting and execution', 'ATTEND',
     240, v_rate, round(240 / 60.0 * v_rate, 2), true);

  -- The litigation matter is billed; the corporate one is not, so the
  -- over-the-agreed-fee report has an open matter to report on rather
  -- than a closed one nobody can act on.
  v_inv2 := public.bill_matter_time(v_m2, v_today - 40, v_today,
                                    v_today + 14);

  -- Read from the bank account the postings moved, not recomputed from
  -- the transactions with a sign convention of this function's own. A
  -- summary that does its own arithmetic can agree with itself while
  -- disagreeing with the ledger, which is how the sign error above
  -- survived its first run: the sentence said RM3,200 and the client
  -- account held RM96,800.
  select current_balance into v_held
    from public.bank_accounts where id = v_client;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Guaman Aziz: 3 matters for 3 clients, RM%s still held in the '
    'client account after completion money out and the fee transferred '
    'to office, one matter billed by the hour and one over its agreed '
    'fee.', to_char(v_held, 'FM999,999,990.00'));
end $$;

comment on function app.demo_legal_guaman(uuid, uuid) is
  'A law firm with client money in a client account, moved only by '
  'post_client_transaction, so the two Solicitors'' Accounts Rules the '
  'module is built around can be seen rather than only asserted.';

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
  perform app.demo_modules(v_amanah, array[
    'secretarial', 'approvals', 'einvoice', 'timesheets', 'chat',
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
    '%s Rebuilt 7 tenants, 9 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc, v_crm,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_name_a, v_time_a, v_books_h,
    v_legal_txt, v_warung_txt, v_salon_txt, v_stall_txt);
end;
$$;

-- ---------------------------------------------------------------------
-- Client money moves the only way it may
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_legal_guaman';

  -- Writing the ledger by hand would seed the same numbers and skip the
  -- rule that client money is a liability and never income. And a
  -- client account this seed built itself might not be one
  -- `is_client_account` recognises, which would make the whole demo
  -- office money wearing a label.
  if v_src !~ '\mpost_client_transaction\M'
     or v_src !~ '\msetup_legal_module\M' then
    raise exception
      'FAIL 0430: client money is seeded without going through '
      'post_client_transaction, or the client account is not the one '
      'setup_legal_module makes.' using errcode = '23514';
  end if;

  select regexp_replace(p.prosrc, '--[^\n]*', '', 'g') into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'demo_rebuild';
  if v_src !~ '\mdemo_legal_guaman\M' then
    raise exception
      'FAIL 0430: demo_rebuild does not call demo_legal_guaman, so the '
      'firm is never built.' using errcode = '23514';
  end if;
  -- And the wrong answer is gone rather than left standing beside the
  -- right one: `legal` must no longer be handed to Amanah.
  if v_src ~ '''secretarial'',\s*''legal''' then
    raise exception
      'FAIL 0430: `legal` is still switched on at the company '
      'secretarial practice.' using errcode = '23514';
  end if;
end $$;
