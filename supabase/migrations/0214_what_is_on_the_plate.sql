-- "Nasi lemak, no cucumber, extra egg, kurang pedas."
--
-- ## A modifier changes the plate, not the bill
--
-- The obvious shape is a second line: "Nasi lemak 12.00" then "Extra
-- egg 1.50". It is wrong in two places at once. The kitchen gets a
-- docket with two unrelated items on it and has to work out that the
-- egg belongs to the nasi lemak; and the customer's bill shows two
-- things when they ordered one. Worse, removing the nasi lemak leaves
-- the egg behind.
--
-- A modifier belongs to a LINE. The line's price is the menu price plus
-- what was added to it, so one plate is one line at one price, and
-- taking the plate off takes its modifiers with it.
--
-- ## What is snapshotted, and why
--
-- The chosen modifier's name and price are copied onto the line. Menu
-- prices change -- often at the turn of a month, sometimes mid-service
-- -- and a bill printed at seven o'clock must not be re-priced by an
-- edit made at nine. This is the same rule `prepare_einvoice` follows
-- for the buyer's address: what was transmitted is frozen, whatever the
-- master record does afterwards.
--
-- ## Where the base price went
--
-- `pos_sale_lines.unit_price` is what the line costs, modifiers
-- included, because that is the number every other part of the system
-- already reads -- the invoice, the tax split, the receipt. That means
-- the menu price has to be kept somewhere or it is lost the first time
-- a modifier is added, so `base_unit_price` holds it.
--
-- It is null until a modifier touches the line, which is deliberate:
-- it means `add_pos_sale_line` did not have to be restated, and a line
-- with no modifiers carries no second copy of its own price.
--
-- ## What this does NOT enforce
--
-- "Choose at least one" is not checked here. A line is built one tap at
-- a time, and a rule that refused the line until the choice was made
-- would refuse every line at the moment it is created. The maximum IS
-- enforced, because exceeding it is always wrong; the minimum is
-- checked when the order is sent to the kitchen, which is the first
-- moment at which an unanswered question actually matters.

-- ---------------------------------------------------------------------
-- The questions, and their answers
-- ---------------------------------------------------------------------
create table if not exists public.pos_modifier_groups (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations (id) on delete cascade,
  code         text not null,
  name         text not null,

  -- "Choose one" is min 1 max 1. "Up to two sauces" is min 0 max 2.
  -- "Any extras you like" is min 0 and max null.
  min_select   integer not null default 0 check (min_select >= 0),
  max_select   integer check (max_select is null or max_select > 0),

  sort_order   integer not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (org_id, code),
  constraint pos_modifier_groups_range_ck
    check (max_select is null or max_select >= min_select)
);

create table if not exists public.pos_modifiers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  group_id    uuid not null references public.pos_modifier_groups (id) on delete cascade,
  code        text not null,
  name        text not null,

  -- Signed. "No cucumber" is zero, "extra egg" is positive, and a
  -- smaller portion at a lower price is negative -- which is why this
  -- is not a `check (>= 0)`.
  price_delta numeric(18, 4) not null default 0,

  is_default  boolean not null default false,
  sort_order  integer not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (group_id, code)
);

create index if not exists pos_modifiers_group_idx on public.pos_modifiers (group_id)
  where is_active;

-- Which questions get asked about which dish.
create table if not exists public.item_modifier_groups (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  item_id    uuid not null references public.items (id) on delete cascade,
  group_id   uuid not null references public.pos_modifier_groups (id) on delete cascade,
  sort_order integer not null default 0,
  unique (item_id, group_id)
);

create index if not exists item_modifier_groups_item_idx
  on public.item_modifier_groups (item_id);

-- ---------------------------------------------------------------------
-- What was actually asked for
-- ---------------------------------------------------------------------
create table if not exists public.pos_sale_line_modifiers (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  line_id     uuid not null references public.pos_sale_lines (id) on delete cascade,
  modifier_id uuid references public.pos_modifiers (id) on delete set null,
  group_id    uuid references public.pos_modifier_groups (id) on delete set null,

  -- Frozen at the moment of ordering. See the header: a bill printed at
  -- seven must not be re-priced by an edit made at nine.
  name        text not null,
  price_delta numeric(18, 4) not null default 0,
  quantity    integer not null default 1 check (quantity > 0),

  created_at  timestamptz not null default now(),
  unique (line_id, modifier_id)
);

