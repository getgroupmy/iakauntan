-- ---------------------------------------------------------------------
-- 0485  One call that restores the whole demo
-- ---------------------------------------------------------------------
-- `app.demo_rebuild()` builds seven tenants and nine logins. The
-- accounting practice -- the firm, its own books and its three client
-- companies -- was never among them: it is built by
-- `app.demo_practice_rebuild`, which had to be called separately and
-- with an address.
--
-- That was untidy while it was only untidy. It is now destructive.
-- `demo_teardown` runs first inside `demo_rebuild` and takes **every**
-- company marked `is_demo`, which the practice's four are. So the
-- standard rebuild deletes the accounting firm and does not put it
-- back, and the guard that refuses to tear down a demo company with a
-- real person in it cannot object: the partner is a demo login, so the
-- books read as nobody's.
--
-- What is left afterwards is worse than nothing -- a `firms` row with
-- no members and no companies. `demo_practice_rebuild` finds its firm
-- through the partner's membership, which the teardown has just swept,
-- so the next run does not find that row and creates a second firm
-- beside it. Then a third.
--
-- ### What changes
--
--   * `demo_teardown` clears away a firm left with no members and no
--     companies, which is the only kind it can create. Restated from
--     0472, not 0463: 0472 wrote it as `CREATE OR REPLACE FUNCTION` in
--     capitals, which is invisible to a case-sensitive search for the
--     lower-case form, and restating the older text silently dropped
--     the exemption 0472 exists for -- the one that lets a practice be
--     torn down when its own books belong to the firm's real account.
--     `demo_practice.sql` caught it within the minute. The self-check
--     below now asserts the exemption survives, so the next
--     restatement cannot lose it quietly.
--   * `demo_rebuild` makes the demo partner and the audit manager,
--     builds the practice through `demo_practice_rebuild`, and seats
--     the manager through `invite_firm_member` -- the function 0483
--     fixed, which is why the office could never hold two people.
--     Eleven tenants, fourteen logins, one call.
--
-- `demo_practice_rebuild` still takes an address, because putting a
-- practice on somebody's real account is a different thing and 0472
-- exists for it.
--
-- ### Mutants
--
-- Run against `supabase/tests/demo_rebuild.sql`, each named with the
-- assertion that kills it:
--   * the practice not built -- "eleven demo companies";
--   * the manager not seated -- "the practice has two people in it";
--   * the orphan firm left behind -- "a firm nobody is left in goes
--     with the teardown", which had to be written for this: the file
--     asserted plenty about what a rebuild makes and nothing about
--     what a teardown leaves;
--   * the partner login not made -- the rebuild raises "There is no
--     account for accountant@iakauntan.com", because
--     `demo_practice_rebuild` refuses an address with no account;
--   * 0472's practice exemption dropped from the guard, which is the
--     mistake this migration actually made -- `demo_practice.sql`
--     refuses with "a company marked is_demo has real members. Found:
--     Accountant & Co.".
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.demo_teardown()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_orgs   uuid[];
  v_users  uuid[];
  v_real   text;
  v_owned  text;
  v_names  text;
  v_n      integer;
  v_count  integer;
  v_swept  text := null;
  r        record;
