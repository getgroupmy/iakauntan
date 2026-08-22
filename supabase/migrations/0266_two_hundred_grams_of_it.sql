-- =====================================================================
-- Two hundred grams of it, and the label the scale printed
--
-- Every item this system sells is sold in whole numbers of something.
-- `pos_sale_lines.quantity` is numeric and always has been, so half a
-- kilogram would go in — but nothing produces one. The till adds 1, the
-- grid tile adds 1, and a scan adds whatever the barcode's pack
-- quantity says, which is also a whole number. A deli, a fishmonger, a
-- grocer with a rice bin and any of the thousands of Malaysian shops
-- that sell kuih by weight cannot ring up a sale at all.
--
-- Two halves, and the shop will have one or the other:
--
--   * a counter scale that prints a label. The scanner reads it as an
--     ordinary EAN-13 and the digits carry the item and its weight.
--     Nothing on the counter changes: the gun beeps and the right
--     0.246 kg lands on the bill.
--
--   * no scale at all. Somebody taps the item and types what the
--     hanging scale says.
--
-- ---------------------------------------------------------------------
-- A scale label is a barcode with a number hidden in it
--
-- GS1 reserves the prefixes 02 and 20-29 for in-store use, and every
-- scale manufacturer lays the rest out slightly differently: two digits
-- of prefix or one, four digits of PLU or five, five digits of weight
-- in grams or of price in sen. There is no standard to hard-code, so
-- the layout is a row a shop fills in once — `scale_barcode_formats` —
-- and the parser is driven by it.
--
-- The check digit is verified, not skipped. A scanner reporting a
-- misread label is rare and a shop would never notice: the wrong five
-- digits are still five digits, and the customer is charged for a
-- plausible weight of the right item. Verifying costs one modulus and
-- turns a silent overcharge into a beep that fails.
--
-- ---------------------------------------------------------------------
-- What the sticker says is what the customer pays
--
-- A price-embedded label carries the ringgit rather than the grams,
-- because the scale did the multiplication at the counter. The weight
-- is then derived, and the derived weight times today's unit price
-- almost never comes back to the sen the sticker shows — the scale
-- rounded, and it rounded an hour ago at a price that may since have
-- changed.
--
-- The sticker wins. It is a price the shop printed, put on a package,
-- and handed to a customer, and a till that charges two sen more than
-- the label is a till that argues with people at the counter. So the
-- line takes the label's total, and its unit price is worked back from
-- it. That is asserted, because it is the one place this feature can
-- quietly overcharge.
--
-- ---------------------------------------------------------------------
-- Weighed in a unit that has weight
--
-- "Sold by weight, priced per unit" is not a thing. `is_weighed` is
-- refused unless the item's own unit measures something — 0264's
-- `ref_uom_factors` with a dimension of weight, volume or length. A
-- piece and a box have no dimension at all; a "unit" has the dimension
-- `quantity`, which is the one that looks like it would work and does
-- not. The whole feature is a quantity with a fraction in it, and a
-- third of a piece is not a thing anybody can hand over.
-- =====================================================================

-- ---------------------------------------------------------------------
-- What the shop sells by weight, and what its scale calls it
-- ---------------------------------------------------------------------
alter table public.items
  add column if not exists is_weighed boolean not null default false,
  add column if not exists scale_plu  text;

create unique index if not exists items_scale_plu_idx
  on public.items (org_id, scale_plu)
  where scale_plu is not null and deleted_at is null;

comment on column public.items.is_weighed is
  'Sold by weight rather than by the piece. Its unit price is per its own unit of measure, which must be one with a dimension -- a third of a box is not a quantity anybody can hand over.';
comment on column public.items.scale_plu is
  'The number the counter scale knows this item by, which its printed label carries. Unique per company: a label that could mean two things is not a label.';

-- ---------------------------------------------------------------------
-- How this shop's scale lays a label out
-- ---------------------------------------------------------------------
do $$ begin
  create type app.scale_value_kind as enum
    ('weight_grams', 'weight_kg_3dp', 'price_sen');
exception when duplicate_object then null; end $$;