create index if not exists pos_sale_line_modifiers_line_idx
  on public.pos_sale_line_modifiers (line_id);

alter table public.pos_sale_lines
  add column if not exists base_unit_price numeric(18, 4);

comment on column public.pos_sale_lines.base_unit_price is
  'The menu price before modifiers. Null until a modifier touches the line, so a plain line carries no second copy of its own price.';

-- ---------------------------------------------------------------------
-- The maximum, which is always wrong to exceed
-- ---------------------------------------------------------------------
create or replace function app.pos_modifier_max()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_max  integer;
  v_used integer;
  v_name text;
begin
  if new.group_id is null then
    return new;
  end if;
  select g.max_select, g.name into v_max, v_name
    from public.pos_modifier_groups g where g.id = new.group_id;
  if v_max is null then
    return new;
  end if;

  select coalesce(sum(m.quantity), 0) into v_used
    from public.pos_sale_line_modifiers m
   where m.line_id = new.line_id
     and m.group_id = new.group_id
     and m.id <> new.id;

  if v_used + new.quantity > v_max then
    raise exception '% takes at most %.', v_name, v_max using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists pos_modifier_max on public.pos_sale_line_modifiers;
create trigger pos_modifier_max
  before insert or update on public.pos_sale_line_modifiers
  for each row execute function app.pos_modifier_max();

