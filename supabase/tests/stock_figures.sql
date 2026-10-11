-- =====================================================================
-- iAkauntan :: the stock figures are the stock's (0813)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/stock_figures.sql
--
-- A sale's cost of goods sold is the item's average cost when it is
-- posted, and the movement trigger keeps that cost and the quantity on
-- hand from the stock levels. Before `0813` a client could write the
-- item's two figures and the three stock tables directly: fifty on hand
-- at RM10, the cost set to RM0.01 by hand, and ten sold posted RM0.10.
-- Asked as the owner, with the role `authenticated`, which is who the
-- app is; the item editor and the stock functions are asked to go on
-- working.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_sf (org uuid, wh uuid, item uuid, cust uuid);
grant select on t_sf to authenticated;

do $$
declare r t_sf;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kos Stok Sdn Bhd');
  perform public.create_fiscal_year(r.org, date '2026-01-01');
  perform pg_temp.open_years(r.org, date '2026-01-01');
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Main', true) returning id into r.wh;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'W', 'Widget', 'stock', true, 'C62', 25) returning id into r.item;
  perform public.import_opening_stock(r.org, jsonb_build_array(
    jsonb_build_object('item_code', 'W', 'quantity', '50', 'unit_cost', '10')),
    date '2026-01-01', true);
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'C-1', 'Pembeli', 'customer') returning id into r.cust;
  insert into t_sf select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

-- =====================================================================
-- The item's two figures
-- =====================================================================
do $$
declare d t_sf;
begin
  select * into d from t_sf;
  perform pg_temp.check_eq('the owner asks as a client', current_user, 'authenticated');
  perform pg_temp.check_true('fifty on hand at RM10, from the opening stock',
    (select quantity_on_hand = 50 and average_cost = 10 from public.items where id = d.item));

  -- What was measured.
  perform pg_temp.check_refused('an item''s cost is not written by hand',
    format('update public.items set average_cost = 0.01 where id = %L', d.item),
    'What W has on hand and what it cost follow from the stock that moved, '
    'and are not written directly (50.0000 at 10.000000 -> 50.0000 at 0.010000).%',
    '42501');
  perform pg_temp.check_refused('nor what it has on hand',
    format('update public.items set quantity_on_hand = 5000 where id = %L', d.item),
    'What W has on hand % (50.0000 at 10.000000 -> 5000.0000 at 10.000000).%', '42501');
  perform pg_temp.check_refused('nor an item created holding stock',
    format($q$insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, quantity_on_hand)
              values (%L, 'X', 'Extra', 'stock', true, 'C62', 100)$q$, d.org),
    'An item is created with nothing on hand and no cost (this one said 100.0000 at 0.000000).%', '42501');
  perform pg_temp.check_refused('nor one created with a cost',
    format($q$insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, average_cost)
              values (%L, 'Y', 'Extra', 'stock', true, 'C62', 5)$q$, d.org),
    'An item is created with nothing on hand and no cost (this one said 0.0000 at 5.000000).%', '42501');

  -- What the item editor does: everything but those two.
  update public.items set name = 'Widget, blue', unit_price = 27, reorder_level = 5
   where id = d.item;
  perform pg_temp.check_true('the item editor still edits an item',
    (select name = 'Widget, blue' and unit_price = 27 from public.items where id = d.item));
  update public.items set average_cost = 10, quantity_on_hand = 50, name = 'Widget'
   where id = d.item;
  perform pg_temp.check_eq('and a row sent back with the figures unchanged is not a change',
    (select name from public.items where id = d.item), 'Widget');
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (d.org, 'Z', 'Gadget', 'stock', true, 'C62', 9);
  perform pg_temp.check_true('and creates one, with nothing on hand',
    (select quantity_on_hand = 0 and average_cost = 0 from public.items
      where org_id = d.org and code = 'Z'));
end $$;