create table public.scale_barcode_formats (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id)
                 on delete cascade,
  name         text not null,

  -- The digits every label from this scale starts with. GS1 reserves
  -- 02 and 20-29 for exactly this, and a shop with two scales may have
  -- one on 20 and one on 21.
  prefix       text not null check (prefix ~ '^[0-9]{1,3}$'),

  -- How many digits carry the item, and how many carry the number.
  code_digits  integer not null check (code_digits between 1 and 8),
  value_digits integer not null check (value_digits between 1 and 8),

  value_kind   app.scale_value_kind not null,

  -- Whether the last digit is an EAN check digit rather than data.
  -- Almost always yes; a few older scales print twelve digits and no
  -- check.
  has_check_digit boolean not null default true,

  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (org_id, prefix)
);

create index scale_barcode_formats_org_idx
  on public.scale_barcode_formats (org_id) where is_active;

-- ---------------------------------------------------------------------
-- The check digit
-- ---------------------------------------------------------------------
--
-- GS1's modulo 10: every digit but the last, weighted 1 and 3 from the
-- right, summed, and the check is what takes that sum up to a multiple
-- of ten. Written from the right rather than the left because that is
-- how the standard defines it and because it then works unchanged for
-- EAN-8, EAN-13 and a twelve-digit UPC.
create or replace function app.ean_check_digit(p_digits text)
returns integer
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_sum integer := 0;
  v_i   integer;
  v_n   integer := length(p_digits);
begin
  if p_digits is null or p_digits !~ '^[0-9]+$' then
    return null;
  end if;
  for v_i in 1 .. v_n loop
    -- Rightmost body digit carries weight 3.
    v_sum := v_sum + substr(p_digits, v_n - v_i + 1, 1)::integer
                     * case when v_i % 2 = 1 then 3 else 1 end;
  end loop;
  return (10 - (v_sum % 10)) % 10;
end;
$$;

revoke all on function app.ean_check_digit(text) from public, anon;
grant execute on function app.ean_check_digit(text) to authenticated;

comment on function app.ean_check_digit(text) is
  'The GS1 modulo 10 check digit for a barcode body. Weighted from the right, so it is the same arithmetic for EAN-8, UPC-A and EAN-13.';

-- ---------------------------------------------------------------------
-- Reading one
-- ---------------------------------------------------------------------
--
-- Returns nothing at all rather than raising when the code is not a
-- scale label. It is called on every scan, and most scans are a tin of
-- Milo.
create or replace function app.parse_scale_barcode(
  p_org  uuid,
  p_code text)
returns table (
  item_id    uuid,
  quantity   numeric,
  unit_price numeric,
  value_kind app.scale_value_kind)
language plpgsql
stable
set search_path = public, app, pg_temp
as $$
declare
  v_code  text := btrim(coalesce(p_code, ''));
  v_f     record;
  v_body  text;
  v_plu   text;
  v_raw   text;
  v_val   numeric;
  v_item  public.items;
  v_qty   numeric;
  v_price numeric;
