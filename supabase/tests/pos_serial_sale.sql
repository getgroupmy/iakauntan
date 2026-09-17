-- =====================================================================
-- iAkauntan :: selling a machine by its serial number, over the counter
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/pos_serial_sale.sql
--
-- `0540` taught the till to sell dated stock and stopped deliberately
-- short of serials, saying why: picking one on the customer's behalf
-- would print on their warranty the number of a machine the next
-- customer walks out with. It said that wanted a scan field at the
-- till. `0546` is that field.
--
-- `pos_tracked_item_sale.sql` still asserts the other half -- that
-- nothing guesses which machine left. This file is what happens when
-- somebody scans.
--
-- WHAT IS BEING PROVED, and each of these was a way to sell the wrong
-- machine or the same machine twice:
--
--   * the invoice names the two serials that were scanned, and the
--     shelf loses those two and not the other one;
--   * a label scanned twice is refused at the scanner, not at payment;
--   * a serial the shop has never received is refused, and a serial it
--     has received but already sold is refused DIFFERENTLY, because
--     one is a mistyped label and the other is a machine that is gone;
--   * a serial sitting in a parked basket at the next till is refused,
--     which no stock balance can see because nothing is posted until a
--     bill is paid;
--   * the count of serials is the quantity, and a bill whose two do
--     not agree is refused before it posts;
--   * and scanning onto a bill that has been paid for is refused.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- Receiving serialised stock: one line, one lot row per machine.
create or replace function pg_temp.sn_receive(
  p_org uuid, p_item uuid, p_wh uuid, p_serials text[])
returns uuid language plpgsql as $$
declare v_supp uuid; v_doc uuid; v_line uuid;
begin
  select id into v_supp from public.contacts
   where org_id = p_org and contact_type = 'supplier' limit 1;
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (p_org, 'bill', 'BILL-' || substr(gen_random_uuid()::text, 1, 8),
          date '2026-02-01', v_supp, 'MYR', 1, 'draft')
  returning id into v_doc;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (p_org, v_doc, 1, 'item', p_item, 'Machines',
          -- An untracked item has no serials to count, so it just gets
          -- a shelf-worth.
          coalesce(array_length(p_serials, 1), 5), 'C62', 900, p_wh)
  returning id into v_line;
  if coalesce(array_length(p_serials, 1), 0) > 0 then
    perform public.set_line_lots('purchase_document_lines', v_line,
      (select jsonb_agg(jsonb_build_object('lot_ref', s, 'quantity', 1))
         from unnest(p_serials) s));
  end if;
  perform public.post_purchase_document(v_doc);
  return v_doc;
end $$;

-- Which serials the invoice behind a counter sale names.
create or replace function pg_temp.sn_named(p_sale uuid)
returns text[] language sql stable as $$
  select coalesce(array_agg(d.lot_ref order by d.lot_ref), '{}'::text[])
    from public.document_line_lots d
    join public.sales_document_lines l on l.id = d.sales_line_id
    join public.pos_sales s on s.invoice_id = l.document_id
   where s.id = p_sale;
$$;

-- And whether one particular machine is still on a shelf anywhere.
create or replace function pg_temp.sn_on_hand(p_item uuid, p_ref text)
returns numeric language sql stable as $$
  select coalesce(sum(b.quantity), 0)
    from public.v_lot_balances b
    join public.stock_lots l on l.id = b.lot_id
   where l.item_id = p_item and l.lot_ref = p_ref;
$$;

