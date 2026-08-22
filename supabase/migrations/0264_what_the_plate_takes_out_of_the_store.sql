-- =====================================================================
-- What the plate takes out of the store
--
-- A warung sells nasi lemak. Nothing in this system has ever known that
-- selling one takes 180g of rice, 40ml of coconut milk, an egg and a
-- spoon of sambal out of the kitchen. The dish is a `service` or
-- `non_stock` item — it has to be, because 0013 would otherwise move
-- stock for a plate nobody keeps a shelf of — so a shop can sell four
-- hundred plates and its rice never moves. The purchase went through
-- inventory, the sale did not, and the difference sits in the stock
-- account until somebody counts the store by hand.
--
-- This migration is the missing half: a recipe per dish, the units to
-- write it in, the movement that takes the ingredients out when the
-- bill is settled, and the countdown that tells the till how many more
-- it can sell before the kitchen runs out.
--
-- ---------------------------------------------------------------------
-- This is not the manufacturing module, and it is not trying to be
--
-- 0133 already has bills of materials, work centres, manufacturing
-- orders and absorbed conversion cost. That is the right model for a
-- factory: you plan a run, you confirm it, you post it, and finished
-- goods arrive on a shelf. A kitchen does none of that. There is no
-- order, there is no run, there is no shelf of finished nasi lemak —
-- there is a customer, and the food is made and gone inside ten
-- minutes. Forcing a manufacturing order per plate would be a lie about
-- how the business works and a thousand rows a day about nothing.
--
-- So: a recipe is consumed at the moment the sale completes, against
-- the outlet's own warehouse, with no order in between. A shop that
-- genuinely batches — the central kitchen that makes twenty litres of
-- sambal on Monday — should use 0133 for that batch and a recipe for
-- the plate. Both are supported, and the two do not collide, because a
-- dish that keeps its own stock is refused a recipe (see below).
--
-- ---------------------------------------------------------------------
-- A dish that keeps its own stock may not have a recipe
--
-- If an item has `track_inventory`, posting the invoice already writes
-- a `sales_delivery` movement for it and already posts its cost of
-- sales. Depleting a recipe on top of that would take the ingredients
-- out a second time and charge the food twice. `upsert_pos_recipe`
-- refuses the combination and says which of the two the shop wants.
--
-- The same rule read the other way is what makes sub-recipes work. A
-- component that keeps its own stock is a leaf: the sambal counted in
-- the fridge comes out of the fridge, and its own chillies were taken
-- when it was made. A component that does not keep stock but has a
-- recipe of its own is exploded further, so a central kitchen's sambal
-- that nobody counts still resolves down to chilli, oil and belacan.
--
-- ---------------------------------------------------------------------
-- Units are the whole difficulty
--
-- Recipes are written in grams and millilitres. Stock is counted in
-- kilograms and litres, and delivered in cartons and packs. Three
-- conversions have to be possible and only three:
--
--   * within a dimension, by the reference factors seeded here — a
--     kilogram is a thousand grams for everybody, always;
--   * per item, by a pack size the shop sets — a carton of this milk is
--     twenty-four, and a carton of that one is twelve, and no reference
--     table can know that;
--   * not at all, loudly. Turning grams into litres by guessing a
--     density is how a system silently orders eight times too much
--     flour. `app.uom_qty` raises and names the item.
--
-- ---------------------------------------------------------------------
-- Depletion is a trigger, not a line in `complete_pos_sale`
--
-- Ingredients leave because a sale completed, not because a particular
-- function ran. Sales complete through the counter, the kiosk, a public
-- menu order and the offline batch lander, and `complete_pos_sale` has
-- been re-created by five migrations already. A trigger on the status
-- change catches every path, now and later, and cannot be forgotten by
-- the next migration that touches the tender arithmetic.
--
-- It runs one way only, because the module does. `void_pos_sale`
-- refuses a settled bill outright -- "raise a credit note instead" --
-- so a completed sale never becomes a voided one and there is no
-- reversal to write. A credit note against a counter sale does not put
-- the ingredients back today; it returns the stock of anything the
-- invoice moved, which for a dish is nothing. Saying so here is better
-- than an arm of this function that could never run.
--
-- Depletion never refuses. By the time it runs the customer has paid.
-- If the kitchen has less rice than the recipe says, the rice goes
-- negative and the shop can see it went negative. Refusing here would
-- fail a sale that has already taken money.
--
-- ---------------------------------------------------------------------
-- The countdown, and the one number a kitchen actually asks for
--
-- "How many more can I sell?" `pos_item_portions` answers it: the
-- smallest number of portions any required ingredient can still make,
-- less what is already committed on parked bills at that outlet. The
-- commitment matters — three plates on three open tables are three
-- plates of rice that have not moved yet, and a till that ignores them
-- promises food twice on a busy night.
--
-- Blocking on it is off by default. A supermarket counting stock to the
-- gram wants the till to refuse; a warung that has never weighed its
-- rice would find every sale blocked by a number nobody maintains.
-- `pos_settings.block_out_of_stock` is the switch.
--
-- Two other things already say no and were never asked. 0258's stop
-- list -- "86 the fish" -- and its menu schedule both reach the
-- published menu and neither reaches the counter, so a cashier can ring
-- up a dish the manager took off an hour ago. The same guard that
-- checks the count asks `app.pos_item_off` first, and those two always
-- block, switch or no switch: a manager saying stop is not an estimate,
-- and neither is a breakfast that finished at eleven.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What one unit is, in the base unit of its dimension
-- ---------------------------------------------------------------------
--
-- `ref_uom_codes` has had a `category` since 0011 but never a factor,
-- so nothing could convert. The base of each dimension is the smallest
-- practical one — gram, millilitre, centimetre — so every factor is a
-- whole number or a published constant and no conversion divides first.
--
-- The packaging codes (box, carton, pack, bag, case, roll, pallet) are
-- deliberately absent. A box is only as big as whatever is in it, and
-- that belongs on the item.
create table public.ref_uom_factors (
  code      text primary key references public.ref_uom_codes(code),
  dimension text not null
              check (dimension in ('weight', 'volume', 'length', 'quantity')),
  factor    numeric(24, 9) not null check (factor > 0)
);