begin
  select array_agg(id), string_agg(name, ', ' order by name)
    into v_orgs, v_names
    from public.organizations where is_demo;

  if v_orgs is null then
    return 'Nothing is marked is_demo; nothing removed.';
  end if;

  -- The guard. A real person inside a company marked demo means the flag
  -- is wrong, and the right response is to stop and say whose account it
  -- is — not to delete their books and report success.
  --
  -- Access lent by a firm is not that. `via_firm_id` says the row was
  -- written by `attach_company_to_firm` and belongs to the appointment,
  -- not to the person; `detach_company_from_firm` deletes exactly these
  -- and leaves what somebody was invited to in their own right. Ending
  -- the appointment by deleting the company takes nobody's books.
  select string_agg(distinct o.name || ' (' || u.email || ')', ', ')
    into v_real
    from public.organizations o
    join public.org_members m on m.org_id = o.id
    join auth.users u on u.id = m.user_id
   where o.id = any (v_orgs)
     and coalesce(u.raw_app_meta_data ->> 'demo', '') <> 'true'
     and m.via_firm_id is null
     -- ...and is not the practice whose books these are. A firm's own
     -- demo company is now owned by the firm's real account rather than
     -- by a throwaway login (see 0472), so without this the second
     -- rebuild would refuse on the account that asked for the first.
     -- Narrow on purpose: it exempts members of the firm the company is
     -- already attached to, and nobody else.
     and not exists (
       select 1 from public.firm_members fm
        where fm.firm_id = o.firm_id and fm.user_id = m.user_id);

  if v_real is not null then
    raise exception
      'Refusing to tear down: a company marked is_demo has real members. '
      'Clear is_demo on it, or remove the member first. Found: %', v_real
      using errcode = '42501';
  end if;

  -- And the same disagreement the other way round. A demo login that
  -- has joined a real company cannot be deleted without taking a
  -- decision about that company, so it is not a decision this function
  -- takes.
  select string_agg(distinct u.email || ' in ' || o.name, ', ')
    into v_owned
    from auth.users u
    join public.org_members m on m.user_id = u.id
    join public.organizations o on o.id = m.org_id
   where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
     and not o.is_demo;

  if v_owned is not null then
    raise exception
      'Refusing to tear down: a demo login is a member of a company that '
      'is not marked demo. Somebody created it while signed in as the '
      'demo. Remove the membership, or mark the company demo, and run '
      'this again. Found: %', v_owned
      using errcode = '42501';
  end if;

  -- The three that will not follow the organization out. Note the column
  -- names: chat rows point at the *sender's* company, not at an owning
  -- one, because a conversation can span two tenants.
  delete from public.chat_messages     where sender_org_id  = any (v_orgs);
  delete from public.chat_calls        where started_by_org = any (v_orgs);
  delete from public.platform_invoices where org_id         = any (v_orgs);

  delete from public.organizations where id = any (v_orgs);

  -- Who is actually going. After the companies are gone, and given the
  -- guard above, this is every demo login.
  select array_agg(u.id) into v_users
    from auth.users u
   where coalesce(u.raw_app_meta_data ->> 'demo', '') = 'true'
     and not exists (select 1 from public.org_members m where m.user_id = u.id);

  if v_users is not null then
    -- Everything still pointing at them, read from the catalogue rather
    -- than from a list somebody has to remember to update. Restricted to
    -- `public`: the `auth` schema's own references cascade, and this is
    -- not the place to reach into them.
    for r in
      select n.nspname as sch, cl.relname as tbl, a.attname as col, a.attnotnull as nn
        from pg_constraint c
        join pg_class cl on cl.oid = c.conrelid
        join pg_namespace n on n.oid = cl.relnamespace
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
       where c.contype = 'f'
         and c.confrelid = 'auth.users'::regclass
         and c.confdeltype in ('a', 'r')
         -- Single-column only. A composite key into auth.users would
         -- need a decision this loop is not equipped to make, and
         -- silently reading its first column would be worse than not
         -- touching it.
         and array_length(c.conkey, 1) = 1
         and n.nspname = 'public'
       order by cl.relname, a.attname
    loop
      if r.nn then
        execute format('delete from %I.%I where %I = any($1)', r.sch, r.tbl, r.col)
          using v_users;
      else
        execute format('update %I.%I set %I = null where %I = any($1)',
                       r.sch, r.tbl, r.col, r.col)
          using v_users;
      end if;

      get diagnostics v_n = row_count;
      if v_n > 0 then
        v_swept := concat_ws(', ', v_swept,
          format('%s.%s %s %s row(s)', r.tbl, r.col,
                 case when r.nn then 'deleted' else 'cleared' end, v_n));
      end if;
    end loop;

    delete from auth.users u where u.id = any (v_users);
    get diagnostics v_count = row_count;
  else
    v_count := 0;
  end if;

  -- A practice whose companies and people have both just gone is
  -- debris, and leaving it behind is not harmless: the practice
  -- rebuild finds its firm through the partner's membership, so an
  -- empty firm it can no longer see becomes a second firm on the next
  -- run, and a third on the one after.
  delete from public.firms f
   where not exists (select 1 from public.firm_members m
                      where m.firm_id = f.id)
     and not exists (select 1 from public.organizations o
                      where o.firm_id = f.id);

  return format('Removed %s demo company(ies) [%s] and %s demo user(s).%s',
                array_length(v_orgs, 1), v_names, v_count,
                case when v_swept is null then ''
                     else ' Also released: ' || v_swept || '.' end);
