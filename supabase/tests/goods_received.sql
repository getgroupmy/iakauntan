-- =====================================================================
-- iAkauntan :: a goods received note receives goods
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/goods_received.sql
--
-- Before `0609`, measured rather than inferred:
--
--   PO -> Bill          : 1 movement(s), 10.0000 received
--   PO -> GRN -> Bill   : 0 movement(s), 0 received
--
-- The same ten units, bought two ways, and one way never reached the
-- shelf. `app.post_purchase_document_internal` skipped receiving when
-- the bill's parent was a goods received note -- correctly reasoning
-- that the note had already done it, and wrongly, because nothing in
-- the schema had ever received stock on one.
--
-- The assertion this file exists for is the first one below: buy the
-- same thing both ways and every figure agrees. Not the stock alone --
-- the LEDGER too, because the fix is not "also move the stock" but "the
-- note accrues what is owed and the bill clears it", and an accrual
-- that does not net off is a balance sheet with a permanent stranded
-- liability on it.
--
-- `posting_a_bill.sql` covers the same ground from the other side and
-- records what it used to assert: an empty, unposted note and a bill
-- that moved no stock, which passed for years and would have passed
-- identically if the note had never been created.
--
-- Nothing is kept; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A company that can buy something: a warehouse, a supplier, a stock
-- item and a fiscal year for the ledger to land in.
create or replace function pg_temp.gr_company(p_name text)
returns table (org uuid, supplier uuid, item uuid, warehouse uuid)
language plpgsql as $$
declare v_org uuid; v_sup uuid; v_item uuid; v_wh uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', app.today())::date);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'Store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal Sdn Bhd', 'supplier')
  returning id into v_sup;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'PART', 'Alat ganti', 'stock', true, 'C62', 25.00)
  returning id into v_item;

  org := v_org; supplier := v_sup; item := v_item; warehouse := v_wh;
  return next;
end $$;

-- A posted purchase order for ten at twenty-five.
create or replace function pg_temp.gr_order(
  p_org uuid, p_sup uuid, p_item uuid, p_wh uuid, p_no text)
returns uuid language plpgsql as $$
declare v_po uuid;
begin
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (p_org, 'purchase_order', p_no, app.today(), p_sup, 'MYR', 1,
          'draft', 250, 250, 250, 250)
  returning id into v_po;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, line_subtotal, line_total,
     warehouse_id)
  values (p_org, v_po, 1, 'item', p_item, 'Alat ganti', 10, 'C62',
          25.00, 250, 250, p_wh);
  update public.purchase_documents set status = 'posted' where id = v_po;
  return v_po;
end $$;

-- What an account has on it, across every entry in the company.
create or replace function pg_temp.gr_balance(p_org uuid, p_code text)
returns numeric language sql stable as $$
  select round(coalesce(sum(l.debit - l.credit), 0), 2)
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where a.org_id = p_org and a.code = p_code;
$$;

