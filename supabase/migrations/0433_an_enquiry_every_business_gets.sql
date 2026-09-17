-- ---------------------------------------------------------------------
-- 0433  An enquiry every business gets
-- ---------------------------------------------------------------------
-- The last of `crm` on the register. `0428` gave Sinar a pipeline and
-- left the other six tenants with the module enabled and no lead in it,
-- on the argument that "a warung does not run one and neither does a
-- salon".
--
-- That argument was made about the wrong thing, as `0432` found when it
-- went looking for where the entitlement comes from. `crm` is not
-- handed out by `app.demo_modules`: `app.seed_org_modules`, from
-- `0019`, turns on `einvoice`, `purchases`, `inventory` and `crm` for
-- EVERY organization created in this product. It is what the plan
-- includes. Turning it off for a demo tenant would show a prospect
-- something a real sign-up does not get.
--
-- And the premise was wrong on its own terms. A warung does not run a
-- sales pipeline the way a software company does, but it is asked to
-- cater an office lunch and quotes for a wedding; the salon is asked
-- for a bridal package; the gerai is asked to supply a kafe every week.
-- Those are enquiries somebody has to remember to call back about,
-- which is what the module is for at this size. Six leads with nobody
-- chasing them is the demo, not a missing one.
--
-- Lighter than Sinar's, deliberately. Sinar gets five leads, three
-- conversions and a deal lost to a named competitor, because it sells
-- to businesses and that is its arrangement. These six get four leads
-- each -- one nobody has touched, one live in Negotiation, one won, and
-- one closed with a reason -- which is what a book of enquiries looks
-- like at a warung. A demo that gave the gerai the wholesaler's funnel
-- would be showing the customer somebody else's business.
--
-- Through the functions, exactly as `0428` argued. The leads are
-- inserted, because a lead arriving is somebody filling in a form.
-- After that it is `convert_lead` -- which alone sets
-- `converted_contact_id`, and is what stops one enquiry becoming two
-- customers -- then `close_opportunity` and `close_lead`, which refuses
-- without a reason. Writing `status = 'converted'` by hand would look
-- identical on the board and leave all of that undone.
--
-- One helper taking the enquiries as jsonb rather than fifteen text
-- parameters, and six call sites that read as what each business was
-- asked for.
--
-- Six mutants applied and measured; five killed, four of them for their
-- own reason:
--
--   * the salon given an empty book, six calls still made -- killed,
--     "every demo tenant has somebody to call back";
--   * the won lead converted by hand instead of through the functions
--     -- killed by "and one it won", because removing the conversion
--     also removes the opportunity, and that assertion runs first. So a
--     sixth was written for the assertion this one was meant to
--     exercise;
--   * `converted_contact_id` nulled after the conversion, which is the
--     state a seed that wrote the row itself would leave -- killed,
--     "every converted lead went through convert_lead";
--   * the dead lead closed by writing `status = ''lost''` -- killed,
--     "and every dead one says why it died";
--   * the live deal left where `convert_lead` put it -- killed, "the
--     open one has moved past the first stage". Nothing else notices:
--     the open deal is still open and the won one still won.
--
-- One mutant could not be applied and is not counted: pointing the
-- salon''s call at Amanah, to leave the salon empty while keeping six
-- calls, collides on `leads_org_id_lead_no_key` because Amanah already
-- has LEAD-000001 to 000004. The empty-book mutant above is what that
-- one was trying to be.
-- ---------------------------------------------------------------------

