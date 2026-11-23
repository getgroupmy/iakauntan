-- =====================================================================
-- iAkauntan :: an account a draft still names is not closed (0922)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/an_account_a_draft_still_names_is_not_closed.sql
--
-- A line's account is fixed when the line is written and read when the
-- document posts. Before `0922` `retire_account` closed an account a
-- draft invoice's line named, and posting the draft put RM100 into the
-- closed account; the same for a bill, an expense and its split, a
-- stock adjustment, and an order carried on into an invoice. Asked as
-- the owner, with the role `authenticated`.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_da (
  org uuid, cust uuid, sup uuid, wh uuid, item uuid,
  inv uuid, bill uuid, so uuid, po uuid, exp uuid, split_b uuid, split_c uuid, adj uuid,
  pend uuid, appr uuid, done_inv uuid,
  void_inv uuid, gone_inv uuid, done_so uuid, cx_so uuid, rej_bill uuid, void_exp uuid, void_adj uuid,
  gone_bill uuid, done_po uuid, cx_po uuid, done_bill uuid, gone_exp uuid);
grant select on t_da to authenticated;

-- An account of the company's own, filed beside an existing one.
create or replace function pg_temp.da_account(
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

-- A sales document of one line naming an account, as it is written.
create or replace function pg_temp.da_sales(
  p_type text, p_no text, p_account uuid, p_qty numeric, p_price numeric)
returns uuid language plpgsql as $$
declare d t_da; v uuid;
begin
  select * into d from t_da;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, p_type::app.sales_doc_type, p_no, pg_temp.today(), pg_temp.today(), d.cust, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v, 1, 'item', 'Khidmat', p_qty, p_price, 0, p_account);
  return v;
end $$;

-- And a purchase document.
create or replace function pg_temp.da_purchase(
  p_type text, p_no text, p_account uuid, p_qty numeric, p_price numeric)
returns uuid language plpgsql as $$
declare d t_da; v uuid;
begin
  select * into d from t_da;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (d.org, p_type::app.purchase_doc_type, p_no, pg_temp.today(), pg_temp.today(), d.sup, 'MYR', 1, 'draft')
  returning id into v;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, description, quantity, unit_price, tax_rate, account_id)
  values (d.org, v, 1, 'item', 'Belanja', p_qty, p_price, 0, p_account);
  return v;
end $$;

