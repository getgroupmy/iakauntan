-- ---------------------------------------------------------------------
-- 0436  The last three empty screens
-- ---------------------------------------------------------------------
-- `branches` and `timesheets` on Sinar, and `fixed_assets` on Harta.
-- The last three lines of the register in `demo_rebuild.sql` that are
-- gaps rather than deliberate absences -- the seven `einvoice` lines
-- stay, because `demo_credentials_locked` withholds LHDN credentials on
-- purpose and a submission row would be a lie about a connection nobody
-- made.
--
-- Three in one migration, which is a departure. Each is small, and each
-- needs `app.demo_rebuild` restated around it: three migrations would
-- be three copies of a 200-line function and three chances to drop an
-- earlier one's call to a careless paste, which is the failure the
-- restatement guards at the bottom of `0433`, `0434` and `0435` exist
-- to catch. One restatement is one chance.
--
-- The decision rule from `0432`-`0435`, applied to each before writing
-- anything. All three come from `app.demo_modules` rather than
-- `app.seed_org_modules`, so all three could be turned off -- and two
-- of them could be turned off without breaking the coverage assertion,
-- because `timesheets` is also on Amanah and Guaman and `fixed_assets`
-- is also on Sinar. So this is a judgement about the business, not
-- about entitlement, and it goes the other way for all three:
--
--   * A system integrator that wholesales computers, keeps a warehouse
--     and -- since `0435` -- assembles servers, sells "Installation and
--     Commissioning" by the day. Engineers record hours against a job
--     and the job is invoiced. That is what `timesheets` is.
--   * A company of that size with customers in Penang opens a branch
--     there. `branches` exists for the question "how did the northern
--     office do", and Sinar is the only demo tenant big enough to ask.
--   * A managing agent does not own the common property -- the JMB
--     does -- but it owns its own service van and office fit-out, and
--     depreciates them. `fixed_assets` on Harta is not a stretch.
--
-- A branch nobody trades through is a row, not a demo, so the northern
-- office raises its own invoices. Raises, not inherits: the first draft
-- of this seed back-tagged Sinar's existing year of documents and was
-- refused -- `branch_id` is one of the figures a journal is built from,
-- and the posting guard will not let it move on a posted document
-- because the ledger is append-only and the document and the accounts
-- would then disagree with no way to reconcile them.
--
-- That refusal is also the truthful shape, so the seed keeps it rather
-- than working around it. A company that opens a branch in March has a
-- January that happened at head office; retro-assigning it would teach
-- the opposite of what the guard enforces.
--
-- Three mutants applied and measured, one per demo, each killed for its
-- own reason: every hour marked billable -- killed, "some of which bill
-- nothing"; the northern invoices raised with no branch on them --
-- killed, "with trade actually raised in it"; Harta's assets acquired
-- and never depreciated -- killed, "and has been depreciating it".
--
-- One thing this migration found rather than fixed, recorded so the
-- next reader is not surprised by it. Sinar is SST-registered, and the
-- invoice `bill_project_time` raised for the engineer's days carries
-- no service tax at all: `app.bill_time_internal` writes `tax_rate =>
-- 0` and no tax code, unconditionally, for every organization. That is
-- a registered company billing professional services and declaring
-- nothing on them. It is a statutory defect, not a demo gap, and it is
-- fixed in `0437` rather than here, because a seed is the wrong place
-- to correct what a posting function does.
--
-- And the timesheet has unbillable hours on it. A timesheet where
-- everything bills is not a timesheet: the gap between recorded and
-- chargeable time is most of what the module is for, which is the same
-- point `0429` made for Amanah and is worth making twice because it is
-- the thing a seed most easily gets wrong.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- A second office, and the trade that goes through it
-- ---------------------------------------------------------------------
create or replace function app.demo_branches_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_north uuid;
  v_cust  uuid;
  v_item  uuid;
  v_st8   uuid;
  v_doc   uuid;
  v_i     integer;
  v_moved integer := 0;