insert into public.ref_uom_factors (code, dimension, factor) values
  ('GRM', 'weight',   1),
  ('KGM', 'weight',   1000),
  ('TNE', 'weight',   1000000),
  ('LBR', 'weight',   453.59237),
  ('MLT', 'volume',   1),
  ('LTR', 'volume',   1000),
  ('MTQ', 'volume',   1000000),
  ('GLL', 'volume',   3785.411784),
  ('CMT', 'length',   1),
  ('MTR', 'length',   100),
  ('C62', 'quantity', 1),
  ('H87', 'quantity', 1),
  ('EA',  'quantity', 1),
  ('SET', 'quantity', 1),
  ('PR',  'quantity', 2),
  ('DZN', 'quantity', 12)
on conflict (code) do nothing;

comment on table public.ref_uom_factors is
  'How many base units of its dimension one of each unit of measure is. Packaging units are absent on purpose: a carton is only as big as the item inside it, which is what item_uom_packs is for.';

-- ---------------------------------------------------------------------
-- How big a carton of this particular thing is
-- ---------------------------------------------------------------------
create table public.item_uom_packs (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations(id) on delete cascade,
  item_id          uuid not null references public.items(id) on delete cascade,
  uom_code         text not null references public.ref_uom_codes(code),

  -- One `uom_code` is this many of the item's own `uom_code`. A carton
  -- of 24 tins where the item is stocked in tins is 24.
  qty_in_stock_uom numeric(18, 6) not null check (qty_in_stock_uom > 0),

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (item_id, uom_code)
);

create index item_uom_packs_org_idx on public.item_uom_packs (org_id);

-- ---------------------------------------------------------------------
-- Turning a written quantity into the item's own units
-- ---------------------------------------------------------------------
--
-- The order matters. A pack size the shop set beats a reference factor,
-- because a shop that has said what its own carton holds has said
-- something more specific than the standards body did.
create or replace function app.uom_qty(
  p_item uuid, p_qty numeric, p_uom text)
returns numeric
language plpgsql
stable
set search_path = public, app, pg_temp
as $$
declare
  v_base text;
  v_name text;
  v_pack numeric;
  v_from numeric; v_from_dim text;
  v_to   numeric; v_to_dim   text;
begin
  select i.uom_code, i.name into v_base, v_name
    from public.items i where i.id = p_item;
  if v_base is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if p_uom is null or p_uom = v_base then
    return p_qty;
  end if;

  select k.qty_in_stock_uom into v_pack
    from public.item_uom_packs k
   where k.item_id = p_item and k.uom_code = p_uom;
  if v_pack is not null then
    return p_qty * v_pack;
  end if;

  select f.factor, f.dimension into v_from, v_from_dim
    from public.ref_uom_factors f where f.code = p_uom;
  select f.factor, f.dimension into v_to, v_to_dim
    from public.ref_uom_factors f where f.code = v_base;

  if v_from is not null and v_to is not null and v_from_dim = v_to_dim then
    return p_qty * v_from / v_to;
  end if;

  -- Deliberately fatal. Grams into litres is a density, and a system
  -- that invents one orders the wrong amount of flour for a year.
  raise exception
    'There is no way to turn % into % for %. Set what one % of it is.',
    p_uom, v_base, v_name, p_uom
    using errcode = '22023';
end;
$$;

revoke all on function app.uom_qty(uuid, numeric, text) from public, anon;
grant execute on function app.uom_qty(uuid, numeric, text) to authenticated;

comment on function app.uom_qty(uuid, numeric, text) is
  'A quantity written in any unit, expressed in the item''s own stock unit. Raises rather than guess a conversion it has not been told.';

-- ---------------------------------------------------------------------
-- The recipe
-- ---------------------------------------------------------------------
create table public.pos_recipes (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id) on delete cascade,
  item_id        uuid not null references public.items(id) on delete cascade,

  -- What the line quantities are written per. A kitchen writes down the
  -- pot it actually makes -- "this makes 20" -- and dividing by twenty
  -- once here is more accurate than a cook rounding a twentieth of an
  -- onion twenty times.
  yield_quantity numeric(18, 4) not null default 1 check (yield_quantity > 0),

  notes          text,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (item_id)
);

create index pos_recipes_org_idx on public.pos_recipes (org_id) where is_active;

create table public.pos_recipe_lines (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id) on delete cascade,
  recipe_id         uuid not null references public.pos_recipes(id) on delete cascade,
  line_no           integer not null,

  component_item_id uuid not null references public.items(id) on delete restrict,
  quantity          numeric(18, 6) not null check (quantity > 0),
  uom_code          text not null references public.ref_uom_codes(code),

  -- Trim, peel, spill and the last spoonful that never comes out of the
  -- pot. A recipe that needs 100g of usable onion from stock that is
  -- 10% skin has to draw 111g, which is what dividing by (1 - w) does.
  -- Not the same as multiplying by 1.1, and the difference compounds.
  wastage_percent   numeric(9, 4) not null default 0
                      check (wastage_percent >= 0 and wastage_percent < 100),

  -- A garnish. Still consumed, but never the reason the till says no.
  is_optional       boolean not null default false,

  created_at        timestamptz not null default now(),
  unique (recipe_id, line_no)
);

create index pos_recipe_lines_recipe_idx on public.pos_recipe_lines (recipe_id);
create index pos_recipe_lines_component_idx on public.pos_recipe_lines (component_item_id);

