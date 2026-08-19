-- Retail: the same shirt in six sizes, and the label that finds it.
--
-- ## Why a variant is an item and not a child of one
--
-- The obvious shape for "navy, medium" is a row in an `item_variants`
-- table hanging off the shirt. It is also wrong here, and the reason is
-- worth stating because it is the reason for most of this file.
--
-- In this database every downstream thing keys on `item_id`: stock
-- movements, weighted-average cost, `stock_levels`, the forecasting
-- reorder point, sales and purchase lines, the e-Invoice line snapshot.
-- A variant that is not an item is a variant that stock does not know
-- about. Stock would be counted for "shirt" while sales happened
-- against "shirt / navy / M", and the two would drift apart quietly and
-- for ever -- and no amount of care in the Flutter layer would stop it,
-- because a rule enforced only in Dart is not enforced.
--
-- So a variant IS an item. It gets a `parent_item_id` pointing at the
-- style it belongs to, and a `variant_attributes` object saying which
-- one it is. Everything downstream keeps working with no changes at
-- all, which is the test of whether the shape is right.
--
-- The style itself stays an item too, so it can carry the shared name,
-- category, tax code and accounts -- but it is not sellable and holds
-- no stock. You cannot put "shirt" in a bag; you put a size in a bag.
--
-- ## Why the axes are not a table
--
-- Sizes and colours are derivable from the children that exist. Storing
-- them separately means storing the same fact twice, and the two copies
-- disagree the first time somebody deletes a variant. `item_variant_matrix`
-- reads them back out of the children instead.
--
-- ## Why barcodes needed a table
--
-- `items.barcode` has existed since 0003 as a single nullable text with
-- a non-unique index. Both halves of that are wrong for a shop:
--
--   * one item genuinely has several codes -- the manufacturer's EAN on
--     the unit, the ITF-14 on the carton, and the shop's own label when
--     the printed one rubs off;
--   * and a scan must resolve to exactly one item, which a non-unique
--     index does not promise.
--
-- The carton case is the one that pays for the table: scanning the
-- outer box of a six-pack should ring up six, not one. That is what
-- `pack_quantity` is for.

-- ---------------------------------------------------------------------
-- A style, and the sizes under it
-- ---------------------------------------------------------------------
alter table public.items
  add column if not exists parent_item_id uuid
    references public.items (id) on delete restrict,
  add column if not exists variant_attributes jsonb not null default '{}'::jsonb;

create index if not exists items_parent_idx
  on public.items (parent_item_id) where parent_item_id is not null;
create index if not exists items_variant_attributes_idx
  on public.items using gin (variant_attributes jsonb_path_ops);

comment on column public.items.parent_item_id is
  'The style this item is a variant of. One level only: a variant cannot itself have variants.';
comment on column public.items.variant_attributes is
  'Which variant this is, e.g. {"Size": "M", "Colour": "Navy"}. Empty on an ordinary item.';

-- One level, and a style that is not for sale.
--
-- Both halves refuse rather than correct. A three-level hierarchy and a
-- sellable style are each the kind of mistake that looks fine on the
-- screen that made it and is discovered at the till.
create or replace function app.items_variant_guard()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if new.parent_item_id is not null then
    if new.parent_item_id = new.id then
      raise exception 'An item cannot be a variant of itself.'
        using errcode = '23514';
    end if;
    if exists (select 1 from public.items p
                where p.id = new.parent_item_id and p.parent_item_id is not null) then
      raise exception
        'That item is already a variant. Variants go one level deep: a '
        'style has sizes, and a size does not have sizes.'
        using errcode = '23514';
    end if;
    if exists (select 1 from public.items p
                where p.id = new.parent_item_id and p.org_id <> new.org_id) then
      raise exception 'That style belongs to another organization.'
        using errcode = '42501';
    end if;
  end if;

  -- A style is a heading, not a thing on a shelf.
  if new.is_sold and exists (select 1 from public.items c
                              where c.parent_item_id = new.id
                                and c.deleted_at is null) then
    raise exception
      'This item has variants, so it is a style rather than something '
      'you can sell. Sell one of its variants.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists items_variant_guard on public.items;