begin
  perform app.demo_act_as(p_owner);

  insert into public.branches
    (org_id, code, name, registration_no, address_line1, city,
     state_code, postcode, phone, email, is_default)
  values (p_org, 'HQ', 'Petaling Jaya (Head Office)', '201901004567',
          'Level 8, Menara Sinar, Jalan Utara', 'Petaling Jaya', '10',
          '46200', '03-7955 1200', 'accounts@sinartek.demo', true)
  on conflict (org_id, code) do nothing;

  insert into public.branches
    (org_id, code, name, registration_no, address_line1, city,
     state_code, postcode, phone, email, is_default)
  values (p_org, 'PG', 'Bayan Lepas (Northern Branch)', '201901004567',
          'Suite 3-2, Menara BLS, Lebuh Tenggiri', 'Bayan Lepas', '07',
          '11900', '04-643 7788', 'utara@sinartek.demo', false)
  on conflict (org_id, code) do nothing;

  select id into v_north from public.branches where org_id = p_org and code = 'PG';

  -- The northern trade is RAISED there, not moved there afterwards.
  -- `branch_id` is one of the figures a journal is built from, so the
  -- posting guard refuses to change it on a posted document -- the
  -- ledger is append-only and the document and the accounts would
  -- disagree with no way to reconcile them. Measured: the first draft
  -- of this seed back-tagged Sinar's year of invoices and was refused
  -- on INV-2026-00021.
  --
  -- Which is also the truthful shape. A company that opens a branch in
  -- March has a January that happened at head office and belongs to
  -- nobody else, and a demo that retro-assigned it would be teaching
  -- the opposite of what the guard enforces.
  select id into v_cust from public.contacts
   where org_id = p_org and contact_type in ('customer', 'both')
   order by code limit 1;
  select id into v_item from public.items
   where org_id = p_org and code = 'ITM-110';
  select id into v_st8 from public.tax_codes
   where org_id = p_org and code = 'ST8';
  if v_cust is null or v_item is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Sinar branches: two offices, no trade -- the catalogue is not there.';
  end if;

  for v_i in 1..3 loop
    insert into public.sales_documents
      (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
       currency, exchange_rate, branch_id, created_by)
    values (p_org, 'invoice',
            app.next_document_number_internal(p_org, 'invoice'),
            app.today() - (v_i * 9), app.today() - (v_i * 9) + 30,
            v_cust, 'draft', 'MYR', 1, v_north, p_owner)
    returning id into v_doc;

    insert into public.sales_document_lines
      (org_id, document_id, line_no, line_type, item_id, description,
       quantity, uom_code, unit_price, tax_code_id, tax_rate)
    select p_org, v_doc, 1, 'item', i.id, i.name, v_i, i.uom_code,
           i.unit_price, v_st8, t.rate
      from public.items i cross join public.tax_codes t
     where i.id = v_item and t.id = v_st8;

    perform app.post_sales_document_internal(v_doc);
    v_moved := v_moved + 1;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar branches: head office and Bayan Lepas, with %s '
                'invoices raised in the north.', v_moved);
end $$;

-- ---------------------------------------------------------------------
-- The days an engineer is on site
-- ---------------------------------------------------------------------
create or replace function app.demo_time_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_today date := app.today();
  v_from  date := (v_today - interval '14 days')::date;
  v_cust  uuid;
  v_proj  uuid;
  v_rate  numeric(18, 2) := 180.00;
  v_inv   uuid;
  v_mins  integer;
