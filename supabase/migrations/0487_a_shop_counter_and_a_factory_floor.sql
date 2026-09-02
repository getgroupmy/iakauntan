-- ---------------------------------------------------------------------
-- 0487  A shop counter and a factory floor
-- ---------------------------------------------------------------------
-- Two business types the product is sold to and had nowhere to be
-- looked at.
--
-- **A convenience store.** `pos_business_type` has had `retail` since
-- 0206, and its comment says "clothing, electronics, convenience". The
-- only outlet using it is Sinar's trade counter -- a computer
-- wholesaler's pick-up desk, where one rack server is rung through for
-- RM9,180 on a card. Nothing about that shows what a minimarket is:
-- scanned barcodes, a hundred small lines, cash and change, a shelf
-- that runs out. Somebody shown the trade counter as "retail" would be
-- shown the wrong shop.
--
-- **A factory.** `manufacturing` sits on Sinar too, which assembles two
-- servers at a bench when an order comes in. That is build-to-order by
-- a wholesaler, not a factory: no raw material bought by the roll, no
-- routing across machines, nothing part-finished at the end of the day.
-- "Kilang Lestari" is a name in the practice's client list with no
-- production behind it at all.
--
-- ### What is here
--
--   * `app.demo_kedai(org, owner)` -- Kedai Serbaneka Mutiara: a
--     counter with two registers, ten lines with barcodes on them,
--     stock bought in at cost through a posted bill, reorder levels
--     that leave one line genuinely below its own, a shift opened,
--     three baskets rung through on cash and card, and the drawer
--     counted back with the five-sen rounding a shop actually applies.
--
--   * `app.demo_kilang(org, owner)` -- Kilang Perabot Meranti: rubber-
--     wood, veneer, hinges and lacquer bought by the sheet and the
--     litre; a bill of materials with a scrap allowance on the veneer,
--     because a sheet cut wrong is thrown away; two work centres with
--     a routing across both; one order finished and posted, and one
--     still on the floor -- so the screen has work in progress rather
--     than only history.
--
-- Both are wired into `app.demo_rebuild`, which is restated here for
-- the third time in four migrations and, as in 0485 and 0486, from the
-- built definition rather than from the file that last wrote it.
--
-- ### Mutants
--
-- Run against `supabase/tests/demo_shop_and_factory.sql`, each named
-- with the assertion that kills it:
--   * the shop's stock never bought in -- "the shelves were stocked at
--     a cost the ledger agrees with";
--   * the barcodes not written -- "every line on the shelf scans";
--   * the same label put on two items -- killed by "every line on the
--     shelf scans", not by "a scan means one thing". 0211's unique
--     constraint refuses the second label outright, so the mutant does
--     not produce an ambiguous scan: it produces a line with no label
--     at all. The database will not hold the mistake this demo could
--     have made, which is the constraint doing its job;
--   * the reorder level left at zero -- "one line is below its reorder
--     level, and the others are not";
--   * the drawer not counted back -- "the shift is closed and counted";
--   * the factory's scrap allowance dropped -- "the veneer issued is
--     more than the veneer in the design";
--   * the second order posted as well -- "one order is still on the
--     floor";
--   * the routing put on one work centre -- "the desk crosses two work
--     centres".
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The shop
-- ---------------------------------------------------------------------
create or replace function app.demo_kedai(p_org uuid, p_owner uuid)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_wh      uuid;
  v_walkin  uuid;
  v_outlet  uuid;
  v_t1      uuid;
  v_t2      uuid;
  v_supp    uuid;
  v_cos     uuid;
  v_doc     uuid;
  v_shift   uuid;
  v_sale    uuid;
  v_cash    uuid;
  v_card    uuid;
  v_ewallet uuid;
  v_today   date := app.today();
  v_lines   integer;
  v_low     integer;
  v_takings numeric := 0;
  r         record;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array['pos', 'inventory', 'purchases']);

  -- A shop rounds cash to five sen because one-sen coins are not in
  -- circulation, and counts the drawer to the ringgit.
  insert into public.pos_settings (org_id, round_cash_to_5sen, variance_tolerance)
  values (p_org, true, 1.00)
  on conflict (org_id) do update
     set round_cash_to_5sen = excluded.round_cash_to_5sen,
         variance_tolerance = excluded.variance_tolerance;

  select w.id into v_wh from public.warehouses w
   where w.org_id = p_org and w.is_active order by w.code limit 1;
  select a.id into v_cos from public.accounts a
   where a.org_id = p_org and a.code = '5100';

  insert into public.contacts (org_id, code, name, contact_type, is_active)
  values (p_org, 'WALK-IN', 'Pelanggan kedai', 'customer', true)
  on conflict (org_id, code) do nothing;
  select c.id into v_walkin from public.contacts c
   where c.org_id = p_org and c.code = 'WALK-IN';

  -- What a minimarket sells: small, fast, and priced to the ten sen.
  -- `reorder_level` is set per line rather than uniformly, so the
  -- low-stock screen has one line to point at and nine to leave alone.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, purchase_account_id, reorder_level,
     reorder_quantity)
  values
    (p_org, 'BEV-100', 'Air mineral 500ml',        'stock', true, 'C62',
     1.50, 0.85, v_cos, 48, 144),
    (p_org, 'BEV-101', 'Kopi tin 240ml',           'stock', true, 'C62',
     2.80, 1.75, v_cos, 24, 72),
    (p_org, 'BEV-102', 'Teh kotak 1L',             'stock', true, 'C62',
     5.90, 4.10, v_cos, 12, 36),
    (p_org, 'SNK-200', 'Kerepek pisang 80g',       'stock', true, 'C62',
     3.50, 2.20, v_cos, 20, 60),
    (p_org, 'SNK-201', 'Biskut kelapa 300g',       'stock', true, 'C62',
     7.20, 5.10, v_cos, 12, 24),
    (p_org, 'GRO-300', 'Beras wangi 5kg',          'stock', true, 'C62',
     28.90, 23.50, v_cos, 8, 20),
    (p_org, 'GRO-301', 'Minyak masak 2kg',         'stock', true, 'C62',
     14.50, 11.80, v_cos, 10, 24),
    (p_org, 'GRO-302', 'Gula halus 1kg',           'stock', true, 'C62',
     3.20, 2.55, v_cos, 20, 48),
    (p_org, 'HSE-400', 'Sabun basuh 1kg',          'stock', true, 'C62',
     9.90, 7.40, v_cos, 10, 24),
    (p_org, 'HSE-401', 'Tisu gulung 10 rol',       'stock', true, 'C62',
     12.90, 9.60, v_cos, 6, 18)
  on conflict (org_id, code) do nothing;

  -- The label on the shelf edge. One scan means one item -- 0211's
  -- unique constraint -- so these are distinct by construction, and
  -- the 5kg rice bag carries the manufacturer's EAN as well as the
  -- shop's own shelf code.
  insert into public.item_barcodes (org_id, item_id, barcode, uom_code,
                                    pack_quantity, label, is_primary)
  select p_org, i.id,
         case i.code
           when 'BEV-100' then '9556001110015'
           when 'BEV-101' then '9556001110022'
           when 'BEV-102' then '9556001110039'
           when 'SNK-200' then '9556002220016'
           when 'SNK-201' then '9556002220023'
           when 'GRO-300' then '9556003330017'
           when 'GRO-301' then '9556003330024'
           when 'GRO-302' then '9556003330031'
           when 'HSE-400' then '9556004440018'
           else                '9556004440025'
         end,
         i.uom_code, 1, 'Label rak', true
    from public.items i
   where i.org_id = p_org and i.code ~ '^(BEV|SNK|GRO|HSE)-'
  on conflict (org_id, barcode) do nothing;

  -- A carton of twelve scans as twelve, which is the whole reason
  -- `pack_quantity` is on the table rather than assumed to be one.
  insert into public.item_barcodes (org_id, item_id, barcode, uom_code,
                                    pack_quantity, label, is_primary)
  select p_org, i.id, '19556001110012', i.uom_code, 12, 'Kotak 12', false
    from public.items i where i.org_id = p_org and i.code = 'BEV-100'
  on conflict (org_id, barcode) do nothing;

  -- Stocked from the wholesaler, at cost, through the same posting
  -- function every other bill in this demo goes through -- so what the
  -- till sells has a cost behind it and the margin on the day's
  -- takings is a real figure rather than a decoration.
  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no, is_active)
  values (p_org, 'SUP-BORONG', 'Pemborong Runcit Mutiara Sdn Bhd',
          'supplier', '201801009911', true)
  on conflict (org_id, code) do nothing;
  select c.id into v_supp from public.contacts c
   where c.org_id = p_org and c.code = 'SUP-BORONG';

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'bill', app.next_document_number_internal(p_org, 'bill'),
          v_today - 21, v_today - 7, v_supp, 'draft', 'MYR', 1, p_owner)
  returning id into v_doc;

  -- Enough of each to sell for a fortnight, and deliberately short on
  -- the tissue: one line below its reorder level is what the low-stock
  -- screen is for, and a shop where nothing is ever short shows
  -- nothing.
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, account_id)
  select p_org, v_doc, row_number() over (order by i.code), 'item', i.id,
         i.name,
         case when i.code = 'HSE-401' then 4 else i.reorder_quantity end,
         i.uom_code, i.cost_price, v_cos
    from public.items i
   where i.org_id = p_org and i.code ~ '^(BEV|SNK|GRO|HSE)-';

  perform public.post_purchase_document(v_doc);

  -- The counter itself.
  insert into public.pos_outlets (
    org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
    receipt_header, receipt_footer, prices_include_tax)
  values (
    p_org, 'KEDAI', 'Kedai Serbaneka Mutiara', 'retail', v_wh, v_walkin,
    'KEDAI SERBANEKA MUTIARA' || chr(10) || 'No 3, Jalan Mutiara 2/1',
    'Terima kasih. Barang dijual tidak boleh dipulangkan.', true)
  on conflict (org_id, code) do nothing;
  select o.id into v_outlet from public.pos_outlets o
   where o.org_id = p_org and o.code = 'KEDAI';

  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (p_org, v_outlet, 'K1', 'Kaunter 1'),
         (p_org, v_outlet, 'K2', 'Kaunter 2')
  on conflict (org_id, code) do nothing;
  -- Aliased `reg`, not `r`: `r` is the record variable this function
  -- loops the baskets over, and PL/pgSQL resolves a qualified name to
  -- the variable before the table -- so `r.id` here read as a field of
  -- an unassigned record and raised "record r is not assigned yet",
  -- pointing at a line that looks like plain SQL.
  select reg.id into v_t1 from public.pos_registers reg
   where reg.org_id = p_org and reg.code = 'K1';

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values
    (p_org, 'CASH',  'Tunai',   'cash',   '01', true,  true,  true),
    (p_org, 'CARD',  'Kad',     'card',   '03', false, false, false),
    (p_org, 'EWALL', 'e-Dompet','ewallet','06', false, false, false)
  on conflict (org_id, code) do nothing;
  select t.id into v_cash    from public.pos_tender_types t
   where t.org_id = p_org and t.code = 'CASH';
  select t.id into v_card    from public.pos_tender_types t
   where t.org_id = p_org and t.code = 'CARD';
  select t.id into v_ewallet from public.pos_tender_types t
   where t.org_id = p_org and t.code = 'EWALL';

  if exists (select 1 from public.pos_sales s
              where s.org_id = p_org and s.status = 'completed') then
    return 'Kedai Mutiara: already rung through.';
  end if;

  v_shift := public.open_pos_shift(v_t1, 150.00,
    'Demo -- float counted into the drawer at opening');

  -- Three baskets, which is what a morning looks like: a small cash
  -- one, a household run on a card, and a drink on an e-wallet.
  -- Written out rather than looped over a table of arrays: three
  -- baskets read as three baskets, and the clever version cost an
  -- hour to a "record r is not assigned yet" that said nothing about
  -- what a shop does.
  for r in
    select * from (values
      (jsonb_build_array(jsonb_build_object('code', 'BEV-100', 'qty', 2),
                         jsonb_build_object('code', 'SNK-200', 'qty', 1)),
       'CASH'),
      (jsonb_build_array(jsonb_build_object('code', 'GRO-300', 'qty', 1),
                         jsonb_build_object('code', 'GRO-301', 'qty', 2),
                         jsonb_build_object('code', 'HSE-400', 'qty', 1)),
       'CARD'),
      (jsonb_build_array(jsonb_build_object('code', 'BEV-102', 'qty', 1)),
       'EWALL')
    ) as b(basket, tender)
  loop
    v_sale := public.open_pos_sale(v_t1);
    perform public.add_pos_sale_line(
              v_sale,
              (select i.id from public.items i
                where i.org_id = p_org and i.code = line ->> 'code'),
              (line ->> 'qty')::numeric, null)
       from jsonb_array_elements(r.basket) as line;

    perform public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object(
        'type', case r.tender when 'CASH' then v_cash
                              when 'CARD' then v_card else v_ewallet end,
        'amount', (select s.total_amount from public.pos_sales s
                    where s.id = v_sale))));
    v_takings := v_takings + (select s.total_amount from public.pos_sales s
                               where s.id = v_sale);
  end loop;

  -- Counted back with the cash taken in it, which is what closing is.
  perform public.close_pos_shift(v_shift,
    150.00 + coalesce((select sum(t.amount)
                         from public.pos_tenders t
                         join public.pos_sales s on s.id = t.sale_id
                        where s.org_id = p_org
                          and t.tender_type_id = v_cash), 0),
    'Demo -- drawer counted back at close');

  select count(*) into v_lines from public.items
   where org_id = p_org and code ~ '^(BEV|SNK|GRO|HSE)-';
  select count(*) into v_low
    from public.items i
   where i.org_id = p_org and i.reorder_level > 0
     and coalesce((select sum(s.quantity) from public.stock_levels s
                    where s.item_id = i.id), 0) < i.reorder_level;

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Kedai Mutiara: %s lines on the shelf with barcodes, stocked in on '
    'one posted bill, %s below its reorder level, and a shift of three '
    'baskets taking RM%s across cash, card and e-wallet, counted back '
    'at close.',
    v_lines, v_low, to_char(v_takings, 'FM999999.00'));
