-- =====================================================================
-- iAkauntan :: an account still named is not closed (0921)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_account_still_named_is_not_closed.sql
--
-- A setting that names an account is read every time something posts
-- through it, open or not. Before `0921` `retire_account` closed an
-- account that payroll settings named as EPF payable, and the next
-- payroll posted RM1,200 into the closed account; the same for a
-- contact's, an item's, a claim type's and a fixed asset's. Asked as
-- the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_na (
  org uuid, cust uuid, item uuid,
  lia uuid, exp uuid, ar uuid, ap uuid, sales uuid, purch uuid, claim uuid,
  fa uuid, acc uuid, dep uuid, many uuid, gone uuid, old_fa uuid,
  cogs uuid, stax uuid, comp uuid, free uuid,
  gone_ap uuid, gone_sales uuid, gone_purch uuid, gone_fa uuid, spent_fa uuid,
  plain uuid, rj_dr uuid, rj_cr uuid, rj_off uuid, rj_done uuid, rd uuid, rd_off uuid,
  chg uuid, chg_off uuid, rev uuid, rev_cn uuid);
grant select on t_na to authenticated;

-- An account of the company's own, filed beside an existing one.
create or replace function pg_temp.na_account(
  p_org uuid, p_code text, p_name text, p_type text, p_subtype text, p_beside text)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select p_org, p_code, p_name, p_type::app.account_type, p_subtype::app.account_subtype, a.parent_id
    from public.accounts a where a.org_id = p_org and a.code = p_beside
  returning id into v;
  if v is null then
    raise exception 'the fixture found no account % to file % beside', p_beside, p_code;
  end if;
  return v;
end $$;