-- =====================================================================
-- The same purchase, bought two ways, agrees on every figure
-- =====================================================================
do $$
declare
  v_a       record;
  v_b       record;
  v_po      uuid;
  v_grn     uuid;
  v_bill    uuid;
  v_stock_a numeric;
  v_stock_b numeric;
  v_code    text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());

  -- Direct: order straight to bill.
  select * into v_a from pg_temp.gr_company('Terus Sdn Bhd');
  v_po := pg_temp.gr_order(v_a.org, v_a.supplier, v_a.item, v_a.warehouse,
                           'PO-A');
  v_bill := public.transfer_document(v_po, 'bill');
  perform public.post_purchase_document(v_bill);

  select round(sl.quantity, 4) into v_stock_a from public.stock_levels sl
   where sl.item_id = v_a.item and sl.warehouse_id = v_a.warehouse;
  perform pg_temp.check_eq(
    'bought straight through, ten arrive', v_stock_a, 10::numeric);

  -- Through a receiving note.
  perform pg_temp.allow_many_companies();
  select * into v_b from pg_temp.gr_company('Melalui GRN Sdn Bhd');
  v_po := pg_temp.gr_order(v_b.org, v_b.supplier, v_b.item, v_b.warehouse,
                           'PO-B');
  v_grn := public.transfer_document(v_po, 'goods_received');
  perform public.post_goods_received(v_grn);

  select round(sl.quantity, 4) into v_stock_b from public.stock_levels sl
   where sl.item_id = v_b.item and sl.warehouse_id = v_b.warehouse;
  perform pg_temp.check_eq(
    'and the receiving note is what puts them there on the other path',
    v_stock_b, 10::numeric);

  -- The accrual exists while the bill has not arrived. This is the
  -- position a receiving note is FOR: the goods are here and nobody has
  -- priced them.
  perform pg_temp.check_eq(
    'with what is owed for them accrued, not payable yet',
    pg_temp.gr_balance(v_b.org, '2118'), -250.00);
  perform pg_temp.check_eq(
    'and nothing on accounts payable, because no bill has come',
    pg_temp.gr_balance(v_b.org, '2110'), 0.00);

  v_bill := public.transfer_document(v_grn, 'bill');
  perform public.post_purchase_document(v_bill);

  select round(sl.quantity, 4) into v_stock_b from public.stock_levels sl
   where sl.item_id = v_b.item and sl.warehouse_id = v_b.warehouse;
  perform pg_temp.check_eq(
    'the bill adds no more -- they are already on the shelf',
    v_stock_b, 10::numeric);

  -- THE assertion. Every account that either path touched, compared.
  foreach v_code in array array['1310', '2110', '2118'] loop
    perform pg_temp.check_eq(
      format('both paths leave account %s on the same figure', v_code),
      pg_temp.gr_balance(v_b.org, v_code),
      pg_temp.gr_balance(v_a.org, v_code));
  end loop;

  perform pg_temp.check_eq(
    'and the accrual is back to nothing once the bill has come',
    pg_temp.gr_balance(v_b.org, '2118'), 0.00);
  perform pg_temp.check_eq(
    'while the stock is on the shelf once, not twice',
    v_stock_b, v_stock_a);

  -- CONTROL. The two companies really did post something, so the
  -- comparisons above are between two real sets of figures rather than
  -- between two empty ones.
  perform pg_temp.check_eq(
    'both of them capitalised the goods', 
    pg_temp.gr_balance(v_a.org, '1310'), 250.00);
end $$;

-- =====================================================================
-- A bill raised from a DRAFT note still receives the goods
--
-- The old skip asked whether the parent was a receiving note. That was
-- standing in for whether the stock was already here, and a draft note
-- has received nothing -- so a bill raised from one skipped, and the
-- goods arrived nowhere at all.
-- =====================================================================
do $$
declare
  v       record;
  v_po    uuid;
  v_grn   uuid;
  v_bill  uuid;
  v_stock numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.gr_company('Draf GRN Sdn Bhd');
  v_po := pg_temp.gr_order(v.org, v.supplier, v.item, v.warehouse, 'PO-C');

  v_grn := public.transfer_document(v_po, 'goods_received');
  perform pg_temp.check_eq(
    'the note is a draft and has received nothing',
    (select count(*)::integer from public.stock_movements
      where source_id = v_grn), 0);

  v_bill := public.transfer_document(v_grn, 'bill');
  perform public.post_purchase_document(v_bill);

  select round(sl.quantity, 4) into v_stock from public.stock_levels sl
   where sl.item_id = v.item and sl.warehouse_id = v.warehouse;
  perform pg_temp.check_eq(
    'so the bill receives them rather than nobody doing it',
    v_stock, 10::numeric);
  perform pg_temp.check_eq(
    'and capitalises them, because no accrual was raised to clear',
    pg_temp.gr_balance(v.org, '1310'), 250.00);
  perform pg_temp.check_eq(
    'leaving goods received not invoiced untouched',
    pg_temp.gr_balance(v.org, '2118'), 0.00);
