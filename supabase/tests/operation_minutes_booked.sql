-- =====================================================================
-- iAkauntan :: minutes are booked before posting (0847)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/operation_minutes_booked.sql
--
-- A manufacturing order's operations are copied from the bill of
-- materials when it is confirmed, and posting costs the labour from
-- them. Before `0847` a client who could post could rewrite a posted
-- order's minutes or delete its operation, the journal standing as it
-- was. Asked as the owner with the role `authenticated`, as the order
-- screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_op (org uuid, wh uuid, flour uuid, bread uuid, bom uuid,
  posted uuid, confirmed uuid, wc uuid);
grant select on t_op to authenticated;

do $$
declare r t_op;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kilang Minit Sdn Bhd', array['inventory', 'manufacturing']);
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
  -- Half an hour in the oven, at RM60 an hour.
  insert into public.work_centres (org_id, code, name, cost_per_hour)
  values (r.org, 'OVEN', 'Oven', 60) returning id into r.wc;
  insert into public.bom_operations (org_id, bom_id, step_no, work_centre_id, name, minutes)
  values (r.org, r.bom, 1, r.wc, 'Bake', 30);
  insert into t_op select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_op;
begin
  select * into d from t_op;
  perform pg_temp.check_true('the owner, asking as a client who may post',
    current_user = 'authenticated' and app.can_post(d.org));

  -- What the screens do: confirm, book the minutes taken, post.
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-1', d.bread, d.bom, d.wh, 10) returning id into d.posted;
  perform public.confirm_manufacturing_order(d.posted);
  update public.mo_operations set actual_minutes = 45 where mo_id = d.posted;
  perform public.post_manufacturing_order(d.posted);
  perform pg_temp.check_eq('minutes are still booked before posting, and posting costs them',
    (select round(unit_cost, 2)::text from public.stock_movements
      where source_id = d.posted and item_id = d.bread),
    '8.50');
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-2', d.bread, d.bom, d.wh, 10) returning id into d.confirmed;
  perform public.confirm_manufacturing_order(d.confirmed);

  -- What was measured.
  perform pg_temp.check_refused('a posted order''s minutes are not booked again',
    format('update public.mo_operations set actual_minutes = 600 where mo_id = %L', d.posted),
    'Manufacturing order MO-1 is posted, and its cost was taken from these minutes. They are not booked again.',
    '42501');
  perform pg_temp.check_refused('nor its operation deleted',
    format('delete from public.mo_operations where mo_id = %L', d.posted),
    'An order''s operations are copied from its bill of materials when it is confirmed.%', '42501');

  -- Nor, on an order not yet posted, anything but the minutes.
  perform pg_temp.check_refused('an operation is not added by hand',
    format($q$insert into public.mo_operations
              (org_id, mo_id, step_no, work_centre_id, name, planned_minutes)
              values (%L, %L, 2, %L, 'Rest the dough', 1)$q$, d.org, d.confirmed, d.wc),
    'An order''s operations are copied from its bill of materials when it is confirmed.%', '42501');
  perform pg_temp.check_refused('nor its planned minutes cut',
    format('update public.mo_operations set planned_minutes = 1 where mo_id = %L', d.confirmed),
    'Only the minutes actually taken are booked against an operation.%', '42501');

  -- And the minutes are still booked on the confirmed one, and cost.
  update public.mo_operations set actual_minutes = 60 where mo_id = d.confirmed;
  perform public.post_manufacturing_order(d.confirmed);
  perform pg_temp.check_eq('so a confirmed order''s minutes are still booked, and costed',
    (select round(unit_cost, 2)::text from public.stock_movements
      where source_id = d.confirmed and item_id = d.bread),
    '10.00');
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
  update public.mo_operations o set actual_minutes = 31
    from public.manufacturing_orders m
   where m.id = o.mo_id and m.org_id = (select org from t_op) and m.order_no = 'MO-1';
  perform pg_temp.check_eq('the owner, at the top, is not refused',
    (select o.actual_minutes::text from public.mo_operations o
       join public.manufacturing_orders m on m.id = o.mo_id
      where m.org_id = (select org from t_op) and m.order_no = 'MO-1'),
    '31.0000');
end $$;

rollback;