do $$
declare r t_na; i int;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Dinamai Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  -- A year on as well: this file releases twelve months of deferred
  -- revenue, and each month's entry is dated in its own period.
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 400);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true
    from unnest(array['accounting', 'sales', 'purchases', 'inventory', 'payroll', 'hr', 'fixed_assets']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  r.lia    := pg_temp.na_account(r.org, '2155', 'KWSP Belum Bayar', 'liability', 'current_liability', '2150');
  r.exp    := pg_temp.na_account(r.org, '6105', 'Gaji Pengarah', 'expense', 'payroll_expense', '6100');
  r.ar     := pg_temp.na_account(r.org, '1215', 'Penghutang Khas', 'asset', 'accounts_receivable', '1210');
  r.ap     := pg_temp.na_account(r.org, '2111', 'Pemiutang Khas', 'liability', 'accounts_payable', '2110');
  r.sales  := pg_temp.na_account(r.org, '4160', 'Jualan Khas', 'revenue', 'sales', '4100');
  r.purch  := pg_temp.na_account(r.org, '5110', 'Belian Khas', 'expense', 'cost_of_sales', '5100');
  r.claim  := pg_temp.na_account(r.org, '6145', 'Tuntutan Khas', 'expense', 'operating_expense', '6140');
  r.fa     := pg_temp.na_account(r.org, '1515', 'Aset Khas', 'asset', 'fixed_asset', '1120');
  r.acc    := pg_temp.na_account(r.org, '1595', 'Susut Terkumpul Khas', 'asset', 'accumulated_depreciation', '1120');
  r.dep    := pg_temp.na_account(r.org, '6405', 'Susut Nilai Khas', 'expense', 'depreciation_expense', '6400');
  r.many   := pg_temp.na_account(r.org, '1216', 'Penghutang Ramai', 'asset', 'accounts_receivable', '1210');
  r.gone   := pg_temp.na_account(r.org, '1217', 'Penghutang Lama', 'asset', 'accounts_receivable', '1210');
  r.old_fa := pg_temp.na_account(r.org, '1516', 'Aset Lama', 'asset', 'fixed_asset', '1120');
  r.gone_ap    := pg_temp.na_account(r.org, '2112', 'Pemiutang Lama', 'liability', 'accounts_payable', '2110');
  r.gone_sales := pg_temp.na_account(r.org, '4161', 'Jualan Lama', 'revenue', 'sales', '4100');
  r.gone_purch := pg_temp.na_account(r.org, '5111', 'Belian Lama', 'expense', 'cost_of_sales', '5100');
  r.gone_fa    := pg_temp.na_account(r.org, '1517', 'Aset Dibuang', 'asset', 'fixed_asset', '1120');
  r.spent_fa   := pg_temp.na_account(r.org, '1518', 'Aset Habis Susut', 'asset', 'fixed_asset', '1120');
  r.rj_dr   := pg_temp.na_account(r.org, '6198', 'Sewa Berulang', 'expense', 'operating_expense', '6200');
  r.rj_cr   := pg_temp.na_account(r.org, '2199', 'Akruan Berulang', 'liability', 'current_liability', '2120');
  r.rj_off  := pg_temp.na_account(r.org, '6197', 'Sewa Dihentikan', 'expense', 'operating_expense', '6200');
  r.rj_done := pg_temp.na_account(r.org, '6196', 'Sewa Tamat', 'expense', 'operating_expense', '6200');
  r.rd      := pg_temp.na_account(r.org, '4170', 'Jualan Berulang', 'revenue', 'sales', '4100');
  r.rd_off  := pg_temp.na_account(r.org, '4171', 'Jualan Dihentikan', 'revenue', 'sales', '4100');
  r.chg     := pg_temp.na_account(r.org, '6301', 'Caj Kad', 'expense', 'finance_cost', '6300');
  r.chg_off := pg_temp.na_account(r.org, '6302', 'Caj Lama', 'expense', 'finance_cost', '6300');
  r.rev     := pg_temp.na_account(r.org, '4180', 'Hasil Tertunda', 'revenue', 'sales', '4100');
  r.rev_cn  := pg_temp.na_account(r.org, '4181', 'Hasil Dibatalkan', 'revenue', 'sales', '4100');
  -- Named, and read by no posting: see the migration's header.
  r.cogs   := pg_temp.na_account(r.org, '5210', 'Kos Jualan Khas', 'expense', 'cost_of_sales', '5200');
  r.stax   := pg_temp.na_account(r.org, '2135', 'Cukai Jualan Khas', 'liability', 'tax_payable', '2130');
  r.comp   := pg_temp.na_account(r.org, '6107', 'Elaun Khas', 'expense', 'payroll_expense', '6100');
  -- Named by nothing.
  r.free   := pg_temp.na_account(r.org, '6199', 'Tiada Nama', 'expense', 'operating_expense', '6200');

  insert into public.payroll_settings (org_id) values (r.org);

  insert into public.contacts (org_id, code, name, contact_type, receivable_account_id)
  values (r.org, 'CUST', 'Pelanggan Khas', 'customer', r.ar) returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type, payable_account_id)
  values (r.org, 'SUP', 'Pembekal Khas', 'supplier', r.ap);
  for i in 1 .. 7 loop
    insert into public.contacts (org_id, code, name, contact_type, receivable_account_id)
    values (r.org, 'M' || i, 'Pelanggan ' || i, 'customer', r.many);
  end loop;
  -- A contact that has been removed still carries the account it named.
  insert into public.contacts (org_id, code, name, contact_type, receivable_account_id, deleted_at)
  values (r.org, 'GONE', 'Pelanggan Lama', 'customer', r.gone, now());

  insert into public.contacts (org_id, code, name, contact_type, payable_account_id, deleted_at)
  values (r.org, 'GONE2', 'Pembekal Lama', 'supplier', r.gone_ap, now());
  -- A customer on the ordinary receivable account, for the invoices
  -- this file posts: an account with a balance is refused for that
  -- first, and the ones above have to stay empty.
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'BIASA', 'Pelanggan Biasa', 'customer') returning id into r.plain;

  -- A payment method that charges, and one that has been removed.
  insert into public.payment_methods (org_id, name, charge_account_id, charge_percent)
  values (r.org, 'Kad Kredit', r.chg, 2);
  insert into public.payment_methods (org_id, name, charge_account_id, charge_percent, deleted_at)
  values (r.org, 'Kad Lama', r.chg_off, 2, now());

  -- Three recurring journals: one running, one switched off, and one
  -- whose last run is behind it.
  insert into public.recurring_journals
    (org_id, name, frequency, start_date, next_run_date, template, auto_post, is_active)
  values (r.org, 'Sewa bulanan', 'monthly', pg_temp.today(), pg_temp.today(),
    jsonb_build_object('description', 'Sewa', 'lines', jsonb_build_array(
      jsonb_build_object('account_id', r.rj_dr, 'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', r.rj_cr, 'debit', 0, 'credit', 100))), true, true);
  insert into public.recurring_journals
    (org_id, name, frequency, start_date, next_run_date, template, auto_post, is_active)
  values (r.org, 'Sewa dihentikan', 'monthly', pg_temp.today(), pg_temp.today(),
    jsonb_build_object('description', 'Sewa', 'lines', jsonb_build_array(
      jsonb_build_object('account_id', r.rj_off, 'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', r.rj_cr, 'debit', 0, 'credit', 100))), true, false);
  insert into public.recurring_journals
    (org_id, name, frequency, start_date, end_date, next_run_date, template, auto_post, is_active)
  values (r.org, 'Sewa tamat', 'monthly', pg_temp.today() - 60, pg_temp.today() - 1, pg_temp.today(),
    jsonb_build_object('description', 'Sewa', 'lines', jsonb_build_array(
      jsonb_build_object('account_id', r.rj_done, 'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', r.rj_cr, 'debit', 0, 'credit', 100))), true, true);

  -- Two recurring invoices, one of them switched off.
  insert into public.recurring_documents
    (org_id, name, kind, contact_id, template, frequency, start_date, next_run_date, is_active)
  values (r.org, 'Langganan bulanan', 'sales', r.plain,
    jsonb_build_object('header', jsonb_build_object('doc_type', 'invoice'),
      'lines', jsonb_build_array(jsonb_build_object(
        'line_type', 'item', 'description', 'Langganan', 'quantity', 1,
        'unit_price', 300, 'account_id', r.rd))),
    'monthly', pg_temp.today(), pg_temp.today(), true);
  insert into public.recurring_documents
    (org_id, name, kind, contact_id, template, frequency, start_date, next_run_date, is_active)
  values (r.org, 'Langganan dihentikan', 'sales', r.plain,
    jsonb_build_object('header', jsonb_build_object('doc_type', 'invoice'),
      'lines', jsonb_build_array(jsonb_build_object(
        'line_type', 'item', 'description', 'Langganan', 'quantity', 1,
        'unit_price', 300, 'account_id', r.rd_off))),
    'monthly', pg_temp.today(), pg_temp.today(), false);

  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
                            sales_account_id, purchase_account_id, cogs_account_id)
  values (r.org, 'KHAS', 'Barang Khas', 'service', false, 'C62', 100, r.sales, r.purch, r.cogs)
  returning id into r.item;
  -- An item that has been removed, likewise.
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
                            sales_account_id, purchase_account_id, deleted_at)
  values (r.org, 'LAMA', 'Barang Lama', 'service', false, 'C62', 100, r.gone_sales, r.gone_purch, now());
  insert into public.tax_codes (org_id, code, name, rate, applies_to, sales_tax_account_id)
  values (r.org, 'KHAS8', 'Cukai Khas 8%', 8, 'sales', r.stax);
  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (r.org, 'KHAS', 'Tuntutan Khas', r.claim);
  -- A second claim type, on the account payroll will also name.
  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (r.org, 'LAIN', 'Tuntutan Lain', r.exp);
  insert into public.salary_components (org_id, code, name, kind, default_amount, account_id)
  values (r.org, 'ELAUN', 'Elaun Khas', 'earning', 200, r.comp);

  insert into public.fixed_assets
    (org_id, asset_no, name, asset_account_id, accumulated_account_id, expense_account_id,
     acquisition_date, cost, method, useful_life_months)
  values (r.org, 'FA-1', 'Mesin', r.fa, r.acc, r.dep, pg_temp.today() - 100, 12000, 'straight_line', 60);
  -- And one disposed of, which posts nothing more.
  insert into public.fixed_assets
    (org_id, asset_no, name, asset_account_id, accumulated_account_id, expense_account_id,
     acquisition_date, cost, method, useful_life_months, status, disposal_date)
  values (r.org, 'FA-0', 'Mesin Lama', r.old_fa, r.acc, r.dep, pg_temp.today() - 900, 5000,
          'straight_line', 60, 'disposed', pg_temp.today() - 10);

  -- One removed from the register, and one with nothing left to
  -- depreciate that is still owned -- its disposal is yet to post.
  insert into public.fixed_assets
    (org_id, asset_no, name, asset_account_id, accumulated_account_id, expense_account_id,
     acquisition_date, cost, method, useful_life_months, deleted_at)
  values (r.org, 'FA-X', 'Mesin Tersalah Daftar', r.gone_fa, r.acc, r.dep, pg_temp.today() - 50, 100,
          'straight_line', 60, now());
  insert into public.fixed_assets
    (org_id, asset_no, name, asset_account_id, accumulated_account_id, expense_account_id,
     acquisition_date, cost, method, useful_life_months, status)
  values (r.org, 'FA-2', 'Komputer', r.spent_fa, r.acc, r.dep, pg_temp.today() - 2500, 3000,
          'straight_line', 36, 'fully_depreciated');

  insert into t_na select r.*;
