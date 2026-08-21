-- =====================================================================
-- Publish the menu, and let a phone order from it
--
-- Everything the till knows is behind a login. A customer sitting at
-- table seven with a phone in their hand cannot see the menu, cannot
-- see that the nasi lemak ran out an hour ago, and cannot order without
-- catching somebody's eye — which on a Saturday is the whole problem.
--
-- ---------------------------------------------------------------------
-- A token, and nothing else
--
-- The link is the only credential. `public_pos_menu`,
-- `public_pos_menu_modifiers` and `place_public_pos_order` are the only
-- functions in this module granted to `anon`, they take a token and
-- never an organization id, and they resolve everything from the link
-- row. Nothing else about the shop is reachable: the tables stay closed
-- to `anon` and the readers are SECURITY DEFINER with the token as the
-- only way in.
--
-- A sticker on a table is a token that never expires. The other kind —
-- the FeedMe guide calls it dynamic — is one printed on a bill with an
-- expiry, or a single-use link texted to somebody. Both are the same
-- row with `expires_at` and `single_use` filled in or not, because the
-- difference is a policy rather than a mechanism.
--
-- ---------------------------------------------------------------------
-- The guards a public endpoint needs
--
-- The order lands as a parked sale, exactly as if a waiter had rung it
-- up, and it needs an open shift to land in. A shop that has not
-- counted its float in is a shop that is closed, and "closed" is the
-- honest answer to a phone at seven in the morning.
--
-- Only what is on the published menu, and only what is available *now*:
-- 0258's scheduler and the sold-out list decide, so a customer cannot
-- order breakfast at four or a dish the kitchen took off at noon. The
-- price is the shop's, never the phone's — a price arriving from a
-- browser is a price somebody typed.
--
-- ---------------------------------------------------------------------
-- Internals, so there is one copy of the arithmetic
--
-- `open_pos_sale` and `add_pos_sale_line` both begin with a permission
-- check and continue with the part a public order needs verbatim: the
-- shift lookup, the document number, the tax split, the line number.
-- Rather than write a second copy that drifts, this migration splits
-- each into `app.*_internal` plus a thin guarded wrapper, and the
-- public path calls the internal. The arithmetic has one home and the
-- guard has another.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Opening a sale, without asking who is asking
-- ---------------------------------------------------------------------
create or replace function app.open_pos_sale_internal(
  p_register    uuid,
  p_contact     uuid default null,
  p_client_uuid uuid default null,
  p_sold_by     uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid; v_outlet uuid; v_shift uuid; v_sale uuid; v_no text;
begin
  select r.org_id, r.outlet_id into v_org, v_outlet
    from public.pos_registers r
   where r.id = p_register and r.deleted_at is null and r.is_active;
  if v_org is null then
    raise exception 'That register does not exist, or has been retired.'
      using errcode = 'P0002';
  end if;

  select s.id into v_shift from public.pos_shifts s
   where s.register_id = p_register and s.status <> 'closed';
  if v_shift is null then
    raise exception
      'No shift is open on this till. Count the float in before selling.'
      using errcode = '23514';
  end if;

  -- The till may have sent this before and not heard back. Hand the
  -- same sale back rather than starting a second basket, which is the
  -- whole reason the id is generated on the device.
  if p_client_uuid is not null then
    select s.id into v_sale from public.pos_sales s
     where s.org_id = v_org and s.client_uuid = p_client_uuid;
    if v_sale is not null then
      return v_sale;
    end if;
  end if;

  v_no := app.next_document_number_internal(v_org, 'pos_sale');

  insert into public.pos_sales
    (org_id, shift_id, register_id, outlet_id, sale_no, status,
     client_uuid, contact_id, sold_by)
  values
    (v_org, v_shift, p_register, v_outlet, v_no, 'parked',
     p_client_uuid, p_contact, p_sold_by)
  returning id into v_sale;

  return v_sale;
end;
$$;

revoke all on function app.open_pos_sale_internal(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;

comment on function app.open_pos_sale_internal(uuid, uuid, uuid, uuid) is
  'Opens a parked sale on a till with a shift on it. No permission check: the callers own that, and one of them is a customer with a phone rather than a member of staff.';

-- Replaced whole from 0209. What is left is the guard and the call;
-- everything the function used to do lives in the internal above, so a
-- public order and a cashier's tap produce the same row.
create or replace function public.open_pos_sale(
  p_register    uuid,
  p_contact     uuid default null,
  p_client_uuid uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select r.org_id into v_org from public.pos_registers r
   where r.id = p_register and r.deleted_at is null and r.is_active;
  if v_org is null then
    raise exception 'That register does not exist, or has been retired.'
      using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  return app.open_pos_sale_internal(
    p_register, p_contact, p_client_uuid, auth.uid());
end;
$$;

-- ---------------------------------------------------------------------
-- And a line on it
-- ---------------------------------------------------------------------
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

create or replace function public.add_pos_sale_line(
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
  v_org uuid;
begin
  select s.org_id into v_org from public.pos_sales s where s.id = p_sale;
  if v_org is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  return app.add_pos_sale_line_internal(
    p_sale, p_item, p_quantity, p_price, p_discount, p_note);
end;
$$;

-- ---------------------------------------------------------------------
-- And the questions the plate comes with
-- ---------------------------------------------------------------------
create or replace function app.add_line_modifier_internal(
  p_line     uuid,
  p_modifier uuid,
  p_quantity integer default 1)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line public.pos_sale_lines;
  v_stat app.pos_sale_status;
  v_mod  public.pos_modifiers;
  v_id   uuid;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;

  select s.status into v_stat from public.pos_sales s where s.id = v_line.sale_id;
  if v_stat <> 'parked' then
    raise exception 'That bill is % and cannot be changed.', v_stat
      using errcode = '23514';
  end if;
  if coalesce(p_quantity, 0) <= 0 then
    raise exception 'A modifier needs a quantity.' using errcode = '23514';
  end if;

  select * into v_mod from public.pos_modifiers where id = p_modifier;
  if v_mod.id is null or v_mod.org_id <> v_line.org_id then
    raise exception 'That is not one of this company''s options.'
      using errcode = 'P0002';
  end if;
  if not v_mod.is_active then
    raise exception '% is off today.', v_mod.name using errcode = '23514';
  end if;

  -- The menu price, kept before the line's own price stops being it.
  if v_line.base_unit_price is null then
    update public.pos_sale_lines l
       set base_unit_price = l.unit_price where l.id = p_line;
  end if;

  -- Asked for twice is asked for twice: "extra cheese" and "extra
  -- cheese again" is two lots of cheese, not an error.
  insert into public.pos_sale_line_modifiers
    (org_id, line_id, modifier_id, group_id, name, price_delta, quantity)
  values (v_line.org_id, p_line, p_modifier, v_mod.group_id,
          v_mod.name, v_mod.price_delta, p_quantity)
  on conflict (line_id, modifier_id) do update
    set quantity = pos_sale_line_modifiers.quantity + excluded.quantity
  returning id into v_id;

  perform app.reprice_pos_line(p_line);
  return v_id;
end;
$$;

revoke all on function app.add_line_modifier_internal(uuid, uuid, integer)
  from public, anon, authenticated;

create or replace function public.add_line_modifier(
  p_line     uuid,
  p_modifier uuid,
  p_quantity integer default 1)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select l.org_id into v_org from public.pos_sale_lines l where l.id = p_line;
  if v_org is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  return app.add_line_modifier_internal(p_line, p_modifier, p_quantity);
end;
$$;

-- ---------------------------------------------------------------------
-- The published menu, and what it is for
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type t
                   join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'app' and t.typname = 'pos_menu_link_kind') then
    create type app.pos_menu_link_kind as enum (
      'table',     -- a sticker on table seven; the order joins that bill
      'takeaway',  -- a poster by the door; they collect it
      'delivery'   -- a link sent to somebody; it needs an address
    );
  end if;
end;
$$;

create table if not exists public.pos_menu_links (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  outlet_id  uuid not null references public.pos_outlets (id) on delete cascade,

  kind       app.pos_menu_link_kind not null default 'table',

  -- Only for a table sticker, and required for one: a QR on table seven
  -- that does not know it is table seven is a QR that sends food to the
  -- wrong party.
  table_id   uuid references public.pos_tables (id) on delete cascade,

  -- Which till the order lands on. Null means whichever one at this
  -- outlet has a shift open, which is what a shop with one counter
  -- wants and never has to think about.
  register_id uuid references public.pos_registers (id) on delete set null,

  -- The credential. Long enough that guessing is not a strategy.
  token      text not null unique
    default encode(gen_random_bytes(18), 'base64'),

  label      text,

  -- A sticker never expires. A link printed on a bill or texted to
  -- somebody does — and single_use closes it the moment it is used.
  -- The difference between a static and a dynamic QR is these two
  -- columns, because it is a policy rather than a mechanism.
  expires_at timestamptz,
  single_use boolean not null default false,
  used_at    timestamptz,

  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null,

  constraint pos_menu_links_table_ck check (
    (kind = 'table') = (table_id is not null))
);

create index if not exists pos_menu_links_outlet_idx
  on public.pos_menu_links (outlet_id) where is_active;
create index if not exists pos_menu_links_org_idx
  on public.pos_menu_links (org_id);

comment on table public.pos_menu_links is
  'A published menu, reachable by token and nothing else. A sticker on a table is a row with no expiry; a link texted to somebody is the same row with expires_at or single_use set.';
comment on column public.pos_menu_links.token is
  'The only credential a customer has. Every public function takes this and never an organization id.';

-- The order, and who placed it. A phone has no login and therefore no
-- contact record; a name to call out and a number to ring are what the
-- counter actually needs.
alter table public.pos_sales
  add column if not exists menu_link_id uuid
    references public.pos_menu_links (id) on delete set null,
  add column if not exists guest_name text,
  add column if not exists guest_phone text;

create index if not exists pos_sales_menu_link_idx
  on public.pos_sales (menu_link_id) where menu_link_id is not null;

comment on column public.pos_sales.menu_link_id is
  'The published menu this order came in through. Null for anything a member of staff rang up.';

-- ---------------------------------------------------------------------
-- Is this link still good?
-- ---------------------------------------------------------------------
--
-- One place decides, and every public function starts here. A refusal
-- is a sentence rather than an empty result, because the thing on the
-- other end is a person holding a phone.
create or replace function app.pos_menu_link(p_token text)
returns public.pos_menu_links
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_link public.pos_menu_links;
begin
  select * into v_link from public.pos_menu_links
   where token = coalesce(p_token, '');
  if v_link.id is null or not v_link.is_active then
    raise exception 'That menu link is not in use.' using errcode = 'P0002';
  end if;
  if v_link.expires_at is not null and v_link.expires_at < now() then
    raise exception 'That menu link has expired. Ask the counter for a new one.'
      using errcode = '23514';
  end if;
  if v_link.single_use and v_link.used_at is not null then
    raise exception 'That link has already been used.' using errcode = '23514';
  end if;
  return v_link;
end;
$$;

revoke all on function app.pos_menu_link(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- What a phone sees
-- ---------------------------------------------------------------------
--
-- The shop's own menu, with what is off right now marked as off. 0258
-- decides that, so breakfast disappears at eleven on the customer's
-- phone at the same moment it disappears from the till.
create or replace function public.public_pos_menu(p_token text)
returns table (
  outlet_name text,
  header      text,
  kind        app.pos_menu_link_kind,
  table_code  text,
  item_id     uuid,
  code        text,
  name        text,
  unit_price  numeric,
  category    text,
  available   boolean,
  off_reason  text)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_link public.pos_menu_links;
begin
  v_link := app.pos_menu_link(p_token);

  return query
  select o.name,
         o.receipt_header,
         v_link.kind,
         t.code,
         m.item_id, m.code, m.name, m.unit_price, m.category,
         m.available, m.off_reason
    from public.pos_outlets o
    left join public.pos_tables t on t.id = v_link.table_id
    -- Read as the shop rather than as the caller: the customer has no
    -- membership and never will, and the token is what stands in for
    -- one. The link decides which outlet's menu this is.
    cross join lateral (
      select i.id as item_id, i.code, i.name, i.unit_price,
             coalesce(c.name, 'Uncategorised') as category,
             app.pos_item_off(i.id, v_link.outlet_id) is null as available,
             app.pos_item_off(i.id, v_link.outlet_id) as off_reason
        from public.items i
        left join public.item_categories c on c.id = i.category_id
       where i.org_id = o.org_id
         and i.deleted_at is null
         and i.is_active
         and i.is_sold
    ) m
   where o.id = v_link.outlet_id
   order by m.category, m.name;
end;
$$;

revoke all on function public.public_pos_menu(text) from public;
grant execute on function public.public_pos_menu(text) to anon, authenticated;

comment on function public.public_pos_menu(text) is
  'The menu behind one published link. Takes a token and never an organization id; what the kitchen has taken off is marked off, so the phone and the till agree.';

-- ---------------------------------------------------------------------
-- And the questions each plate comes with
-- ---------------------------------------------------------------------
create or replace function public.public_pos_menu_modifiers(
  p_token text,
  p_item  uuid)
returns table (
  group_id    uuid,
  group_name  text,
  min_select  integer,
  max_select  integer,
  modifier_id uuid,
  name        text,
  price_delta numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_link public.pos_menu_links;
  v_org  uuid;
begin
  v_link := app.pos_menu_link(p_token);
  select o.org_id into v_org from public.pos_outlets o where o.id = v_link.outlet_id;

  return query
  select g.id, g.name, g.min_select, g.max_select, m.id, m.name, m.price_delta
    from public.item_modifier_groups img
    join public.pos_modifier_groups g on g.id = img.group_id and g.is_active
    left join public.pos_modifiers m on m.group_id = g.id and m.is_active
   where img.item_id = p_item
     -- The link's own company, so a token cannot be pointed at another
     -- shop's item id and read its options.
     and img.org_id = v_org
   order by img.sort_order, g.name, m.sort_order, m.name;
end;
$$;

revoke all on function public.public_pos_menu_modifiers(text, uuid) from public;
grant execute on function public.public_pos_menu_modifiers(text, uuid)
  to anon, authenticated;

-- ---------------------------------------------------------------------
-- Placing the order
-- ---------------------------------------------------------------------
--
-- The order lands as a parked sale on a real till, so everything the
-- rest of the module already does — the kitchen ticket, the floor plan,
-- the promotions, the receipt, the money — happens without knowing that
-- a phone put it there.
--
-- Three rules a public endpoint cannot do without:
--
--   * The price is the shop's. `p_items` carries an item and a
--     quantity and nothing else; a price arriving from a browser is a
--     price somebody typed.
--   * Only what is available now. 0258's scheduler and the sold-out
--     list decide, so nobody orders breakfast at four.
--   * Only into an open shift. A shop that has not counted its float in
--     is closed, and "closed" is the honest answer.
create or replace function public.place_public_pos_order(
  p_token   text,
  p_items   jsonb,
  p_name    text default null,
  p_phone   text default null,
  p_note    text default null,
  p_line1   text default null,
  p_line2   text default null,
  p_city    text default null,
  p_state   text default null,
  p_postcode text default null)
returns table (
  sale_id  uuid,
  sale_no  text,
  total    numeric,
  fee      numeric,
  blocked_reason text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_link   public.pos_menu_links;
  v_org    uuid;
  v_reg    uuid;
  v_sale   uuid;
  v_e      jsonb;
  v_item   uuid;
  v_qty    numeric;
  v_off    text;
  v_line   uuid;
  v_mod    jsonb;
  v_n      integer := 0;
  v_chan   app.pos_order_channel;
begin
  v_link := app.pos_menu_link(p_token);
  select o.org_id into v_org from public.pos_outlets o where o.id = v_link.outlet_id;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'There is nothing in this order.' using errcode = '23514';
  end if;

  -- The till the order lands on: the one the link names, else whichever
  -- one at this outlet has a shift open. A shop with one counter never
  -- has to think about this.
  select r.id into v_reg
    from public.pos_registers r
    join public.pos_shifts s on s.register_id = r.id and s.status <> 'closed'
   where r.outlet_id = v_link.outlet_id
     and r.is_active and r.deleted_at is null
     and (v_link.register_id is null or r.id = v_link.register_id)
   order by r.code
   limit 1;
  if v_reg is null then
    raise exception
      'The shop is not taking orders right now.' using errcode = '23514';
  end if;

  -- A delivery needs somewhere to go, before anything is written.
  if v_link.kind = 'delivery' and btrim(coalesce(p_line1, '')) = '' then
    raise exception 'A delivery needs an address.' using errcode = '23514';
  end if;

  -- A table sticker joins the bill already on that table, which is what
  -- 0213 made `seat_table` for: a second basket on one table is the
  -- oldest way to charge a party twice or not at all.
  if v_link.kind = 'table' then
    select s.id into v_sale from public.pos_sales s
     where s.table_id = v_link.table_id and s.status = 'parked'
     limit 1;
  end if;

  if v_sale is null then
    v_sale := app.open_pos_sale_internal(v_reg, null, null, null);
    if v_link.kind = 'table' then
      update public.pos_sales s set table_id = v_link.table_id where s.id = v_sale;
    end if;
  end if;

  v_chan := case v_link.kind
              when 'table' then 'dine_in'
              when 'delivery' then 'delivery'
              else 'takeaway' end::app.pos_order_channel;

  update public.pos_sales s
     set menu_link_id = v_link.id,
         guest_name = coalesce(nullif(btrim(coalesce(p_name, '')), ''), s.guest_name),
         guest_phone = coalesce(nullif(btrim(coalesce(p_phone, '')), ''), s.guest_phone),
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), s.note),
         -- Only when the outlet accepts it. 0229's rule holds for a
         -- phone exactly as it holds for a cashier.
         order_channel = case
           when exists (select 1 from public.pos_outlet_channels c
                         where c.outlet_id = v_link.outlet_id
                           and c.channel = v_chan and c.is_active)
           then v_chan else s.order_channel end,
         updated_at = now()
   where s.id = v_sale;

  -- --------------------------------------------------------------
  -- What was ordered
  -- --------------------------------------------------------------
  for v_e in select * from jsonb_array_elements(p_items) loop
    v_item := (v_e ->> 'item')::uuid;
    v_qty  := coalesce((v_e ->> 'quantity')::numeric, 1);

    if not exists (select 1 from public.items i
                    where i.id = v_item and i.org_id = v_org
                      and i.deleted_at is null and i.is_active and i.is_sold) then
      raise exception 'That is not on the menu.' using errcode = 'P0002';
    end if;

    -- The same test the till applies, at the moment the customer taps
    -- rather than at the moment the page was loaded. A menu left open
    -- on a phone since ten o'clock is a menu that is now wrong.
    v_off := app.pos_item_off(v_item, v_link.outlet_id);
    if v_off is not null then
      raise exception '%', v_off using errcode = '23514';
    end if;

    -- No price argument: the shop's own price, whatever the phone says.
    v_line := app.add_pos_sale_line_internal(
      v_sale, v_item, v_qty, null, 0, nullif(btrim(coalesce(v_e ->> 'note', '')), ''));
    v_n := v_n + 1;

    for v_mod in
      select * from jsonb_array_elements(coalesce(v_e -> 'modifiers', '[]'::jsonb))
    loop
      perform app.add_line_modifier_internal(
        v_line, (v_mod ->> 'modifier')::uuid,
        coalesce((v_mod ->> 'quantity')::integer, 1));
    end loop;
  end loop;

  if v_n = 0 then
    raise exception 'There is nothing in this order.' using errcode = '23514';
  end if;

  -- --------------------------------------------------------------
  -- Where it is going
  -- --------------------------------------------------------------
  if v_link.kind = 'delivery' then
    -- Through 0259's own function, so the zone, the fee and the
    -- minimum are decided in one place whoever took the address.
    perform public.set_pos_delivery(
      v_sale, btrim(p_line1),
      coalesce(nullif(btrim(coalesce(p_phone, '')), ''), 'not given'),
      p_line2, p_city, p_state, p_postcode, p_name, p_note);
  end if;

  -- The shop's own rules, applied to a basket a phone filled. A
  -- customer who qualifies for happy hour gets it without asking.
  perform app.refresh_pos_promotions(v_sale);
  perform app.recalc_pos_sale(v_sale);

  if v_link.single_use then
    update public.pos_menu_links l set used_at = now() where l.id = v_link.id;
  end if;

  sale_id := v_sale;
  select s.sale_no, s.total_amount, coalesce(s.delivery_fee, 0)
    into sale_no, total, fee
    from public.pos_sales s where s.id = v_sale;
  blocked_reason := app.pos_delivery_blocked(v_sale);
  return next;
end;
$$;

revoke all on function public.place_public_pos_order(
  text, jsonb, text, text, text, text, text, text, text, text) from public;
grant execute on function public.place_public_pos_order(
  text, jsonb, text, text, text, text, text, text, text, text)
  to anon, authenticated;

comment on function public.place_public_pos_order(
  text, jsonb, text, text, text, text, text, text, text, text) is
  'Places an order from a published menu. The price is the shop''s, the availability is checked at the moment of ordering, and it lands as a parked sale on a till with a shift open — so the kitchen, the floor plan and the money all work as if a waiter had rung it up.';

-- ---------------------------------------------------------------------
-- Keeping the links
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_menu_link(
  p_outlet   uuid,
  p_kind     app.pos_menu_link_kind default 'table',
  p_table    uuid default null,
  p_register uuid default null,
  p_label    text default null,
  p_expires  timestamptz default null,
  p_single   boolean default false,
  p_id       uuid default null,
  p_active   boolean default true)
returns table (id uuid, token text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
  v_id  uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;
  if p_kind = 'table' and p_table is null then
    raise exception
      'A table QR has to say which table. One that does not sends food '
      'to the wrong party.'
      using errcode = '23514';
  end if;
  if p_table is not null
     and not exists (select 1 from public.pos_tables t
                      where t.id = p_table and t.outlet_id = p_outlet) then
    raise exception 'That table is not in this outlet.' using errcode = '23514';
  end if;

  if p_id is null then
    insert into public.pos_menu_links
      (org_id, outlet_id, kind, table_id, register_id, label,
       expires_at, single_use, is_active, created_by)
    values
      (v_org, p_outlet, p_kind,
       case when p_kind = 'table' then p_table end,
       p_register, nullif(btrim(coalesce(p_label, '')), ''),
       p_expires, coalesce(p_single, false), coalesce(p_active, true), auth.uid())
    returning pos_menu_links.id into v_id;
  else
    update public.pos_menu_links l
       set kind = p_kind,
           table_id = case when p_kind = 'table' then p_table end,
           register_id = p_register,
           label = nullif(btrim(coalesce(p_label, '')), ''),
           expires_at = p_expires,
           single_use = coalesce(p_single, false),
           is_active = coalesce(p_active, true)
     where l.id = p_id and l.org_id = v_org
    returning l.id into v_id;
    if v_id is null then
      raise exception 'No such link.' using errcode = 'P0002';
    end if;
  end if;

  return query
  select l.id, l.token from public.pos_menu_links l where l.id = v_id;
end;
$$;

revoke all on function public.upsert_pos_menu_link(
  uuid, app.pos_menu_link_kind, uuid, uuid, text, timestamptz, boolean,
  uuid, boolean) from public, anon;
grant execute on function public.upsert_pos_menu_link(
  uuid, app.pos_menu_link_kind, uuid, uuid, text, timestamptz, boolean,
  uuid, boolean) to authenticated;

create or replace function public.retire_pos_menu_link(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org uuid;
begin
  select org_id into v_org from public.pos_menu_links where id = p_id;
  if v_org is null then
    raise exception 'No such link.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;
  -- Switched off rather than deleted: the orders that came in through
  -- it still name it, and a sticker somebody has to go and peel off is
  -- a sticker that should stop working the moment it is switched off.
  update public.pos_menu_links set is_active = false where id = p_id;
end;
$$;

revoke all on function public.retire_pos_menu_link(uuid) from public, anon;
grant execute on function public.retire_pos_menu_link(uuid) to authenticated;

create or replace function public.pos_menu_links_admin(p_org uuid)
returns table (
  id          uuid,
  outlet_id   uuid,
  outlet_name text,
  kind        app.pos_menu_link_kind,
  table_code  text,
  label       text,
  token       text,
  expires_at  timestamptz,
  single_use  boolean,
  used_at     timestamptz,
  is_active   boolean,
  orders      integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, l.outlet_id, o.name, l.kind, t.code, l.label, l.token,
         l.expires_at, l.single_use, l.used_at, l.is_active,
         (select count(*)::integer from public.pos_sales s
           where s.menu_link_id = l.id)
    from public.pos_menu_links l
    join public.pos_outlets o on o.id = l.outlet_id
    left join public.pos_tables t on t.id = l.table_id
   where l.org_id = p_org
     and app.can_read_module(p_org, 'pos')
   order by o.name, l.kind, t.code nulls first, l.label;
$$;

grant execute on function public.pos_menu_links_admin(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_menu_links enable row level security;

create policy pos_menu_links_read on public.pos_menu_links for select
  to authenticated using (app.can_read_module(org_id, 'pos'));

-- Staff only, and read only. A customer never touches this table: the
-- three public functions are SECURITY DEFINER and the token is the
-- whole of what they are given.
grant select on public.pos_menu_links to authenticated;
