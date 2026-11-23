-- =====================================================================
-- iAkauntan :: a closed account takes no new name (0923)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/a_closed_account_takes_no_new_name.sql
--
-- `0921` and `0922` stop an account closing while something names it.
-- Before `0923` the other door stood open: an item, a document line,
-- an expense, a claim type, a payment method, a fixed asset, a stock
-- adjustment and a recurring template each took an account that was
-- closed already. As the owner with the role `authenticated`, and once
-- as the database's owner: the rule is for every writer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_cn (
  org uuid, other uuid, cust uuid, sup uuid, wh uuid, item uuid, ct uuid, inv_line uuid,
  c_rev uuid, c_rev2 uuid, c_exp uuid, c_fa uuid, c_acc uuid, c_dep uuid, dormant uuid,
  o_rev uuid, o_exp uuid, o_lia uuid, o_fa uuid, o_acc uuid, o_dep uuid,
  theirs uuid, old_so uuid, old_so_line uuid, old_journal uuid, live_journal uuid);
grant select on t_cn to authenticated;

-- An account of the company's own, filed beside an existing one.
create or replace function pg_temp.cn_account(
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

-- A recurring journal's template: one debit, one credit.
create or replace function pg_temp.cn_template(p_dr uuid, p_cr uuid)
returns jsonb language sql as $$
  select jsonb_build_object('description', 'Sewa', 'lines', jsonb_build_array(
    jsonb_build_object('account_id', p_dr, 'debit', 100, 'credit', 0),
    jsonb_build_object('account_id', p_cr, 'debit', 0, 'credit', 100)));
$$;

do $$
declare r t_cn;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Tutup Dulu Sdn Bhd');
  r.other := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true
    from unnest(array['accounting', 'sales', 'purchases', 'inventory', 'fixed_assets', 'hr']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  r.c_rev   := pg_temp.cn_account(r.org, '4190', 'Jualan Tutup', 'revenue', 'sales', '4100');
  r.c_rev2  := pg_temp.cn_account(r.org, '4192', 'Jualan Tutup Dua', 'revenue', 'sales', '4100');
  r.c_exp   := pg_temp.cn_account(r.org, '6292', 'Belanja Tutup', 'expense', 'operating_expense', '6200');
  r.c_fa    := pg_temp.cn_account(r.org, '1519', 'Aset Tutup', 'asset', 'fixed_asset', '1120');
  r.c_acc   := pg_temp.cn_account(r.org, '1596', 'Susut Terkumpul Tutup', 'asset', 'accumulated_depreciation', '1120');
  r.c_dep   := pg_temp.cn_account(r.org, '6406', 'Susut Nilai Tutup', 'expense', 'depreciation_expense', '6400');
  r.dormant := pg_temp.cn_account(r.org, '6294', 'Belanja Tidur', 'expense', 'operating_expense', '6200');
  r.o_rev   := pg_temp.cn_account(r.org, '4191', 'Jualan Buka', 'revenue', 'sales', '4100');
  r.o_exp   := pg_temp.cn_account(r.org, '6293', 'Belanja Buka', 'expense', 'operating_expense', '6200');
  r.o_fa    := pg_temp.cn_account(r.org, '1521', 'Aset Buka', 'asset', 'fixed_asset', '1120');
  r.o_acc   := pg_temp.cn_account(r.org, '1597', 'Susut Terkumpul Buka', 'asset', 'accumulated_depreciation', '1120');
  r.o_dep   := pg_temp.cn_account(r.org, '6407', 'Susut Nilai Buka', 'expense', 'depreciation_expense', '6400');
  select id into r.o_lia from public.accounts where org_id = r.org and code = '2120';

  -- Closed as the chart closes one; and one merely switched off, which
  -- is how an account was put out of use before there was a way to
  -- close it.
  perform public.retire_account(r.c_rev);
  perform public.retire_account(r.c_rev2);
  perform public.retire_account(r.c_exp);
  perform public.retire_account(r.c_fa);
  perform public.retire_account(r.c_acc);
  perform public.retire_account(r.c_dep);
  update public.accounts set is_active = false where id = r.dormant;

  -- Another company's account, closed too: the wrong company first.
  r.theirs := pg_temp.cn_account(r.other, '4190', 'Jualan Mereka', 'revenue', 'sales', '4100');
  perform public.retire_account(r.theirs);

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal', 'supplier') returning id into r.sup;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'ADA', 'Barang Ada', 'service', false, 'C62', 10) returning id into r.item;
  insert into public.claim_types (org_id, code, name)
  values (r.org, 'ADA', 'Tuntutan Ada') returning id into r.ct;
  insert into public.recurring_journals
    (org_id, name, frequency, start_date, next_run_date, template, auto_post, is_active)
  values (r.org, 'Sewa bulanan', 'monthly', pg_temp.today(), pg_temp.today(),
          pg_temp.cn_template(r.o_exp, r.o_lia), true, true)
  returning id into r.live_journal;

  -- What named an account before it closed, and was not in use when it
  -- did: written with the rule off, since `0923` refuses it for every
  -- writer. An item that had been removed and was restored, a
  -- recurring journal that was switched off, and an order whose goods
  -- had been received but not yet invoiced.
  alter table public.items disable trigger a_closed_account_takes_no_new_name;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price, sales_account_id)
  values (r.org, 'LAMA', 'Barang Lama', 'service', false, 'C62', 10, r.c_rev);
  alter table public.items enable trigger a_closed_account_takes_no_new_name;

  alter table public.recurring_journals disable trigger a_recurring_template_names_no_closed_account;
  insert into public.recurring_journals
    (org_id, name, frequency, start_date, next_run_date, template, auto_post, is_active)
  values (r.org, 'Sewa lama', 'monthly', pg_temp.today(), pg_temp.today(),
          pg_temp.cn_template(r.c_exp, r.o_lia), true, false)
  returning id into r.old_journal;
  alter table public.recurring_journals enable trigger a_recurring_template_names_no_closed_account;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'sales_order', 'SO-LAMA', pg_temp.today(), pg_temp.today(), r.cust, 'MYR', 1, 'draft')
  returning id into r.old_so;
  alter table public.sales_document_lines disable trigger a_closed_account_takes_no_new_name;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (r.org, r.old_so, 1, 'item', 'Khidmat lama', 2, 100, 0, r.c_rev)
  returning id into r.old_so_line;
  alter table public.sales_document_lines enable trigger a_closed_account_takes_no_new_name;

  insert into t_cn select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_cn; v_inv uuid; v_bill uuid; v_line uuid; v_exp uuid; v_bank uuid; v_new uuid;
  v_col text;