end $$;

-- A year of support invoiced today on one line, released month by month.
create or replace function pg_temp.na_deferred(p_no text, p_account uuid)
returns void language plpgsql as $$
declare d t_na; v uuid;
  v_from date := date_trunc('month', pg_temp.today())::date;
begin
  select * into d from t_na;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', p_no, pg_temp.today(), pg_temp.today(), d.plain, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate,
     account_id, service_start, service_end)
  values (d.org, v, 1, 'item', 'Sokongan setahun', 1, 1200, 0, p_account,
          v_from, (v_from + interval '12 months' - interval '1 day')::date);
  perform public.post_sales_document(v);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_na; v_line text[]; v_acct uuid;
begin
  select * into d from t_na;

  -- -------------------------------------------------------------------
  -- Named by one thing
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a customer''s receivable account is not closed',
    format('select public.retire_account(%L)', d.ar),
    'Account 1215 is still named by contact CUST Pelanggan Khas (receivable account), and what is posted through that would go on landing in it after it closed. Name another account there first, then close it.',
    '23514');
  perform pg_temp.check_refused('nor a supplier''s payable account',
    format('select public.retire_account(%L)', d.ap),
    'Account 2111 is still named by contact SUP Pembekal Khas (payable account), and what is posted%', '23514');
  perform pg_temp.check_refused('nor an item''s sales account',
    format('select public.retire_account(%L)', d.sales),
    'Account 4160 is still named by item KHAS Barang Khas (sales account), and what is posted%', '23514');
  perform pg_temp.check_refused('nor its purchase account',
    format('select public.retire_account(%L)', d.purch),
    'Account 5110 is still named by item KHAS Barang Khas (purchase account), and what is posted%', '23514');
  perform pg_temp.check_refused('nor a claim type''s expense account',
    format('select public.retire_account(%L)', d.claim),
    'Account 6145 is still named by claim type KHAS Tuntutan Khas, and what is posted%', '23514');
  perform pg_temp.check_refused('nor a fixed asset''s asset account',
    format('select public.retire_account(%L)', d.fa),
    'Account 1515 is still named by fixed asset FA-1 Mesin (asset account), and what is posted%', '23514');
  perform pg_temp.check_refused('nor its accumulated depreciation',
    format('select public.retire_account(%L)', d.acc),
    'Account 1595 is still named by fixed asset FA-1 Mesin (accumulated depreciation), fixed asset FA-2 Komputer (accumulated depreciation), and what is posted%', '23514');
  perform pg_temp.check_refused('nor its depreciation expense',
    format('select public.retire_account(%L)', d.dep),
    'Account 6405 is still named by fixed asset FA-1 Mesin (depreciation expense), fixed asset FA-2 Komputer (depreciation expense), and what is posted%', '23514');
  perform pg_temp.check_refused('nor the asset account of one fully depreciated and still owned',
    format('select public.retire_account(%L)', d.spent_fa),
    'Account 1518 is still named by fixed asset FA-2 Komputer (asset account), and what is posted%', '23514');

  perform pg_temp.check_refused('nor a payment method''s charge account',
    format('select public.retire_account(%L)', d.chg),
    'Account 6301 is still named by payment method Kad Kredit (charge account), and what is posted%', '23514');
  perform pg_temp.check_refused('nor a line of a recurring journal',
    format('select public.retire_account(%L)', d.rj_dr),
    'Account 6198 is still named by recurring journal Sewa bulanan, and what is posted%', '23514');
  perform pg_temp.check_refused('on either side of it',
    format('select public.retire_account(%L)', d.rj_cr),
    'Account 2199 is still named by recurring journal Sewa bulanan, and what is posted%', '23514');
  perform pg_temp.check_refused('nor a line of a recurring invoice',
    format('select public.retire_account(%L)', d.rd),
    'Account 4170 is still named by recurring sales document Langganan bulanan, and what is posted%', '23514');

  perform pg_temp.na_deferred('INV-TUNDA-1', d.rev);
  perform pg_temp.na_deferred('INV-TUNDA-2', d.rev_cn);
  perform pg_temp.check_refused('nor the account a year of deferred revenue is still to be released into',
    format('select public.retire_account(%L)', d.rev),
    'Account 4180 is still named by revenue still to recognise on INV-TUNDA-1, and what is posted%', '23514');
  perform pg_temp.check_refused('whichever invoice it is',
    format('select public.retire_account(%L)', d.rev_cn),
    'Account 4181 is still named by revenue still to recognise on INV-TUNDA-2, and what is posted%', '23514');

  -- -------------------------------------------------------------------
  -- Named by any one line of the payroll settings
  -- -------------------------------------------------------------------
  foreach v_line slice 1 in array array[
    ['salary_expense', 'salary expense',            'exp'],
    ['epf_expense',    'employer''s EPF expense',   'exp'],
    ['socso_expense',  'employer''s SOCSO expense', 'exp'],
    ['eis_expense',    'employer''s EIS expense',   'exp'],
    ['hrdf_expense',   'HRD Corp levy expense',     'exp'],
    ['salary_payable', 'net salary payable',        'lia'],
    ['epf_payable',    'EPF payable',               'lia'],
    ['socso_payable',  'SOCSO payable',             'lia'],
    ['eis_payable',    'EIS payable',               'lia'],
    ['pcb_payable',    'PCB payable',               'lia'],
    ['zakat_payable',  'zakat payable',             'lia']] loop
    v_acct := case v_line[3] when 'exp' then d.exp else d.lia end;
    execute format('update public.payroll_settings set %I = %L where org_id = %L',
                   v_line[1] || '_account_id', v_acct, d.org);
    perform pg_temp.check_refused(
      'an account named as the ' || v_line[2] || ' is not closed',
      format('select public.retire_account(%L)', v_acct),
      format('Account %s is still named by %s, and what is posted%%',
             case v_line[3] when 'exp' then '6105' else '2155' end,
             case v_line[3]
               when 'exp' then 'payroll settings (' || v_line[2] || '), claim type LAIN Tuntutan Lain'
               else 'payroll settings (' || v_line[2] || ')' end),
      '23514');
    execute format('update public.payroll_settings set %I = null where org_id = %L',
                   v_line[1] || '_account_id', d.org);
  end loop;

  -- -------------------------------------------------------------------
  -- Named by many
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('seven customers on one account are named five and counted two',
    format('select public.retire_account(%L)', d.many),
    'Account 1216 is still named by contact M1 Pelanggan 1 (receivable account), contact M2 Pelanggan 2 (receivable account), contact M3 Pelanggan 3 (receivable account), contact M4 Pelanggan 4 (receivable account), contact M5 Pelanggan 5 (receivable account) and 2 more, and what is posted%',
    '23514');

  perform pg_temp.check_eq('after all of that nothing in the company was closed',
    (select count(*) from public.accounts a
      where a.org_id = d.org and (a.deleted_at is not null or not a.is_active)), 0::bigint);

  -- -------------------------------------------------------------------
  -- What does not hold an account open
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq('an account only a removed contact names is closed',
    public.retire_account(d.gone), 'closed');
  perform pg_temp.check_eq('and one only a removed supplier names',
    public.retire_account(d.gone_ap), 'closed');
  perform pg_temp.check_eq('a removed item''s sales account',
    public.retire_account(d.gone_sales), 'closed');
  perform pg_temp.check_eq('and its purchase account',
    public.retire_account(d.gone_purch), 'closed');
  perform pg_temp.check_eq('one only a disposed asset names',
    public.retire_account(d.old_fa), 'closed');
  perform pg_temp.check_eq('and one only an asset removed from the register names',
    public.retire_account(d.gone_fa), 'closed');
  perform pg_temp.check_eq('one only a removed payment method names',
    public.retire_account(d.chg_off), 'closed');
  perform pg_temp.check_eq('one only a recurring journal switched off names',
    public.retire_account(d.rj_off), 'closed');
  perform pg_temp.check_eq('and one only a recurring journal past its end names',
    public.retire_account(d.rj_done), 'closed');
  perform pg_temp.check_eq('and one only a recurring invoice switched off names',
    public.retire_account(d.rd_off), 'closed');
  -- Read by no posting, so naming them moves nothing once closed.
  perform pg_temp.check_eq('an item''s cost of sales account is closed',
    public.retire_account(d.cogs), 'closed');
  perform pg_temp.check_eq('and a tax code''s sales tax account',
    public.retire_account(d.stax), 'closed');
  perform pg_temp.check_eq('and a salary component''s account',
    public.retire_account(d.comp), 'closed');
  perform pg_temp.check_eq('and one that nothing names',
    public.retire_account(d.free), 'closed');

  -- -------------------------------------------------------------------
  -- Unnamed, then closed
  -- -------------------------------------------------------------------
  update public.contacts set receivable_account_id = null where id = d.cust;
  perform pg_temp.check_eq('the customer given back the ordinary account, its own is closed',
    public.retire_account(d.ar), 'closed');
  update public.items set sales_account_id = null where id = d.item;
  perform pg_temp.check_eq('the item unnamed, its sales account is closed',
    public.retire_account(d.sales), 'closed');
  -- Every payroll line was cleared as it was asked, so 2155 is free;
  -- 6105 is still a claim type's.
  perform pg_temp.check_eq('the payroll settings cleared, the liability is closed',
    public.retire_account(d.lia), 'closed');
  perform pg_temp.check_refused('and the expense is still held by the claim type alone',
    format('select public.retire_account(%L)', d.exp),
    'Account 6105 is still named by claim type LAIN Tuntutan Lain, and what is posted%', '23514');
