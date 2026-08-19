-- ---------------------------------------------------------------------
-- 0230  A demo card with something on it
-- ---------------------------------------------------------------------
--
-- The warung's member holds six points, earned honestly from one RM6.50
-- sale, against a scheme that redeems from a hundred. So the loyalty
-- panel 0227 put on the tender sheet demonstrates itself by refusing:
-- "Redeems from 100", greyed out, on the only tenant that has a card at
-- all. A demo that cannot show the feature it is demonstrating argues
-- against it.
--
-- ## An opening balance, because that is what really happens
--
-- The fix is not to invent sales. It is the thing every shop does on
-- the day it installs a loyalty scheme: put the customer's existing
-- points on the card. `adjust_loyalty_points` is exactly that call, it
-- insists on a reason, and it refuses to run for anyone who is not an
-- owner or admin — so demonstrating it demonstrates three rules rather
-- than fabricating a balance.
--
-- ## Topped up to a figure, not by one
--
-- `demo_rebuild` is safe to run twice and this has to be too. Adjusting
-- *by* 494 would give a card 1,000 points on the second run. Adjusting
-- *to* 500 lands on the same number however often it is called, and
-- does nothing at all once it is there.
--
-- ## Why `demo_rebuild` is restated and `demo_warung` is not
--
-- The balance belongs to the warung, so the honest home for this is
-- inside `app.demo_warung` — and that function is 312 lines. Restating
-- it to add one call would be a diff nobody can check, which is the
-- objection this repository makes to restatements in the first place.
-- `demo_rebuild` is 120 lines and 0222 already restated it once, so the
-- new work goes in a named function of its own and the entry point
-- gains a single line calling it.

-- ---------------------------------------------------------------------
-- The top-up
-- ---------------------------------------------------------------------
create or replace function app.demo_warung_loyalty(
  p_org   uuid,
  p_owner uuid)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_acct   uuid;
  v_least  integer;
  v_now    integer;
  v_target constant integer := 500;
begin
  -- As the owner, because `adjust_loyalty_points` is deliberately
  -- narrower than selling: handing out points is handing out money, and
  -- a cashier who can do it unwitnessed is a control nobody has.
  perform app.demo_act_as(p_owner);

  select a.id, p.min_redeem_points into v_acct, v_least
    from public.loyalty_accounts a
    join public.loyalty_programs p on p.id = a.program_id
   where a.org_id = p_org and a.is_active and p.is_active
   limit 1;

  if v_acct is null then
    perform set_config('request.jwt.claims', '', true);
    return 'No loyalty card to top up.';
  end if;

  v_now := app.loyalty_balance(v_acct);
  if v_now < v_target then
    perform public.adjust_loyalty_points(
      v_acct, v_target - v_now,
      'Mata terkumpul sebelum sistem dipasang');
  end if;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'The card holds %s points, redeemable from %s.',
    app.loyalty_balance(v_acct), coalesce(v_least, 0));
end;
$$;

revoke all on function app.demo_warung_loyalty(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The tenant that already exists
-- ---------------------------------------------------------------------
--
-- So the deploy fixes the running demo rather than waiting for somebody
-- to rebuild it. Guarded on `is_demo`, the same guard `demo_teardown`
-- uses, because nothing here may touch a real shop's loyalty ledger.
do $$
declare
  v_org   uuid;
  v_owner uuid;
begin
  select g.id, g.created_by into v_org, v_owner
    from public.organizations g
    join public.loyalty_programs p on p.org_id = g.id and p.is_active
   where g.is_demo
   limit 1;

  if v_org is not null and v_owner is not null then
    perform app.demo_warung_loyalty(v_org, v_owner);
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- The entry point, with one line added
-- ---------------------------------------------------------------------
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

  perform set_config('request.jwt.claims', '', true);

  return format(
    '%s Rebuilt 6 tenants, 8 logins. %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc,
    v_pos, v_books_a, v_books_h, v_warung_txt, v_salon_txt, v_stall_txt);
end;
$$;