begin
  if v_code !~ '^[0-9]+$' then
    return;
  end if;

  for v_f in
    select * from public.scale_barcode_formats f
     where f.org_id = p_org and f.is_active
     order by length(f.prefix) desc, f.prefix
  loop
    if left(v_code, length(v_f.prefix)) <> v_f.prefix then
      continue;
    end if;

    -- Everything but the check digit, when there is one.
    v_body := case when v_f.has_check_digit
                   then left(v_code, length(v_code) - 1)
                   else v_code end;

    if length(v_body) <> length(v_f.prefix) + v_f.code_digits + v_f.value_digits then
      continue;
    end if;

    if v_f.has_check_digit then
      if right(v_code, 1)::integer is distinct from app.ean_check_digit(v_body) then
        -- A misread label. Silence rather than a wrong weight: the
        -- caller finds nothing, the gun does not beep its success, and
        -- somebody scans it again.
        continue;
      end if;
    end if;

    v_plu := substr(v_body, length(v_f.prefix) + 1, v_f.code_digits);
    v_raw := substr(v_body, length(v_f.prefix) + v_f.code_digits + 1, v_f.value_digits);
    v_val := v_raw::numeric;

    select * into v_item from public.items i
     where i.org_id = p_org and i.scale_plu = v_plu
       and i.deleted_at is null and i.is_active and i.is_sold;
    -- Leading zeros are a layout choice, not part of the number a shop
    -- typed on its scale.
    if v_item.id is null then
      select * into v_item from public.items i
       where i.org_id = p_org and i.scale_plu = ltrim(v_plu, '0')
         and i.deleted_at is null and i.is_active and i.is_sold;
    end if;
    if v_item.id is null then
      continue;
    end if;

    if v_f.value_kind = 'weight_grams' then
      -- Grams into the item's own unit, by 0264's conversion rather
      -- than by assuming the shop stocks in kilograms.
      v_qty   := round(app.uom_qty(v_item.id, v_val, 'GRM'), 6);
      v_price := v_item.unit_price;
    elsif v_f.value_kind = 'weight_kg_3dp' then
      v_qty   := round(app.uom_qty(v_item.id, v_val / 1000.0, 'KGM'), 6);
      v_price := v_item.unit_price;
    else
      -- See the header: the sticker is the offer. The weight is
      -- derived for the record, and the unit price is worked back so
      -- the line comes to exactly what the customer was shown.
      v_val := round(v_val / 100.0, 2);
      if coalesce(v_item.unit_price, 0) <= 0 then
        continue;
      end if;
      v_qty := round(v_val / v_item.unit_price, 3);
      if v_qty <= 0 then
        continue;
      end if;
      v_price := round(v_val / v_qty, 6);
    end if;

    if v_qty <= 0 then
      continue;
    end if;

    item_id    := v_item.id;
    quantity   := v_qty;
    unit_price := v_price;
    value_kind := v_f.value_kind;
    return next;
    return;
  end loop;
end;
$$;

revoke all on function app.parse_scale_barcode(uuid, text) from public, anon;
grant execute on function app.parse_scale_barcode(uuid, text) to authenticated;

comment on function app.parse_scale_barcode(uuid, text) is
  'Reads a counter scale''s printed label into an item and a weight, by the layout this company said its scale uses. Returns nothing when the code is not one, because it is asked about every scan.';

-- ---------------------------------------------------------------------
-- And the scan, which now has a fifth way in
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0211 for two columns and one branch. The scale
-- label is tried first and, when it matches, is the only answer: it
-- already names the item and the weight, and offering a list beside it
-- would be offering a choice between an answer and some guesses.
--
-- `matched_on = 'scale'` is deliberately distinct from `'barcode'`. The
-- till acts on both without asking, but a shop reading its own logs
-- should be able to tell the gun from the scale, and a screen that
-- wants to show "0.246 kg" rather than "1" needs to know which it got.
--
-- Dropped first: two new OUT parameters is a changed return type, and
-- Postgres refuses to replace through that (42P13). The drop takes the
-- grant with it.
drop function if exists public.pos_lookup_item(uuid, text);

