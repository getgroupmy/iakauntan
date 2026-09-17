-- ---------------------------------------------------------------------
-- 0432  Every business buys something
-- ---------------------------------------------------------------------
-- Six of the seven demo tenants have `purchases` enabled and not one
-- purchase document between them. Somebody signs in as the warung, the
-- salon, the bakery, the corp-sec practice, the property manager or the
-- law firm, opens Bills, and reads an empty state -- while
-- `post_purchase_document`, `post_purchase_payment`, the payables
-- ageing and the supplier statement are all there and all unseen.
--
-- First, a correction to the register's own reasoning. `0428` wrote
-- that "`crm` being enabled on all six is a question about what
-- `demo_modules` hands out", and the same was assumed of `purchases`.
-- It is not. `app.seed_org_modules`, from `0019`, turns on `einvoice`,
-- `purchases`, `inventory` and `crm` for EVERY organization created in
-- this product -- they are what the plan includes, not something the
-- demo hands out. `app.demo_modules` never mentions `purchases` for any
-- of these six.
--
-- That inverts the answer. Turning `purchases` off for a demo tenant
-- would make the demo show something a real sign-up does not see, and
-- the whole point of the register is that what is on the screen is what
-- a customer gets. So the register's `purchases` lines are not a
-- question about entitlement at all: they are six small demos, and the
-- honest thing is to write them. The comment in `demo_rebuild.sql` is
-- corrected in the same commit, because a register that reasons from a
-- false mechanism sends the next reader to the wrong file.
--
-- One helper, six tenants. The shape is the same for all of them -- a
-- supplier, two bills, one settled and one still open -- because that
-- is what the module is: it differs only in what each business buys.
-- Writing six bespoke seeds would have been six chances to get the
-- posting wrong in six different ways.
--
-- Through the functions, not into the tables. The bill header and its
-- lines are inserted, because entering a bill is somebody typing what a
-- supplier sent. Everything after is the function that owns it:
-- `post_purchase_document`, which writes the payable and the expense,
-- and `post_purchase_payment`, which moves the money and settles the
-- allocation. Setting `status = 'posted'` by hand would look identical
-- on the Bills list and leave the ledger empty.
--
-- One open bill each, deliberately. A tenant whose bills are all
-- settled has an empty payables ageing and a supplier statement with
-- nothing outstanding on it, which is three screens demonstrating
-- themselves by being blank. The open one is dated far enough back to
-- land in an ageing bucket rather than in "current".
--
-- Five mutants applied and measured:
--
--   * the second bill never raised -- killed, "one still owed, so the
--     ageing has something in it", six tenants short;
--   * the payment raised and never posted -- killed, "one settled
--     through a posted supplier payment", six tenants short;
--   * one of the six calls deleted -- killed by this migration's own
--     apply-time guard before the test ran, so the test assertion was
--     not measured by it;
--   * so a fifth was applied that keeps six calls and points the
--     salon's at Amanah -- killed, "every demo tenant has a posted
--     bill", one tenant short. That is the mutant the first assertion
--     is actually for;
--   * `demo_sync_bank_balance` put back the way it was -- killed, but
--     by `0430`'s existing client-account assertion, which runs first.
--     The mechanical assertion added here did not make that kill. It is
--     the general form -- every bank account of every demo tenant, not
--     one account of one -- and it earns its place by covering the next
--     tenant to be given two accounts, not by catching this mutant.
--
-- Five of the six had no `bank_accounts` row at all, so there was
-- nowhere for a payment to come from -- measured on a rebuild, not
-- assumed. Each gets one: a current account for the companies, and
-- Wang Tunai for the warung, which is a cash business and would not be
-- shown a Maybank current account to make a demo tidier.
-- ---------------------------------------------------------------------

create or replace function app.demo_purchases(
  p_org           uuid,
  p_owner         uuid,
  p_supplier      text,
  p_supplier_code text,
  p_what          text,
  p_account_code  text,
  p_amount        numeric,
  p_bank_name     text,
  p_bank_code     text,
  p_bank_no       text,
  p_bank_type     text)
