-- =====================================================================
-- iAkauntan :: an order moves by its functions (0845)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_status_by_its_functions.sql
--
-- A manufacturing order is confirmed by `confirm_manufacturing_order`
-- and done by `post_manufacturing_order`. Before `0845` a client could
-- mark a posted order cancelled with its journal standing, mark a
-- confirmed one done with nothing issued -- after which it could never
-- be posted -- and put a posted one back to draft. Asked as the owner
-- with the role `authenticated`, as the order screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_os (org uuid, wh uuid, flour uuid, bread uuid, bom uuid,
  posted uuid, confirmed uuid, spare uuid);
grant select on t_os to authenticated;

do $$
declare r t_os;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kilang Status Sdn Bhd', array['inventory', 'manufacturing']);
  perform public.create_fiscal_year(r.org, date_trunc('year', app.today())::date);
  perform pg_temp.open_years(r.org, date_trunc('year', app.today())::date);
  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'KILANG', 'Factory', true) returning id into r.wh;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (r.org, 'TEPUNG', 'Flour', 'stock', true, 'KGM', 2.00) returning id into r.flour;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code)
  values (r.org, 'ROTI', 'Bread', 'stock', true, 'C62') returning id into r.bread;
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id, quantity, unit_cost)
  values (r.org, 'OPEN-1', app.today(), 'opening_balance', r.flour, r.wh, 100, 2.00);
  insert into public.bills_of_materials (org_id, item_id, code, name, output_quantity, is_active)
  values (r.org, r.bread, 'BOM-1', 'Bread', 10, true) returning id into r.bom;
  insert into public.bom_lines (org_id, bom_id, line_no, item_id, quantity)
  values (r.org, r.bom, 1, r.flour, 20);
  insert into t_os select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_os;
begin
  select * into d from t_os;
  perform pg_temp.check_true('the owner, asking as a client who may post',
    current_user = 'authenticated' and app.can_post(d.org));

  -- What the screens do: made as a draft, confirmed, posted.
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-1', d.bread, d.bom, d.wh, 10) returning id into d.posted;
  perform public.confirm_manufacturing_order(d.posted);
  perform public.post_manufacturing_order(d.posted);
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-2', d.bread, d.bom, d.wh, 10) returning id into d.confirmed;
  perform public.confirm_manufacturing_order(d.confirmed);
  perform pg_temp.check_eq('an order is still confirmed and posted by its functions',
    (select status::text from public.manufacturing_orders where id = d.posted) || ' / ' ||
    (select status::text from public.manufacturing_orders where id = d.confirmed),
    'done / confirmed');

  -- What was measured.
  perform pg_temp.check_refused('a posted order is not cancelled',
    format('update public.manufacturing_orders set status = ''cancelled'' where id = %L', d.posted),
    'Manufacturing order MO-1 is posted, and its journal and the stock it moved stand on it. It is not cancelled.',
    '42501');
  perform pg_temp.check_refused('a confirmed order is not marked done by hand',
    format('update public.manufacturing_orders set status = ''done'' where id = %L', d.confirmed),
    'Manufacturing order MO-2 is confirmed by confirming it and done by posting it. By hand it may only be cancelled.',
    '42501');
  perform pg_temp.check_refused('nor a posted one put back to draft',
    format('update public.manufacturing_orders set status = ''draft'' where id = %L', d.posted),
    'Manufacturing order MO-1 is confirmed by confirming it%', '42501');
  perform pg_temp.check_refused('nor an order made already confirmed',
    format($q$insert into public.manufacturing_orders
              (org_id, order_no, item_id, bom_id, warehouse_id, quantity, status)
              values (%L, 'MO-BORN', %L, %L, %L, 5, 'confirmed')$q$, d.org, d.bread, d.bom, d.wh),
    'Manufacturing order MO-BORN starts as a draft.%', '42501');

  -- So the confirmed one can still be posted, and a draft and a
  -- confirmed order can still be cancelled.
  perform public.post_manufacturing_order(d.confirmed);
  perform pg_temp.check_eq('so the confirmed order is still posted, and done',
    (select status::text || ' / ' || (gl_entry_id is not null)::text
       from public.manufacturing_orders where id = d.confirmed),
    'done / true');
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-3', d.bread, d.bom, d.wh, 10) returning id into d.spare;
  update public.manufacturing_orders set status = 'cancelled' where id = d.spare;
  perform pg_temp.check_eq('a draft is still cancelled from the screen',
    (select status::text from public.manufacturing_orders where id = d.spare), 'cancelled');
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-4', d.bread, d.bom, d.wh, 10) returning id into d.spare;
  perform public.confirm_manufacturing_order(d.spare);
  update public.manufacturing_orders set status = 'cancelled' where id = d.spare;
  perform pg_temp.check_eq('and so is a confirmed order not yet posted',
    (select status::text from public.manufacturing_orders where id = d.spare), 'cancelled');
  perform pg_temp.check_refused('but a cancelled one is not brought back by hand',
    format('update public.manufacturing_orders set status = ''draft'' where id = %L', d.spare),
    'Manufacturing order MO-4 is confirmed by confirming it%', '42501');
end $$;

reset role;

-- The database itself, as the owner, is not a client.
--
-- The guard's other door -- `pg_trigger_depth() > 1`, a statement one
-- trigger down -- has nothing to assert here, and its mutant survives as
-- an equivalent one: confirming and posting are definers, which run as
-- the owner at any depth.
do $$
begin
  update public.manufacturing_orders set status = 'in_progress'
   where org_id = (select org from t_os) and order_no = 'MO-1';
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select status::text from public.manufacturing_orders
      where org_id = (select org from t_os) and order_no = 'MO-1'), 'in_progress');
end $$;

rollback;