-- ---------------------------------------------------------------------
-- What one of something actually draws out of the store
-- ---------------------------------------------------------------------
--
-- Recursive, because a dish can call for a sub-recipe nobody counts.
-- Descent stops at anything that keeps its own stock, and at six
-- levels, and at a component already on the path -- a recipe that
-- contains itself is refused when it is saved, and this is the belt to
-- that braces.
create or replace function app.pos_recipe_components(
  p_item uuid, p_qty numeric)
returns table (item_id uuid, quantity numeric, is_optional boolean)
language sql
stable
set search_path = public, app, pg_temp
as $$
  with recursive x (item_id, quantity, is_optional, depth, path, expand) as (
    select p_item, p_qty, false, 0, array[p_item]::uuid[], true
    union all
    select l.component_item_id,
           x.quantity
             * app.uom_qty(l.component_item_id, l.quantity, l.uom_code)
             / r.yield_quantity
             / (1 - l.wastage_percent / 100.0),
           x.is_optional or l.is_optional,
           x.depth + 1,
           x.path || l.component_item_id,
           not ci.track_inventory
             and exists (select 1 from public.pos_recipes cr
                          where cr.item_id = l.component_item_id
                            and cr.is_active)
      from x
      join public.pos_recipes r
        on r.item_id = x.item_id and r.is_active
      join public.pos_recipe_lines l on l.recipe_id = r.id
      join public.items ci on ci.id = l.component_item_id
     where x.expand
       and x.depth < 6
       and not (l.component_item_id = any (x.path))
  )
  select x.item_id, sum(x.quantity), bool_and(x.is_optional)
    from x
   where x.depth > 0 and not x.expand
   group by x.item_id;
$$;

revoke all on function app.pos_recipe_components(uuid, numeric) from public, anon;
grant execute on function app.pos_recipe_components(uuid, numeric) to authenticated;

comment on function app.pos_recipe_components(uuid, numeric) is
  'The stock that making p_qty of an item draws, in each component''s own unit, with sub-recipes exploded and wastage grossed up.';

-- Everything a recipe reaches, leaf or not. `pos_recipe_components`
-- deliberately drops the sub-recipes it explodes through -- they are
-- not stock and cannot be moved -- which makes it exactly the wrong
-- thing to test a loop with: a recipe that contains itself through a
-- sub-recipe would not appear in its own components.
create or replace function app.pos_recipe_uses(p_item uuid)
returns table (item_id uuid)
language sql
stable
set search_path = public, app, pg_temp
as $$
  with recursive x (item_id, depth, path) as (
    select p_item, 0, array[p_item]::uuid[]
    union all
    select l.component_item_id, x.depth + 1, x.path || l.component_item_id
      from x
      join public.pos_recipes r on r.item_id = x.item_id and r.is_active
      join public.pos_recipe_lines l on l.recipe_id = r.id
     where x.depth < 8
       and not (l.component_item_id = any (x.path))
  )
  select distinct x.item_id from x where x.depth > 0;
$$;

revoke all on function app.pos_recipe_uses(uuid) from public, anon;
grant execute on function app.pos_recipe_uses(uuid) to authenticated;

-- The same question asked about something that might not be a dish at
-- all. A modifier's "extra egg" points at an egg, which keeps its own
-- stock and is therefore its own answer.
create or replace function app.pos_item_consumption(
  p_item uuid, p_qty numeric)
returns table (item_id uuid, quantity numeric, is_optional boolean)
language sql
stable
set search_path = public, app, pg_temp
as $$
  select c.item_id, c.quantity, c.is_optional
    from app.pos_recipe_components(p_item, p_qty) c
  union all
  select p_item, p_qty, false
   where exists (select 1 from public.items i
                  where i.id = p_item and i.track_inventory)
     and not exists (select 1 from public.pos_recipes r
                      where r.item_id = p_item and r.is_active);
$$;