returns text
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_supp    uuid;
  v_acct    uuid;
  v_bank_gl uuid;
  v_bank    uuid;
  v_doc     uuid;
  v_pay     uuid;
  v_settled numeric(18,2);
  v_open    numeric(18,2);
  v_date    date;
begin
  perform app.demo_act_as(p_owner);

  -- The bank the money leaves from. Five of the six had no
  -- `bank_accounts` row at all -- measured on a rebuild -- and without
  -- one `post_purchase_payment` has no account to credit.
  --
  -- An existing account is used if there is one, and `is_client_account`
  -- is excluded from that search rather than left to chance: the law
  -- firm has two, and paying the firm's own supplier out of money held
  -- for a client is the breach of rule 7 of the Solicitors' Accounts
  -- Rules 1990 that `0430` exists to make visible.
  select id into v_bank from public.bank_accounts
   where org_id = p_org and is_active and not is_client_account
   order by is_default desc, created_at limit 1;

  if v_bank is null then
    select id into v_bank_gl from public.accounts
     where org_id = p_org and code = case when p_bank_type = 'cash'
                                          then '1110' else '1120' end;
    insert into public.bank_accounts
      (org_id, account_id, name, bank_name, bank_code, account_number,
       account_type, currency, opening_balance, current_balance, is_default)
    values (p_org, v_bank_gl, p_bank_name, p_bank_code, null, p_bank_no,
            p_bank_type, 'MYR', 0, 0, true);
    select id into v_bank from public.bank_accounts
     where org_id = p_org and account_number = p_bank_no;
  end if;

  select id into v_acct from public.accounts
   where org_id = p_org and code = p_account_code;

  insert into public.contacts
    (org_id, code, name, contact_type, email, phone)
  values (p_org, p_supplier_code, p_supplier, 'supplier',
          lower(replace(p_supplier_code, '-', '')) || '@pembekal.demo',
          '03-8000 1000')
  on conflict (org_id, code) do nothing;
  select id into v_supp from public.contacts
   where org_id = p_org and code = p_supplier_code;

  -- The settled one, two months back, so the payment has somewhere to
  -- sit between the bill and today.
  v_settled := round(p_amount, 2);
  v_date    := app.today() - 75;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'bill', app.next_document_number_internal(p_org, 'bill'),
          v_date, v_date + 30, v_supp, 'draft', 'MYR', 1, p_owner)
  returning id into v_doc;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, uom_code, unit_price, account_id)
  values (p_org, v_doc, 1, 'item', p_what, 1, 'C62', v_settled, v_acct);

  perform public.post_purchase_document(v_doc);

  insert into public.purchase_payments
    (org_id, payment_no, payment_date, contact_id, payment_mode_code,
     bank_account_id, reference, currency, exchange_rate, amount, created_by)
  select p_org, app.next_document_number_internal(p_org, 'payment'),
         v_date + 28, v_supp,
         case when p_bank_type = 'cash' then '01' else '03' end,
         v_bank, 'Settlement of ' || d.doc_no, 'MYR', 1, d.total_amount,
         p_owner
    from public.purchase_documents d where d.id = v_doc
  returning id into v_pay;

  insert into public.payment_allocations (org_id, payment_id, bill_id, amount)
  select p_org, v_pay, d.id, d.total_amount
    from public.purchase_documents d where d.id = v_doc;

  perform public.post_purchase_payment(v_pay);

  -- And the one still owed. Forty days old, so it is past its terms and
  -- lands in an ageing bucket rather than in "current".
  v_open := round(p_amount * 0.6, 2);
  v_date := app.today() - 40;

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'bill', app.next_document_number_internal(p_org, 'bill'),
          v_date, v_date + 30, v_supp, 'draft', 'MYR', 1, p_owner)
  returning id into v_doc;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description,
     quantity, uom_code, unit_price, account_id)
  values (p_org, v_doc, 1, 'item', p_what, 1, 'C62', v_open, v_acct);

  perform public.post_purchase_document(v_doc);

  perform app.demo_sync_bank_balance(p_org);
  perform set_config('request.jwt.claims', '', true);

  return format('%s: 2 bills from %s, %s paid and %s outstanding.',
                p_supplier_code, p_supplier, v_settled, v_open);
