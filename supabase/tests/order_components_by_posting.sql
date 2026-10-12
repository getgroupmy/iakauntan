-- =====================================================================
-- iAkauntan :: an order's components are its functions' (0843)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/order_components_by_posting.sql
--
-- Confirming an order writes its components from the bill of materials;
-- posting issues them and records what they cost. Before `0843` a client
-- who could post could rewrite a posted order's components away from
-- the stock it moved, delete them or add to them, and cut a confirmed
-- order's flour so posting costed each loaf at a twentieth. Asked as the
-- owner with the role `authenticated`, as the order screen asks.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_oc (org uuid, wh uuid, flour uuid, bread uuid, bom uuid,
  posted uuid, confirmed uuid);
grant select on t_oc to authenticated;

do $$
declare r t_oc;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Kilang Roti Sdn Bhd', array['inventory', 'manufacturing']);
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
  -- Twenty kilos of flour make ten loaves.
  insert into public.bills_of_materials (org_id, item_id, code, name, output_quantity, is_active)
  values (r.org, r.bread, 'BOM-1', 'Bread', 10, true) returning id into r.bom;
  insert into public.bom_lines (org_id, bom_id, line_no, item_id, quantity)
  values (r.org, r.bom, 1, r.flour, 20);
  insert into t_oc select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare d t_oc;
begin
  select * into d from t_oc;
  perform pg_temp.check_true('the owner, asking as a client who may post',
    current_user = 'authenticated' and app.can_post(d.org));

  -- What the screens do: an order made, confirmed and posted.
  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-1', d.bread, d.bom, d.wh, 10) returning id into d.posted;
  perform public.confirm_manufacturing_order(d.posted);
  perform pg_temp.check_eq('confirming still takes the components from the bill of materials',
    (select string_agg(quantity_required::text, ',') from public.mo_components where mo_id = d.posted),
    '20.0000');
  perform public.post_manufacturing_order(d.posted);
  perform pg_temp.check_eq('and posting still records what was issued and what it cost',
    (select quantity_issued || ' kg / RM' || total_cost from public.mo_components where mo_id = d.posted),
    '20.0000 kg / RM40.00');

  insert into public.manufacturing_orders (org_id, order_no, item_id, bom_id, warehouse_id, quantity)
  values (d.org, 'MO-2', d.bread, d.bom, d.wh, 10) returning id into d.confirmed;
  perform public.confirm_manufacturing_order(d.confirmed);

  -- What was measured.
  perform pg_temp.check_refused('a posted order''s component is not rewritten',
    format('update public.mo_components set quantity_issued = 2, total_cost = 4, unit_cost = 2 where mo_id = %L',
           d.posted),
    'permission denied for table mo_components', '42501');
  perform pg_temp.check_refused('nor deleted',
    format('delete from public.mo_components where mo_id = %L', d.posted),
    'permission denied for table mo_components', '42501');
  perform pg_temp.check_refused('nor added to',
    format($q$insert into public.mo_components
              (org_id, mo_id, item_id, quantity_required, quantity_issued, unit_cost, total_cost)
              values (%L, %L, %L, 1, 1, 999, 999)$q$, d.org, d.posted, d.bread),
    'permission denied for table mo_components', '42501');
  perform pg_temp.check_eq('so the order still says what its movement says',
    (select c.quantity_issued::text from public.mo_components c where c.mo_id = d.posted)
      || ' / ' ||
    (select (-sum(s.quantity))::text from public.stock_movements s
      where s.source_id = d.posted and s.item_id = d.flour),
    '20.0000 / 20.0000');

  perform pg_temp.check_refused('a confirmed order''s flour is not cut before posting',
    format('update public.mo_components set quantity_required = 1 where mo_id = %L', d.confirmed),
    'permission denied for table mo_components', '42501');
  perform public.post_manufacturing_order(d.confirmed);
  perform pg_temp.check_eq('so posting issues what the bill of materials says',
    (select (-sum(s.quantity))::text from public.stock_movements s
      where s.source_id = d.confirmed and s.item_id = d.flour),
    '20.0000');
end $$;

reset role;

do $$
begin
  perform pg_temp.check_true('no client may write a component',
    not has_table_privilege('authenticated', 'public.mo_components', 'INSERT')
    and not has_table_privilege('authenticated', 'public.mo_components', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.mo_components', 'DELETE')
    and not has_table_privilege('anon', 'public.mo_components', 'INSERT')
    and not has_table_privilege('anon', 'public.mo_components', 'UPDATE')
    and not has_table_privilege('anon', 'public.mo_components', 'DELETE'));
  perform pg_temp.check_true('and no policy lets one',
    not exists (select 1 from pg_policies where schemaname = 'public'
                 and tablename = 'mo_components'
                 and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')));
end $$;

rollback;
