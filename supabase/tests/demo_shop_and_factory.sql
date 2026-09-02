-- =====================================================================
-- iAkauntan :: the shop counter and the factory floor
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/demo_shop_and_factory.sql
--
-- `retail` had one outlet on this deployment -- a computer
-- wholesaler's trade counter, where a rack server goes through for
-- RM9,180 -- and `manufacturing` had one bench, where the same
-- wholesaler assembles two servers when an order comes in. Neither is
-- a minimarket or a factory, and 0487 builds one of each.
--
-- What these assert is the part a demo is for: that the screens have
-- something true behind them. A shelf with no cost behind it, a
-- barcode that scans to nothing, a factory with every order closed --
-- each would look right and teach the wrong thing.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_owner  uuid;
  v_org    uuid;
  v_report text;
  v_n      integer;
  v_qty    numeric;
  v_cost   numeric;
begin
  -- ------------------------------------------------------------------
  -- The shop
  -- ------------------------------------------------------------------
  v_owner := app.demo_user('kedai-t@iakauntan.test', 'Kedai Test');
  v_org := app.demo_company(
    v_owner, 'Kedai Ujian Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '202201005566', 'C20225566778', '47111',
    'Retail sale in non-specialised stores with food predominating',
    '07', 'George Town', '11900', 'No 3, Jalan Mutiara 2/1',
    '04-641 2200', 'kedai@ujian.demo', 12::smallint);
  v_report := app.demo_kedai(v_org, v_owner);

  -- Every line scans, and one scan means one thing: 0211's unique
  -- constraint is the whole reason the table exists, and a demo that
  -- put two labels on one item would be showing a shop that cannot
  -- use its own scanner.
  select count(*) into v_n from public.items i
   where i.org_id = v_org and i.code ~ '^(BEV|SNK|GRO|HSE)-'
     and not exists (select 1 from public.item_barcodes b
                      where b.item_id = i.id and b.is_primary);
  perform pg_temp.check_eq('every line on the shelf scans', v_n, 0);
  perform pg_temp.check_eq('a scan means one thing',
    (select count(distinct barcode)::integer from public.item_barcodes
      where org_id = v_org),
    (select count(*)::integer from public.item_barcodes
      where org_id = v_org));

  -- A carton scans as a carton.
  perform pg_temp.check_true('and a carton of twelve scans as twelve',
    exists (select 1 from public.item_barcodes
             where org_id = v_org and pack_quantity = 12));

  -- Stock on hand, at a cost the ledger agrees with. A shelf stocked
  -- by an insert would show quantities with no purchase behind them
  -- and a cost of nothing, and every margin on the screen would be
  -- the full selling price.
  select count(*) into v_n from public.purchase_documents
   where org_id = v_org and doc_type = 'bill' and gl_entry_id is not null;
  perform pg_temp.check_true(
    'the shelves were stocked at a cost the ledger agrees with', v_n >= 1);
  select sum(s.quantity) into v_qty from public.stock_levels s
    join public.items i on i.id = s.item_id
   where i.org_id = v_org and i.code ~ '^(BEV|SNK|GRO|HSE)-';
  perform pg_temp.check_true('and there is stock on the shelf', v_qty > 0);

  -- One line short and the rest not: a low-stock screen where nothing
  -- is ever low shows nothing about being low.
  select count(*) into v_n
    from public.items i
   where i.org_id = v_org and i.reorder_level > 0
     and coalesce((select sum(s.quantity) from public.stock_levels s
                    where s.item_id = i.id), 0) < i.reorder_level;
  perform pg_temp.check_eq(
    'one line is below its reorder level, and the others are not',
    v_n, 1);

  -- The day was rung through and the drawer counted back.
  perform pg_temp.check_eq('three baskets went through the till',
    (select count(*)::integer from public.pos_sales
      where org_id = v_org and status = 'completed'), 3);
  perform pg_temp.check_true('on three different tenders',
    (select count(distinct t.tender_type_id) from public.pos_tenders t
       join public.pos_sales s on s.id = t.sale_id
      where s.org_id = v_org) = 3);
  perform pg_temp.check_eq('the shift is closed and counted',
    (select count(*)::integer from public.pos_shifts
      where org_id = v_org and status = 'closed'
        and declared_cash is not null), 1);
  -- Counted back with the cash actually taken in it, so the variance
  -- is nil rather than the drawer being declared at the float.
  perform pg_temp.check_eq('and the drawer agrees with what it took',
    (select variance from public.pos_shifts
      where org_id = v_org and status = 'closed'), 0::numeric);

  -- ------------------------------------------------------------------
  -- The factory
  -- ------------------------------------------------------------------
  v_owner := app.demo_user('kilang-t@iakauntan.test', 'Kilang Test');
  v_org := app.demo_company(
    v_owner, 'Kilang Ujian Sdn Bhd', 'sdn_bhd'::app.entity_type,
    '201601003311', 'C20163311224', '31001',
    'Manufacture of furniture', '05', 'Seremban', '70450',
    'Lot 22, Kawasan Perindustrian Senawang', '06-678 3300',
    'kilang@ujian.demo', 12::smallint);
  v_report := app.demo_kilang(v_org, v_owner);

  -- A desk is cut on one machine and finished on another. One work
  -- centre is a bench, which is what Sinar already had.
  perform pg_temp.check_eq('the desk crosses two work centres',
    (select count(distinct o.work_centre_id)::integer
       from public.bom_operations o
       join public.bills_of_materials b on b.id = o.bom_id
      where b.org_id = v_org), 2);

  -- The scrap allowance, which is the arithmetic
  -- `confirm_manufacturing_order` exists to do: needing three sheets
  -- and losing some to the press means issuing more than three.
  select sum(c.quantity_required), sum(l.quantity * mo.quantity)
    into v_qty, v_cost
    from public.mo_components c
    join public.manufacturing_orders mo on mo.id = c.mo_id
    join public.bom_lines l on l.bom_id = mo.bom_id and l.item_id = c.item_id
    join public.items i on i.id = c.item_id
   where mo.org_id = v_org and mo.order_no = 'MO-000001'
     and i.code = 'RM-VENEER';
  perform pg_temp.check_true(
    'the veneer issued is more than the veneer in the design',
    v_qty > v_cost);
  -- And only the veneer: a scrap allowance on everything would be a
  -- number nobody chose.
  perform pg_temp.check_eq('the board has no scrap allowance',
    (select count(*)::integer from public.bom_lines l
       join public.items i on i.id = l.item_id
       join public.bills_of_materials b on b.id = l.bom_id
      where b.org_id = v_org and l.scrap_percent > 0), 1);

  -- One order finished, one still open.
  perform pg_temp.check_eq('one order is posted',
    (select count(*)::integer from public.manufacturing_orders
      where org_id = v_org and status = 'done'), 1);
  perform pg_temp.check_eq('one order is still on the floor',
    (select count(*)::integer from public.manufacturing_orders
      where org_id = v_org and status in ('confirmed', 'in_progress')), 1);

  -- What came off the line has a cost, and was sold.
  select mo.component_cost + mo.conversion_cost into v_cost
    from public.manufacturing_orders mo
   where mo.org_id = v_org and mo.order_no = 'MO-000001';
  perform pg_temp.check_true('the finished desks cost something to make',
    v_cost > 0);
  perform pg_temp.check_true('and some of them were invoiced',
    exists (select 1 from public.sales_documents
             where org_id = v_org and doc_type = 'invoice'
               and gl_entry_id is not null));

  raise notice 'shop and factory: all assertions passed';
end $$;

rollback;