end $$;

comment on function app.demo_purchases(uuid, uuid, text, text, text, text,
                                       numeric, text, text, text, text) is
  'Seeds one supplier, two bills and a settlement for a demo tenant: '
  'the shape every business shares, so the six tenants that had '
  '`purchases` enabled and empty differ only in what they buy.';

revoke all on function app.demo_purchases(uuid, uuid, text, text, text, text,
                                          numeric, text, text, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- One balance per bank account, not one per tenant
-- ---------------------------------------------------------------------
-- Found by this migration, not reasoned about. `app.demo_sync_bank_balance`
-- from `0190` sums every ledger account that a bank account maps to,
-- across the whole tenant, and writes that ONE number onto EVERY
-- `bank_accounts` row the tenant has:
--
--     update public.bank_accounts set current_balance = v_bal
--      where org_id = p_org;
--
-- Correct for as long as no demo tenant had more than one account,
-- which was true until `0430` gave the law firm an office account and a
-- client account. `0430` never called the function, so nothing moved;
-- the first call from here set the client account's balance to the sum
-- of both and `demo_rebuild.sql` went red -- "what the client account
-- holds is what the ledger says it holds: expected 3200.00, got
-- -400.00".
--
-- That is a client account misstated by the seed. It is a demo, so no
-- client's money was anywhere near it, but the screen a solicitor would
-- open to answer rule 11's "how much am I holding for this client"
-- would have shown the firm's own overdrawn office balance. Each row
-- now gets the balance of its own ledger account. The return value is
-- unchanged in meaning -- the tenant's total across its bank accounts --
-- so callers that print it read the same number as before.
create or replace function app.demo_sync_bank_balance(p_org uuid)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_bal numeric(18,2);
begin
  update public.bank_accounts b
     set current_balance = coalesce((
           select sum(l.debit - l.credit)
             from public.gl_lines l
             join public.gl_entries e on e.id = l.entry_id
            where e.org_id = p_org and e.status = 'posted'
              and l.account_id = b.account_id), 0)
   where b.org_id = p_org;

  select coalesce(sum(current_balance), 0) into v_bal
    from public.bank_accounts where org_id = p_org;
  return v_bal;
end $$;

revoke all on function app.demo_sync_bank_balance(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The rebuild, restated to call it for the six
-- ---------------------------------------------------------------------
-- Verified against the live `pg_get_functiondef` before editing: the
-- block in `0430` and the installed function have the same normalised
-- body, so this restates what is actually there rather than what a
-- migration once said.

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
    v_legal_txt, v_warung_txt, v_salon_txt, v_stall_txt) || v_buy;
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

  if v_src !~ 'demo_purchases' then
    raise exception
      'FAIL 0432: the rebuild does not seed any purchases, so the six '
      'tenants that have the module still have nothing in it';
  end if;

  -- Six calls, not one. A restatement that dropped five of them would
  -- satisfy the check above and leave five empty Bills screens.
  if (length(v_src) - length(replace(v_src, 'app.demo_purchases(', '')))
       / length('app.demo_purchases(') < 6 then
    raise exception
      'FAIL 0432: the rebuild seeds purchases for fewer than six tenants';
  end if;

  -- The client account is excluded from where the money comes out. This
  -- reads the helper rather than the rebuild, because that is where the
  -- rule lives.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
   where p.oid = to_regprocedure(
     'app.demo_purchases(uuid, uuid, text, text, text, text, numeric,'
     ' text, text, text, text)');
  if v_src !~ 'is_client_account' then
    raise exception
      'FAIL 0432: a supplier could be paid out of a client account';
  end if;

  raise notice '0432: every demo tenant buys something and pays for it';
end
$do$;