end $function$;

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
  v_partner uuid; v_firm uuid; v_practice text;
  v_practice_org uuid;
  r record;
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
  v_partner   := app.demo_user('accountant@iakauntan.com', 'Akauntan Partner');
  perform app.demo_user('audit@iakauntan.com', 'Priya Menon');

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

  -- ------------------------------------------------------------------
  -- The practice, which used to be rebuilt separately or not at all
  -- ------------------------------------------------------------------
  -- `demo_teardown` above takes every company marked `is_demo`, and
  -- the practice's four are marked. Building the tenants and leaving
  -- the practice to a second call meant the standard rebuild deleted
  -- the accounting firm and did not put it back -- and the teardown
  -- guard could not object, because the partner is a demo login and so
  -- reads as nobody's real books.
  --
  -- `demo_practice_rebuild` still takes an address, for putting a
  -- practice on somebody's real account. What it gets here is the demo
  -- partner, made a moment ago.
  v_practice := app.demo_practice_rebuild('accountant@iakauntan.com');

  -- The second chair, through the function a firm actually uses. It
  -- was broken from 0450 to 0483, which is why the office has always
  -- been a room for one.
  select f.id into v_firm
    from public.firms f
    join public.firm_members m on m.firm_id = f.id
   where m.user_id = v_partner
   order by f.created_at limit 1;
  if v_firm is not null then
    perform app.demo_act_as(v_partner);
    perform public.invite_firm_member(v_firm, 'audit@iakauntan.com',
                                      'manager'::app.firm_role);
  end if;

  -- The practice prepares its clients' accounts and bills the hours
  -- doing it -- which is what `mbrs` and `timesheets` are, and it had
  -- both switched on with nothing behind either. The same two seeds
  -- Amanah uses, because it is the same work.
  select o.id into v_practice_org
    from public.organizations o
   where o.firm_id = v_firm and o.name = 'Accountant & Co.';
  if v_practice_org is not null then
    v_practice := v_practice || ' ' || app.demo_amanah_accounts(
      v_practice_org, v_partner);
    v_practice := v_practice || ' ' || app.demo_amanah_time(
      v_practice_org, v_partner);
  end if;

  -- Every business buys something, the practice's four included. The
  -- suite holds every `is_demo` company to a posted bill, one still
  -- owed and one settled -- 0432's rule, and the reason is the empty
  -- Purchases screen a tenant without one demonstrates. Each company
  -- buys as its own owner: access lent by the firm is `accounts_clerk`,
  -- which may write but not post.
  for r in
    select o.id as org_id, o.name, m.user_id
      from public.organizations o
      join public.org_members m on m.org_id = o.id and m.role = 'owner'
     where o.firm_id = v_firm
     order by o.name
  loop
    v_buy := v_buy || ' ' || app.demo_purchases(
      r.org_id, r.user_id, 'Bekalan Pejabat Mutiara Sdn Bhd', 'SUP-BPM',
      'Alat tulis, cetakan dan bekalan pejabat', '6230', 1250.00,
      'Maybank Current Account', 'Malayan Banking Berhad',
      '514088990011', 'current');

    -- And somebody to call back. The same four fates every other
    -- tenant's pipeline has -- one untouched, one live, one won, one
    -- lost with a reason -- because a board with everything closed
    -- shows nothing about stages, which is the whole of what the
    -- screen is. Written for what each company actually does: a
    -- rubber factory in Seremban is not chasing the same work as a
    -- software house in Cyberjaya.
    v_ask := v_ask || ' ' || app.demo_crm(r.org_id, r.user_id,
      case r.name
        when 'Kilang Lestari Sdn Bhd' then $k$
          [
            {"company": "Pemasangan Auto Seremban Sdn Bhd",
             "first_name": "Lim", "last_name": "Boon Hock",
             "role": "Purchasing manager",
             "email": "buyer@autoseremban.demo", "phone": "06-763 2200",
             "city": "Seremban", "state_code": "05", "source": "Referral",
             "industry": "Automotive", "value": 68000, "fate": "new",
             "note": null, "age": 7},
            {"company": "Perabot Klasik Melaka",
             "first_name": "Siti", "last_name": "Rohaya",
             "role": "Owner", "email": "siti@perabotklasik.demo",
             "phone": "06-284 1100", "city": "Melaka", "state_code": "04",
             "source": "Trade fair", "industry": "Furniture",
             "value": 24000, "fate": "live", "note": null, "age": 21},
            {"company": "Getah Perdana Trading",
             "first_name": "Ravi", "last_name": "Chandran",
             "role": "Director", "email": "ravi@getahperdana.demo",
             "phone": "06-761 8899", "city": "Seremban",
             "state_code": "05", "source": "Cold call",
             "industry": "Wholesale", "value": 41000, "fate": "won",
             "note": "Annual supply of moulded seals", "age": 38},
            {"company": "Kilang Tayar Nusantara Sdn Bhd",
             "first_name": "Ahmad", "last_name": "Fauzi",
             "role": "Procurement lead", "email": "ahmad@tayarnusantara.demo",
             "phone": "06-799 4433", "city": "Nilai", "state_code": "05",
             "source": "Tender", "industry": "Manufacturing",
             "value": 155000, "fate": "dead",
             "note": "Awarded to a supplier with its own compounding line",
             "age": 60}
          ]
        $k$::jsonb
        when 'Bayu Digital Sdn Bhd' then $k$
          [
            {"company": "Klinik Prima Cyberjaya",
             "first_name": "Nurul", "last_name": "Aina",
             "role": "Practice manager", "email": "admin@klinikprima.demo",
             "phone": "03-8322 1100", "city": "Cyberjaya",
             "state_code": "10", "source": "Website",
             "industry": "Healthcare", "value": 32000, "fate": "new",
             "note": null, "age": 4},
            {"company": "Koperasi Belia Selangor",
             "first_name": "Hafizuddin", "last_name": "Omar",
             "role": "IT lead", "email": "it@koperasibelia.demo",
             "phone": "03-5544 7700", "city": "Shah Alam",
             "state_code": "10", "source": "Referral",
             "industry": "Financial services", "value": 88000,
             "fate": "live", "note": null, "age": 25},
            {"company": "Pasar Raya Segar Online Sdn Bhd",
             "first_name": "Cheryl", "last_name": "Tan",
             "role": "Head of e-commerce", "email": "cheryl@segaronline.demo",
             "phone": "03-7712 3300", "city": "Petaling Jaya",
             "state_code": "10", "source": "Referral", "industry": "Retail",
             "value": 120000, "fate": "won",
             "note": "Rebuilt the ordering app and the stock feed",
             "age": 45},
            {"company": "Agensi Pelancongan Damai",
             "first_name": "Zulhelmi", "last_name": "Bakar",
             "role": "Founder", "email": "zul@pelancongandamai.demo",
             "phone": "03-2011 5566", "city": "Kuala Lumpur",
             "state_code": "14", "source": "Cold email",
             "industry": "Travel", "value": 26000, "fate": "dead",
             "note": "Took an off-the-shelf booking product instead",
             "age": 57}
          ]
        $k$::jsonb
        when 'Pinang Holdings Berhad' then $k$
          [
            {"company": "Ladang Sawit Kedah Sdn Bhd",
             "first_name": "Mohd", "last_name": "Ridzuan",
             "role": "Managing director", "email": "md@ladangsawitkedah.demo",
             "phone": "04-733 2200", "city": "Alor Setar",
             "state_code": "02", "source": "Broker",
             "industry": "Agriculture", "value": 2400000, "fate": "new",
             "note": null, "age": 11},
            {"company": "Hartanah Tanjung Bungah Sdn Bhd",
             "first_name": "Ooi", "last_name": "Kim Guan",
             "role": "Director", "email": "kg@hartanahtb.demo",
             "phone": "04-890 1122", "city": "George Town",
             "state_code": "07", "source": "Referral",
             "industry": "Property", "value": 5600000, "fate": "live",
             "note": null, "age": 33},
            {"company": "Logistik Pulau Sdn Bhd",
             "first_name": "Sharon", "last_name": "Fernandez",
             "role": "Finance director", "email": "fd@logistikpulau.demo",
             "phone": "04-263 7788", "city": "Butterworth",
             "state_code": "07", "source": "Broker",
             "industry": "Logistics", "value": 3100000, "fate": "won",
             "note": "Took a thirty per cent stake", "age": 52},
            {"company": "Teknologi Bayu Baharu Sdn Bhd",
             "first_name": "Iskandar", "last_name": "Zulkifli",
             "role": "Founder", "email": "iskandar@bayubaharu.demo",
             "phone": "04-611 9900", "city": "Bayan Lepas",
             "state_code": "07", "source": "Inbound",
             "industry": "Technology", "value": 1800000, "fate": "dead",
             "note": "Raised from a venture fund at a higher valuation",
             "age": 66}
          ]
        $k$::jsonb
        else $k$
          [
            {"company": "Restoran Selera Kampung Sdn Bhd",
             "first_name": "Rosnah", "last_name": "Yaakob",
             "role": "Owner", "email": "rosnah@selerakampung.demo",
             "phone": "03-4142 8800", "city": "Kuala Lumpur",
             "state_code": "14", "source": "Walk-in",
             "industry": "Food and beverage", "value": 4800, "fate": "new",
             "note": null, "age": 6},
            {"company": "Bina Murni Construction Sdn Bhd",
             "first_name": "Kumaran", "last_name": "Selvam",
             "role": "Finance manager", "email": "finance@binamurni.demo",
             "phone": "03-6274 1100", "city": "Rawang",
             "state_code": "10", "source": "Referral",
             "industry": "Construction", "value": 36000, "fate": "live",
             "note": null, "age": 19},
            {"company": "Klinik Pergigian Damai",
             "first_name": "Lee", "last_name": "Wai Mun",
             "role": "Principal dentist", "email": "drlee@pergigiandamai.demo",
             "phone": "03-9058 2200", "city": "Cheras", "state_code": "14",
             "source": "Referral", "industry": "Healthcare",
             "value": 14400, "fate": "won",
             "note": "Bookkeeping and the annual audit file", "age": 41},
            {"company": "Perniagaan Idris Enterprise",
             "first_name": "Idris", "last_name": "Hamzah",
             "role": "Proprietor", "email": "idris@idrisent.demo",
             "phone": "03-3341 7700", "city": "Klang", "state_code": "10",
             "source": "Website", "industry": "Trading", "value": 6000,
             "fate": "dead",
             "note": "Stayed with the bookkeeper who does it by hand",
             "age": 63}
          ]
        $k$::jsonb
      end);
  end loop;

  -- Every module a demo tenant has data for, switched on for it.
  -- `demo_rebuild` runs after the migrations, so 0232's backfill cannot
  -- reach these tenants -- and `demo_rebuild.sql` asserts that no
  -- active module is left without somewhere to be looked at. Doing it
  -- from the data rather than by listing modules per tenant means the
  -- next module added cannot quietly fail that gate.
  perform app.demo_modules_in_use();

  perform set_config('request.jwt.claims', '', true);

  return format(
    '%s Rebuilt 11 tenants, 14 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc, v_crm,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_name_a, v_time_a, v_books_h,
    v_legal_txt, v_warung_txt, v_salon_txt, v_stall_txt) || v_buy || v_ask || ' ' || v_appr || ' ' || v_make || ' ' || v_last || ' ' || v_practice;
end;
$$;

-- ---------------------------------------------------------------------
-- Self-check
-- ---------------------------------------------------------------------
do $do$
declare
  v_td text := pg_get_functiondef('app.demo_teardown()'::regprocedure);
  v_rb text := pg_get_functiondef('app.demo_rebuild()'::regprocedure);
begin
  -- 0472's exemption. Restating this function from an older copy drops
  -- it, and the only symptom is that the second rebuild refuses.
  if position('fm.firm_id = o.firm_id and fm.user_id = m.user_id' in v_td) = 0
  then
    raise exception '0485: the teardown lost 0472''s practice exemption';
  end if;
  if position('delete from public.firms f' in v_td) = 0 then
    raise exception '0485: the teardown leaves an empty firm behind';
  end if;
  if position('demo_practice_rebuild' in v_rb) = 0 then
    raise exception '0485: the rebuild still does not build the practice';
  end if;
  if position('invite_firm_member' in v_rb) = 0 then
    raise exception '0485: the office is still a room for one';
  end if;
end $do$;