revoke all on function app.pos_item_consumption(uuid, numeric) from public, anon;
grant execute on function app.pos_item_consumption(uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- An "extra egg" that is actually an egg
-- ---------------------------------------------------------------------
alter table public.pos_modifiers
  add column if not exists recipe_item_id uuid references public.items(id) on delete set null,
  add column if not exists recipe_quantity numeric(18, 6),
  add column if not exists recipe_uom_code text references public.ref_uom_codes(code);

comment on column public.pos_modifiers.recipe_item_id is
  'What choosing this modifier takes out of the store, if anything. "Extra egg" points at the egg; "no cucumber" points at nothing, because a system that credits stock back for an omission has invented an egg.';

-- ---------------------------------------------------------------------
-- Taking it out of the store
-- ---------------------------------------------------------------------
--
-- One movement per component, one journal for the lot.
--
-- The movement type is `assembly_out`, which 0006 already means
-- "components consumed making something". A new enum value would have
-- been more descriptive and could not be used in the transaction that
-- added it, and the reports that group movements would all have needed
-- a new arm for a synonym.
create or replace function app.pos_deplete_recipes(p_sale uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_wh     uuid;
  v_row    record;
  v_cost   numeric := 0;
  v_lines  jsonb := '[]'::jsonb;
  v_cogs   uuid;
  v_inv    uuid;
  v_entry  uuid;
  v_moved  numeric;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    return null;
  end if;

  select coalesce(o.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = v_sale.org_id and w.is_default limit 1))
    into v_wh
    from public.pos_outlets o where o.id = v_sale.outlet_id;
  if v_wh is null then
    -- No warehouse anywhere in this company. Nothing to take stock out
    -- of, and refusing would fail a sale that has already been paid.
    return null;
  end if;

  for v_row in
    with need as (
      -- The dishes. Never the dish itself: a dish that keeps its own
      -- stock is refused a recipe, and one that does not has nothing
      -- of its own to move.
      select c.item_id, sum(c.quantity) as quantity
        from public.pos_sale_lines l
        cross join lateral app.pos_recipe_components(l.item_id, l.quantity) c
       where l.sale_id = p_sale and l.item_id is not null
       group by c.item_id
      union all
      -- And what was asked for on top of them.
      select c.item_id, sum(c.quantity)
        from public.pos_sale_lines l
        join public.pos_sale_line_modifiers m on m.line_id = l.id
        join public.pos_modifiers pm on pm.id = m.modifier_id
        cross join lateral app.pos_item_consumption(
          pm.recipe_item_id,
          app.uom_qty(pm.recipe_item_id,
                      coalesce(pm.recipe_quantity, 0),
                      coalesce(pm.recipe_uom_code,
                               (select i.uom_code from public.items i
                                 where i.id = pm.recipe_item_id)))
            * m.quantity * l.quantity) c
       where l.sale_id = p_sale
         and pm.recipe_item_id is not null
         and coalesce(pm.recipe_quantity, 0) > 0
       group by c.item_id
    )
    select n.item_id, sum(n.quantity) as quantity, i.name
      from need n join public.items i on i.id = n.item_id
     where i.track_inventory
     group by n.item_id, i.name
     having sum(n.quantity) > 0
  loop
    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id,
      warehouse_id, quantity, unit_cost, source_table, source_id, notes)
    values (
      v_sale.org_id,
      app.next_document_number_internal(v_sale.org_id, 'stock_movement'),
      coalesce(v_sale.completed_at::date, current_date),
      'assembly_out', v_row.item_id, v_wh,
      -round(v_row.quantity, 4),
      -- Zero, so that the trigger substitutes the current weighted
      -- average. That is what the food actually cost, and it is the
      -- figure the journal below has to agree with.
      0,
      'pos_sales', p_sale, 'Recipe ' || v_sale.sale_no);

    -- Read back rather than recomputed: on the way out the trigger
    -- substitutes the current weighted average for a zero unit cost,
    -- and the journal has to agree with whatever it used.
    select sm.total_cost into v_moved
      from public.stock_movements sm
     where sm.source_table = 'pos_sales' and sm.source_id = p_sale
       and sm.item_id = v_row.item_id
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

  -- v_cost is negative: the movement was.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_cogs,
      'description', 'Food cost ' || v_sale.sale_no,
      'debit', greatest(-v_cost, 0), 'credit', greatest(v_cost, 0)),
    jsonb_build_object('account_id', v_inv,
      'description', 'Ingredients ' || v_sale.sale_no,
      'debit', greatest(v_cost, 0), 'credit', greatest(-v_cost, 0)));

  v_entry := app.create_gl_entry_internal(
    v_sale.org_id,
    coalesce(v_sale.completed_at::date, current_date),
    'stock_movement', v_lines,
    'Recipe consumption ' || v_sale.sale_no, 'pos_sales', p_sale);

  update public.stock_movements sm
     set gl_entry_id = v_entry
   where sm.source_table = 'pos_sales' and sm.source_id = p_sale
     and sm.gl_entry_id is null;

  return v_entry;
end;
$$;

revoke all on function app.pos_deplete_recipes(uuid)
  from public, anon, authenticated;

comment on function app.pos_deplete_recipes(uuid) is
  'Moves a settled sale''s ingredients out of the outlet''s warehouse and posts their cost. Called by trigger, never by a client.';

-- ---------------------------------------------------------------------
-- Which fires when the bill is settled, whoever settled it
-- ---------------------------------------------------------------------
create or replace function app.pos_sale_recipe_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    perform app.pos_deplete_recipes(new.id);
  end if;
  return new;
end;
$$;

create trigger pos_sale_recipes
  after update of status on public.pos_sales
  for each row execute function app.pos_sale_recipe_trigger();

-- ---------------------------------------------------------------------
-- Taken off the menu by hand -- which already exists
-- ---------------------------------------------------------------------
--
-- 0258 built `pos_item_stops` and `app.pos_item_off` for exactly this:
-- the fish did not arrive, somebody says so, and the published menu
-- stops offering it until tomorrow. Nothing here re-invents it. What
-- 0258 did not do is stop the *counter* selling it -- the public menu
-- checked, the till never did -- and this migration closes that, in the
-- same place it puts the ingredient check, so both answers come from
-- one function.

-- ---------------------------------------------------------------------
-- Whether the till refuses on the count as well
-- ---------------------------------------------------------------------
alter table public.pos_settings
  add column if not exists block_out_of_stock boolean not null default false;

comment on column public.pos_settings.block_out_of_stock is
  'Whether the till refuses a dish its recipe can no longer make. Off by default: a shop that has never weighed its rice would find every sale blocked by a number nobody maintains. Marking something off by hand always blocks, switch or no switch.';