do $$
declare r t_da; v uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Draf Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true from unnest(array['accounting', 'sales', 'purchases', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  r.inv      := pg_temp.da_account(r.org, '4190', 'Jualan Draf', 'revenue', 'sales', '4100');
  r.so       := pg_temp.da_account(r.org, '4191', 'Jualan Pesanan', 'revenue', 'sales', '4100');
  r.void_inv := pg_temp.da_account(r.org, '4192', 'Jualan Batal', 'revenue', 'sales', '4100');
  r.gone_inv := pg_temp.da_account(r.org, '4193', 'Jualan Dibuang', 'revenue', 'sales', '4100');
  r.done_so  := pg_temp.da_account(r.org, '4194', 'Jualan Selesai', 'revenue', 'sales', '4100');
  r.cx_so    := pg_temp.da_account(r.org, '4195', 'Jualan Dibatalkan', 'revenue', 'sales', '4100');
  r.pend     := pg_temp.da_account(r.org, '4196', 'Jualan Menunggu', 'revenue', 'sales', '4100');
  r.done_inv := pg_temp.da_account(r.org, '4197', 'Jualan Dihantar', 'revenue', 'sales', '4100');
  r.bill     := pg_temp.da_account(r.org, '6291', 'Belanja Draf', 'expense', 'operating_expense', '6200');
  r.po       := pg_temp.da_account(r.org, '6281', 'Belanja Pesanan', 'expense', 'operating_expense', '6200');
  r.exp      := pg_temp.da_account(r.org, '6282', 'Belanja Tunai', 'expense', 'operating_expense', '6200');
  r.split_b  := pg_temp.da_account(r.org, '6283', 'Belanja Pecah B', 'expense', 'operating_expense', '6200');
  r.split_c  := pg_temp.da_account(r.org, '6284', 'Belanja Pecah C', 'expense', 'operating_expense', '6200');
  r.rej_bill := pg_temp.da_account(r.org, '6285', 'Belanja Ditolak', 'expense', 'operating_expense', '6200');
  r.void_exp := pg_temp.da_account(r.org, '6286', 'Belanja Batal', 'expense', 'operating_expense', '6200');
  r.appr     := pg_temp.da_account(r.org, '6287', 'Belanja Lulus', 'expense', 'operating_expense', '6200');
  r.gone_bill := pg_temp.da_account(r.org, '6271', 'Belanja Dibuang', 'expense', 'operating_expense', '6200');
  r.done_po   := pg_temp.da_account(r.org, '6272', 'Belanja Selesai', 'expense', 'operating_expense', '6200');
  r.cx_po     := pg_temp.da_account(r.org, '6273', 'Belanja Dibatalkan', 'expense', 'operating_expense', '6200');
  r.done_bill := pg_temp.da_account(r.org, '6274', 'Belanja Diterima', 'expense', 'operating_expense', '6200');
  r.gone_exp  := pg_temp.da_account(r.org, '6275', 'Belanja Tunai Dibuang', 'expense', 'operating_expense', '6200');
  r.adj      := pg_temp.da_account(r.org, '5901', 'Pelarasan Khas', 'expense', 'cost_of_sales', '5900');
  r.void_adj := pg_temp.da_account(r.org, '5902', 'Pelarasan Batal', 'expense', 'cost_of_sales', '5900');

  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'CUST', 'Pelanggan', 'customer') returning id into r.cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal', 'supplier') returning id into r.sup;
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'STK', 'Barang Stok', 'stock', true, 'C62', 40) returning id into r.item;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity, unit_cost)
  values (r.org, 'KS-0001', pg_temp.today() - 5, 'opening_balance', r.item, r.wh, 100, 10);
  insert into t_da select r.*;

  -- Documents that will post nothing more, each naming an account of
  -- its own: written here in the state they end in.
  v := pg_temp.da_sales('invoice', 'INV-BATAL', r.void_inv, 1, 100);
  update public.sales_documents set status = 'void' where id = v;
  v := pg_temp.da_sales('invoice', 'INV-DIBUANG', r.gone_inv, 1, 100);
  update public.sales_documents set deleted_at = now() where id = v;
  v := pg_temp.da_sales('sales_order', 'SO-SELESAI', r.done_so, 1, 100);
  update public.sales_documents set fulfilment_status = 'fulfilled' where id = v;
  v := pg_temp.da_sales('sales_order', 'SO-BATAL', r.cx_so, 1, 100);
  update public.sales_documents set fulfilment_status = 'cancelled' where id = v;
  v := pg_temp.da_purchase('bill', 'BIL-TOLAK', r.rej_bill, 1, 60);
  update public.purchase_documents set status = 'rejected' where id = v;
  v := pg_temp.da_purchase('bill', 'BIL-DIBUANG', r.gone_bill, 1, 60);
  update public.purchase_documents set deleted_at = now() where id = v;
  v := pg_temp.da_purchase('purchase_order', 'PO-SELESAI', r.done_po, 1, 60);
  update public.purchase_documents set fulfilment_status = 'fulfilled' where id = v;
  v := pg_temp.da_purchase('purchase_order', 'PO-BATAL', r.cx_po, 1, 60);
  update public.purchase_documents set fulfilment_status = 'cancelled' where id = v;
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, amount, total_amount, status, description, deleted_at)
  values (r.org, 'EXP-DIBUANG', pg_temp.today(), r.gone_exp, 40, 40, 'draft', 'Dibuang', now());
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, amount, total_amount, status, description)
  values (r.org, 'EXP-BATAL', pg_temp.today(), r.void_exp, 40, 40, 'void', 'Batal');
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id)
  values (r.org, 'ADJ-BATAL', pg_temp.today(), r.wh, 'Batal', 'stock_take', 'void', r.void_adj);

  -- And three still on their way: one waiting for approval, one
  -- approved, and an invoice whose goods have gone out and which has
  -- yet to post.
  v := pg_temp.da_sales('invoice', 'INV-TUNGGU', r.pend, 1, 100);
  update public.sales_documents set status = 'pending' where id = v;
  v := pg_temp.da_purchase('bill', 'BIL-LULUS', r.appr, 1, 60);
  update public.purchase_documents set status = 'approved' where id = v;
  v := pg_temp.da_sales('invoice', 'INV-DIHANTAR', r.done_inv, 1, 100);
  update public.sales_documents set fulfilment_status = 'fulfilled' where id = v;
  v := pg_temp.da_purchase('bill', 'BIL-DITERIMA', r.done_bill, 1, 60);
  update public.purchase_documents set fulfilment_status = 'fulfilled' where id = v;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_da; v_inv uuid; v_bill uuid; v_so uuid; v_exp uuid; v_adj uuid; v_bank uuid;
