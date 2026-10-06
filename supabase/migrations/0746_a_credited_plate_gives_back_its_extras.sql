-- A credited plate gives back what its modifiers took, too.
--
-- `app.pos_deplete_recipes` takes a dish's ingredients off the shelf when
-- a counter sale settles, and since 0250 it has had a second branch for
-- the dish's MODIFIERS -- an extra egg is an egg. `app.pos_return_recipes`
-- (0269), which puts them back when the sale is credited, has no
-- reference to any modifier table at all. Measured on
-- `pos_recipes.sql`'s own fixture: a plate with an extra egg takes two
-- eggs out, and crediting it puts one back.
--
-- Found by reading the two halves against each other on 5 October 2026,
-- reported, and fixed on 6 October at the user's word. A mutation sweep
-- could not have found it: it breaks what is there and cannot see what
-- is missing.
--
-- The second-order effect is worse than the shortfall. The missing egg
-- stays "owing" against the sale, so a DUPLICATE credit note -- a
-- mistake -- could claim it, and the stock came right only if somebody
-- made a second error. `pos_recipes.sql` asserted exactly that, as the
-- defect's consequence, and now asserts the opposite.
--
-- ## The rate, since a credit line does not name its sale line
--
-- `credit_sales_invoice` copies the invoice's lines and renumbers them,
-- so a credit note says "one Nasi lemak" and not "line 2 of the sale".
-- The modifiers are therefore returned PER DISH, at the rate the sale
-- took them per plate of that dish, times the plates credited:
--
--     modifier consumption on the sale's lines of dish D
--       * (plates of D credited / plates of D sold)
--
-- Exact when D was on one sale line, which is the ordinary case. Where
-- D was on several lines with different modifiers it is their average;
-- and in every case "never more than went out", which this function
-- already enforces per ingredient, caps the total. A full credit
-- therefore returns exactly what the sale took.
--
-- Nothing else in the function changes. The dish's own components are
-- read exactly as before; the `track_inventory` test moves from the
-- line query to the outer select so it covers both branches.