end $$;

-- -------------------------------------------------------------------
-- Revenue with nothing left to release
-- -------------------------------------------------------------------
-- A credit note that takes a deferred invoice back in full leaves its
-- periods with nothing to release (`0310`). Written here as the owner:
-- the credit note's own road is `revenue_recognition.sql`'s to assert.
reset role;
update public.revenue_schedule_periods p
   set cancelled_amount = p.amount
 where p.document_id = (select id from public.sales_documents
                         where org_id = (select org from t_na) and doc_no = 'INV-TUNDA-2');
set local role authenticated;

do $$
declare d t_na; v_sales uuid;
begin
  select * into d from t_na;
  select id into v_sales from public.accounts where org_id = d.org and code = '4100';

  perform pg_temp.check_eq('revenue taken back in full holds nothing open',
    public.retire_account(d.rev_cn), 'closed');

  -- Released, the other invoice's account holds what was released --
  -- and that, not the schedule, is what keeps it open now.
  perform pg_temp.check_eq('the year is released in twelve entries',
    public.recognise_revenue(d.org, pg_temp.today() + 400), 12);
  perform pg_temp.check_refused('an account holding the revenue released is kept for its balance',
    format('select public.retire_account(%L)', d.rev),
    'Account 4180 still carries a balance of 1,200.00 credit.%', '23514');
  perform public.post_manual_journal(d.org, pg_temp.today(),
    jsonb_build_array(
      jsonb_build_object('account_id', d.rev, 'debit', 1200, 'credit', 0),
      jsonb_build_object('account_id', v_sales, 'debit', 0, 'credit', 1200)),
    'Pindah hasil', 'JV-TUNDA-1');
  perform pg_temp.check_eq('and journalled on, with nothing left to release, it is closed',
    public.retire_account(d.rev), 'closed');
end $$;

reset role;
rollback;
