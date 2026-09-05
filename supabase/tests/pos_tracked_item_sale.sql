-- =====================================================================
-- iAkauntan :: selling dated stock over the counter
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/pos_tracked_item_sale.sql
--
-- A pharmacy sells the box of tablets itself. A mini-market sells the
-- carton of milk itself. Neither of them is a recipe, and until 0540
-- neither of them could be rung through the till at all:
-- `complete_pos_sale` raised
--
--     Item MILK is tracked by batch, so every unit has to be named
--     before this can be posted.
--
-- from the delivery movement the counter invoice writes. There is
-- nobody at a till to name a batch, and the POS has no screen that
-- could ask -- so the whole business type was shut out.
--
-- The rule the refusal protects is a real one and stays: an ordinary
-- invoice for a tracked item still has to say which batch went, because
-- an office typing an invoice CAN be asked and a silent pick would let
-- a recall miss the customer who has the affected box. What 0540 does
-- is answer for the till: earliest expiry first, written onto the
-- invoice line as `document_line_lots` at the moment the sale
-- completes, so the invoice says which batch left exactly as a typed
-- one would.
--
-- A SERIAL NUMBER IS NOT A BATCH, and 0540 keeps refusing it. A batch
-- names a production run, and which carton of the run somebody carried
-- out is not a fact a counter knows. A serial names one machine, and
-- picking one would print on this customer's warranty the number of the
-- machine the next customer walks out with. That wants a scan field at
-- the till, so the refusal stays -- reworded to say what is missing.
--
-- This file sells a batch-tracked item straight over the counter, with
-- two batches on hand and the older one not big enough, and asks which
-- batch left. Then it asks for more than the shelf holds, and then it
-- asks for a serialised machine.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.pt_receive(
  p_org uuid, p_item uuid, p_wh uuid, p_lots jsonb)
returns uuid language plpgsql as $$
declare v_supp uuid; v_doc uuid; v_line uuid; v_qty numeric;
begin
  select id into v_supp from public.contacts
   where org_id = p_org and contact_type = 'supplier' limit 1;
  select coalesce(sum((x ->> 'quantity')::numeric), 0) into v_qty
    from jsonb_array_elements(p_lots) x;
  if v_qty = 0 then v_qty := 10; end if;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', 'BILL-' || substr(gen_random_uuid()::text, 1, 8),
          date '2026-02-01', v_supp, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (p_org, v_doc, 1, 'item', p_item, 'Goods', v_qty, 'C62', 10, p_wh)
  returning id into v_line;
  -- An untracked item has no batches to name, and `set_line_lots`
  -- refuses to pretend otherwise.
  if jsonb_array_length(p_lots) > 0 then
    perform public.set_line_lots('purchase_document_lines', v_line, p_lots);
  end if;
  perform public.post_purchase_document(v_doc);
  return v_line;
end $$;

-- How much of a named batch a counter sale's invoice line says it took.
create or replace function pg_temp.pt_named(
  p_sale uuid, p_item uuid, p_ref text)
returns numeric language sql stable as $$
  select coalesce(sum(d.quantity), 0)
    from public.document_line_lots d
    join public.sales_document_lines l on l.id = d.sales_line_id
    join public.pos_sales s on s.invoice_id = l.document_id
   where s.id = p_sale and l.item_id = p_item and d.lot_ref = p_ref;
$$;

-- And how much of it actually left the shelf.
create or replace function pg_temp.pt_moved(
  p_sale uuid, p_item uuid, p_ref text)
returns numeric language sql stable as $$
  select coalesce(sum(sml.quantity), 0)
    from public.stock_movement_lots sml
    join public.stock_movements m on m.id = sml.movement_id
    join public.stock_lots lo on lo.id = sml.lot_id
    join public.pos_sales s on s.invoice_id = m.source_id
   where s.id = p_sale and m.source_table = 'sales_documents'
     and m.item_id = p_item and lo.lot_ref = p_ref;
$$;