-- ---------------------------------------------------------------------
-- How many more of each dish this outlet can make
-- ---------------------------------------------------------------------
--
-- `portions` is what can still be sold: the smallest number any
-- required ingredient can make, less what parked bills at this outlet
-- have already promised. Null means nothing counted limits it -- a dish
-- with no recipe, or one whose ingredients are all untracked.
create or replace function public.pos_item_portions(p_outlet uuid)
returns table (
  item_id            uuid,
  item_name          text,
  portions           numeric,
  on_hand_portions   numeric,
  committed          numeric,
  limiting_item_id   uuid,
  limiting_item_name text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
  v_wh  uuid;
begin
  select o.org_id,
         coalesce(o.warehouse_id,
                  (select w.id from public.warehouses w
                    where w.org_id = o.org_id and w.is_default limit 1))
    into v_org, v_wh
    from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  return query
  with dish as (
    select i.id, i.name
      from public.items i
      join public.pos_recipes r on r.item_id = i.id and r.is_active
     where i.org_id = v_org and i.deleted_at is null
  ),
  req as (
    select d.id as dish_id, c.item_id as comp_id, c.quantity
      from dish d
      cross join lateral app.pos_recipe_components(d.id, 1) c
     where not c.is_optional
  ),
  cap as (
    select r.dish_id, r.comp_id,
           floor(coalesce(sl.quantity, 0) / r.quantity) as portions
      from req r
      join public.items ci on ci.id = r.comp_id and ci.track_inventory
      left join public.stock_levels sl
        on sl.item_id = r.comp_id and sl.warehouse_id = v_wh
     where r.quantity > 0
  ),
  worst as (
    select distinct on (c.dish_id) c.dish_id, c.comp_id, c.portions
      from cap c
     order by c.dish_id, c.portions asc, c.comp_id
  ),
  -- What the open bills at this outlet have already promised. The
  -- ingredients have not moved -- a parked sale is not a sale -- but
  -- the kitchen has three of them to make, and a till that ignores
  -- that sells the same last portion twice on a busy night.
  held as (
    select l.item_id, sum(l.quantity) as qty
      from public.pos_sale_lines l
      join public.pos_sales s on s.id = l.sale_id
     where s.outlet_id = p_outlet and s.status = 'parked'
       and l.item_id is not null
     group by l.item_id
  )
  select d.id, d.name,
         case when w.portions is null then null
              else greatest(w.portions - coalesce(h.qty, 0), 0) end,
         w.portions,
         coalesce(h.qty, 0),
         w.comp_id, ci.name
    from dish d
    left join worst w on w.dish_id = d.id
    left join held  h on h.item_id = d.id
    left join public.items ci on ci.id = w.comp_id
   order by d.name;
end;
$$;

revoke all on function public.pos_item_portions(uuid) from public, anon;
grant execute on function public.pos_item_portions(uuid) to authenticated;

comment on function public.pos_item_portions(uuid) is
  'How many more of each dish this outlet can make: the smallest number any required ingredient can still make, less what parked bills have already promised.';

-- What the button on the till should say. One row per dish with a
-- recipe: what the kitchen can still make, and whether anything else --
-- a stop somebody entered, a schedule that has closed -- says no first.
create or replace function public.pos_item_availability(p_outlet uuid)
returns table (
  item_id            uuid,
  item_name          text,
  portions           numeric,
  limiting_item_name text,
  off_reason         text,
  available          boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org   uuid;
  v_block boolean;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  select coalesce(ps.block_out_of_stock, false) into v_block
    from public.pos_settings ps where ps.org_id = v_org;
  v_block := coalesce(v_block, false);

  return query
  select p.item_id, p.item_name, p.portions, p.limiting_item_name,
         app.pos_item_off(p.item_id, p_outlet),
         app.pos_item_off(p.item_id, p_outlet) is null
           and (not v_block or p.portions is null or p.portions > 0)
    from public.pos_item_portions(p_outlet) p
   order by p.item_name;
end;
$$;

revoke all on function public.pos_item_availability(uuid) from public, anon;
grant execute on function public.pos_item_availability(uuid) to authenticated;

comment on function public.pos_item_availability(uuid) is
  'What the till should do with each dish that has a recipe: how many are left, and whether a stop or a schedule refuses it before the count does.';

-- ---------------------------------------------------------------------
-- And the till, refusing
-- ---------------------------------------------------------------------
--
-- Re-created from 0262 with two checks in front of the line. Both are
-- here rather than in the public wrapper so that the counter, the
-- kiosk and a phone ordering off the published menu all get the same
-- answer -- `place_public_pos_order` calls this function, and a menu
-- link that could sell the fish the manager took off would be the one
-- door left open.
create or replace function app.add_pos_sale_line_internal(
  p_sale     uuid,
  p_item     uuid,
  p_quantity numeric default 1,
  p_price    numeric default null,
  p_discount numeric default 0,
  p_note     text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid; v_status app.pos_sale_status; v_outlet uuid;
  v_incl boolean; v_wh uuid;
  v_item record; v_rate numeric := 0; v_taxcode uuid;
  v_price numeric; v_line uuid; v_no integer;
  v_gross numeric; v_net numeric; v_tax numeric;
  v_off text; v_block boolean; v_port numeric; v_on_bill numeric;
begin
  select s.org_id, s.status, s.outlet_id into v_org, v_status, v_outlet
    from public.pos_sales s where s.id = p_sale;
  if v_org is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if v_status <> 'parked' then
    raise exception
      'That sale is % and cannot be added to.', v_status using errcode = '23514';
  end if;
  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'A line needs a quantity.' using errcode = '23514';
  end if;

  select o.prices_include_tax, o.warehouse_id into v_incl, v_wh
    from public.pos_outlets o where o.id = v_outlet;

  select i.id, i.name, i.uom_code, i.unit_price, i.sales_tax_code_id
    into v_item
    from public.items i
   where i.id = p_item and i.org_id = v_org and i.deleted_at is null;
  if v_item.id is null then
    raise exception 'That item is not on this company''s list.'
      using errcode = 'P0002';
  end if;

  -- Stopped by hand, or off the timetable. 0258 wrote both answers
  -- into one function and gave them to the published menu; the counter
  -- has been able to ring up a stopped dish ever since. Always refused,
  -- switch or no switch: a manager saying stop is not an estimate, and
  -- neither is a breakfast that finished at eleven.
  v_off := app.pos_item_off(p_item, v_outlet);
  if v_off is not null then
    raise exception '%: %', v_item.name, v_off using errcode = '23514';
  end if;

  -- Out of ingredients, if the shop asked to be stopped by that.
  select coalesce(ps.block_out_of_stock, false) into v_block
    from public.pos_settings ps where ps.org_id = v_org;
  if coalesce(v_block, false) then
    select p.portions into v_port
      from public.pos_item_portions(v_outlet) p where p.item_id = p_item;
    if v_port is not null then
      -- What this bill already holds is inside `portions` already --
      -- it is parked, and the countdown nets off parked bills -- so
      -- only the quantity being added now is compared.
      if v_port < p_quantity then
        if v_port <= 0 then
          raise exception
            'The kitchen has run out of what % is made of.', v_item.name
            using errcode = '23514';
        end if;
        raise exception
          'There is only enough left for % of %.', v_port, v_item.name
          using errcode = '23514';
      end if;
    end if;
  end if;

  v_price := coalesce(p_price, v_item.unit_price, 0);
  v_taxcode := v_item.sales_tax_code_id;
  if v_taxcode is not null then
    select t.rate into v_rate from public.tax_codes t
     where t.id = v_taxcode and t.is_active;
    if v_rate is null then
      v_taxcode := null; v_rate := 0;
    end if;
  end if;

  -- The same split app.calc_document_line performs, done here because
  -- a POS line is not a document line yet and the till has to show the
  -- customer a total before either exists.
  v_gross := round(v_price * p_quantity, 2) - coalesce(p_discount, 0);
  if v_incl and v_rate > 0 then
    v_net := round(v_gross / (1 + v_rate / 100.0), 2);
    v_tax := round(v_gross - v_net, 2);
  else
    v_net := round(v_gross, 2);
    v_tax := round(v_net * v_rate / 100.0, 2);
  end if;

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from public.pos_sale_lines l where l.sale_id = p_sale;

  insert into public.pos_sale_lines (
    org_id, sale_id, line_no, item_id, description, quantity, uom_code,
    unit_price, discount_amount, tax_code_id, tax_rate, tax_amount,
    is_tax_inclusive, line_subtotal, line_total, warehouse_id, note)
  values (
    v_org, p_sale, v_no, p_item, v_item.name, p_quantity, v_item.uom_code,
    v_price, coalesce(p_discount, 0), v_taxcode, v_rate, v_tax,
    coalesce(v_incl, false), v_net, v_net + v_tax, v_wh, p_note)
  returning id into v_line;

  perform app.recalc_pos_sale(p_sale);
  return v_line;
end;
$$;

revoke all on function app.add_pos_sale_line_internal(
  uuid, uuid, numeric, numeric, numeric, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Writing a recipe down
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_recipe(
  p_org    uuid,
  p_item   uuid,
  p_yield  numeric,
  p_lines  jsonb,
  p_notes  text default null,
  p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_id    uuid;
  v_name  text;
  v_track boolean;
  v_e     jsonb;
  v_no    integer := 0;
  v_comp  uuid;
  v_uom   text;
  v_qty   numeric;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if coalesce(p_yield, 0) <= 0 then
    raise exception 'A recipe has to say how many it makes.'
      using errcode = '23514';
  end if;

  select i.name, i.track_inventory into v_name, v_track
    from public.items i
   where i.id = p_item and i.org_id = p_org and i.deleted_at is null;
  if v_name is null then
    raise exception 'That item is not on this company''s list.'
      using errcode = 'P0002';
  end if;

  -- The rule the whole design rests on. See the header.
  if v_track then
    raise exception
      '% keeps its own stock, so selling one already moves it. A recipe '
      'would take the ingredients out a second time. Turn stock tracking '
      'off for the dish, or make it with a manufacturing order instead.',
      v_name
      using errcode = '23514';
  end if;

  insert into public.pos_recipes (org_id, item_id, yield_quantity, notes, is_active)
  values (p_org, p_item, p_yield, nullif(trim(coalesce(p_notes, '')), ''),
          coalesce(p_active, true))
  on conflict (item_id) do update
    set yield_quantity = excluded.yield_quantity,
        notes          = excluded.notes,
        is_active      = excluded.is_active,
        updated_at     = now()
  returning id into v_id;

  delete from public.pos_recipe_lines l where l.recipe_id = v_id;

  for v_e in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_comp := (v_e ->> 'item')::uuid;
    v_qty  := (v_e ->> 'quantity')::numeric;
    v_uom  := coalesce(nullif(v_e ->> 'uom', ''),
                       (select i.uom_code from public.items i where i.id = v_comp));

    if v_comp is null or coalesce(v_qty, 0) <= 0 then
      raise exception 'Every ingredient needs an item and a quantity.'
        using errcode = '23514';
    end if;
    if v_comp = p_item then
      raise exception '% cannot be an ingredient of itself.', v_name
        using errcode = '23514';
    end if;
    if not exists (select 1 from public.items i
                    where i.id = v_comp and i.org_id = p_org
                      and i.deleted_at is null) then
      raise exception 'One of the ingredients is not on this company''s list.'
        using errcode = 'P0002';
    end if;
    -- Refused here rather than survived at run time. The explosion
    -- stops at a repeat, so a loop would silently under-deplete
    -- forever; a cook who has just typed one wants to be told now.
    if exists (select 1 from app.pos_recipe_uses(v_comp) u
                where u.item_id = p_item) then
      raise exception
        'That would make % an ingredient of itself, through its own '
        'sub-recipes.', v_name
        using errcode = '23514';
    end if;
    -- Proves the units can be converted at all, at the moment somebody
    -- can still fix it, rather than in the middle of a Saturday
    -- lunchtime.
    perform app.uom_qty(v_comp, v_qty, v_uom);

    v_no := v_no + 1;
    insert into public.pos_recipe_lines (
      org_id, recipe_id, line_no, component_item_id, quantity, uom_code,
      wastage_percent, is_optional)
    values (
      p_org, v_id, v_no, v_comp, v_qty, v_uom,
      coalesce((v_e ->> 'wastage')::numeric, 0),
      coalesce((v_e ->> 'optional')::boolean, false));
  end loop;

  return v_id;
end;
$$;

revoke all on function public.upsert_pos_recipe(
  uuid, uuid, numeric, jsonb, text, boolean) from public, anon;
grant execute on function public.upsert_pos_recipe(
  uuid, uuid, numeric, jsonb, text, boolean) to authenticated;

create or replace function public.delete_pos_recipe(p_recipe uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select r.org_id into v_org from public.pos_recipes r where r.id = p_recipe;
  if v_org is null then
    return false;
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  delete from public.pos_recipes r where r.id = p_recipe;
  return true;
end;
$$;

revoke all on function public.delete_pos_recipe(uuid) from public, anon;
grant execute on function public.delete_pos_recipe(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Reading them back
-- ---------------------------------------------------------------------
create or replace function public.pos_recipes_list(p_org uuid)
returns table (
  id             uuid,
  item_id        uuid,
  item_name      text,
  item_code      text,
  yield_quantity numeric,
  line_count     integer,
  cost_per_unit  numeric,
  is_active      boolean,
  notes          text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
begin
  if not app.can_read_module(p_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select r.id, r.item_id, i.name, i.code, r.yield_quantity,
         (select count(*)::integer from public.pos_recipe_lines l
           where l.recipe_id = r.id),
         -- What one costs at today's weighted average. The number a
         -- shop wants next to the menu price, and the only reason to
         -- write a recipe down at all for a kitchen that never runs out.
         coalesce((select round(sum(c.quantity * ci.average_cost), 4)
                     from app.pos_recipe_components(r.item_id, 1) c
                     join public.items ci on ci.id = c.item_id), 0),
         r.is_active, r.notes
    from public.pos_recipes r
    join public.items i on i.id = r.item_id
   where r.org_id = p_org and i.deleted_at is null
   order by i.name;
end;
$$;

revoke all on function public.pos_recipes_list(uuid) from public, anon;
grant execute on function public.pos_recipes_list(uuid) to authenticated;

create or replace function public.pos_recipe_lines_for(p_recipe uuid)
returns table (
  line_no           integer,
  component_item_id uuid,
  component_name    text,
  component_code    text,
  quantity          numeric,
  uom_code          text,
  wastage_percent   numeric,
  is_optional       boolean,
  stock_quantity    numeric,
  stock_uom         text,
  tracks_stock      boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select r.org_id into v_org from public.pos_recipes r where r.id = p_recipe;
  if v_org is null then
    raise exception 'No such recipe.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select l.line_no, l.component_item_id, i.name, i.code, l.quantity,
         l.uom_code, l.wastage_percent, l.is_optional,
         i.quantity_on_hand, i.uom_code, i.track_inventory
    from public.pos_recipe_lines l
    join public.items i on i.id = l.component_item_id
   where l.recipe_id = p_recipe
   order by l.line_no;
end;
$$;

revoke all on function public.pos_recipe_lines_for(uuid) from public, anon;
grant execute on function public.pos_recipe_lines_for(uuid) to authenticated;

-- What one of these actually draws, exploded, for the screen that has
-- to explain why the countdown says four.
create or replace function public.pos_recipe_requirement(
  p_item uuid, p_qty numeric default 1)
returns table (
  component_item_id uuid,
  component_name    text,
  quantity          numeric,
  uom_code          text,
  is_optional       boolean,
  on_hand           numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select i.org_id into v_org from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select c.item_id, i.name, round(c.quantity, 6), i.uom_code,
         c.is_optional, i.quantity_on_hand
    from app.pos_recipe_components(p_item, p_qty) c
    join public.items i on i.id = c.item_id
   order by i.name;
end;
$$;

revoke all on function public.pos_recipe_requirement(uuid, numeric)
  from public, anon;
grant execute on function public.pos_recipe_requirement(uuid, numeric)
  to authenticated;

-- ---------------------------------------------------------------------
-- Pack sizes
-- ---------------------------------------------------------------------
create or replace function public.upsert_item_uom_pack(
  p_item uuid, p_uom text, p_qty numeric)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_base text; v_id uuid;
begin
  select i.org_id, i.uom_code into v_org, v_base
    from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if coalesce(p_qty, 0) <= 0 then
    raise exception 'A pack has to hold something.' using errcode = '23514';
  end if;
  if p_uom = v_base then
    raise exception
      'One % is one %, and saying so twice is how the two copies come to '
      'disagree.', p_uom, v_base
      using errcode = '23514';
  end if;

  insert into public.item_uom_packs (org_id, item_id, uom_code, qty_in_stock_uom)
  values (v_org, p_item, p_uom, p_qty)
  on conflict (item_id, uom_code) do update
    set qty_in_stock_uom = excluded.qty_in_stock_uom, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.upsert_item_uom_pack(uuid, text, numeric)
  from public, anon;
grant execute on function public.upsert_item_uom_pack(uuid, text, numeric)
  to authenticated;

create or replace function public.delete_item_uom_pack(p_item uuid, p_uom text)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_n integer;
begin
  select i.org_id into v_org from public.items i where i.id = p_item;
  if v_org is null then
    return false;
  end if;
  if not app.can_write_module(v_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  delete from public.item_uom_packs k
   where k.item_id = p_item and k.uom_code = p_uom;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

revoke all on function public.delete_item_uom_pack(uuid, text) from public, anon;
grant execute on function public.delete_item_uom_pack(uuid, text) to authenticated;

-- Every unit this item can be written in: its own, the ones its
-- dimension converts to, and whatever packs the shop has set.
create or replace function public.item_uom_options(p_item uuid)
returns table (uom_code text, uom_name text, qty_in_stock_uom numeric, is_pack boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_base text;
begin
  select i.org_id, i.uom_code into v_org, v_base
    from public.items i where i.id = p_item;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'inventory') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select u.code, u.name, app.uom_qty(p_item, 1, u.code), false
    from public.ref_uom_codes u
    join public.ref_uom_factors f on f.code = u.code
   where f.dimension = (select f2.dimension from public.ref_uom_factors f2
                         where f2.code = v_base)
  union all
  select u.code, u.name, k.qty_in_stock_uom, true
    from public.item_uom_packs k
    join public.ref_uom_codes u on u.code = k.uom_code
   where k.item_id = p_item
   order by 4, 1;
end;
$$;

revoke all on function public.item_uom_options(uuid) from public, anon;
grant execute on function public.item_uom_options(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_recipes      enable row level security;
alter table public.pos_recipe_lines enable row level security;
alter table public.item_uom_packs   enable row level security;

create policy pos_recipes_read on public.pos_recipes for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

create policy pos_recipe_lines_read on public.pos_recipe_lines for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

-- No write policies on either: a recipe and its lines are saved
-- together by `upsert_pos_recipe`, which is where the dish-keeps-stock
-- rule and the cycle check live. A client that could write the tables
-- directly could write a recipe neither of them had seen.

create policy item_uom_packs_read on public.item_uom_packs for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));

-- Revoked before granted, because Supabase's default privileges hand
-- `anon` and `authenticated` every data privilege on a table the moment
-- it is created. Row level security would have stopped the writes, but
-- a grant that is never used is a grant waiting for a policy to be
-- widened by somebody who did not read this far.
revoke all on public.pos_recipes      from anon, authenticated;
revoke all on public.pos_recipe_lines from anon, authenticated;
revoke all on public.item_uom_packs   from anon, authenticated;
revoke all on public.ref_uom_factors  from anon, authenticated;

grant select on public.pos_recipes      to authenticated;
grant select on public.pos_recipe_lines to authenticated;
grant select on public.item_uom_packs   to authenticated;
grant select on public.ref_uom_factors  to authenticated;

-- A reference table, guarded the way 0099 guards its own: row level
-- security on so `table_grants.sql` finds nothing unguarded in public,
-- and one policy that lets a signed-in user read the factors. Nobody
-- writes it but a migration.
alter table public.ref_uom_factors enable row level security;
create policy ref_uom_factors_read on public.ref_uom_factors
  for select to authenticated using (true);

create trigger set_updated_at before update on public.pos_recipes
  for each row execute function app.set_updated_at();
create trigger set_updated_at before update on public.item_uom_packs
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------
-- And the till's own menu, now that it knows what the kitchen has
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0258 for one column, and for the same reason that
-- migration gave: nothing is filtered out. A dish that vanishes reads
-- as a broken menu; a tile that says "3 left" and then "Out of telur"
-- is the only version a cashier can answer a customer from.
--
-- `available` now folds the count in, but only when the shop asked for
-- it. Off by default the tile stays live and the number is advice; on,
-- the tile greys out at zero and `add_pos_sale_line` refuses if
-- somebody taps it anyway. The two agree because both read
-- `pos_item_portions`.
--
-- Dropped first rather than replaced: a new OUT parameter is a changed
-- return type and Postgres refuses (42P13). The drop takes the grants
-- with it, so they are restated underneath.
drop function if exists public.pos_menu(uuid);

create function public.pos_menu(p_outlet uuid)
returns table (
  item_id     uuid,
  code        text,
  name        text,
  unit_price  numeric,
  uom_code    text,
  category_id uuid,
  category    text,
  variant_attributes jsonb,
  on_hand     numeric,
  tracks_stock boolean,
  portions    numeric,
  available   boolean,
  off_reason  text)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with outlet as (
    select o.org_id, o.warehouse_id
      from public.pos_outlets o
     where o.id = p_outlet
       and app.can_read_module(o.org_id, 'pos')
  ),
  -- Once for the whole menu rather than once per tile.
  left_to_make as (
    select p.item_id, p.portions, p.limiting_item_name
      from public.pos_item_portions(p_outlet) p
     where exists (select 1 from outlet)
  ),
  blocking as (
    select coalesce(ps.block_out_of_stock, false) as on
      from public.pos_settings ps
      join outlet o on o.org_id = ps.org_id
  )
  select i.id, i.code, i.name, i.unit_price, i.uom_code,
         i.category_id,
         coalesce(c.name, 'Uncategorised'),
         i.variant_attributes,
         coalesce((select sl.quantity from public.stock_levels sl
                    where sl.item_id = i.id
                      and sl.warehouse_id = (select o.warehouse_id from outlet o)), 0),
         i.track_inventory,
         m.portions,
         app.pos_item_off(i.id, p_outlet) is null
           and (not coalesce((select b.on from blocking b), false)
                or m.portions is null or m.portions > 0),
         -- The count only speaks when nothing louder already has. A
         -- dish that is both out of season and out of rice is out of
         -- season, which is the half a customer can be told something
         -- useful about.
         coalesce(
           app.pos_item_off(i.id, p_outlet),
           case when coalesce((select b.on from blocking b), false)
                     and m.portions is not null and m.portions <= 0
                then coalesce('Out of ' || lower(m.limiting_item_name), 'Out')
           end)
    from public.items i
    join outlet o on o.org_id = i.org_id
    left join public.item_categories c on c.id = i.category_id
    left join left_to_make m on m.item_id = i.id
   where i.deleted_at is null
     and i.is_active
     and i.is_sold
     and not exists (select 1 from public.items v
                      where v.parent_item_id = i.id and v.deleted_at is null)
   order by coalesce(c.name, 'Uncategorised'), i.name;
$$;

revoke all on function public.pos_menu(uuid) from public, anon;
grant execute on function public.pos_menu(uuid) to authenticated;

comment on function public.pos_menu(uuid) is
  'Everything an outlet can sell, with whether it is being offered right now, why not, and how many more of it the kitchen can make. Nothing is filtered out: a dish that vanishes reads as a broken menu.';