create function public.pos_lookup_item(
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
  is_weighed boolean,
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
  scale as (
    select s.item_id, s.quantity, s.unit_price
      from outlet o, needle n,
           lateral app.parse_scale_barcode(o.org_id, n.t) s
  ),
  hits as (
    select b.item_id, b.pack_quantity as quantity, 1 as rank,
           'barcode'::text as matched_on
      from public.item_barcodes b, outlet o, needle n
     where b.org_id = o.org_id and b.barcode = n.t
       and not exists (select 1 from scale)
    union all
    select i.id, 1, 2, 'barcode'
      from public.items i, outlet o, needle n
     where i.org_id = o.org_id and btrim(i.barcode) = n.t
       and not exists (select 1 from scale)
    union all
    select i.id, 1, 3, 'code'
      from public.items i, outlet o, needle n
     where i.org_id = o.org_id and upper(i.code) = upper(n.t)
       and not exists (select 1 from scale)
    union all
    select i.id, 1, 4, 'name'
      from public.items i, outlet o, needle n
     where i.org_id = o.org_id and length(n.t) >= 2
       and i.name ilike '%' || n.t || '%'
       and not exists (select 1 from scale)
  ),
  best as (
    select h.item_id, min(h.rank) as rank,
           (array_agg(h.quantity order by h.rank))[1] as quantity,
           (array_agg(h.matched_on order by h.rank))[1] as matched_on
      from hits h group by h.item_id
    union all
    select s.item_id, 0, s.quantity, 'scale' from scale s
  )
  select i.id, i.code, i.name, b.quantity,
         -- The price the label was printed at, when it carried one.
         coalesce((select s.unit_price from scale s where s.item_id = i.id),
                  i.unit_price),
         i.uom_code, i.variant_attributes,
         coalesce((select sl.quantity from public.stock_levels sl
                    where sl.item_id = i.id
                      and sl.warehouse_id = (select o.warehouse_id from outlet o)), 0),
         i.is_weighed,
         b.matched_on
    from best b
    join public.items i on i.id = b.item_id
   where i.deleted_at is null
     and i.is_active
     and i.is_sold
   order by b.rank, i.code
   limit 50;
$$;

revoke all on function public.pos_lookup_item(uuid, text) from public, anon;
grant execute on function public.pos_lookup_item(uuid, text) to authenticated;

comment on function public.pos_lookup_item(uuid, text) is
  'Resolves a scan or a typed search to sellable items. A counter scale''s label is read first and answers on its own, carrying the weight it printed and the price it printed it at.';

-- ---------------------------------------------------------------------
-- And the grid, which has to ask
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0264 for one column. A weighed item tapped on the
-- grid is not one of anything, and the screen needs to know to ask
-- before it adds a line.
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
  is_weighed  boolean,
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
         i.is_weighed,
         m.portions,
         app.pos_item_off(i.id, p_outlet) is null
           and (not coalesce((select b.on from blocking b), false)
                or m.portions is null or m.portions > 0),
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
  'Everything an outlet can sell, with whether it is offered right now, why not, how many more the kitchen can make, and whether it is sold by weight.';

-- ---------------------------------------------------------------------
-- Saying that something is sold by weight
-- ---------------------------------------------------------------------
create or replace function public.set_item_weighed(
  p_item     uuid,
  p_weighed  boolean,
  p_plu      text default null)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org  uuid;
  v_uom  text;
  v_name text;
begin
  select i.org_id, i.uom_code, i.name into v_org, v_uom, v_name
    from public.items i where i.id = p_item and i.deleted_at is null;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'inventory') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;

  -- See the header. A third of a box is not a quantity, and neither is
  -- a third of a piece: `quantity` is a dimension in 0264's table too,
  -- and it is exactly the one this refuses.
  if p_weighed and not exists (select 1 from public.ref_uom_factors f
                                where f.code = v_uom
                                  and f.dimension <> 'quantity') then
    raise exception
      '% is counted in %, which is a thing rather than an amount. Sold '
      'by weight needs a unit that measures something -- a kilogram, a '
      'litre, a metre.', v_name, v_uom
      using errcode = '23514';
  end if;

  update public.items i
     set is_weighed = coalesce(p_weighed, false),
         scale_plu  = nullif(btrim(coalesce(p_plu, '')), ''),
         updated_at = now()
   where i.id = p_item;
  return true;
end;
$$;

revoke all on function public.set_item_weighed(uuid, boolean, text)
  from public, anon;