do $$
declare
  v_org    uuid := pg_temp.test_org('Farmasi Kaunter Sdn Bhd');
  v_shop   uuid;
  v_walkin uuid;
  v_supp   uuid;
  v_pill   uuid;
  v_soap   uuid;
  v_phone  uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_sale   uuid;
  v_inv    uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'KEDAI', 'The shop floor', true) returning id into v_shop;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Pembekal Ubat', 'supplier') returning id into v_supp;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Kaunter', 'customer') returning id into v_walkin;

  -- The thing itself is tracked. Not an ingredient of it: the box on
  -- the shelf, with a date printed on the box.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, tracking)
  values (v_org, 'UBAT', 'Ubat batuk 100ml', 'stock', true, 'C62',
          15.00, 10.00, 'batch')
  returning id into v_pill;
  -- And something on the same bill that is not tracked at all, so the
  -- pick is shown to be per line rather than per sale.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'SABUN', 'Sabun', 'stock', true, 'C62', 3.00, 1.00)
  returning id into v_soap;
  -- And one tracked the other way, which is a different question and
  -- gets a different answer.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, tracking)
  values (v_org, 'ALAT', 'Alat ukur tekanan darah', 'stock', true, 'C62',
          250.00, 180.00, 'serial')
  returning id into v_phone;

  -- TWO BATCHES, AND THE OLDER ONE IS NOT BIG ENOUGH. Three units are
  -- sold against two on the early batch, so a pick that took the
  -- newest, or that stopped at the first batch, or that took all three
  -- from one of them, reads differently from a pick that empties the
  -- early one and starts the late one.
  perform pg_temp.pt_receive(v_org, v_pill, v_shop, jsonb_build_array(
    jsonb_build_object('lot_ref', 'LOT-LAMA', 'quantity', 2,
                       'expiry_date', '2026-06-30'),
    jsonb_build_object('lot_ref', 'LOT-BARU', 'quantity', 5,
                       'expiry_date', '2027-06-30')));
  perform pg_temp.pt_receive(v_org, v_soap, v_shop, '[]'::jsonb);
  perform pg_temp.pt_receive(v_org, v_phone, v_shop, jsonb_build_array(
    jsonb_build_object('lot_ref', 'SN-0001', 'quantity', 1),
    jsonb_build_object('lot_ref', 'SN-0002', 'quantity', 1)));

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'FARMASI', 'Farmasi Jalan Besar', 'retail', v_shop,
          v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Kaunter') returning id into v_reg;
  insert into public.pos_settings (org_id) values (v_org);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true)
  returning id into v_cash;
  perform public.open_pos_shift(v_reg, 100.00);

  -- ==================================================================
  -- The sale a pharmacy makes all day
  -- ==================================================================
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_pill, 3, 15.00);
  perform public.add_pos_sale_line(v_sale, v_soap, 1, 3.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 48.00)));

  select invoice_id into v_inv from public.pos_sales where id = v_sale;
  perform pg_temp.check_true('a counter sale of dated stock completes',
    v_inv is not null);
  -- Paid in full at the counter, so the invoice is settled rather than
  -- merely posted — which is what says the movement went through.
  perform pg_temp.check_eq('and the invoice behind it is settled',
    (select status::text from public.sales_documents where id = v_inv),
    'completed');

  -- WHICH BATCH LEFT. Earliest expiry first, and the older batch is
  -- only two, so the third unit comes off the newer one.
  perform pg_temp.check_eq('the invoice names the batch expiring first',
    pg_temp.pt_named(v_sale, v_pill, 'LOT-LAMA'), 2);
  perform pg_temp.check_eq('and the rest against the one behind it',
    pg_temp.pt_named(v_sale, v_pill, 'LOT-BARU'), 1);
  perform pg_temp.check_eq('which is the whole of what was sold',
    pg_temp.pt_named(v_sale, v_pill, 'LOT-LAMA')
      + pg_temp.pt_named(v_sale, v_pill, 'LOT-BARU'), 3);

  -- And the shelf agrees with the paper. This is the assertion that
  -- would have failed before 0540 -- there was no paper.
  perform pg_temp.check_eq('two off the early batch',
    pg_temp.pt_moved(v_sale, v_pill, 'LOT-LAMA'), -2);
  perform pg_temp.check_eq('and one off the late one',
    pg_temp.pt_moved(v_sale, v_pill, 'LOT-BARU'), -1);
  perform pg_temp.check_eq('the early batch is finished',
    (select coalesce(sum(b.quantity), 0) from public.v_lot_balances b
      join public.stock_lots l on l.id = b.lot_id
     where l.item_id = v_pill and l.lot_ref = 'LOT-LAMA'), 0);
  perform pg_temp.check_eq('and four of the late one are left',
    (select coalesce(sum(b.quantity), 0) from public.v_lot_balances b
      join public.stock_lots l on l.id = b.lot_id
     where l.item_id = v_pill and l.lot_ref = 'LOT-BARU'), 4);

  -- The soap is stock and is not tracked, so nothing is named for it
  -- and nothing needed to be.
  perform pg_temp.check_eq('an untracked line is named against no batch',
    (select count(*) from public.document_line_lots d
      join public.sales_document_lines l on l.id = d.sales_line_id
     where l.document_id = v_inv and l.item_id = v_soap), 0);
  perform pg_temp.check_eq('and still leaves the shelf',
    (select coalesce(sum(m.quantity), 0) from public.stock_movements m
      where m.source_id = v_inv and m.item_id = v_soap), -1);

  -- ==================================================================
  -- Selling what there is no batch of
  -- ==================================================================
  -- Four are left. Asking for five is asking for a box that is not on
  -- any shelf, and a shop that sells dated stock cannot hand over what
  -- it has not got — so this is refused, and refused in words a cashier
  -- can act on rather than in the invariant's own words.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_pill, 5, 15.00);
  perform pg_temp.check_refused('more than is on the shelf is refused',
    format($q$select public.complete_pos_sale(%L, %L::jsonb)$q$,
           v_sale, jsonb_build_array(
             jsonb_build_object('type', v_cash, 'amount', 75.00))),
    '%only 4 of the 5 asked for%', '23514');
  perform pg_temp.check_eq('and the sale is still open to be corrected',
    (select status::text from public.pos_sales where id = v_sale),
    'parked');

  -- ==================================================================
  -- The same box scanned twice
  -- ==================================================================
  -- Nothing on this bill is posted while the pick runs, so the balance
  -- the second line reads is the balance the first line read. Two lines
  -- of the same item is how a till is actually used — the cashier scans
  -- the box, then scans it again — and a second line that cannot see
  -- what the first one claimed picks the SAME batch again: two boxes
  -- handed over, one batch recorded twice, and a recall that reaches
  -- half the customers it should.
  --
  -- A fresh batch of exactly two, expiring before the four already on
  -- the shelf. Two lines of two: the first empties the new batch and
  -- the second must fall through to the one behind it.
  perform pg_temp.pt_receive(v_org, v_pill, v_shop, jsonb_build_array(
    jsonb_build_object('lot_ref', 'LOT-TENGAH', 'quantity', 2,
                       'expiry_date', '2026-09-30')));

  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_pill, 2, 15.00);
  perform public.add_pos_sale_line(v_sale, v_pill, 2, 15.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 60.00)));

  perform pg_temp.check_eq('the first line empties the batch expiring first',
    pg_temp.pt_named(v_sale, v_pill, 'LOT-TENGAH'), 2);
  perform pg_temp.check_eq('and the second falls through to the one behind it',
    pg_temp.pt_named(v_sale, v_pill, 'LOT-BARU'), 2);
  perform pg_temp.check_eq('rather than claiming the same two twice',
    (select count(*) from public.document_line_lots d
      join public.sales_document_lines l on l.id = d.sales_line_id
      join public.pos_sales s on s.invoice_id = l.document_id
     where s.id = v_sale and d.lot_ref = 'LOT-TENGAH'), 1);
  perform pg_temp.check_eq('so the shelf is down four and not down two',
    (select coalesce(sum(b.quantity), 0) from public.v_lot_balances b
      join public.stock_lots l on l.id = b.lot_id
     where l.item_id = v_pill), 2);

  -- ==================================================================
  -- A serial number is not a batch
  -- ==================================================================
  -- Two machines on the shelf and nothing to tell them apart to the
  -- customer. A batch names a production run and picking one of those
  -- is a true statement; a serial names ONE MACHINE, and picking one
  -- would print on this customer's warranty the number of a machine the
  -- next customer walks out with. So it is still refused — but in words
  -- that say what is missing, not in the storekeeping invariant's.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_phone, 1, 250.00);
  perform pg_temp.check_refused('a serialised item is not picked for the customer',
    format($q$select public.complete_pos_sale(%L, %L::jsonb)$q$,
           v_sale, jsonb_build_array(
             jsonb_build_object('type', v_cash, 'amount', 250.00))),
    '%a till has nowhere to scan one%', '23514');
  perform pg_temp.check_true('and both machines are still on the shelf',
    (select count(*) from public.v_lot_balances b
      join public.stock_lots l on l.id = b.lot_id
     where l.item_id = v_phone and b.quantity > 0) = 2);
end $$;

rollback;