begin
  select * into d from t_da;
  v_bank := public.upsert_bank_account('Bank Utama', 'Maybank', null, '5123000055', p_org_id => d.org);

  v_inv  := pg_temp.da_sales('invoice', 'INV-DRAF-1', d.inv, 1, 100);
  v_bill := pg_temp.da_purchase('bill', 'BIL-DRAF-1', d.bill, 1, 60);
  v_so   := pg_temp.da_sales('sales_order', 'SO-DRAF-1', d.so, 2, 100);
  perform pg_temp.da_purchase('purchase_order', 'PO-DRAF-1', d.po, 1, 60);
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, bank_account_id, amount, total_amount, status, description)
  values (d.org, 'EXP-DRAF-1', pg_temp.today(), d.exp, v_bank, 40, 40, 'draft', 'Tunai');
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, bank_account_id, amount, total_amount, status, description)
  values (d.org, 'EXP-DRAF-2', pg_temp.today(), d.split_b, v_bank, 100, 100, 'draft', 'Pecah')
  returning id into v_exp;
  perform public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object('account_id', d.split_b, 'amount', 70),
    jsonb_build_object('account_id', d.split_c, 'amount', 30)));
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id)
  values (d.org, 'ADJ-DRAF-1', pg_temp.today(), d.wh, 'Kiraan', 'stock_take', 'draft', d.adj)
  returning id into v_adj;
  insert into public.stock_adjustment_lines
    (org_id, adjustment_id, line_no, item_id, system_quantity, counted_quantity, unit_cost)
  values (d.org, v_adj, 1, d.item, 100, 90, 10);

  -- -------------------------------------------------------------------
  -- Written, and yet to post
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('an account on a draft invoice''s line is not closed',
    format('select public.retire_account(%L)', d.inv),
    'Account 4190 is still named by unposted invoice INV-DRAF-1, and what is posted through that would go on landing in it after it closed. Name another account there first, then close it.',
    '23514');
  perform pg_temp.check_refused('nor one on a draft bill''s',
    format('select public.retire_account(%L)', d.bill),
    'Account 6291 is still named by unposted bill BIL-DRAF-1, and what is posted%', '23514');
  perform pg_temp.check_refused('nor one on a sales order still to be invoiced',
    format('select public.retire_account(%L)', d.so),
    'Account 4191 is still named by open sales order SO-DRAF-1, and what is posted%', '23514');
  perform pg_temp.check_refused('nor one on a purchase order still to be billed',
    format('select public.retire_account(%L)', d.po),
    'Account 6281 is still named by open purchase order PO-DRAF-1, and what is posted%', '23514');
  perform pg_temp.check_refused('nor a draft expense''s account',
    format('select public.retire_account(%L)', d.exp),
    'Account 6282 is still named by unposted expense EXP-DRAF-1, and what is posted%', '23514');
  perform pg_temp.check_refused('nor the first line of an expense split in two',
    format('select public.retire_account(%L)', d.split_b),
    'Account 6283 is still named by unposted expense EXP-DRAF-2, and what is posted%', '23514');
  perform pg_temp.check_refused('nor the second, which only the split names',
    format('select public.retire_account(%L)', d.split_c),
    'Account 6284 is still named by unposted expense EXP-DRAF-2, and what is posted%', '23514');
  perform pg_temp.check_refused('nor a draft stock adjustment''s own account',
    format('select public.retire_account(%L)', d.adj),
    'Account 5901 is still named by unposted stock adjustment ADJ-DRAF-1, and what is posted%', '23514');

  -- Not a draft any more, and not yet posted either.
  perform pg_temp.check_refused('nor one on an invoice waiting for approval',
    format('select public.retire_account(%L)', d.pend),
    'Account 4196 is still named by unposted invoice INV-TUNGGU, and what is posted%', '23514');
  perform pg_temp.check_refused('nor one on a bill approved and not yet posted',
    format('select public.retire_account(%L)', d.appr),
    'Account 6287 is still named by unposted bill BIL-LULUS, and what is posted%', '23514');
  -- An order all carried on is done with; an invoice all delivered
  -- still has its own posting to come.
  perform pg_temp.check_refused('nor one on an invoice whose goods have all gone out',
    format('select public.retire_account(%L)', d.done_inv),
    'Account 4197 is still named by unposted invoice INV-DIHANTAR, and what is posted%', '23514');

  perform pg_temp.check_refused('nor one on a bill whose goods have all come in',
    format('select public.retire_account(%L)', d.done_bill),
    'Account 6274 is still named by unposted bill BIL-DITERIMA, and what is posted%', '23514');

  perform pg_temp.check_eq('after all of that nothing in the company was closed',
    (select count(*) from public.accounts a
      where a.org_id = d.org and (a.deleted_at is not null or not a.is_active)), 0::bigint);

  -- -------------------------------------------------------------------
  -- What will post nothing more
  -- -------------------------------------------------------------------
  perform pg_temp.check_eq('an account only a voided invoice names is closed',
    public.retire_account(d.void_inv), 'closed');
  perform pg_temp.check_eq('and one only a removed invoice names',
    public.retire_account(d.gone_inv), 'closed');
  perform pg_temp.check_eq('and one only an order all carried on names',
    public.retire_account(d.done_so), 'closed');
  perform pg_temp.check_eq('and one only a cancelled order names',
    public.retire_account(d.cx_so), 'closed');
  perform pg_temp.check_eq('and one only a rejected bill names',
    public.retire_account(d.rej_bill), 'closed');
  perform pg_temp.check_eq('and one only a removed bill names',
    public.retire_account(d.gone_bill), 'closed');
  perform pg_temp.check_eq('and one only a purchase order all carried on names',
    public.retire_account(d.done_po), 'closed');
  perform pg_temp.check_eq('and one only a cancelled purchase order names',
    public.retire_account(d.cx_po), 'closed');
  perform pg_temp.check_eq('and one only a voided expense names',
    public.retire_account(d.void_exp), 'closed');
  perform pg_temp.check_eq('and one only a removed expense names',
    public.retire_account(d.gone_exp), 'closed');
  perform pg_temp.check_eq('and one only a voided stock adjustment names',
    public.retire_account(d.void_adj), 'closed');

  -- -------------------------------------------------------------------
  -- Moved off the line, carried on, or posted
  -- -------------------------------------------------------------------
  update public.sales_document_lines set account_id = null where document_id = v_inv;
  perform pg_temp.check_eq('the invoice''s line moved off it, the account is closed',
    public.retire_account(d.inv), 'closed');

  -- The order turned into an invoice: the order is done with, and the
  -- invoice it became names the account in its place.
  perform public.transfer_document(v_so, 'invoice', null);
  perform pg_temp.check_refused('an order carried on hands its account to the invoice it became',
    format('select public.retire_account(%L)', d.so),
    'Account 4191 is still named by unposted invoice %, and what is posted%', '23514');

  -- Posted, a bill no longer names its account: what it put there does.
  perform public.post_purchase_document(v_bill);
  perform pg_temp.check_refused('a bill once posted keeps its account by the balance it left',
    format('select public.retire_account(%L)', d.bill),
    'Account 6291 still carries a balance of 60.00 debit.%', '23514');
end $$;

reset role;
rollback;