grant execute on function public.set_item_weighed(uuid, boolean, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the layout its scale prints
-- ---------------------------------------------------------------------
create or replace function public.upsert_scale_format(
  p_id     uuid,
  p_org    uuid,
  p_name   text,
  p_prefix text,
  p_code_digits integer,
  p_value_digits integer,
  p_kind   app.scale_value_kind,
  p_check  boolean default true,
  p_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid := p_id;
begin
  if not app.can_write_module(p_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'Give the scale a name.' using errcode = '23514';
  end if;
  if btrim(coalesce(p_prefix, '')) !~ '^[0-9]{1,3}$' then
    raise exception
      'A prefix is the one to three digits every label from this scale '
      'starts with. GS1 keeps 02 and 20 to 29 free for exactly this.'
      using errcode = '23514';
  end if;
  -- The whole label has to be a length a scanner produces. Twelve or
  -- thirteen with a check digit, eight for the short ones.
  if length(btrim(p_prefix)) + p_code_digits + p_value_digits
       + (case when coalesce(p_check, true) then 1 else 0 end)
     not in (8, 12, 13) then
    raise exception
      'Those add up to % digits, which is not a barcode. A scale prints '
      '8, 12 or 13.',
      length(btrim(p_prefix)) + p_code_digits + p_value_digits
        + (case when coalesce(p_check, true) then 1 else 0 end)
      using errcode = '23514';
  end if;

  if v_id is null then
    insert into public.scale_barcode_formats (
      org_id, name, prefix, code_digits, value_digits, value_kind,
      has_check_digit, is_active)
    values (
      p_org, btrim(p_name), btrim(p_prefix), p_code_digits, p_value_digits,
      p_kind, coalesce(p_check, true), coalesce(p_active, true))
    returning id into v_id;
  else
    update public.scale_barcode_formats f
       set name = btrim(p_name), prefix = btrim(p_prefix),
           code_digits = p_code_digits, value_digits = p_value_digits,
           value_kind = p_kind, has_check_digit = coalesce(p_check, true),
           is_active = coalesce(p_active, true), updated_at = now()
     where f.id = v_id and f.org_id = p_org;
    if not found then
      raise exception 'No such scale.' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;

revoke all on function public.upsert_scale_format(
  uuid, uuid, text, text, integer, integer, app.scale_value_kind,
  boolean, boolean) from public, anon;
grant execute on function public.upsert_scale_format(
  uuid, uuid, text, text, integer, integer, app.scale_value_kind,
  boolean, boolean) to authenticated;

create or replace function public.delete_scale_format(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select f.org_id into v_org from public.scale_barcode_formats f where f.id = p_id;
  if v_org is null then
    return false;
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  delete from public.scale_barcode_formats f where f.id = p_id;
  return true;
end;
$$;

revoke all on function public.delete_scale_format(uuid) from public, anon;
grant execute on function public.delete_scale_format(uuid) to authenticated;

create or replace function public.scale_formats_list(p_org uuid)
returns table (
  id           uuid,
  name         text,
  prefix       text,
  code_digits  integer,
  value_digits integer,
  value_kind   app.scale_value_kind,
  has_check_digit boolean,
  is_active    boolean,
  total_digits integer)
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
  select f.id, f.name, f.prefix, f.code_digits, f.value_digits,
         f.value_kind, f.has_check_digit, f.is_active,
         (length(f.prefix) + f.code_digits + f.value_digits
            + case when f.has_check_digit then 1 else 0 end)::integer
    from public.scale_barcode_formats f
   where f.org_id = p_org
   order by f.prefix;
end;
$$;

revoke all on function public.scale_formats_list(uuid) from public, anon;
grant execute on function public.scale_formats_list(uuid) to authenticated;

-- Everything this shop sells by weight, and what its scale calls it.
create or replace function public.weighed_items(p_org uuid)
returns table (
  item_id    uuid,
  code       text,
  name       text,
  scale_plu  text,
  uom_code   text,
  unit_price numeric,
  on_hand    numeric)
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
  select i.id, i.code, i.name, i.scale_plu, i.uom_code, i.unit_price,
         i.quantity_on_hand
    from public.items i
   where i.org_id = p_org and i.deleted_at is null and i.is_weighed
   order by i.name;
end;
$$;

revoke all on function public.weighed_items(uuid) from public, anon;
grant execute on function public.weighed_items(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.scale_barcode_formats enable row level security;

create policy scale_barcode_formats_read on public.scale_barcode_formats
  for select to authenticated using (app.can_read_module(org_id, 'pos'));

-- No write policy: the digit-count rule that keeps a format readable
-- lives in `upsert_scale_format`, and a row written round it would be a
-- scale that silently never matches.

revoke all on public.scale_barcode_formats from anon, authenticated;
grant select on public.scale_barcode_formats to authenticated;

create trigger set_updated_at before update on public.scale_barcode_formats
  for each row execute function app.set_updated_at();