create or replace function app.pos_return_recipes(
  p_sale   uuid,
  p_credit uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_doc    public.sales_documents;
  v_wh     uuid;
  v_row    record;
  v_qty    numeric;
  v_left   numeric;
  v_unit   numeric;
  v_cost   numeric := 0;
  v_moved  numeric;
  v_lines  jsonb;
  v_cogs   uuid;
  v_inv    uuid;
  v_entry  uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  select * into v_doc  from public.sales_documents where id = p_credit;
  if v_sale.id is null or v_doc.id is null then
    return null;
  end if;

  select coalesce(o.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = v_sale.org_id and w.is_default limit 1))
    into v_wh
    from public.pos_outlets o where o.id = v_sale.outlet_id;
  if v_wh is null then
    return null;
  end if;

  -- Already done. A credit note posted twice -- reversed and re-posted,
  -- say -- must not return the food twice.
  if exists (select 1 from public.stock_movements sm
              where sm.source_table = 'pos_sales'
                and sm.source_id = p_sale
                and sm.source_line_id = p_credit) then
    return null;
  end if;

  for v_row in
    with need as (
      select c.item_id, sum(c.quantity) as quantity
        from public.sales_document_lines l
        cross join lateral app.pos_recipe_components(l.item_id, l.quantity) c
       where l.document_id = p_credit
         and l.line_type = 'item'
         and l.item_id is not null
         and l.quantity > 0
       group by c.item_id
      union all
      -- 0746. What the dish's MODIFIERS took, given back at the rate the
      -- sale took them per plate of that dish. The depletion has had
      -- this branch since 0250; the return never did, so an extra egg
      -- sold was an egg never given back. A credit note does not say
      -- which sale line it reverses -- `credit_sales_invoice` renumbers
      -- its lines -- so the rate is per dish: exact when the dish was on
      -- one line, an average across lines of it otherwise, and capped
      -- either way by "never more than went out" below.
      select c.item_id, sum(c.quantity)
        from (select cl.item_id, sum(cl.quantity) as credited
                from public.sales_document_lines cl
               where cl.document_id = p_credit
                 and cl.line_type = 'item'
                 and cl.quantity > 0
               group by cl.item_id) cr
        join (select sl.item_id, sum(sl.quantity) as sold
                from public.pos_sale_lines sl
               where sl.sale_id = p_sale
               group by sl.item_id) so
          on so.item_id = cr.item_id and so.sold > 0
        join public.pos_sale_lines pl
          on pl.sale_id = p_sale and pl.item_id = cr.item_id
        join public.pos_sale_line_modifiers m on m.line_id = pl.id
        join public.pos_modifiers pm on pm.id = m.modifier_id
        cross join lateral app.pos_item_consumption(
          pm.recipe_item_id,
          app.uom_qty(pm.recipe_item_id,
                      coalesce(pm.recipe_quantity, 0),
                      coalesce(pm.recipe_uom_code,
                               (select i.uom_code from public.items i
                                 where i.id = pm.recipe_item_id)))
            * m.quantity * pl.quantity * cr.credited / so.sold) c
       where pm.recipe_item_id is not null
         and coalesce(pm.recipe_quantity, 0) > 0
       group by c.item_id
    )
    select n.item_id, sum(n.quantity) as quantity, i.name
      from need n
      join public.items i on i.id = n.item_id
     where i.track_inventory
     group by n.item_id, i.name
  loop
    -- Never more than went out. See the header.
    v_left := app.pos_recipe_consumed(p_sale, v_row.item_id)
              - app.pos_recipe_returned(p_sale, v_row.item_id);
    v_qty  := least(round(v_row.quantity, 4), round(v_left, 4));
    if v_qty <= 0 then
      continue;
    end if;

    -- The price it left at, read off the movement that took it.
    select sm.unit_cost into v_unit
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.item_id = v_row.item_id and sm.quantity < 0
     order by sm.created_at limit 1;

    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id,
      source_line_id, notes, created_by)
    values (
      v_sale.org_id,
      app.next_document_number_internal(v_sale.org_id, 'stock_movement'),
      v_doc.doc_date, 'assembly_in', v_row.item_id, v_wh, v_qty,
      coalesce(v_unit, 0),
      'pos_sales', p_sale, p_credit,
      'Credited ' || v_doc.doc_no, auth.uid());

    select sm.total_cost into v_moved
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.source_line_id = p_credit and sm.item_id = v_row.item_id
     order by sm.created_at desc limit 1;

    v_cost := v_cost + coalesce(v_moved, 0);
  end loop;

  if round(v_cost, 2) = 0 then
    return null;
  end if;

  select a.id into v_cogs from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '5200';
  select a.id into v_inv from public.accounts a
   where a.org_id = v_sale.org_id and a.code = '1310';
  if v_cogs is null or v_inv is null then
    return null;
  end if;

  -- The mirror of 0264's entry: stock back in, cost of sales released.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_inv,
      'description', 'Ingredients returned ' || v_doc.doc_no,
      'debit', round(v_cost, 2), 'credit', 0),
    jsonb_build_object('account_id', v_cogs,
      'description', 'Food cost credited ' || v_doc.doc_no,
      'debit', 0, 'credit', round(v_cost, 2)));

  v_entry := app.create_gl_entry_internal(
    v_sale.org_id, v_doc.doc_date, 'stock_movement', v_lines,
    'Recipe returned ' || v_doc.doc_no, 'pos_sales', p_sale);

  update public.stock_movements sm
     set gl_entry_id = v_entry
   where sm.source_table = 'pos_sales' and sm.source_id = p_sale
     and sm.source_line_id = p_credit and sm.gl_entry_id is null;

  return v_entry;
end;
$$;

revoke all on function app.pos_return_recipes(uuid, uuid)
  from public, anon, authenticated;