-- ---------------------------------------------------------------------
-- Re-pricing one plate
-- ---------------------------------------------------------------------
--
-- The same split `add_pos_sale_line` performs, run again over a price
-- that has changed. Factored out here rather than duplicated, because
-- two copies of a tax split disagree eventually and the one that is
-- wrong is whichever nobody tested.
create or replace function app.reprice_pos_line(p_line uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line  public.pos_sale_lines;
  v_extra numeric;
  v_price numeric;
  v_gross numeric;
  v_net   numeric;
  v_tax   numeric;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    return;
  end if;

  select coalesce(sum(m.price_delta * m.quantity), 0) into v_extra
    from public.pos_sale_line_modifiers m where m.line_id = p_line;

  v_price := coalesce(v_line.base_unit_price, v_line.unit_price) + v_extra;

  v_gross := round(v_price * v_line.quantity, 2) - coalesce(v_line.discount_amount, 0);
  if v_line.is_tax_inclusive and v_line.tax_rate > 0 then
    v_net := round(v_gross / (1 + v_line.tax_rate / 100.0), 2);
    v_tax := round(v_gross - v_net, 2);
  else
    v_net := round(v_gross, 2);
    v_tax := round(v_net * v_line.tax_rate / 100.0, 2);
  end if;

  update public.pos_sale_lines l
     set unit_price = v_price,
         tax_amount = v_tax,
         line_subtotal = v_net,
         line_total = v_net + v_tax
   where l.id = p_line;

  perform app.recalc_pos_sale(v_line.sale_id);
end;
$$;

revoke all on function app.reprice_pos_line(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Adding one
-- ---------------------------------------------------------------------
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
  v_line public.pos_sale_lines;
  v_stat app.pos_sale_status;
  v_mod  public.pos_modifiers;
  v_id   uuid;
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_line.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
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

revoke all on function public.add_line_modifier(uuid, uuid, integer) from public, anon;
grant execute on function public.add_line_modifier(uuid, uuid, integer) to authenticated;

create or replace function public.remove_line_modifier(p_line_modifier uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row  public.pos_sale_line_modifiers;
  v_line uuid;
  v_stat app.pos_sale_status;
begin
  select * into v_row from public.pos_sale_line_modifiers where id = p_line_modifier;
  if v_row.id is null then
    return;
  end if;
  if not app.can_write_module(v_row.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select s.status into v_stat
    from public.pos_sale_lines l
    join public.pos_sales s on s.id = l.sale_id
   where l.id = v_row.line_id;
  if v_stat <> 'parked' then
    raise exception 'That bill is % and cannot be changed.', v_stat
      using errcode = '23514';
  end if;

  v_line := v_row.line_id;
  delete from public.pos_sale_line_modifiers where id = p_line_modifier;
  perform app.reprice_pos_line(v_line);
end;
$$;

revoke all on function public.remove_line_modifier(uuid) from public, anon;
grant execute on function public.remove_line_modifier(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Questions nobody has answered
-- ---------------------------------------------------------------------
--
-- Reported rather than refused, and reported per line, because the till
-- has to tell the waiter which plate it is still waiting on. 0215 uses
-- this to stop an order reaching the kitchen: "choose one" is not
-- something a cook can guess.
create or replace function public.pos_line_modifier_gaps(p_sale uuid)
returns table (
  line_id     uuid,
  line_no     integer,
  description text,
  group_name  text,
  needed      integer,
  chosen      integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select l.id, l.line_no, l.description, g.name, g.min_select,
         coalesce((select sum(m.quantity)::integer
                     from public.pos_sale_line_modifiers m
                    where m.line_id = l.id and m.group_id = g.id), 0)
    from public.pos_sale_lines l
    join public.item_modifier_groups img on img.item_id = l.item_id
    join public.pos_modifier_groups g
      on g.id = img.group_id and g.is_active
   where l.sale_id = p_sale
     and g.min_select > 0
     and app.can_read_module(l.org_id, 'pos')
     and coalesce((select sum(m.quantity)::integer
                     from public.pos_sale_line_modifiers m
                    where m.line_id = l.id and m.group_id = g.id), 0) < g.min_select
   order by l.line_no, g.sort_order, g.name;
$$;

grant execute on function public.pos_line_modifier_gaps(uuid) to authenticated;

comment on function public.pos_line_modifier_gaps(uuid) is
  'Required choices nobody has made yet, per line. A cook cannot guess "choose one", so an order with gaps does not go to the kitchen.';

-- The menu, as a screen has to draw it: what can be asked about a dish.
create or replace function public.item_modifier_options(p_item uuid)
returns table (
  group_id    uuid,
  group_name  text,
  min_select  integer,
  max_select  integer,
  modifier_id uuid,
  name        text,
  price_delta numeric,
  is_default  boolean)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select g.id, g.name, g.min_select, g.max_select,
         m.id, m.name, m.price_delta, m.is_default
    from public.item_modifier_groups img
    join public.pos_modifier_groups g on g.id = img.group_id and g.is_active
    left join public.pos_modifiers m on m.group_id = g.id and m.is_active
   where img.item_id = p_item
     and app.can_read_module(img.org_id, 'pos')
   order by img.sort_order, g.name, m.sort_order, m.name;
$$;

grant execute on function public.item_modifier_options(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_modifier_groups     enable row level security;
alter table public.pos_modifiers           enable row level security;
alter table public.item_modifier_groups    enable row level security;
alter table public.pos_sale_line_modifiers enable row level security;

create policy pos_modifier_groups_read on public.pos_modifier_groups for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_modifier_groups_write on public.pos_modifier_groups for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy pos_modifiers_read on public.pos_modifiers for select
  using (app.can_read_module(org_id, 'pos'));
create policy pos_modifiers_write on public.pos_modifiers for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

create policy item_modifier_groups_read on public.item_modifier_groups for select
  using (app.can_read_module(org_id, 'pos'));
create policy item_modifier_groups_write on public.item_modifier_groups for all
  using (app.can_write_module(org_id, 'pos'))
  with check (app.can_write_module(org_id, 'pos'));

-- Read only, like the line it hangs off: what was ordered is written by
-- the functions that re-price the plate, and a client that could insert
-- its own modifier could add an extra egg for nothing.
create policy pos_sale_line_modifiers_read on public.pos_sale_line_modifiers for select
  using (app.can_read_module(org_id, 'pos'));

grant select, insert, update, delete on public.pos_modifier_groups to authenticated;
grant select, insert, update, delete on public.pos_modifiers to authenticated;
grant select, insert, update, delete on public.item_modifier_groups to authenticated;
grant select on public.pos_sale_line_modifiers to authenticated;

create trigger set_updated_at before update on public.pos_modifier_groups
  for each row execute function app.set_updated_at();