end $$;

-- =====================================================================
-- A return still goes out
--
-- The first attempt at the fix asked only "does the parent have
-- movements". A purchase credit note raised by `credit_purchase_bill`
-- carries the BILL as its parent, and that bill has movements -- so
-- every return skipped its own outward movement. Twenty credited and a
-- hundred still on the shelf.
-- =====================================================================
do $$
declare
  v       record;
  v_bill  uuid;
  v_note  uuid;
  v_line  uuid;
  v_stock numeric;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.gr_company('Pulang Sdn Bhd');

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (v.org, 'bill', 'BILL-D', app.today(), v.supplier, 'MYR', 1,
          'draft', 250, 250, 250, 250)
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, line_subtotal, line_total,
     warehouse_id)
  values (v.org, v_bill, 1, 'item', v.item, 'Alat ganti', 10, 'C62',
          25.00, 250, 250, v.warehouse)
  returning id into v_line;
  perform public.post_purchase_document(v_bill);

  v_note := public.credit_purchase_bill(v_bill,
    jsonb_build_array(jsonb_build_object('line', v_line, 'quantity', 4)),
    'Empat rosak');

  select round(sl.quantity, 4) into v_stock from public.stock_levels sl
   where sl.item_id = v.item and sl.warehouse_id = v.warehouse;
  perform pg_temp.check_eq(
    'four went back, so six are left', v_stock, 6::numeric);
  perform pg_temp.check_eq(
    'and the movement says it was a return',
    (select m.movement_type::text from public.stock_movements m
      where m.source_id = v_note limit 1), 'purchase_return');
end $$;

-- =====================================================================
-- What a receiving note refuses
-- =====================================================================
do $$
declare
  v      record;
  v_po   uuid;
  v_grn  uuid;
  v_svc  uuid;
  v_only uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.gr_company('Enggan Sdn Bhd');
  v_po := pg_temp.gr_order(v.org, v.supplier, v.item, v.warehouse, 'PO-E');
  v_grn := public.transfer_document(v_po, 'goods_received');
  perform public.post_goods_received(v_grn);

  perform pg_temp.check_refused(
    'a note cannot be posted twice',
    format($q$ select public.post_goods_received(%L) $q$, v_grn),
    '%already posted%', '22023');

  perform pg_temp.check_refused(
    'and a bill is not a receiving note',
    format($q$ select public.post_goods_received(%L) $q$, v_po),
    '%is not a goods received note%', '22023');

  -- A note of nothing but services. Nothing arrived, nothing goes on a
  -- shelf, and capitalising it into inventory would be worse than
  -- refusing it.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v.org, 'FIT', 'Pemasangan', 'service', false, 'C62', 100.00)
  returning id into v_svc;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (v.org, 'goods_received', 'GRN-SVC', app.today(), v.supplier,
          'MYR', 1, 'draft', 100, 100, 100, 100)
  returning id into v_only;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, line_subtotal, line_total)
  values (v.org, v_only, 1, 'item', v_svc, 'Pemasangan', 1, 'C62',
          100, 100, 100);

  perform pg_temp.check_refused(
    'a note of nothing but services is refused, and says where it belongs',
    format($q$ select public.post_goods_received(%L) $q$, v_only),
    '%service belongs on the bill%', '22023');
end $$;