create trigger items_variant_guard
  before insert or update on public.items
  for each row execute function app.items_variant_guard();

-- ---------------------------------------------------------------------
-- Six rows nobody should type by hand
-- ---------------------------------------------------------------------
--
-- Three sizes and two colours is six SKUs; four sizes and five colours
-- is twenty. Generating the product is the whole reason variant
-- management is a feature rather than a naming convention.
--
-- Re-runnable: a shop that adds a colour in March runs it again with
-- the full axis list and gets only the new combinations, because the
-- codes are deterministic and the existing ones are skipped.
create or replace function public.create_item_variants(
  p_parent uuid,
  p_axes   jsonb)
returns table (
  item_id    uuid,
  code       text,
  name       text,
  attributes jsonb,
  created    boolean)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_parent public.items;
  v_combos jsonb := '[]'::jsonb;
  v_axis   text;
  v_next   jsonb;
  v_combo  jsonb;
  v_value  jsonb;
  v_code   text;
  v_name   text;
  v_id     uuid;
  v_new    boolean;
  v_suffix text;
begin
  select * into v_parent from public.items where id = p_parent;
  if v_parent.id is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_write(v_parent.org_id) then
    raise exception 'not permitted to change items for this organization'
      using errcode = '42501';
  end if;
  if v_parent.parent_item_id is not null then
    raise exception
      'That item is already a variant of something else.' using errcode = '23514';
  end if;
  if jsonb_typeof(p_axes) <> 'object' or p_axes = '{}'::jsonb then
    raise exception
      'Give at least one axis, e.g. {"Size": ["S", "M", "L"]}.'
      using errcode = '23514';
  end if;

  -- Stock already counted against the style has nowhere to go once the
  -- style stops holding stock. Move it or write it off first; this
  -- function will not decide which.
  if exists (select 1 from public.stock_levels sl
              where sl.item_id = p_parent and sl.quantity <> 0)
     or v_parent.quantity_on_hand <> 0 then
    raise exception
      'There is still stock counted against %. Move it onto a variant or '
      'adjust it out before splitting the item.', v_parent.code
      using errcode = '23514';
  end if;

  -- The cartesian product, built one axis at a time.
  v_combos := '[{}]'::jsonb;
  for v_axis in select k from jsonb_object_keys(p_axes) k order by k loop
    if jsonb_typeof(p_axes -> v_axis) <> 'array'
       or jsonb_array_length(p_axes -> v_axis) = 0 then
      raise exception 'Axis "%" needs a list of values.', v_axis
        using errcode = '23514';
    end if;
    v_next := '[]'::jsonb;
    for v_combo in select e from jsonb_array_elements(v_combos) e loop
      for v_value in select e from jsonb_array_elements(p_axes -> v_axis) e loop
        v_next := v_next || jsonb_build_array(
          v_combo || jsonb_build_object(v_axis, v_value #>> '{}'));
      end loop;
    end loop;
    v_combos := v_next;
  end loop;

  for v_combo in select e from jsonb_array_elements(v_combos) e loop
    -- Deterministic, so re-running adds only what is missing. Values
    -- are upper-cased and stripped of anything that is not a letter or
    -- a digit, because a code with a slash in it is a code somebody has
    -- to escape later.
    select string_agg(upper(regexp_replace(v.value, '[^a-zA-Z0-9]', '', 'g')), '-'
                      order by v.key)
      into v_suffix
      from jsonb_each_text(v_combo) v;
    v_code := v_parent.code || '-' || v_suffix;

    select string_agg(v.value, ' / ' order by v.key)
      into v_name from jsonb_each_text(v_combo) v;
    v_name := v_parent.name || ' - ' || v_name;

    select i.id into v_id from public.items i
     where i.org_id = v_parent.org_id and i.code = v_code;

    if v_id is null then
      insert into public.items (
        org_id, code, name, description, item_type, category_id,
        uom_code, classification_code, unit_price, cost_price, min_price,
        currency, sales_tax_code_id, purchase_tax_code_id,
        sales_account_id, purchase_account_id, inventory_account_id,
        cogs_account_id, track_inventory, costing_method,
        preferred_supplier_id, is_active, is_sold, is_purchased,
        parent_item_id, variant_attributes)
      values (
        v_parent.org_id, v_code, v_name, v_parent.description,
        v_parent.item_type, v_parent.category_id,
        v_parent.uom_code, v_parent.classification_code,
        v_parent.unit_price, v_parent.cost_price, v_parent.min_price,
        v_parent.currency, v_parent.sales_tax_code_id,
        v_parent.purchase_tax_code_id, v_parent.sales_account_id,
        v_parent.purchase_account_id, v_parent.inventory_account_id,
        v_parent.cogs_account_id, v_parent.track_inventory,
        v_parent.costing_method, v_parent.preferred_supplier_id,
        true, true, v_parent.is_purchased,
        p_parent, v_combo)
      returning id into v_id;
      v_new := true;
    else
      v_new := false;
    end if;

    item_id := v_id;
    code := v_code;
    name := v_name;
    attributes := v_combo;
    created := v_new;
    return next;
  end loop;

  -- Last, because the guard above refuses a sellable style and the
  -- children have to exist before that is true.
  update public.items i
     set is_sold = false, track_inventory = false
   where i.id = p_parent;
end;
$$;

revoke all on function public.create_item_variants(uuid, jsonb) from public, anon;
grant execute on function public.create_item_variants(uuid, jsonb) to authenticated;

-- The grid a variant picker draws, read back out of the variants that
-- exist rather than out of a second copy of the same fact.
create or replace function public.item_variant_matrix(p_parent uuid)
returns table (axis text, axis_values text[])
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select a.key, array_agg(distinct a.value order by a.value)
    from public.items i
    cross join lateral jsonb_each_text(i.variant_attributes) a
   where i.parent_item_id = p_parent
     and i.deleted_at is null
     and app.can_read_module(
           (select p.org_id from public.items p where p.id = p_parent), 'inventory')
   group by a.key
   order by a.key;
$$;

grant execute on function public.item_variant_matrix(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Every label that resolves to this item
-- ---------------------------------------------------------------------
create table if not exists public.item_barcodes (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations (id) on delete cascade,
  item_id       uuid not null references public.items (id) on delete cascade,
  barcode       text not null check (btrim(barcode) <> ''),

  -- What one scan of this label means. A carton of six scans as six.
  uom_code      text references public.ref_uom_codes (code),
  pack_quantity numeric(18, 4) not null default 1 check (pack_quantity > 0),

  label         text,
  is_primary    boolean not null default false,
  created_at    timestamptz not null default now(),

  -- The point of the table. A scan that could mean two items is not a
  -- scan, it is a question, and a till has nobody to ask.
  unique (org_id, barcode)
);

create unique index if not exists item_barcodes_one_primary
  on public.item_barcodes (item_id) where is_primary;
create index if not exists item_barcodes_item_idx
  on public.item_barcodes (item_id);

comment on table public.item_barcodes is
  'Every label that resolves to an item, with what one scan of it means. Unique per organization, because a scan must not be ambiguous.';

-- Carry across what 0003 already holds. Duplicates are skipped rather
-- than merged: a shop with one barcode on two items has a problem that
-- the scanner would find eventually, and `items.barcode` is left intact
-- so nothing is lost while they sort it out.
insert into public.item_barcodes (org_id, item_id, barcode, uom_code, pack_quantity, is_primary)
select i.org_id, i.id, btrim(i.barcode), i.uom_code, 1, true
  from public.items i
 where nullif(btrim(i.barcode), '') is not null
   and i.deleted_at is null
on conflict (org_id, barcode) do nothing;

alter table public.item_barcodes enable row level security;

-- Gated on the same module as `items` itself: a barcode is a label on
-- an item, and access to one that outlived access to the other would be
-- a hole shaped exactly like the item list.
create policy item_barcodes_read on public.item_barcodes for select
  to authenticated using (app.can_read_module(org_id, 'inventory'));
create policy item_barcodes_write on public.item_barcodes for all
  to authenticated using (app.can_write_module(org_id, 'inventory'))
  with check (app.can_write_module(org_id, 'inventory'));

grant select, insert, update, delete on public.item_barcodes to authenticated;

-- ---------------------------------------------------------------------
-- What the scanner found
-- ---------------------------------------------------------------------
--
-- Four ways in, in the order a counter actually uses them: the gun, the
-- old single barcode column, the shop's own item code typed in, and
-- finally the name for when the label is missing and somebody is
-- squinting at a tablet.
--
-- `matched_on = 'barcode'` with exactly one row is the case the till
-- can act on without asking: add `quantity` of `item_id` and move on.
-- Everything else is a list for a human to choose from.
create or replace function public.pos_lookup_item(
  p_outlet uuid,
  p_code   text)
returns table (
  item_id    uuid,
  code       text,
  name       text,
  quantity   numeric,
  unit_price numeric,
  uom_code   text,
  variant_attributes jsonb,
  on_hand    numeric,
  matched_on text)
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
  needle as (select btrim(coalesce(p_code, '')) as t),
  hits as (
    select b.item_id, b.pack_quantity as quantity, 1 as rank, 'barcode'::text as matched_on
      from public.item_barcodes b, outlet o, needle n
     where b.org_id = o.org_id and b.barcode = n.t
    union all
    select i.id, 1, 2, 'barcode'
      from public.items i, outlet o, needle n
     where i.org_id = o.org_id and btrim(i.barcode) = n.t
    union all
    select i.id, 1, 3, 'code'
      from public.items i, outlet o, needle n
     where i.org_id = o.org_id and upper(i.code) = upper(n.t)
    union all
    select i.id, 1, 4, 'name'
      from public.items i, outlet o, needle n
     where i.org_id = o.org_id and length(n.t) >= 2
       and i.name ilike '%' || n.t || '%'
  ),
  best as (
    select h.item_id, min(h.rank) as rank,
           (array_agg(h.quantity order by h.rank))[1] as quantity,
           (array_agg(h.matched_on order by h.rank))[1] as matched_on
      from hits h group by h.item_id
  )
  select i.id, i.code, i.name, b.quantity, i.unit_price, i.uom_code,
         i.variant_attributes,
         coalesce((select sl.quantity from public.stock_levels sl
                    where sl.item_id = i.id
                      and sl.warehouse_id = (select o.warehouse_id from outlet o)), 0),
         b.matched_on
    from best b
    join public.items i on i.id = b.item_id
   where i.deleted_at is null
     and i.is_active
     and i.is_sold
   order by b.rank, i.code
   limit 50;
$$;

grant execute on function public.pos_lookup_item(uuid, text) to authenticated;

comment on function public.pos_lookup_item(uuid, text) is
  'Resolves a scan or a typed search to sellable items, with what one scan means and what is on the outlet shelf.';

-- A style has no size, so it cannot be rung up. The items guard already
-- clears `is_sold` on one, but a line can name an item directly and the
-- till is the place where that would cost somebody money.
create or replace function app.pos_sale_line_sellable()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if new.item_id is not null
     and exists (select 1 from public.items c
                  where c.parent_item_id = new.item_id and c.deleted_at is null) then
    raise exception
      'That is a style rather than a variant. Pick the size and colour.'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists pos_sale_line_sellable on public.pos_sale_lines;
create trigger pos_sale_line_sellable
  before insert or update on public.pos_sale_lines
  for each row execute function app.pos_sale_line_sellable();