do $$
declare
  v_org    uuid := pg_temp.test_org('Kedai Telefon Sdn Bhd');
  v_shop   uuid;
  v_back   uuid;
  v_walkin uuid;
  v_supp   uuid;
  v_phone  uuid;
  v_case   uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_sale   uuid;
  v_other  uuid;
  v_line   uuid;
  v_inv    uuid;
  v_refs   text[];
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'KEDAI', 'The shop floor', true) returning id into v_shop;
  -- A second shelf, so "not on the shelf" can be shown to mean THIS
  -- shelf rather than the company's whole stock.
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'GUDANG', 'The store room') returning id into v_back;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-001', 'Pembekal Telefon', 'supplier') returning id into v_supp;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Kaunter', 'customer') returning id into v_walkin;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, tracking)
  values (v_org, 'FON', 'Telefon pintar', 'stock', true, 'C62',
          1200.00, 900.00, 'serial')
  returning id into v_phone;
  -- Something untracked on the same bill, so the scan is shown to be
  -- per line rather than per sale.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'SARUNG', 'Sarung telefon', 'stock', true, 'C62', 30.00, 10.00)
  returning id into v_case;

  -- Three machines on the shop floor and one in the store room.
  perform pg_temp.sn_receive(v_org, v_phone, v_shop,
    array['SN-A1', 'SN-A2', 'SN-A3']);
  perform pg_temp.sn_receive(v_org, v_phone, v_back, array['SN-B9']);
  perform pg_temp.sn_receive(v_org, v_case, v_shop, '{}'::text[]);

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'KEDAI1', 'Kedai Jalan Besar', 'retail', v_shop,
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
  -- 1. What the scanner refuses, while the customer is still standing
  --    there
  -- ==================================================================
  v_sale := public.open_pos_sale(v_reg);
  v_line := public.add_pos_sale_line(v_sale, v_phone, 1, 1200.00);

  perform pg_temp.check_refused('a blank scan is not a serial',
    format($q$select public.pos_scan_serial(%L, '   ')$q$, v_line),
    'Scan a serial number%', '23514');

  -- A MISTYPED LABEL AND A MACHINE THAT IS GONE ARE DIFFERENT
  -- PROBLEMS. One means look at the label again; the other means look
  -- for the machine. A single "cannot scan that" would send the
  -- cashier hunting for a phone that was never in the shop.
  perform pg_temp.check_refused('a serial this shop never received',
    format($q$select public.pos_scan_serial(%L, 'SN-ZZZZ')$q$, v_line),
    'No serial SN-ZZZZ on file%', '23514');
  perform pg_temp.check_refused('and one that is on another shelf',
    format($q$select public.pos_scan_serial(%L, 'SN-B9')$q$, v_line),
    'Serial SN-B9 is not on the shelf at Kedai Jalan Besar%', '23514');

  -- ==================================================================
  -- 2. Two machines, scanned
  -- ==================================================================
  v_refs := public.pos_scan_serial(v_line, 'SN-A1');
  perform pg_temp.check_eq('the first scan lands on the line',
    array_to_string(v_refs, ','), 'SN-A1');

  -- THE COMMONEST THING THAT GOES WRONG AT A COUNTER is the same label
  -- read twice, and it is refused as itself rather than as "not on the
  -- shelf" -- because the machine IS on the shelf; it is on this bill.
  perform pg_temp.check_refused('the same label twice is refused at the scanner',
    format($q$select public.pos_scan_serial(%L, 'SN-A1')$q$, v_line),
    'Serial SN-A1 is already on this line%', '23514');

  v_refs := public.pos_scan_serial(v_line, 'SN-A2');
  perform pg_temp.check_eq('and the second joins it',
    array_to_string(v_refs, ','), 'SN-A1,SN-A2');

  -- THE COUNT OF SERIALS IS THE QUANTITY. A till is used by scanning,
  -- and a quantity box the cashier also has to keep in step is a
  -- second source of truth that will disagree with the scans.
  perform pg_temp.check_eq('scanning sets the quantity',
    (select quantity from public.pos_sale_lines where id = v_line), 2);

  -- A mis-scan comes off again, and the line stays.
  v_refs := public.pos_unscan_serial(v_line, 'SN-A2');
  perform pg_temp.check_eq('a mis-scan comes off',
    array_to_string(v_refs, ','), 'SN-A1');
  perform pg_temp.check_eq('and the quantity follows it down',
    (select quantity from public.pos_sale_lines where id = v_line), 1);
  perform pg_temp.check_refused('taking off what is not there is refused',
    format($q$select public.pos_unscan_serial(%L, 'SN-A3')$q$, v_line),
    'Serial SN-A3 is not on this line%', '23514');
  v_refs := public.pos_scan_serial(v_line, 'SN-A2');

  -- ==================================================================
  -- 3. The bill at the next till
  -- ==================================================================
  -- No stock balance can see this: nothing is posted until a bill is
  -- paid, so SN-A3 is still fully on the shelf as far as the movements
  -- are concerned while it sits in somebody else's basket.
  v_other := public.open_pos_sale(v_reg);
  perform public.pos_scan_serial(
    public.add_pos_sale_line(v_other, v_phone, 1, 1200.00), 'SN-A3');
  perform pg_temp.check_refused('a machine in another open basket is refused',
    format($q$select public.pos_scan_serial(%L, 'SN-A3')$q$, v_line),
    'Serial SN-A3 is on another bill that is still open%', '23514');

  -- ==================================================================
  -- 4. The sale
  -- ==================================================================
  perform public.add_pos_sale_line(v_sale, v_case, 1, 30.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 2430.00)));

  select invoice_id into v_inv from public.pos_sales where id = v_sale;
  perform pg_temp.check_true('a counter sale of serialised stock completes',
    v_inv is not null);
  perform pg_temp.check_eq('and the invoice behind it is settled',
    (select status::text from public.sales_documents where id = v_inv),
    'completed');

  -- WHICH MACHINES LEFT. This is the whole point: the customer's
  -- warranty names the phone in their hand.
  perform pg_temp.check_eq('the invoice names the two that were scanned',
    array_to_string(pg_temp.sn_named(v_sale), ','), 'SN-A1,SN-A2');
  perform pg_temp.check_eq('one unit named per machine, never two',
    (select coalesce(max(d.quantity), 0) from public.document_line_lots d
       join public.sales_document_lines l on l.id = d.sales_line_id
      where l.document_id = v_inv), 1);

  -- And the shelf agrees with the paper.
  perform pg_temp.check_eq('the first machine is gone',
    pg_temp.sn_on_hand(v_phone, 'SN-A1'), 0);
  perform pg_temp.check_eq('and the second',
    pg_temp.sn_on_hand(v_phone, 'SN-A2'), 0);
  perform pg_temp.check_eq('the one nobody scanned is still in the shop',
    pg_temp.sn_on_hand(v_phone, 'SN-A3'), 1);
  perform pg_temp.check_eq('and so is the one in the store room',
    pg_temp.sn_on_hand(v_phone, 'SN-B9'), 1);

  -- The case is stock and is not tracked, so nothing is named for it.
  perform pg_temp.check_eq('an untracked line on the same bill names nothing',
    (select count(*) from public.document_line_lots d
       join public.sales_document_lines l on l.id = d.sales_line_id
      where l.document_id = v_inv and l.item_id = v_case), 0);

  -- A bill that has been paid for is not a bill to scan onto.
  perform pg_temp.check_refused('scanning onto a completed bill is refused',
    format($q$select public.pos_scan_serial(%L, 'SN-A3')$q$, v_line),
    'That bill is completed%', '22023');

  -- ==================================================================
  -- 5. The quantity and the scans have to agree
  -- ==================================================================
  -- A cashier who typed the quantity up to two and scanned one is the
  -- ordinary way this goes wrong, and it goes wrong SILENTLY without
  -- this: the movement takes two off the shelf and the paper names one.
  --
  -- The quantity is written straight onto the column here, which is
  -- the one thing `pos_scan_serial` will not let a cashier do -- and
  -- that is deliberate. What is being tested is the SECOND check, the
  -- one at completion, which exists because a basket queued offline
  -- never met the first one.
  update public.pos_sale_lines set quantity = 2
   where sale_id = v_other;
  perform pg_temp.check_refused('two on the bill and one scanned is refused',
    format($q$select public.complete_pos_sale(%L, %L::jsonb)$q$,
           v_other, jsonb_build_array(
             jsonb_build_object('type', v_cash, 'amount', 2400.00))),
    '%2 on the bill and 1 scanned%', '23514');
  perform pg_temp.check_eq('and the machine is still in the shop',
    pg_temp.sn_on_hand(v_phone, 'SN-A3'), 1);

  -- ==================================================================
  -- 6. Nothing is tracked, nothing is scanned
  -- ==================================================================
  v_sale := public.open_pos_sale(v_reg);
  perform pg_temp.check_refused('an untracked item has no serial to scan',
    format($q$select public.pos_scan_serial(%L, 'SN-A3')$q$,
           public.add_pos_sale_line(v_sale, v_case, 1, 30.00)),
    'Sarung telefon is not tracked by serial number%', '23514');
end $$;

rollback;