begin
  perform app.demo_act_as(p_owner);

  select id into v_cust from public.contacts
   where org_id = p_org and contact_type in ('customer', 'both')
   order by code limit 1;
  if v_cust is null then
    perform set_config('request.jwt.claims', '', true);
    return 'Sinar time: skipped, there is no customer to bill.';
  end if;

  insert into public.projects
    (org_id, code, name, description, contact_id, start_date,
     budget_amount, is_active)
  values (p_org, 'JOB-001', 'Rack rollout and commissioning',
          'Install, cable and commission the servers built on MO-000001',
          v_cust, (v_today - interval '1 month')::date, 15000, true)
  on conflict (org_id, code) do nothing;
  select id into v_proj from public.projects
   where org_id = p_org and code = 'JOB-001';

  insert into public.billing_rates
    (org_id, user_id, project_id, effective_from, hourly_rate, notes)
  values (p_org, p_owner, null, (v_today - interval '1 year')::date,
          v_rate, 'Standard engineer rate')
  on conflict do nothing;

  -- Chargeable days on site, and time that is not chargeable. The gap
  -- between recorded and billable hours is most of what this module is
  -- for; a timesheet where everything bills is not one.
  insert into public.time_entries
    (org_id, project_id, user_id, entry_date, description, activity_code,
     minutes, hourly_rate, amount, is_billable)
  values
    (p_org, v_proj, p_owner, v_from + 1,
     'Rack and cable the cabinet on site', 'INSTALL',
     420, v_rate, round(420 / 60.0 * v_rate, 2), true),
    (p_org, v_proj, p_owner, v_from + 2,
     'Firmware, imaging and network configuration', 'INSTALL',
     390, v_rate, round(390 / 60.0 * v_rate, 2), true),
    (p_org, v_proj, p_owner, v_from + 3,
     'Failover testing and handover with the customer', 'COMMISSION',
     300, v_rate, round(300 / 60.0 * v_rate, 2), true),
    (p_org, v_proj, p_owner, v_from + 4,
     'Travel to Bayan Lepas and back', 'TRAVEL',
     240, v_rate, round(240 / 60.0 * v_rate, 2), false),
    (p_org, v_proj, p_owner, v_from + 8,
     'Rework after a faulty backplane -- not chargeable', 'INSTALL',
     180, v_rate, round(180 / 60.0 * v_rate, 2), false);

  -- Billed through the function that owns it, so the entries are marked
  -- and pointed at the invoice it raised. Writing `is_billed` by hand
  -- would leave the same rows looking billed with no invoice behind
  -- them.
  v_inv := public.bill_project_time(v_proj, v_from, v_today);

  select coalesce(sum(minutes), 0) into v_mins from public.time_entries
   where org_id = p_org and project_id = v_proj and is_billable;

  perform set_config('request.jwt.claims', '', true);

  return format('Sinar time: %s chargeable minutes on JOB-001, billed '
                'on one invoice, and two entries that bill nothing.',
                v_mins);
end $$;