end;
$fn$;

comment on function app.demo_kedai(uuid, uuid) is
  'A minimarket: barcoded lines, stock bought in at cost, reorder '
  'levels with one line genuinely short, and a shift rung through and '
  'cashed up. See 0487.';

revoke all on function app.demo_kedai(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The factory
-- ---------------------------------------------------------------------
create or replace function app.demo_kilang(p_org uuid, p_owner uuid)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_wh     uuid;
  v_cos    uuid;
  v_supp   uuid;
  v_cust   uuid;
  v_desk   uuid;
  v_bom    uuid;
  v_cut    uuid;
  v_finish uuid;
  v_doc    uuid;
  v_mo1    uuid;
  v_mo2    uuid;
  v_inv    uuid;
  v_today  date := app.today();
  v_made   numeric;
  v_cost   numeric(18,2);
  v_veneer numeric;
  v_design numeric;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array[
    'manufacturing', 'inventory', 'purchases']);

  select w.id into v_wh from public.warehouses w
   where w.org_id = p_org and w.is_active order by w.code limit 1;
  select a.id into v_cos from public.accounts a
   where a.org_id = p_org and a.code = '5100';

  -- What a furniture factory buys, in the units it buys them in: board
  -- by the sheet, veneer by the sheet, hinges by the piece, lacquer by
  -- the litre.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, purchase_account_id, reorder_level)
  values
    (p_org, 'RM-BOARD',  'Papan getah 18mm (1220x2440)', 'stock', true,
     'H87', 0, 78.00, v_cos, 40),
    (p_org, 'RM-VENEER', 'Venir oak 0.6mm (helaian)',    'stock', true,
     'H87', 0, 22.50, v_cos, 60),
    (p_org, 'RM-HINGE',  'Engsel keluli lembut',         'stock', true,
     'H87', 0,  3.80, v_cos, 200),
    (p_org, 'RM-LACQ',   'Lakuer kayu (liter)',          'stock', true,
     'LTR', 0, 34.00, v_cos, 30),
    (p_org, 'FG-DESK',   'Meja pejabat 1.4m',            'stock', true,
     'H87', 890.00, 0, v_cos, 0)
  on conflict (org_id, code) do nothing;
  select i.id into v_desk from public.items i
   where i.org_id = p_org and i.code = 'FG-DESK';

  insert into public.contacts (org_id, code, name, contact_type,
                               registration_no, is_active)
  values (p_org, 'SUP-KAYU', 'Bekalan Kayu Seremban Sdn Bhd', 'supplier',
          '201701004422', true),
         (p_org, 'CUST-PEJ', 'Perabot Pejabat Klang Sdn Bhd', 'customer',
          '201901007733', true)
  on conflict (org_id, code) do nothing;
  select c.id into v_supp from public.contacts c
   where c.org_id = p_org and c.code = 'SUP-KAYU';
  select c.id into v_cust from public.contacts c
   where c.org_id = p_org and c.code = 'CUST-PEJ';

  -- Materials in, through the posting function, so what comes off the
  -- line has a cost the ledger agrees with.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'bill', app.next_document_number_internal(p_org, 'bill'),
          v_today - 30, v_today - 2, v_supp, 'draft', 'MYR', 1, p_owner)
  returning id into v_doc;

  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, account_id)
  select p_org, v_doc, row_number() over (order by i.code), 'item', i.id,
         i.name,
         case i.code when 'RM-BOARD' then 60 when 'RM-VENEER' then 120
                     when 'RM-HINGE' then 400 else 40 end,
         i.uom_code, i.cost_price, v_cos
    from public.items i
   where i.org_id = p_org and i.code like 'RM-%';

  perform public.post_purchase_document(v_doc);

  -- Two work centres, because a desk is cut on one machine and
  -- finished on another. Sinar's single bench is the whole difference
  -- between assembling to order and running a floor.
  insert into public.work_centres
    (org_id, code, name, cost_per_hour, capacity_hours_per_day)
  values (p_org, 'WC-CUT',    'Pemotong panel dan pengelim tepi', 68.00, 16),
         (p_org, 'WC-FINISH', 'Bilik sembur dan pemasangan',      52.00, 16)
  on conflict (org_id, code) do nothing;
  select w.id into v_cut    from public.work_centres w
   where w.org_id = p_org and w.code = 'WC-CUT';
  select w.id into v_finish from public.work_centres w
   where w.org_id = p_org and w.code = 'WC-FINISH';

  insert into public.bills_of_materials
    (org_id, item_id, code, name, output_quantity)
  values (p_org, v_desk, 'BOM-DESK', 'Meja pejabat 1.4m -- kayu getah', 1)
  on conflict (org_id, code) do nothing;
  select b.id into v_bom from public.bills_of_materials b
   where b.org_id = p_org and b.code = 'BOM-DESK';

  -- Two sheets of board, three of veneer, six hinges, a litre of
  -- lacquer -- and a scrap allowance on the veneer, because a sheet
  -- torn on the press is thrown away rather than re-used. That is what
  -- makes the veneer issued exceed the veneer in the design, which is
  -- the arithmetic `confirm_manufacturing_order` exists to do.
  delete from public.bom_lines where bom_id = v_bom;
  insert into public.bom_lines
    (org_id, bom_id, line_no, item_id, quantity, scrap_percent)
  select p_org, v_bom,
         case i.code when 'RM-BOARD' then 1 when 'RM-VENEER' then 2
                     when 'RM-HINGE' then 3 else 4 end,
         i.id,
         case i.code when 'RM-BOARD' then 2 when 'RM-VENEER' then 3
                     when 'RM-HINGE' then 6 else 1 end,
         case i.code when 'RM-VENEER' then 8 else 0 end
    from public.items i
   where i.org_id = p_org and i.code like 'RM-%';

  delete from public.bom_operations where bom_id = v_bom;
  insert into public.bom_operations
    (org_id, bom_id, step_no, work_centre_id, name, minutes)
  values (p_org, v_bom, 1, v_cut,    'Potong panel, kelim tepi', 55),
         (p_org, v_bom, 2, v_finish, 'Sembur, keringkan, pasang', 90);

  -- One order finished, one still on the floor. A factory whose every
  -- order is closed has no work in progress, and work in progress is
  -- the thing this screen is for.
  insert into public.manufacturing_orders
    (org_id, order_no, bom_id, item_id, warehouse_id, quantity,
     status, planned_start, planned_finish, notes, created_by)
  values (p_org, 'MO-000001', v_bom, v_desk, v_wh, 12, 'draft',
          v_today - 20, v_today - 13,
          'Pesanan Perabot Pejabat Klang -- 12 meja', p_owner)
  returning id into v_mo1;
  perform public.confirm_manufacturing_order(v_mo1);
  perform public.post_manufacturing_order(v_mo1);

  insert into public.manufacturing_orders
    (org_id, order_no, bom_id, item_id, warehouse_id, quantity,
     status, planned_start, planned_finish, notes, created_by)
  values (p_org, 'MO-000002', v_bom, v_desk, v_wh, 8, 'draft',
          v_today - 2, v_today + 3,
          'Stok gudang -- 8 meja, di atas lantai', p_owner)
  returning id into v_mo2;
  perform public.confirm_manufacturing_order(v_mo2);

  -- And the desks that were finished are sold, so the finished-goods
  -- account does not simply accumulate.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate, created_by)
  values (p_org, 'invoice', app.next_document_number_internal(p_org, 'invoice'),
          v_today - 10, v_today + 20, v_cust, 'draft', 'MYR', 1, p_owner)
  returning id into v_inv;

  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price)
  values (p_org, v_inv, 1, 'item', v_desk, 'Meja pejabat 1.4m', 10, 'H87',
          890.00);

  perform public.post_sales_document(v_inv);

  select mo.quantity_done, mo.component_cost + mo.conversion_cost
    into v_made, v_cost
    from public.manufacturing_orders mo where mo.id = v_mo1;
  -- What was issued against what the design calls for. The gap is the
  -- scrap allowance, and saying both numbers is the only way the line
  -- means anything.
  select sum(c.quantity_required), sum(l.quantity * mo.quantity)
    into v_veneer, v_design
    from public.mo_components c
    join public.manufacturing_orders mo on mo.id = c.mo_id
    join public.bom_lines l on l.bom_id = mo.bom_id
                           and l.item_id = c.item_id
    join public.items i on i.id = c.item_id
   where c.mo_id = v_mo1 and i.code = 'RM-VENEER';

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Kilang Meranti: materials in by the sheet and the litre, a bill of '
    'materials across two work centres, %s desks finished at RM%s each '
    'and 10 of them invoiced -- and one order of 8 still on the floor. '
    'The veneer issued was %s sheets against %s in the design, the '
    'difference being the scrap allowance.',
    v_made, to_char(v_cost / nullif(v_made, 0), 'FM999999.00'),
    v_veneer, v_design);