-- =====================================================================
-- The three stock tables
-- =====================================================================
do $$
declare d t_sf;
begin
  select * into d from t_sf;
  perform pg_temp.check_eq('a member reads the levels',
    (select quantity from public.stock_levels where item_id = d.item), 50::numeric);
  perform pg_temp.check_refused('a level''s value is not written by hand',
    format('update public.stock_levels set value = 1 where item_id = %L', d.item),
    'permission denied for table stock_levels', '42501');
  perform pg_temp.check_refused('nor a movement typed in',
    format($q$insert into public.stock_movements
                (org_id, movement_no, item_id, warehouse_id, movement_type, movement_date, quantity, unit_cost)
              values (%L, 'MV-X', %L, %L, 'write_off', date '2026-02-01', 50, 10)$q$, d.org, d.item, d.wh),
    'permission denied for table stock_movements', '42501');
  perform pg_temp.check_refused('nor one deleted',
    format('delete from public.stock_movements where item_id = %L', d.item),
    'permission denied for table stock_movements', '42501');
  perform pg_temp.check_refused('nor a lot written',
    format($q$insert into public.stock_lots (org_id, item_id, lot_ref) values (%L, %L, 'L-1')$q$,
           d.org, d.item),
    'permission denied for table stock_lots', '42501');
end $$;

-- And every door on each, by name: the three above are the ones with a
-- story, and a door nobody asked about is a door.
do $$
declare
  d   t_sf;
  v_t text;
begin
  select * into d from t_sf;
  foreach v_t in array array['stock_movements', 'stock_levels', 'stock_lots'] loop
    perform pg_temp.check_refused(format('%s takes no insert', v_t),
      format('insert into public.%I (org_id) values (%L)', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
    perform pg_temp.check_refused(format('%s takes no update', v_t),
      format('update public.%I set org_id = org_id where org_id = %L', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
    perform pg_temp.check_refused(format('%s takes no delete', v_t),
      format('delete from public.%I where org_id = %L', v_t, d.org),
      format('permission denied for table %s', v_t), '42501');
  end loop;
end $$;

-- =====================================================================
-- The functions are the road, and still run for a client
-- =====================================================================
do $$
declare
  d     t_sf;
  v_inv uuid;
  v_adj uuid;
begin
  select * into d from t_sf;
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (d.org, 'invoice', 'INV-1', date '2026-03-01', d.cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, item_id, description, quantity, unit_price)
  values (d.org, v_inv, 1, d.item, 'Widget', 10, 25);
  perform public.post_sales_document(v_inv);
  perform pg_temp.check_eq('ten sold cost RM100, at the cost the stock carries',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
       join public.sales_documents s on s.gl_entry_id = l.entry_id
      where s.id = v_inv and a.code = '5200'), 100::numeric);
  perform pg_temp.check_eq('and the item has forty left',
    (select quantity_on_hand from public.items where id = d.item), 40::numeric);

  -- A stocktake drafted by the app and posted through its function.
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason,
     adjustment_type, status)
  values (d.org, 'ADJ-1', date '2026-03-02', d.wh, 'Stocktake', 'stock_take', 'draft')
  returning id into v_adj;
  insert into public.stock_adjustment_lines
    (org_id, adjustment_id, line_no, item_id, system_quantity,
     counted_quantity, difference, unit_cost, total_cost)
  values (d.org, v_adj, 1, d.item, 40, 38, -2, 10, -20);
  perform public.post_stock_adjustment(v_adj);
  perform pg_temp.check_eq('and a stocktake two short leaves thirty-eight',
    (select quantity_on_hand from public.items where id = d.item), 38::numeric);
end $$;

reset role;

-- The database's own statement passes: here the session, which owns the
-- table, sets an item's cost as a function running as its owner would.
update public.items set average_cost = 3
 where org_id = (select org from t_sf) and code = 'Z';

do $$
begin
  perform pg_temp.check_eq('the database sets the figures it keeps',
    (select average_cost from public.items
      where org_id = (select org from t_sf) and code = 'Z'), 3::numeric);
  perform pg_temp.check_eq('no write policy is left on the three',
    (select count(*)::integer from pg_policies
      where schemaname = 'public'
        and tablename in ('stock_movements', 'stock_levels', 'stock_lots')
        and cmd <> 'SELECT'), 0);
end $$;

rollback;
