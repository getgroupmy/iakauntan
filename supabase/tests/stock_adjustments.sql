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
  v_item uuid; v_adj uuid; v_msg text;
begin
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'SVC-1', 'Consulting', 'service', false, 'C62')
  returning id into v_item;

  v_adj := pg_temp.adjustment(v_org, v_item, 0, 5);
  begin
    perform public.post_stock_adjustment(v_adj);
    raise exception 'FAIL: adjusted the quantity of a service';
  exception when sqlstate '23514' then
    -- The message, because 23514 is also what an adjustment that
    -- changes nothing raises, and a consulting line counted at five
    -- against a system figure of zero reaches both.
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a service cannot be counted',
      v_msg like '%does not track inventory%');
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

-- ---------------------------------------------------------------------
-- Kira Stok Sdn Bhd: everything about a count except the two figures
--
-- Sweeping `post_stock_adjustment` killed eight of twenty mutants. The
-- two figures the file was written for — what the ledger says and what
-- the stock report says — were caught every time. Almost everything
-- around them was open: which warehouse the stock came off, which
-- accounts it went to, whether the line's own cost was used or the
-- average, whether a shortfall was labelled a shortfall, what day any
-- of it happened on, whether the adjustment ended up posted, and
-- whether the movements were tied back to the journal at all.
--
-- The fixture above cannot reach most of that. It has one warehouse,
-- so a posting into the wrong one is invisible; one line, so a line
-- that counted exactly right cannot be skipped wrongly; no cost on the
-- line and no accounts of its own, so every `coalesce` falls through
-- to the same answer either way. This one is built to tell them apart.
-- ---------------------------------------------------------------------
do $$
declare
  v_org   uuid := pg_temp.sa_org('Kira Stok Sdn Bhd');
  v_utama uuid; v_simpan uuid;
  v_inv   uuid; v_adj_acct uuid;
  v_item  uuid; v_tepat uuid; v_adj uuid; v_entry uuid;
  v_owner uuid := pg_temp.test_user();
  v_msg   text;
begin
  -- Two warehouses, and the count is in the one that is not the
  -- default, so a posting that quietly picks the default is visible.
  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'UTAMA', 'Main store', true) returning id into v_utama;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'SIMPAN', 'Back store') returning id into v_simpan;

  -- Accounts of its own at both ends, so falling through to 1310 and
  -- 5900 is visible as well.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group,
     parent_id, sort_order)
  values (v_org, '1315', 'Stock in the back store', 'asset', 'inventory',
          false, (select id from public.accounts
                   where org_id = v_org and code = '1300'), 1500)
  returning id into v_inv;
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group,
     parent_id, sort_order)
  values (v_org, '5910', 'Shrinkage, back store', 'expense', 'cost_of_sales',
          false, (select parent_id from public.accounts
                   where org_id = v_org and code = '5900'), 1500)
  returning id into v_adj_acct;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, inventory_account_id)
  values (v_org, 'BARANG', 'Widget', 'stock', true, 'C62', 20, 10, v_inv)
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price)
  values (v_org, 'TEPAT', 'Counted right', 'stock', true, 'C62', 5, 1)
  returning id into v_tepat;

  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'KS-0001', date '2026-01-01', 'opening_balance', v_item,
          v_simpan, 100, 10),
         (v_org, 'KS-0002', date '2026-01-01', 'opening_balance', v_tepat,
          v_simpan, 50, 1);

  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason,
     adjustment_type, status, account_id)
  values (v_org, 'ADJ-KIRA', date '2026-03-31', v_simpan, 'Kiraan tahunan',
          'stock_take', 'draft', v_adj_acct)
  returning id into v_adj;

  -- Ten short at twelve ringgit — a cost written on the line, not the
  -- ten the average would give — and a second line that counted
  -- exactly right and should leave no trace at all.
  insert into public.stock_adjustment_lines
    (org_id, adjustment_id, line_no, item_id, system_quantity,
     counted_quantity, unit_cost)
  values (v_org, v_adj, 1, v_item, 100, 90, 12),
         (v_org, v_adj, 2, v_tepat, 50, 50, 0);

  -- ------------------------------------------------------------------
  -- Who may post it
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-kira@example.test'));
  begin
    perform public.post_stock_adjustment(v_adj);
    raise exception 'FAIL a stranger posted another company''s count';
  exception when sqlstate '42501' then
    -- The whole message, not a fragment: create_gl_entry refuses with
    -- '...to post to the ledger' and would satisfy a `like`.
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('somebody outside the company cannot post a count',
      v_msg = 'Insufficient privileges to post');
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and the count is still in draft',
    (select status = 'draft' and gl_entry_id is null
       from public.stock_adjustments where id = v_adj));

  v_entry := public.post_stock_adjustment(v_adj);

  -- ------------------------------------------------------------------
  -- One movement, in the right store, on the right day, labelled right
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a line that counted right leaves no movement',
    (select count(*)::integer from public.stock_movements
      where source_table = 'stock_adjustments' and source_id = v_adj), 1);
  perform pg_temp.check_true('the shortfall is a shortfall, not a windfall',
    (select movement_type::text = 'adjustment_out' from public.stock_movements
      where source_table = 'stock_adjustments' and source_id = v_adj));
  perform pg_temp.check_true('it came off the store that was counted',
    (select warehouse_id = v_simpan from public.stock_movements
      where source_table = 'stock_adjustments' and source_id = v_adj));
  perform pg_temp.check_true('on the day of the count, not the day of posting',
    (select movement_date = date '2026-03-31' from public.stock_movements
      where source_table = 'stock_adjustments' and source_id = v_adj));
  perform pg_temp.check_true('and it names the journal it was posted with',
    (select gl_entry_id = v_entry from public.stock_movements
      where source_table = 'stock_adjustments' and source_id = v_adj));

  perform pg_temp.check_eq('the back store is down ten',
    (select quantity from public.stock_levels
      where item_id = v_item and warehouse_id = v_simpan), 90);
  perform pg_temp.check_eq('and nothing was taken out of the main store',
    (select count(*)::integer from public.stock_levels
      where item_id = v_item and warehouse_id = v_utama), 0);

  -- ------------------------------------------------------------------
  -- At the line's own cost, into the accounts it named
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('written off at twelve, not at the average ten',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_inv), 120);
  perform pg_temp.check_eq('to the account the item names, not 1310',
    (select coalesce(sum(l.credit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1310'), 0);
  perform pg_temp.check_eq('and charged where the count said, not to 5900',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
      where l.entry_id = v_entry and l.account_id = v_adj_acct), 120);
  perform pg_temp.check_eq('with nothing in the default adjustment account',
    (select coalesce(sum(l.debit), 0) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '5900'), 0);

  -- ------------------------------------------------------------------
  -- And the journal, and the adjustment itself
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the journal is dated the day of the count',
    (select entry_date = date '2026-03-31' from public.gl_entries
      where id = v_entry));
  perform pg_temp.check_true('and carries the reason somebody typed',
    (select reference = 'Kiraan tahunan' from public.gl_entries
      where id = v_entry));
  perform pg_temp.check_true('the count is posted, not still open',
    (select status = 'posted' from public.stock_adjustments where id = v_adj));

  perform pg_temp.sign_out();
end $$;

rollback;