end;
$fn$;

comment on function app.demo_kilang(uuid, uuid) is
  'A furniture factory: raw materials by the sheet, a BOM with a scrap '
  'allowance, a routing across two work centres, one order posted and '
  'one still in progress. See 0487.';

revoke all on function app.demo_kilang(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Both, in the rebuild
-- ---------------------------------------------------------------------
-- Restated from the built definition, as 0485 and 0486 were and for
-- the reason 0485 learned the hard way.
CREATE OR REPLACE FUNCTION app.demo_rebuild()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
  v_shopkeeper uuid; v_maker uuid;
  v_kedai uuid; v_kilang uuid;
  v_kedai_txt text; v_kilang_txt text;
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
  v_shopkeeper := app.demo_user('kedai@iakauntan.com',  'Lim Siew Fong');
  v_maker      := app.demo_user('kilang@iakauntan.com', 'Mohd Faizal Awang');

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
  -- The two business types that had nowhere to be looked at
  -- ------------------------------------------------------------------
  -- 0487. `retail` had only Sinar's trade counter, where one rack
  -- server goes through for RM9,180, and `manufacturing` had only
  -- Sinar's assembly bench. Neither shows a shop or a factory.
  v_kedai := app.demo_company(
    v_shopkeeper, 'Kedai Serbaneka Mutiara Sdn Bhd',
    'sdn_bhd'::app.entity_type,
    '202201005566', 'C20225566778', '47111',
    'Retail sale in non-specialised stores with food predominating',
    '07', 'George Town', '11900',
    'No 3, Jalan Mutiara 2/1', '04-641 2200',
    'kedai@serbanekamutiara.demo', 12::smallint);
  v_kedai_txt := app.demo_kedai(v_kedai, v_shopkeeper);
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_kedai, v_shopkeeper, 'Elektrik Mutiara Enterprise', 'SUP-ELM',
    'Bil elektrik peti sejuk dan penghawa dingin', '6300', 1180.00,
    'Maybank Current Account', 'Malayan Banking Berhad',
    '514077220033', 'current');
  v_ask := v_ask || ' ' || app.demo_crm(v_kedai, v_shopkeeper, $j$
    [
      {"company": "Pejabat Klinik Mutiara", "first_name": "Suriani",
       "last_name": "Abdul Wahab", "role": "Clinic manager",
       "email": "admin@klinikmutiara.demo", "phone": "04-642 1100",
       "city": "George Town", "state_code": "07", "source": "Walk-in",
       "industry": "Healthcare", "value": 900, "fate": "new",
       "note": null, "age": 4},
      {"company": "Hostel Pelajar Seberang", "first_name": "Tan",
       "last_name": "Ah Seng", "role": "Warden",
       "email": "warden@hostelseberang.demo", "phone": "04-398 7722",
       "city": "Butterworth", "state_code": "07", "source": "Referral",
       "industry": "Education", "value": 2400, "fate": "live",
       "note": null, "age": 17},
      {"company": "Kafe Tepi Jalan", "first_name": "Rosli",
       "last_name": "Mat Zin", "role": "Owner",
       "email": "rosli@kafetepijalan.demo", "phone": "04-226 5511",
       "city": "George Town", "state_code": "07", "source": "Word of mouth",
       "industry": "Food and beverage", "value": 1500, "fate": "won",
       "note": "Weekly standing order for drinks and sundries", "age": 31},
      {"company": "Pasar Mini Jelutong", "first_name": "Ganesan",
       "last_name": "Muthu", "role": "Proprietor",
       "email": "ganesan@pasarminijelutong.demo", "phone": "04-281 3300",
       "city": "Jelutong", "state_code": "07", "source": "Cold call",
       "industry": "Retail", "value": 5200, "fate": "dead",
       "note": "Buys direct from the same wholesaler we do", "age": 48}
    ]
  $j$::jsonb);

  v_kilang := app.demo_company(
    v_maker, 'Kilang Perabot Meranti Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201601003311', 'C20163311224', '31001',
    'Manufacture of furniture',
    '05', 'Seremban', '70450',
    'Lot 22, Kawasan Perindustrian Senawang', '06-678 3300',
    'kilang@perabotmeranti.demo', 12::smallint);
  v_kilang_txt := app.demo_kilang(v_kilang, v_maker);
  v_buy := v_buy || ' ' || app.demo_purchases(
    v_kilang, v_maker, 'Perkhidmatan Mesin Senawang Sdn Bhd', 'SUP-MSN',
    'Servis dan asah mata pemotong panel', '6250', 2650.00,
    'CIMB Current Account', 'CIMB Bank Berhad',
    '800266440099', 'current');
  v_ask := v_ask || ' ' || app.demo_crm(v_kilang, v_maker, $j$
    [
      {"company": "Reka Dalaman Ampang Sdn Bhd", "first_name": "Yasmin",
       "last_name": "Kamaruddin", "role": "Design director",
       "email": "yasmin@rekadalaman.demo", "phone": "03-4256 8800",
       "city": "Ampang", "state_code": "10", "source": "Trade fair",
       "industry": "Interior design", "value": 145000, "fate": "new",
       "note": null, "age": 8},
      {"company": "Universiti Teknikal Negeri", "first_name": "Zainal",
       "last_name": "Abidin", "role": "Procurement officer",
       "email": "perolehan@utn.demo", "phone": "06-234 9900",
       "city": "Durian Tunggal", "state_code": "04", "source": "Tender",
       "industry": "Education", "value": 320000, "fate": "live",
       "note": null, "age": 29},
      {"company": "Perabot Pejabat Klang Sdn Bhd", "first_name": "Loo",
       "last_name": "Chee Wan", "role": "Buyer",
       "email": "buyer@perabotklang.demo", "phone": "03-3341 2200",
       "city": "Klang", "state_code": "10", "source": "Referral",
       "industry": "Wholesale", "value": 89000, "fate": "won",
       "note": "Standing order for office desks", "age": 42},
      {"company": "Hotel Bandar Seremban", "first_name": "Fatimah",
       "last_name": "Long", "role": "General manager",
       "email": "gm@hotelbandarseremban.demo", "phone": "06-762 4400",
       "city": "Seremban", "state_code": "05", "source": "Cold call",
       "industry": "Hospitality", "value": 210000, "fate": "dead",
       "note": "Refurbishment postponed to next financial year",
       "age": 64}
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
    '%s Rebuilt 13 tenants, 16 logins. %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s',
    v_removed, v_books, v_cash, v_assets, v_pay, v_desk, v_fc, v_crm,
    v_pos, v_fs_s, v_books_a, v_fs_a, v_name_a, v_time_a, v_books_h,
    v_legal_txt, v_warung_txt, v_salon_txt, v_stall_txt) || v_buy || v_ask || ' ' || v_appr || ' ' || v_make || ' ' || v_last || ' ' || v_practice || ' ' || v_kedai_txt || ' ' || v_kilang_txt;
end;
$function$;

revoke all on function app.demo_rebuild() from public, anon, authenticated;