-- =====================================================================
-- Who may receive goods
-- =====================================================================
do $$
declare
  v       record;
  v_po    uuid;
  v_grn   uuid;
  v_me    uuid;
  v_other uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  select * into v from pg_temp.gr_company('Siapa Sdn Bhd');
  v_po := pg_temp.gr_order(v.org, v.supplier, v.item, v.warehouse, 'PO-F');
  v_grn := public.transfer_document(v_po, 'goods_received');

  v_me := pg_temp.test_user();
  v_other := pg_temp.another_user('penonton@siapa.test');
  insert into public.org_members (org_id, user_id, role, status)
  values (v.org, v_other, 'viewer', 'active')
  on conflict (org_id, user_id) do update set role = 'viewer';

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_refused(
    'somebody who cannot post cannot receive goods either',
    format($q$ select public.post_goods_received(%L) $q$, v_grn),
    '%Insufficient privileges to post%', '42501');

  -- CONTROL. It goes through for somebody who can, so the refusal above
  -- is about the person rather than about the note.
  perform pg_temp.sign_in_as(v_me);
  perform pg_temp.check_true(
    'while somebody who can post, can',
    public.post_goods_received(v_grn) is not null);
end $$;

-- ---------------------------------------------------------------------
-- The twelve a mutation run found this file could not see
-- ---------------------------------------------------------------------
--
-- `app.post_goods_received_internal` was mutated eighteen ways on
-- 5 October. SIX died against the assertions above and TWELVE survived
-- -- the worst score of any function measured. `posting_a_bill.sql`,
-- the only other file that reaches it, killed just the two journal
-- balance mutations this file already killed, so the union is twelve.
--
--     python3 scripts/mutate_sql.py \
--       supabase/migrations/0609_the_goods_arrived_and_nobody_wrote_it_down.sql \
--       supabase/tests/goods_received.sql \
--       supabase/tests/mutants/post_goods_received_internal.py
--
-- Almost all twelve were ONE fixture problem wearing twelve hats: every
-- note above is in MYR at rate 1, for an item whose selling unit is its
-- stocking unit, with no inventory account of its own, in a company
-- with one warehouse. So
--
--   subtotal x rate  ==  subtotal
--   base_quantity    ==  quantity
--   round(x, 6)      ==  round(x, 2)        (the costs all divide clean)
--   the item's account == the chart's 1310
--   the default warehouse == the only warehouse
--
-- and five separate rules in the function were asserting the same
-- arithmetic. That is the twelfth entry in docs/widget-tests.md at its
-- widest: not one value collapsed into another, but a whole fixture
-- flattened so that half the function was unobservable.
--
-- The unit cost is the figure worth the trouble. It is
-- `round(line_subtotal * rate / base_quantity, 6)`, and it is what the
-- weighted average is built on afterwards -- so a wrong one here is
-- invisible until something is sold, and then wrong in the cost of
-- sales rather than here.
--
-- The numbers below are chosen so that every one of those five
-- collapses comes apart:
--
--   5 cartons of 24 at USD 100     -> subtotal USD 500, base qty 120
--   rate 4.2345                    -> inventory debit MYR 2,117.25
--   unit cost = 500 * 4.2345 / 120 = 17.643750, to six places
--
--   dropping the rate       -> 4.166667    dividing by 5 -> 423.450000
--   rounding to two places  -> 17.64       using quantity -> 5, not 120
--
-- Four assertions are plain gaps rather than collapses: no 2118
-- account, a note with nothing to receive, the movement-to-journal
-- link, and the status.
create or replace function pg_temp.gr_pack(p_org uuid, p_item uuid,
                                           p_uom text, p_qty numeric)
returns void language plpgsql as $$
begin
  insert into public.item_uom_packs
    (org_id, item_id, uom_code, qty_in_stock_uom)
  values (p_org, p_item, p_uom, p_qty);
end $$;

