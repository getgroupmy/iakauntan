-- Stock adjustments, and a warehouse that always exists.
--
-- `stock_adjustments` and `stock_adjustment_lines` have been in the
-- schema since 0006 with RLS since 0010, and — unlike every other
-- document in this system — **no posting function at all**. A stock take
-- could not be recorded from the app, from the API, or from SQL. The
-- tables were furniture.
--
-- The warehouse problem underneath it
-- -----------------------------------
-- `create_organization` seeds a MAIN warehouse, and the posting
-- functions fall back to `warehouses where is_default`. Any org that did
-- not come through that path — a restore, a fixture, an org created
-- before 0012 — has none, and then every stock movement is written with
-- `warehouse_id` null. `stock_levels` is unique on `(item_id,
-- warehouse_id)` and PostgreSQL treats nulls as distinct, so
-- `on conflict do nothing` never fires and a fresh level row is created
-- per movement. The item's total still rolls up correctly, which is why
-- nothing has ever complained; the per-warehouse figures are nonsense.
--
-- So the default warehouse is resolved through a function that creates
-- it rather than a select that may find nothing, and the rows already
-- written without one are repointed.

-- ---------------------------------------------------------------------
-- A warehouse, guaranteed
-- ---------------------------------------------------------------------
create or replace function app.default_warehouse(p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  select id into v_id from public.warehouses
   where org_id = p_org_id and is_default and is_active
   order by created_at limit 1;
  if v_id is not null then return v_id; end if;

  select id into v_id from public.warehouses
   where org_id = p_org_id and is_active order by created_at limit 1;
  if v_id is not null then return v_id; end if;

  insert into public.warehouses (org_id, code, name, is_default)
  values (p_org_id, 'MAIN', 'Main Warehouse', true)
  on conflict (org_id, code) do update set is_default = true
  returning id into v_id;

  return v_id;
end;
$$;

-- Repoint what was written before there was one. Done as a loop over
-- organizations rather than one statement so an org with no stock is
-- not given a warehouse it will never use.
do $$
declare r record; v_wh uuid;
begin
  for r in
    select distinct org_id from public.stock_movements where warehouse_id is null
    union
    select distinct org_id from public.stock_levels where warehouse_id is null
  loop
    v_wh := app.default_warehouse(r.org_id);

    -- Fold any null-warehouse level rows into the real one first, so the
    -- update below cannot collide with the unique constraint.
    insert into public.stock_levels
      (org_id, item_id, warehouse_id, quantity, value, average_cost)
    select l.org_id, l.item_id, v_wh, sum(l.quantity), sum(l.value),
           case when sum(l.quantity) = 0 then 0
                else round(sum(l.value) / sum(l.quantity), 6) end
      from public.stock_levels l
     where l.org_id = r.org_id and l.warehouse_id is null
     group by l.org_id, l.item_id
    on conflict (item_id, warehouse_id) do update
      set quantity = public.stock_levels.quantity + excluded.quantity,
          value = public.stock_levels.value + excluded.value;

    delete from public.stock_levels
     where org_id = r.org_id and warehouse_id is null;

    update public.stock_movements
       set warehouse_id = v_wh
     where org_id = r.org_id and warehouse_id is null;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Post a stock take
--
-- The lines hold what the system thought and what was counted. The
-- difference is the movement, valued at the item's weighted average
-- cost, which is what `app.apply_stock_movement` already uses for
-- everything else — a stock take that revalued the whole holding at a
-- new cost would be a revaluation, not a count, and would quietly
-- restate margin on every sale since.
--
-- One journal for the whole adjustment: Dr or Cr inventory against the
-- adjustment account, per item so the inventory account named on the
-- item is respected.
-- ---------------------------------------------------------------------
create or replace function public.post_stock_adjustment(p_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_adj      public.stock_adjustments;
  v_wh       uuid;
  v_entries  jsonb := '[]'::jsonb;
  v_entry_id uuid;
  v_adj_acct uuid;
  v_total    numeric(18, 2) := 0;
  r          record;
  v_cost     numeric(18, 2);
begin
  select * into v_adj from public.stock_adjustments where id = p_id;
  if not found then
    raise exception 'Adjustment % not found', p_id using errcode = 'P0002';
  end if;
  if not app.can_post(v_adj.org_id) then
    raise exception 'Insufficient privileges to post' using errcode = '42501';
  end if;
  if v_adj.gl_entry_id is not null then
    raise exception 'Adjustment % is already posted', v_adj.adjustment_no
      using errcode = '23514';
  end if;

  -- `stock_adjustments.warehouse_id` is not null, so the caller has
  -- already chosen. `app.default_warehouse` exists for the caller to
  -- resolve one with, not as a fallback here — a posting function that
  -- silently picks a warehouse is a posting function that moves stock
  -- somewhere nobody asked for.
  v_wh := v_adj.warehouse_id;

  v_adj_acct := coalesce(v_adj.account_id,
    (select id from public.accounts
      where org_id = v_adj.org_id and code = '5900'));
  if v_adj_acct is null then
    raise exception
      'No inventory adjustment account (5900) in the chart. Add it, or name '
      'an account on the adjustment.' using errcode = 'P0002';
  end if;

  for r in
    select l.id, l.item_id, l.line_no,
           round(coalesce(l.counted_quantity, 0)
                 - coalesce(l.system_quantity, 0), 4) as difference,
           coalesce(nullif(l.unit_cost, 0), i.average_cost, 0) as unit_cost,
           coalesce(i.inventory_account_id,
             (select id from public.accounts
               where org_id = v_adj.org_id and code = '1310')) as inventory_account,
           i.track_inventory, i.code as item_code
      from public.stock_adjustment_lines l
      join public.items i on i.id = l.item_id
     where l.adjustment_id = p_id
     order by l.line_no
  loop
    if r.difference = 0 then continue; end if;

    if not r.track_inventory then
      raise exception
        'Item % does not track inventory, so it has no quantity to adjust.',
        r.item_code using errcode = '23514';
    end if;
    if r.inventory_account is null then
      raise exception
        'No inventory account (1310) in the chart, and item % names none.',
        r.item_code using errcode = 'P0002';
    end if;

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
      quantity, unit_cost, source_table, source_id, source_line_id,
      notes, created_by)
    values (
      v_adj.org_id,
      app.next_document_number_internal(v_adj.org_id, 'stock_movement'),
      v_adj.adjustment_date,
      case when r.difference > 0 then 'adjustment_in' else 'adjustment_out' end
        ::app.stock_movement_type,
      r.item_id, v_wh, r.difference, r.unit_cost,
      'stock_adjustments', p_id, r.id, v_adj.reason, auth.uid());

    -- What the movement actually cost, read back from the row the
    -- trigger has just priced rather than recomputed here: on an
    -- outbound movement with no unit cost given, the trigger substitutes
    -- the current weighted average, and the journal has to agree with
    -- whatever it used.
    select total_cost into v_cost from public.stock_movements
     where source_line_id = r.id and source_table = 'stock_adjustments'
     order by created_at desc limit 1;

    if v_cost = 0 then continue; end if;

    if v_cost > 0 then
      v_entries := v_entries
        || jsonb_build_object('account_id', r.inventory_account,
             'description', 'Stock adjustment ' || v_adj.adjustment_no,
             'debit', v_cost, 'credit', 0, 'fc_debit', 0, 'fc_credit', 0,
             'item_id', r.item_id);
    else
      v_entries := v_entries
        || jsonb_build_object('account_id', r.inventory_account,
             'description', 'Stock adjustment ' || v_adj.adjustment_no,
             'debit', 0, 'credit', -v_cost, 'fc_debit', 0, 'fc_credit', 0,
             'item_id', r.item_id);
    end if;
    v_total := v_total + v_cost;
  end loop;

  if v_total = 0 then
    -- Every line counted exactly what the system thought, or the stock
    -- was worthless. Either way there is nothing to post, and an empty
    -- journal in the ledger is a thing somebody has to explain.
    raise exception
      'Nothing to adjust — every line matches what the system already holds.'
      using errcode = '23514';
  end if;

  -- The other side, once, against the adjustment account.
  v_entries := v_entries || jsonb_build_object(
    'account_id', v_adj_acct,
    'description', 'Stock adjustment ' || v_adj.adjustment_no,
    'debit', case when v_total < 0 then -v_total else 0 end,
    'credit', case when v_total > 0 then v_total else 0 end,
    'fc_debit', 0, 'fc_credit', 0);

  v_entry_id := app.create_gl_entry_internal(
    v_adj.org_id, v_adj.adjustment_date, 'stock_movement'::app.journal_source,
    v_entries,
    'Stock adjustment ' || v_adj.adjustment_no, 'stock_adjustments', p_id,
    v_adj.reason, app.base_currency(v_adj.org_id), 1);

  update public.stock_movements set gl_entry_id = v_entry_id
   where source_table = 'stock_adjustments' and source_id = p_id;

  update public.stock_adjustments
     set gl_entry_id = v_entry_id, status = 'posted', posted_at = now(),
         updated_at = now()
   where id = p_id;

  return v_entry_id;
end;
$$;

-- The warehouse to file a new adjustment against, made if the
-- organization has none. The client needs an id before it can insert the
-- adjustment at all, and `warehouses` being empty is not a state it can
-- do anything about on its own.
create or replace function public.ensure_default_warehouse(p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.can_write(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;
  return app.default_warehouse(p_org_id);
end;
$$;

-- What the system currently holds, for the stock take sheet to open on.
create or replace function public.stock_on_hand(
  p_org_id uuid, p_warehouse_id uuid default null)
returns table (
  item_id uuid, code text, name text, uom_code text,
  quantity numeric, average_cost numeric, value numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select i.id, i.code, i.name, i.uom_code,
         coalesce(sum(l.quantity), 0),
         coalesce(i.average_cost, 0),
         coalesce(sum(l.value), 0)
    from public.items i
    left join public.stock_levels l on l.item_id = i.id
      and (p_warehouse_id is null or l.warehouse_id = p_warehouse_id)
   where i.org_id = p_org_id and i.track_inventory and i.deleted_at is null
     and i.is_active
   group by i.id, i.code, i.name, i.uom_code, i.average_cost
   order by i.code;
end;
$$;

revoke all on function app.default_warehouse(uuid) from public, anon, authenticated;

revoke all on function public.post_stock_adjustment(uuid) from public, anon;
grant execute on function public.post_stock_adjustment(uuid) to authenticated;

revoke all on function public.stock_on_hand(uuid, uuid) from public, anon;
grant execute on function public.stock_on_hand(uuid, uuid) to authenticated;

revoke all on function public.ensure_default_warehouse(uuid) from public, anon;
grant execute on function public.ensure_default_warehouse(uuid) to authenticated;