create or replace function app.demo_crm(
  p_org uuid, p_owner uuid, p_enquiries jsonb)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_today date := app.today();
  v_pipe  uuid;
  v_nego  uuid;
  r       record;
  v_lead  uuid;
  v_opp   uuid;
  v_no    integer := 0;
  v_leads integer := 0;
  v_opps  integer := 0;
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
    return 'Pipeline: skipped, there is nowhere to put one.';
  end if;
  select id into v_nego from public.pipeline_stages
   where pipeline_id = v_pipe and name = 'Negotiation';

  for r in select * from jsonb_to_recordset(p_enquiries) as x(
             company text, first_name text, last_name text, role text,
             email text, phone text, city text, state_code text,
             source text, industry text, value numeric,
             fate text, note text, age integer)
  loop
    v_no := v_no + 1;

    insert into public.leads
      (org_id, lead_no, company_name, first_name, last_name, designation,
       email, phone, city, state_code, source, industry, status, rating,
       estimated_value, owner_id, created_by, created_at)
    values
      (p_org, format('LEAD-%s', lpad(v_no::text, 6, '0')), r.company,
       r.first_name, r.last_name, r.role, r.email, r.phone, r.city,
       r.state_code, r.source, r.industry,
       case when r.fate = 'new' then 'new' else 'contacted' end::app.lead_status,
       case r.fate when 'won' then 'hot' when 'live' then 'hot'
                   when 'new' then 'warm' else 'cold' end,
       r.value, p_owner, p_owner, (v_today - r.age)::timestamptz)
    returning id into v_lead;
    v_leads := v_leads + 1;

    if r.fate = 'won' then
      v_opp := (public.convert_lead(v_lead, true, v_pipe, r.value,
                  v_today - (r.age / 2)) ->> 'opportunity_id')::uuid;
      perform public.close_opportunity(v_opp, 'won', r.note, null,
                                       v_today - (r.age / 3));
      v_opps := v_opps + 1;

    elsif r.fate = 'live' then
      v_opp := (public.convert_lead(v_lead, true, v_pipe, r.value,
                  v_today + 21) ->> 'opportunity_id')::uuid;
      -- Moved out of the first stage. A board where every card sits in
      -- Qualification is a board that demonstrates nothing about
      -- stages, which is the whole of what the screen is.
      if v_nego is not null then
        update public.opportunities
           set stage_id = v_nego, probability = 70, updated_at = now()
         where id = v_opp;
      end if;
      v_opps := v_opps + 1;

    elsif r.fate = 'dead' then
      -- `close_lead` refuses without a reason, and a list of dead
      -- enquiries with no reasons on it is a list nobody reads twice.
      perform public.close_lead(v_lead, r.note);
    end if;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  return format('%s leads, %s opportunities.', v_leads, v_opps);
end $$;

comment on function app.demo_crm(uuid, uuid, jsonb) is
  'Seeds a small book of enquiries for a demo tenant: one untouched, '
  'one live, one won and one closed with a reason. Leads are inserted; '
  'everything after goes through convert_lead, close_opportunity and '
  'close_lead. Lighter than app.demo_crm_sinar on purpose -- a warung '
  'is asked to cater a lunch, it does not run a software funnel.';

revoke all on function app.demo_crm(uuid, uuid, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The rebuild, restated to call it for the six
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
  perform app.demo_modules(v_harta, array[
    'property_strata', 'property_nonstrata', 'purchases', 'fixed_assets',
    'approvals', 'chat']);
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
    v_legal_txt, v_warung_txt, v_salon_txt, v_stall_txt) || v_buy || v_ask;
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

  if (length(v_src) - length(replace(v_src, 'app.demo_crm(', '')))
       / length('app.demo_crm(') < 6 then
    raise exception
      'FAIL 0433: fewer than six tenants are given a book of enquiries';
  end if;

  -- Sinar keeps its own, which is a different and fuller demo. A
  -- restatement that replaced it with the light one would satisfy the
  -- count above and quietly delete the only full funnel in the product.
  if v_src !~ 'demo_crm_sinar' then
    raise exception
      'FAIL 0433: Sinar has lost its pipeline to the generic seed';
  end if;

  -- And the purchases six are still there. This function is restated
  -- from a copy every time, and losing an earlier migration''s calls to
  -- a careless paste is the failure mode the restatement discipline
  -- exists for.
  if (length(v_src) - length(replace(v_src, 'app.demo_purchases(', '')))
       / length('app.demo_purchases(') < 6 then
    raise exception
      'FAIL 0433: 0432''s purchases have been dropped from the rebuild';
  end if;

  raise notice '0433: every demo tenant has somebody to call back';
end
$do$;
