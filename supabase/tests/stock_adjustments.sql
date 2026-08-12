-- =====================================================================
-- iAkauntan :: stock adjustment tests
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/stock_adjustments.sql
--
-- A stock take posts two things at once — a quantity and a value — and
-- they have to agree. If the journal says RM 100 came off inventory and
-- the movement took off RM 90 of stock, the ledger balances, the stock
-- report balances, and the two disagree with each other forever.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.sa_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  return v_org;
end;
$$;

-- A tracked item with an opening holding, put there the way every other
-- movement in the system arrives.
create or replace function pg_temp.stocked_item(
  p_org uuid, p_qty numeric, p_cost numeric)
returns uuid language plpgsql as $$
declare v_item uuid; v_wh uuid;
begin
  insert into public.items (org_id, code, name, item_type, track_inventory,
                            uom_code, unit_price, cost_price)
  values (p_org, 'ITM-' || substr(gen_random_uuid()::text, 1, 6), 'Widget',
          'stock', true, 'C62', 20, p_cost)
  returning id into v_item;

  v_wh := app.default_warehouse(p_org);
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
     quantity, unit_cost)
  values (p_org, 'OPEN-1', date '2026-01-01', 'opening_balance', v_item, v_wh,
          p_qty, p_cost);
  return v_item;
end;
$$;

create or replace function pg_temp.adjustment(
  p_org uuid, p_item uuid, p_system numeric, p_counted numeric)
returns uuid language plpgsql as $$
declare v_adj uuid;
begin
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason,
     adjustment_type, status)
  values (p_org, 'ADJ-' || substr(gen_random_uuid()::text, 1, 6),
          date '2026-03-31', app.default_warehouse(p_org), 'Annual count',
          'stock_take', 'draft')
  returning id into v_adj;
  insert into public.stock_adjustment_lines
    (org_id, adjustment_id, line_no, item_id, system_quantity, counted_quantity)
  values (p_org, v_adj, 1, p_item, p_system, p_counted);
  return v_adj;
end;
$$;

-- ---------------------------------------------------------------------
-- A shortfall: 90 counted where the system held 100, at RM 10 each
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sa_org('Stock Take Sdn Bhd');
  v_item uuid; v_adj uuid; v_entry uuid;
begin
  v_item := pg_temp.stocked_item(v_org, 100, 10);
  perform pg_temp.check_eq('opening on hand',
    (select quantity_on_hand from public.items where id = v_item), 100);

  v_adj := pg_temp.adjustment(v_org, v_item, 100, 90);
  v_entry := public.post_stock_adjustment(v_adj);
  perform pg_temp.check_true('a journal was posted', v_entry is not null);

  perform pg_temp.check_eq('the stock came down',
    (select quantity_on_hand from public.items where id = v_item), 90);

  -- The two halves that have to agree.
  perform pg_temp.check_eq('inventory credited',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1310'), 100);
  perform pg_temp.check_eq('and written off',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '5900'), 100);

  begin
    perform public.post_stock_adjustment(v_adj);
    raise exception 'FAIL: the same adjustment posted twice';
  exception when sqlstate '23514' then
    raise notice 'ok   an adjustment cannot be posted twice';
  end;
end $$;

-- ---------------------------------------------------------------------
-- A surplus goes the other way, at the same average cost
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sa_org('Surplus Sdn Bhd');
  v_item uuid; v_adj uuid; v_entry uuid;
begin
  v_item := pg_temp.stocked_item(v_org, 100, 10);
  v_adj := pg_temp.adjustment(v_org, v_item, 100, 105);
  v_entry := public.post_stock_adjustment(v_adj);

  perform pg_temp.check_eq('the stock went up',
    (select quantity_on_hand from public.items where id = v_item), 105);
  perform pg_temp.check_eq('inventory debited at the average cost',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1310'), 50);
end $$;

-- ---------------------------------------------------------------------
-- A count that agrees posts nothing
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sa_org('No Change Sdn Bhd');
  v_item uuid; v_adj uuid;
begin
  v_item := pg_temp.stocked_item(v_org, 100, 10);
  v_adj := pg_temp.adjustment(v_org, v_item, 100, 100);
  begin
    perform public.post_stock_adjustment(v_adj);
    raise exception 'FAIL: posted an adjustment that changed nothing';
  exception when sqlstate '23514' then
    raise notice 'ok   a count that agrees leaves no journal behind';
  end;
end $$;

-- ---------------------------------------------------------------------
-- A service has no quantity to adjust
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sa_org('Service Item Sdn Bhd');
  v_item uuid; v_adj uuid;
begin
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'SVC-1', 'Consulting', 'service', false, 'C62')
  returning id into v_item;

  v_adj := pg_temp.adjustment(v_org, v_item, 0, 5);
  begin
    perform public.post_stock_adjustment(v_adj);
    raise exception 'FAIL: adjusted the quantity of a service';
  exception when sqlstate '23514' then
    raise notice 'ok   a service cannot be counted';
  end;
end $$;

-- ---------------------------------------------------------------------
-- The default warehouse is made, not assumed
--
-- Every stock movement written without one creates its own stock_levels
-- row, because the unique key is (item_id, warehouse_id) and PostgreSQL
-- treats nulls as distinct. The item total still rolls up, which is why
-- this went unnoticed; the per-warehouse figures did not.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sa_org('No Warehouse Sdn Bhd');
  v_wh uuid; v_again uuid;
begin
  perform pg_temp.check_eq('a bare organization has none',
    (select count(*) from public.warehouses where org_id = v_org), 0);

  v_wh := app.default_warehouse(v_org);
  perform pg_temp.check_true('one is created', v_wh is not null);

  v_again := app.default_warehouse(v_org);
  perform pg_temp.check_true('and reused, not remade', v_again = v_wh);
  perform pg_temp.check_eq('so there is still only one',
    (select count(*) from public.warehouses where org_id = v_org), 1);
end $$;

-- ---------------------------------------------------------------------
-- What the stock take sheet opens on
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.sa_org('On Hand Sdn Bhd');
  v_item uuid; r record;
begin
  v_item := pg_temp.stocked_item(v_org, 40, 2.50);
  select * into r from public.stock_on_hand(v_org);
  perform pg_temp.check_eq('the quantity', r.quantity, 40);
  perform pg_temp.check_eq('and the value', r.value, 100);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('posting is closed to anon',
    not has_function_privilege('anon',
      'public.post_stock_adjustment(uuid)', 'execute'));
  perform pg_temp.check_true('and the warehouse resolver is internal',
    not has_function_privilege('authenticated',
      'app.default_warehouse(uuid)', 'execute'));
  perform pg_temp.check_true('while its checked wrapper is not',
    has_function_privilege('authenticated',
      'public.ensure_default_warehouse(uuid)', 'execute'));
end $$;

rollback;