do $$
declare
  v_owner uuid := pg_temp.test_user();
  v_org   uuid;
  v_poor  uuid;
  v_sup   uuid;
  v_item  uuid;
  v_other uuid;
  v_acct  uuid;
  v_wh1   uuid;
  v_wh2   uuid;
  v_grn   uuid;
  v_entry uuid;
  v_mv    record;
  v_n     integer;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Pengimport Sirap Sdn Bhd',
                            array['inventory', 'accounting']);
  perform public.create_fiscal_year(v_org,
    date_trunc('year', pg_temp.today())::date);

  -- TWO warehouses, and the default is NOT the first one inserted, so
  -- `is_default` and "whichever row comes back" are different answers.
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'WH-B', 'Gudang biasa', false) returning id into v_wh2;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'WH-U', 'Gudang utama', true) returning id into v_wh1;

  -- The item's OWN inventory account, distinct from the chart's 1310,
  -- so `coalesce(inventory_account_id, 1310)` has two answers.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group)
  values (v_org, '1312', 'Inventory - sirap', 'asset', 'inventory', false)
  returning id into v_acct;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'Pembekal Sirap', 'supplier') returning id into v_sup;

  -- Stocked in pieces, bought in cartons of 24.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price,
     inventory_account_id)
  values (v_org, 'SIRAP', 'Sirap bandung', 'stock', true, 'C62', 12.00,
          v_acct)
  returning id into v_item;
  perform pg_temp.gr_pack(v_org, v_item, 'CT', 24);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'GULA', 'Gula', 'stock', true, 'C62', 3.00)
  returning id into v_other;

  -- The note: USD at 4.2345, five cartons, and a zero-quantity line for
  -- a second stocked item which must make no movement at all.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (v_org, 'goods_received', 'GRN-FX', app.today(), v_sup, 'USD',
          4.2345, 'draft', 500, 500, 2117.25, 0)
  returning id into v_grn;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_grn, 1, 'item', v_item, 'Lima kotak', 5, 'CT', 100.00);
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_org, v_grn, 2, 'item', v_other, 'Tiada lagi', 0, 'C62', 3.00);

  -- The trigger did the conversion, which is what makes the rest of
  -- this block mean anything.
  perform pg_temp.check_eq('five cartons of 24 is 120 pieces',
    (select base_quantity from public.purchase_document_lines
      where document_id = v_grn and line_no = 1), 120.000000);
  perform pg_temp.check_eq('priced per carton, so the subtotal is 500',
    (select line_subtotal from public.purchase_document_lines
      where document_id = v_grn and line_no = 1), 500.00);

  v_entry := public.post_goods_received(v_grn);
  perform pg_temp.check_true('the note posts', v_entry is not null);

  -- ------------------------------------------------------------------
  -- The journal: the item's own account, at the day's rate
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq(
    'the inventory debit is in RINGGIT, not the invoice currency',
    pg_temp.gr_balance(v_org, '1312'), 2117.25);
  perform pg_temp.check_eq(
    'and it is on the ITEM''s inventory account, not the chart''s 1310',
    pg_temp.gr_balance(v_org, '1310'), 0.00);
  perform pg_temp.check_eq('2118 carries the same figure, credited',
    pg_temp.gr_balance(v_org, '2118'), -2117.25);

  -- ------------------------------------------------------------------
  -- The stock: one movement, in pieces, at the converted unit cost
  -- ------------------------------------------------------------------
  select count(*)::integer into v_n from public.stock_movements
   where source_table = 'purchase_documents' and source_id = v_grn;
  perform pg_temp.check_eq(
    'one movement, because the zero-quantity line makes none', v_n, 1);

  select * into v_mv from public.stock_movements
   where source_table = 'purchase_documents' and source_id = v_grn;
  perform pg_temp.check_eq('the movement is for the item that arrived',
    v_mv.item_id, v_item);
  perform pg_temp.check_eq(
    'in PIECES -- 120, not the 5 cartons that were typed',
    v_mv.quantity, 120.000000);
  perform pg_temp.check_eq(
    'at the unit cost in ringgit per piece, to six places',
    v_mv.unit_cost, 17.643750);
  perform pg_temp.check_eq(
    'in the DEFAULT warehouse, no warehouse having been named',
    v_mv.warehouse_id, v_wh1);
  perform pg_temp.check_eq('and the movement names the journal it went with',
    v_mv.gl_entry_id, v_entry);
  perform pg_temp.check_eq('the note is posted',
    (select status::text from public.purchase_documents where id = v_grn),
    'posted');

  -- Each of the four ways to get that unit cost wrong gives a different
  -- figure, which is what makes the assertion above worth having.
  perform pg_temp.check_true('the four wrong unit costs are all different '
    'from the right one',
    round(500 * 4.2345 / 120, 6) = 17.643750
    and round(500 / 120, 6) <> 17.643750
    and round(500 * 4.2345 / 5, 6) <> 17.643750
    and round(500 * 4.2345 / 120, 2) <> 17.643750);

  -- ------------------------------------------------------------------
  -- A company with no 2118 cannot receive goods into limbo
  -- ------------------------------------------------------------------
  v_poor := pg_temp.test_org('Tiada 2118 Sdn Bhd',
                             array['inventory', 'accounting']);
  perform public.create_fiscal_year(v_poor,
    date_trunc('year', pg_temp.today())::date);
  update public.accounts set code = '2119'
   where org_id = v_poor and code = '2118';
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_poor, 'SUP', 'Pembekal', 'supplier') returning id into v_sup;
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_poor, 'W', 'Gudang', true);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_poor, 'ITM', 'Barang', 'stock', true, 'C62', 10.00)
  returning id into v_item;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (v_poor, 'goods_received', 'GRN-NO2118', app.today(), v_sup, 'MYR',
          1, 'draft', 100, 100, 100, 0)
  returning id into v_grn;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (v_poor, v_grn, 1, 'item', v_item, 'Barang', 10, 'C62', 10.00);
  perform pg_temp.check_refused(
    'a company with no 2118 is told to add it, not posted around',
    format('select public.post_goods_received(%L)', v_grn),
    '%account 2118%', 'P0002');

  -- ------------------------------------------------------------------
  -- A note with money on it and nothing to receive
  -- ------------------------------------------------------------------
  -- Two guards in the function look alike and are not: `v_total = 0`
  -- refuses a note of pure SERVICE lines, and `v_n = 0` refuses one
  -- where the stocked lines have no QUANTITY. Reaching the second means
  -- a tracked line whose subtotal is not zero while its quantity is --
  -- and the only way to make one is a NEGATIVE discount, because the
  -- line trigger computes `quantity * unit_price - discount`:
  --
  --     quantity 0, unit_price 0, discount_amount -100
  --       -> line_subtotal 100, base_quantity 0
  --
  -- A negative discount is a strange thing to type and the schema
  -- permits it, which was checked before writing this rather than
  -- assumed: without it the branch would be unreachable and the guard
  -- dead code, and the mutant that deletes it would be equivalent
  -- rather than a gap. It is a gap.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status, subtotal, total_amount, base_total_amount,
     balance_amount)
  values (v_poor, 'goods_received', 'GRN-NOQTY', app.today(), v_sup, 'MYR',
          1, 'draft', 100, 100, 100, 0)
  returning id into v_grn;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, discount_amount)
  values (v_poor, v_grn, 1, 'item', v_item, 'Sifar', 0, 'C62', 0, -100);

  perform pg_temp.check_eq('the line carries money and no quantity',
    (select line_subtotal from public.purchase_document_lines
      where document_id = v_grn and line_no = 1), 100.00);
  perform pg_temp.check_eq('and nothing to move',
    (select base_quantity from public.purchase_document_lines
      where document_id = v_grn and line_no = 1), 0.000000);

  -- 2118 is still renamed in this company, so put it back first -- the
  -- refusal under test is the quantity one, and the 2118 lookup comes
  -- before it. A fixture that tripped the earlier guard would pass this
  -- assertion while proving nothing about the later one.
  update public.accounts set code = '2118'
   where org_id = v_poor and code = '2119';
  perform pg_temp.check_refused(
    'a note with money on it and nothing to receive is refused',
    format('select public.post_goods_received(%L)', v_grn),
    '%has a quantity to receive%', '22023');

  perform pg_temp.sign_out();
end $$;

rollback;