-- ---------------------------------------------------------------------
-- What a managing agent owns itself
-- ---------------------------------------------------------------------
create or replace function app.demo_assets_harta(p_org uuid, p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_ppe   uuid;
  v_veh   uuid;
  v_accum uuid;
  v_exp   uuid;
  v_bank  uuid;
  v_a     record;
  v_month date;
  v_runs  integer := 0;
begin
  perform app.demo_act_as(p_owner);

  select id into v_ppe   from public.accounts where org_id = p_org and code = '1510';
  select id into v_veh   from public.accounts where org_id = p_org and code = '1520';
  select id into v_accum from public.accounts where org_id = p_org and code = '1590';
  select id into v_exp   from public.accounts where org_id = p_org and code = '6400';
  select id into v_bank  from public.accounts where org_id = p_org and code = '1120';

  -- Its own things, not the buildings it manages. A managing agent that
  -- carried the common property on its balance sheet would be a demo of
  -- a serious accounting error.
  insert into public.fixed_assets
    (org_id, asset_no, name, description, category, asset_account_id,
     accumulated_account_id, expense_account_id, acquisition_date, cost,
     residual_value, method, useful_life_months, location, created_by)
  values
    (p_org, 'FA-H01', 'Service van (BQK 7781)',
     'Toyota Hiace for the maintenance rounds', 'Motor vehicles',
     v_veh, v_accum, v_exp,
     date_trunc('year', app.today())::date + 31, 128000, 18000,
     'straight_line', 60, 'Shah Alam', p_owner),
    (p_org, 'FA-H02', 'Office fit-out',
     'Counter, partitions and the records room', 'Furniture and fittings',
     v_ppe, v_accum, v_exp,
     date_trunc('year', app.today())::date + 60, 42800, 0,
     'straight_line', 120, 'Shah Alam', p_owner),
    (p_org, 'FA-H03', 'Site inspection equipment',
     'Thermal camera, moisture meter and tablets', 'Office equipment',
     v_ppe, v_accum, v_exp,
     date_trunc('year', app.today())::date + 110, 19600, 0,
     'straight_line', 36, 'Shah Alam', p_owner)
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

  -- Depreciated month by month rather than in one catch-up, because a
  -- register with a single charge on it says nothing about the schedule
  -- an auditor asks for.
  v_month := date_trunc('year', app.today())::date;
  while v_month < date_trunc('month', app.today())::date loop
    if public.run_depreciation(
         p_org, ((v_month + interval '1 month')::date - 1)) is not null then
      v_runs := v_runs + 1;
    end if;
    v_month := (v_month + interval '1 month')::date;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('Harta assets: %s of its own assets, %s monthly '
                'depreciation runs.',
                (select count(*) from public.fixed_assets
                  where org_id = p_org), v_runs);
end $$;

comment on function app.demo_branches_sinar(uuid, uuid) is
  'Head office and a Bayan Lepas branch, with a share of the trade '
  'actually raised in the north so the branch report has something to '
  'compare.';
comment on function app.demo_time_sinar(uuid, uuid) is
  'An installation job with chargeable days and unchargeable ones, '
  'billed through bill_project_time.';
comment on function app.demo_assets_harta(uuid, uuid) is
  'The van and the fit-out a managing agent owns itself -- not the '
  'common property it manages, which belongs to the JMB.';

revoke all on function app.demo_branches_sinar(uuid, uuid)
  from public, anon, authenticated;
revoke all on function app.demo_time_sinar(uuid, uuid)
  from public, anon, authenticated;
revoke all on function app.demo_assets_harta(uuid, uuid)
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
  v_last text := '';
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
  -- Last of all on Sinar: the branch tagging has to see every document
  -- the other seeds raised, including the build's components bill.
  v_last := app.demo_time_sinar(v_sinar, v_demo)
         || ' ' || app.demo_branches_sinar(v_sinar, v_demo);

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
  v_last := v_last || ' ' || app.demo_assets_harta(v_harta, v_property);
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
    v_legal_txt, v_warung_txt, v_salon_txt, v_stall_txt) || v_buy || v_ask || ' ' || v_appr || ' ' || v_make || ' ' || v_last;
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

  if v_src !~ 'demo_branches_sinar' or v_src !~ 'demo_time_sinar'
     or v_src !~ 'demo_assets_harta' then
    raise exception
      'FAIL 0436: one of the last three demos is not called, so a module '
      'somebody bought is still an empty screen';
  end if;

  -- The branch seed raises documents of its own, so it has to run after
  -- everything else on Sinar or the invoice numbers it takes come out
  -- of the middle of the year.
  if position('demo_branches_sinar' in v_src)
     < position('demo_manufacturing_sinar' in v_src) then
    raise exception
      'FAIL 0436: the branch seed runs before the rest of Sinar';
  end if;

  if v_src !~ 'app.demo_purchases\(' or v_src !~ 'app.demo_crm\('
     or v_src !~ 'demo_approvals_sinar' or v_src !~ 'demo_manufacturing_sinar' then
    raise exception
      'FAIL 0436: an earlier migration''s seed has been dropped from the '
      'rebuild';
  end if;

  raise notice '0436: the register has nothing on it but the einvoice lines';
end
$do$;