begin
  select * into d from t_cn;
  v_bank := public.upsert_bank_account('Bank Utama', 'Maybank', null, '5123000077', p_org_id => d.org);

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-BUKA-1', pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v_inv, 1, 'item', 'Khidmat', 1, 100, 0, d.o_rev)
  returning id into v_line;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'bill', 'BIL-BUKA-1', pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, bank_account_id, amount, total_amount, status, description)
  values (d.org, 'EXP-BUKA-1', pg_temp.today(), d.o_exp, v_bank, 100, 100, 'draft', 'Tunai')
  returning id into v_exp;

  -- -------------------------------------------------------------------
  -- An item
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a new item does not take a closed account for its sales',
    format('insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price, sales_account_id) '
           'values (%L, %L, %L, %L, false, %L, 10, %L)', d.org, 'BARU1', 'Barang Baru', 'service', 'C62', d.c_rev),
    'An item''s sales account may not be 4190 Jualan Tutup, which is closed: what is posted through it would land in an account that is out of use. Choose one that is open.',
    '23514');
  perform pg_temp.check_refused('nor for its purchases',
    format('insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price, purchase_account_id) '
           'values (%L, %L, %L, %L, false, %L, 10, %L)', d.org, 'BARU2', 'Barang Baru', 'service', 'C62', d.c_exp),
    'An item''s purchase account may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor is an item already there given one',
    format('update public.items set sales_account_id = %L where id = %L', d.c_rev, d.item),
    'An item''s sales account may not be 4190 Jualan Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor one that was only ever switched off',
    format('update public.items set purchase_account_id = %L where id = %L', d.dormant, d.item),
    'An item''s purchase account may not be 6294 Belanja Tidur, which is closed:%', '23514');

  -- -------------------------------------------------------------------
  -- A document line
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a new invoice line does not name a closed account',
    format('insert into public.sales_document_lines (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id) '
           'values (%L, %L, 2, %L, %L, 1, 100, 0, %L)', d.org, v_inv, 'item', 'Khidmat', d.c_rev),
    'A sales document line''s account may not be 4190 Jualan Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor is a line already there moved onto one',
    format('update public.sales_document_lines set account_id = %L where id = %L', d.c_rev, v_line),
    'A sales document line''s account may not be 4190 Jualan Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor a new bill line',
    format('insert into public.purchase_document_lines (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id) '
           'values (%L, %L, 1, %L, %L, 1, 60, 0, %L)', d.org, v_bill, 'item', 'Belanja', d.c_exp),
    'A purchase document line''s account may not be 6292 Belanja Tutup, which is closed:%', '23514');

  -- -------------------------------------------------------------------
  -- An expense, and its split
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a new expense does not take a closed account',
    format('insert into public.expenses (org_id, expense_no, expense_date, account_id, bank_account_id, amount, total_amount, status, description) '
           'values (%L, %L, %L, %L, %L, 40, 40, %L, %L)', d.org, 'EXP-TUTUP', pg_temp.today(), d.c_exp, v_bank, 'draft', 'Tunai'),
    'An expense''s account may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor is one already there moved onto one',
    format('update public.expenses set account_id = %L where id = %L', d.c_exp, v_exp),
    'An expense''s account may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor split onto one',
    format('select public.set_expense_split(%L, %L::jsonb)', v_exp,
           jsonb_build_array(jsonb_build_object('account_id', d.o_exp, 'amount', 70),
                             jsonb_build_object('account_id', d.c_exp, 'amount', 30))::text),
    'A line of an expense''s split may not be 6292 Belanja Tutup, which is closed:%', '23514');

  -- -------------------------------------------------------------------
  -- A claim type, a payment method, a fixed asset, a stock adjustment
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a new claim type does not take a closed account',
    format('insert into public.claim_types (org_id, code, name, expense_account_id) values (%L, %L, %L, %L)',
           d.org, 'BARU', 'Tuntutan Baru', d.c_exp),
    'A claim type''s expense account may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor is one already there given one',
    format('update public.claim_types set expense_account_id = %L where id = %L', d.c_exp, d.ct),
    'A claim type''s expense account may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('a payment method does not charge to a closed account',
    format('select public.save_payment_method(%L, %L, p_charge_account_id => %L, p_charge_percent => 2)',
           d.org, 'Kad Kredit', d.c_exp),
    'A payment method''s charge account may not be 6292 Belanja Tutup, which is closed:%', '23514');

  foreach v_col in array array['asset', 'accumulated', 'expense'] loop
    perform pg_temp.check_refused('a fixed asset does not take a closed ' || v_col || ' account',
      format('insert into public.fixed_assets (org_id, asset_no, name, asset_account_id, accumulated_account_id, '
             'expense_account_id, acquisition_date, cost, method, useful_life_months) '
             'values (%L, %L, %L, %L, %L, %L, %L, 1200, %L, 60)',
             d.org, 'FA-' || v_col, 'Mesin',
             case v_col when 'asset' then d.c_fa else d.o_fa end,
             case v_col when 'accumulated' then d.c_acc else d.o_acc end,
             case v_col when 'expense' then d.c_dep else d.o_dep end,
             pg_temp.today() - 10, 'straight_line'),
      case v_col
        when 'asset' then 'A fixed asset''s asset account may not be 1519 Aset Tutup, which is closed:%'
        when 'accumulated' then 'A fixed asset''s accumulated depreciation account may not be 1596 Susut Terkumpul Tutup, which is closed:%'
        else 'A fixed asset''s depreciation expense account may not be 6406 Susut Nilai Tutup, which is closed:%' end,
      '23514');
  end loop;

  perform pg_temp.check_refused('a stock adjustment does not take a closed account',
    format('insert into public.stock_adjustments (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id) '
           'values (%L, %L, %L, %L, %L, %L, %L, %L)',
           d.org, 'ADJ-TUTUP', pg_temp.today(), d.wh, 'Kiraan', 'stock_take', 'draft', d.c_exp),
    'A stock adjustment''s account may not be 6292 Belanja Tutup, which is closed:%', '23514');

  -- -------------------------------------------------------------------
  -- A recurring journal and a recurring document
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a new recurring journal does not name a closed account',
    format('insert into public.recurring_journals (org_id, name, frequency, start_date, next_run_date, template, auto_post, is_active) '
           'values (%L, %L, %L, %L, %L, %L::jsonb, true, true)',
           d.org, 'Sewa baru', 'monthly', pg_temp.today(), pg_temp.today(),
           pg_temp.cn_template(d.c_exp, d.o_lia)::text),
    'A recurring journal''s line may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor is one already running rewritten to name one',
    format('update public.recurring_journals set template = %L::jsonb where id = %L',
           pg_temp.cn_template(d.c_exp, d.o_lia)::text, d.live_journal),
    'A recurring journal''s line may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor is one switched back on while it names one',
    format('update public.recurring_journals set is_active = true where id = %L', d.old_journal),
    'A recurring journal''s line may not be 6292 Belanja Tutup, which is closed:%', '23514');
  perform pg_temp.check_refused('nor does one name an account that was only ever switched off',
    format('update public.recurring_journals set template = %L::jsonb where id = %L',
           pg_temp.cn_template(d.dormant, d.o_lia)::text, d.live_journal),
    'A recurring journal''s line may not be 6294 Belanja Tidur, which is closed:%', '23514');
  perform pg_temp.check_refused('a new recurring document does not name a closed account',
    format('insert into public.recurring_documents (org_id, name, kind, contact_id, template, frequency, start_date, next_run_date, is_active) '
           'values (%L, %L, %L, %L, %L::jsonb, %L, %L, %L, true)',
           d.org, 'Langganan', 'sales', d.cust,
           jsonb_build_object('header', jsonb_build_object('doc_type', 'invoice'),
             'lines', jsonb_build_array(jsonb_build_object('line_type', 'item', 'description', 'L',
               'quantity', 1, 'unit_price', 300, 'account_id', d.c_rev)))::text,
           'monthly', pg_temp.today(), pg_temp.today()),
    'A recurring document''s line may not be 4190 Jualan Tutup, which is closed:%', '23514');

  -- -------------------------------------------------------------------
  -- Another company's account is the tenant key's, closed or not
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('another company''s closed account is refused by the tenant key, not described',
    format('update public.items set sales_account_id = %L where id = %L', d.theirs, d.item),
    '%violates foreign key constraint%', '23503');

  -- A template carries no tenant key. This rule looks up only the
  -- company's own accounts, so another company's is neither refused
  -- nor described here. Measured on 23 November: the run then posts
  -- nothing and keeps the ledger's own refusal -- its tenant key on
  -- `gl_lines` -- in `last_error`.
  insert into public.recurring_journals
    (org_id, name, frequency, start_date, next_run_date, template, auto_post, is_active)
  values (d.org, 'Sewa orang', 'monthly', pg_temp.today() + 20, pg_temp.today() + 20,
          pg_temp.cn_template(d.theirs, d.o_lia), true, true);
  perform pg_temp.check_eq('a template naming another company''s closed account is not described by this rule',
    (select count(*) from public.recurring_journals where org_id = d.org and name = 'Sewa orang'),
    1::bigint);
  delete from public.recurring_journals where org_id = d.org and name = 'Sewa orang';

  perform pg_temp.check_eq('after all of that nothing new names a closed account',
    (select count(*) from public.items where org_id = d.org and code like 'BARU%')
    + (select count(*) from public.sales_document_lines where document_id = v_inv and account_id = d.c_rev)
    + (select count(*) from public.purchase_document_lines where document_id = v_bill)
    + (select count(*) from public.expenses where org_id = d.org and account_id = d.c_exp)
    + (select count(*) from public.expense_lines where expense_id = v_exp)
    + (select count(*) from public.claim_types where org_id = d.org and expense_account_id is not null)
    + (select count(*) from public.payment_methods where org_id = d.org)
    + (select count(*) from public.fixed_assets where org_id = d.org)
    + (select count(*) from public.stock_adjustments where org_id = d.org)
    + (select count(*) from public.recurring_journals where org_id = d.org and name = 'Sewa baru')
    + (select count(*) from public.recurring_documents where org_id = d.org),
    0::bigint);

  -- -------------------------------------------------------------------
  -- What was there before is still written
  -- -------------------------------------------------------------------
  -- Saved whole, the account sent back as it was: the trigger fires and
  -- has to see that it did not change.
  update public.items set name = 'Barang Lama Sekali', sales_account_id = d.c_rev
   where org_id = d.org and code = 'LAMA';
  perform pg_temp.check_eq('an item that already names a closed account is still saved whole',
    (select name from public.items where org_id = d.org and code = 'LAMA'), 'Barang Lama Sekali');
  update public.recurring_journals
     set name = 'Sewa lama sekali', template = template, is_active = false
   where id = d.old_journal;
  perform pg_temp.check_eq('and a recurring journal switched off, with its template sent back as it was',
    (select name from public.recurring_journals where id = d.old_journal), 'Sewa lama sekali');
  -- Its amounts rewritten and its accounts left alone: the closed
  -- account is one it named before, and is not asked for again.
  update public.recurring_journals
     set template = jsonb_build_object('description', 'Sewa', 'lines', jsonb_build_array(
           jsonb_build_object('account_id', d.c_exp, 'debit', 250, 'credit', 0),
           jsonb_build_object('account_id', d.o_lia, 'debit', 0, 'credit', 250)))
   where id = d.old_journal;
  perform pg_temp.check_eq('and with its amounts rewritten and its accounts as they were',
    (select (template -> 'lines' -> 0 ->> 'debit')::numeric from public.recurring_journals
      where id = d.old_journal), 250::numeric);

  -- -------------------------------------------------------------------
  -- A line carried on keeps the account of the line it came from
  -- -------------------------------------------------------------------
  v_new := public.transfer_document(d.old_so, 'invoice', null);
  perform pg_temp.check_eq('an order''s line is carried into its invoice with the account it had',
    (select a.code from public.sales_document_lines l join public.accounts a on a.id = l.account_id
      where l.document_id = v_new), '4190');
  perform pg_temp.check_refused('but a line citing that one may not name a different closed account',
    format('insert into public.sales_document_lines (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id, source_line_id) '
           'values (%L, %L, 2, %L, %L, 1, 100, 0, %L, %L)', d.org, v_new, 'item', 'Lain', d.c_rev2, d.old_so_line),
    'A sales document line''s account may not be 4192 Jualan Tutup Dua, which is closed:%', '23514');

  -- -------------------------------------------------------------------
  -- And an open account is taken everywhere, as before
  -- -------------------------------------------------------------------
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
                            sales_account_id, purchase_account_id)
  values (d.org, 'BUKA', 'Barang Buka', 'service', false, 'C62', 10, d.o_rev, d.o_exp);
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v_bill, 1, 'item', 'Belanja', 1, 60, 0, d.o_exp);
  perform public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object('account_id', d.o_exp, 'amount', 70),
    jsonb_build_object('account_id', (select id from public.accounts where org_id = d.org and code = '6200'),
                       'amount', 30)));
  update public.claim_types set expense_account_id = d.o_exp where id = d.ct;
  perform public.save_payment_method(d.org, 'Kad Kredit', p_charge_account_id => d.o_exp, p_charge_percent => 2);
  insert into public.fixed_assets
    (org_id, asset_no, name, asset_account_id, accumulated_account_id, expense_account_id,
     acquisition_date, cost, method, useful_life_months)
  values (d.org, 'FA-BUKA', 'Mesin', d.o_fa, d.o_acc, d.o_dep, pg_temp.today() - 10, 1200, 'straight_line', 60);
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id)
  values (d.org, 'ADJ-BUKA', pg_temp.today(), d.wh, 'Kiraan', 'stock_take', 'draft', d.o_exp);
  update public.recurring_journals set template = pg_temp.cn_template(d.o_exp, d.o_lia), is_active = true
   where id = d.old_journal;
  perform pg_temp.check_eq('an open account is taken by each of them, as before',
    (select count(*) from public.items where org_id = d.org and code = 'BUKA')
    + (select count(*) from public.purchase_document_lines where document_id = v_bill)
    + (select count(*) from public.expense_lines where expense_id = v_exp)
    + (select count(*) from public.claim_types where id = d.ct and expense_account_id = d.o_exp)
    + (select count(*) from public.payment_methods where org_id = d.org and charge_account_id = d.o_exp)
    + (select count(*) from public.fixed_assets where org_id = d.org)
    + (select count(*) from public.stock_adjustments where org_id = d.org)
    + (select count(*) from public.recurring_journals where id = d.old_journal and is_active),
    9::bigint);
end $$;

-- The rule is for every writer, not only the app.
reset role;
select pg_temp.check_refused('the database''s owner is refused too',
  format('update public.items set sales_account_id = %L where id = %L',
         (select c_rev from t_cn), (select item from t_cn)),
  'An item''s sales account may not be 4190 Jualan Tutup, which is closed:%', '23514');
select pg_temp.check_refused('for a recurring journal as for an item',
  format('update public.recurring_journals set template = %L::jsonb where id = %L',
         pg_temp.cn_template((select c_exp from t_cn), (select o_lia from t_cn))::text,
         (select live_journal from t_cn)),
  'A recurring journal''s line may not be 6292 Belanja Tutup, which is closed:%', '23514');

rollback;
