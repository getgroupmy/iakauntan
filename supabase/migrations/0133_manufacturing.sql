-- =====================================================================
-- iAkauntan :: manufacturing
--
-- What a thing is made of, whether the parts are there, and what it
-- actually cost. That is the floor everything else in an MRP suite
-- stands on — scheduling, shop floor, quality, maintenance — and it is
-- the part an accounting system has to get right, because a
-- manufacturing order is not a note about work: it moves stock and it
-- moves money.
--
-- ---------------------------------------------------------------------
-- What a manufacturing order does to the books
--
-- Three things happen when one is posted, and they have to happen
-- together or the inventory and the ledger stop agreeing:
--
--   components leave stock, valued at the weighted average they are
--     carried at — not at what they cost when bought, which is a
--     different number and the wrong one;
--   conversion cost is absorbed, being the time booked to each work
--     centre at that work centre's rate;
--   the finished item enters stock at components + conversion, which is
--     what it cost to make and therefore what it is worth.
--
-- The ledger entry mirrors it exactly: inventory rises by the finished
-- value, falls by the components, and the difference is credited to
-- `Manufacturing Cost Absorbed`. That last account is why the labour is
-- not counted twice — the wages were already an expense when they were
-- paid, and absorbing them into stock has to take them back out of the
-- profit and loss, not add a second copy.
--
-- ---------------------------------------------------------------------
-- What this is not
--
-- Not scheduling: there is a planned start and finish on an order and
-- nothing that solves for finite capacity, so a work centre can be
-- promised to two orders at once and nothing will say so. Not a shop
-- floor terminal, not quality control points, not maintenance, not
-- product lifecycle. Each is its own piece of work and each needs this
-- one first. Written down here rather than discovered later.
-- =====================================================================

create type app.mo_status as enum
  ('draft', 'confirmed', 'in_progress', 'done', 'cancelled');

-- A manufacturing order is its own kind of journal, not a stock
-- movement and not a manual entry. Added before the function that names
-- it: the literal is resolved when that function runs, which is after
-- this migration has committed.
alter type app.journal_source add value if not exists 'manufacturing';

-- ---------------------------------------------------------------------
-- What a thing is made of
-- ---------------------------------------------------------------------
create table public.bills_of_materials (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  item_id     uuid not null references public.items(id) on delete restrict,
  code        text not null,
  name        text,
  -- What the component quantities are expressed per. A recipe that
  -- makes 100 is easier to write down than one that makes 1, and
  -- rounding a hundredth of a component is how quantities drift.
  output_quantity numeric(18, 4) not null default 1
    check (output_quantity > 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, code)
);

create table public.bom_lines (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id)
                on delete cascade,
  bom_id      uuid not null references public.bills_of_materials(id)
                on delete cascade,
  line_no     int not null,
  item_id     uuid not null references public.items(id) on delete restrict,
  quantity    numeric(18, 4) not null check (quantity > 0),
  -- Expected loss, as a percentage. A process that wastes one board in
  -- twenty needs twenty-one, and a plan that asks for twenty is a plan
  -- that stops halfway through.
  scrap_percent numeric(9, 4) not null default 0
    check (scrap_percent >= 0 and scrap_percent < 100),
  unique (bom_id, line_no)
);

-- ---------------------------------------------------------------------
-- Where the work happens, and what an hour of it costs
-- ---------------------------------------------------------------------
create table public.work_centres (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id)
                  on delete cascade,
  code          text not null,
  name          text not null,
  -- Labour and overhead together, per hour. One rate rather than two,
  -- because a company that cannot split them still needs a cost, and
  -- one honest number beats two invented ones.
  cost_per_hour numeric(18, 4) not null default 0 check (cost_per_hour >= 0),
  -- What it can do in a day. Nothing enforces it yet — see the header —
  -- but a capacity nobody wrote down cannot be planned against later.
  capacity_hours_per_day numeric(9, 2) not null default 8
    check (capacity_hours_per_day > 0),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (org_id, code)
);

-- The steps, in order, that turn the components into the thing.
create table public.bom_operations (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  bom_id         uuid not null references public.bills_of_materials(id)
                   on delete cascade,
  step_no        int not null,
  work_centre_id uuid not null references public.work_centres(id)
                   on delete restrict,
  name           text not null,
  -- Per `output_quantity` of the BOM, like the component quantities, so
  -- the two are read the same way.
  minutes        numeric(18, 4) not null default 0 check (minutes >= 0),
  unique (bom_id, step_no)
);

-- ---------------------------------------------------------------------
-- An order to make something
-- ---------------------------------------------------------------------
create table public.manufacturing_orders (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  order_no       text not null,
  bom_id         uuid references public.bills_of_materials(id)
                   on delete restrict,
  item_id        uuid not null references public.items(id) on delete restrict,
  warehouse_id   uuid not null references public.warehouses(id)
                   on delete restrict,
  branch_id      uuid references public.branches(id),

  quantity       numeric(18, 4) not null check (quantity > 0),
  quantity_done  numeric(18, 4) not null default 0 check (quantity_done >= 0),

  status         app.mo_status not null default 'draft',
  planned_start  timestamptz,
  planned_finish timestamptz,

  -- Filled in by posting, never by hand. What it actually cost.
  component_cost numeric(18, 2) not null default 0,
  conversion_cost numeric(18, 2) not null default 0,
  posted_at      timestamptz,
  gl_entry_id    uuid references public.gl_entries(id),

  notes          text,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (org_id, order_no)
);

create index manufacturing_orders_open_idx
  on public.manufacturing_orders (org_id, status)
  where status in ('draft', 'confirmed', 'in_progress');

-- What this particular order needs, copied from the BOM when it is
-- confirmed. A snapshot on purpose: the recipe can change tomorrow and
-- this order was costed against the one that existed today.
create table public.mo_components (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  mo_id          uuid not null references public.manufacturing_orders(id)
                   on delete cascade,
  item_id        uuid not null references public.items(id) on delete restrict,
  quantity_required numeric(18, 4) not null check (quantity_required > 0),
  quantity_issued   numeric(18, 4) not null default 0,
  unit_cost      numeric(18, 6) not null default 0,
  total_cost     numeric(18, 2) not null default 0
);

create index mo_components_mo_idx on public.mo_components (mo_id);

create table public.mo_operations (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null references public.organizations(id)
                   on delete cascade,
  mo_id          uuid not null references public.manufacturing_orders(id)
                   on delete cascade,
  step_no        int not null,
  work_centre_id uuid not null references public.work_centres(id)
                   on delete restrict,
  name           text not null,
  planned_minutes numeric(18, 4) not null default 0,
  actual_minutes  numeric(18, 4) not null default 0
    check (actual_minutes >= 0),
  unique (mo_id, step_no)
);

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array array[
    'bills_of_materials', 'bom_lines', 'work_centres', 'bom_operations',
    'manufacturing_orders', 'mo_components', 'mo_operations'
  ]
  loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (app.is_org_member(org_id))', v_table || '_select', v_table);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (app.can_post(org_id)) with check (app.can_post(org_id))',
      v_table || '_write', v_table);
    execute format(
      'grant select, insert, update, delete on public.%I to authenticated',
      v_table);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- The module gate
--
-- The same restrictive layer 0127 put on the other twenty tables, so a
-- company that defines an access type without manufacturing in it can
-- actually keep somebody out of the shop floor. Written per command,
-- because a single `for all` restrictive policy would hold reading to
-- the standard for writing.
-- ---------------------------------------------------------------------
do $$
declare v_table text;
begin
  foreach v_table in array array[
    'bills_of_materials', 'bom_lines', 'work_centres', 'bom_operations',
    'manufacturing_orders', 'mo_components', 'mo_operations'
  ]
  loop
    execute format(
      'create policy module_gate_select on public.%I
         as restrictive for select to authenticated
         using (app.can_read_module(org_id, ''manufacturing''))', v_table);
    execute format(
      'create policy module_gate_insert on public.%I
         as restrictive for insert to authenticated
         with check (app.can_write_module(org_id, ''manufacturing''))',
      v_table);
    execute format(
      'create policy module_gate_update on public.%I
         as restrictive for update to authenticated
         using (app.can_write_module(org_id, ''manufacturing''))
         with check (app.can_write_module(org_id, ''manufacturing''))',
      v_table);
    execute format(
      'create policy module_gate_delete on public.%I
         as restrictive for delete to authenticated
         using (app.can_write_module(org_id, ''manufacturing''))', v_table);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Are the parts there?
--
-- Answered against `stock_levels` in the order's own warehouse, because
-- a part sitting in another warehouse is a transfer somebody has to
-- make, not stock this order can consume.
-- ---------------------------------------------------------------------
create or replace function public.mo_shortages(p_mo_id uuid)
returns table (
  item_id uuid,
  item_code text,
  item_name text,
  quantity_required numeric,
  quantity_on_hand numeric,
  quantity_short numeric
)
language sql stable security definer
set search_path = public, app, pg_temp as $$
  select c.item_id, i.code, i.name,
         c.quantity_required,
         coalesce(sl.quantity, 0),
         greatest(c.quantity_required - coalesce(sl.quantity, 0), 0)
    from public.mo_components c
    join public.manufacturing_orders m on m.id = c.mo_id
    join public.items i on i.id = c.item_id
    left join public.stock_levels sl
      on sl.item_id = c.item_id and sl.warehouse_id = m.warehouse_id
   where c.mo_id = p_mo_id
     and app.is_org_member(m.org_id)
   order by i.code;
$$;

revoke all on function public.mo_shortages(uuid) from public, anon;
grant execute on function public.mo_shortages(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Confirming an order: take the snapshot
-- ---------------------------------------------------------------------
create or replace function public.confirm_manufacturing_order(p_mo_id uuid)
returns void
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_mo public.manufacturing_orders;
  v_factor numeric;
begin
  select * into v_mo from public.manufacturing_orders where id = p_mo_id;
  if v_mo.id is null then
    raise exception 'No such manufacturing order' using errcode = 'P0002';
  end if;
  if not app.can_post(v_mo.org_id) then
    raise exception 'You may not confirm a manufacturing order'
      using errcode = '42501';
  end if;
  if v_mo.status <> 'draft' then
    raise exception 'This order is already %', v_mo.status
      using errcode = '22023';
  end if;
  if v_mo.bom_id is null then
    raise exception 'This order has no bill of materials'
      using errcode = '22023';
  end if;

  -- How many times over the recipe is being made.
  select v_mo.quantity / b.output_quantity into v_factor
    from public.bills_of_materials b where b.id = v_mo.bom_id;

  delete from public.mo_components where mo_id = p_mo_id;
  insert into public.mo_components
    (org_id, mo_id, item_id, quantity_required)
  select v_mo.org_id, p_mo_id, l.item_id,
         -- Scrap is added, not deducted: needing twenty and wasting one
         -- in twenty means issuing twenty-one.
         round(l.quantity * v_factor / (1 - l.scrap_percent / 100), 4)
    from public.bom_lines l
   where l.bom_id = v_mo.bom_id
   order by l.line_no;

  delete from public.mo_operations where mo_id = p_mo_id;
  insert into public.mo_operations
    (org_id, mo_id, step_no, work_centre_id, name, planned_minutes)
  select v_mo.org_id, p_mo_id, o.step_no, o.work_centre_id, o.name,
         round(o.minutes * v_factor, 4)
    from public.bom_operations o
   where o.bom_id = v_mo.bom_id
   order by o.step_no;

  update public.manufacturing_orders
     set status = 'confirmed', updated_at = now()
   where id = p_mo_id;
end; $$;

revoke all on function public.confirm_manufacturing_order(uuid)
  from public, anon;
grant execute on function public.confirm_manufacturing_order(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- The account conversion cost is taken back out of expenses through
--
-- Found or made, never assumed. The seeded chart of accounts is a fixed
-- list written long before this module existed, so an organization
-- created tomorrow would not have this account and its first
-- manufacturing order would fail on a missing code — which is a strange
-- thing to tell somebody who has just made ten chairs. `app` already
-- does this for warehouses, in `app.default_warehouse`; same shape.
--
-- `is_system` so it cannot be deleted out from under a posted order.
-- ---------------------------------------------------------------------
create or replace function app.absorption_account(p_org_id uuid)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '5350' and not is_group;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '5350', 'Manufacturing Cost Absorbed', 'expense',
          'cost_of_sales', false, true, 5350,
          (select id from public.accounts
            where org_id = p_org_id and code = '5000'))
  returning id into v_id;
  return v_id;
end; $$;

revoke all on function app.absorption_account(uuid) from public, anon,
  authenticated;

-- ---------------------------------------------------------------------
-- Posting: stock and ledger, together or not at all
-- ---------------------------------------------------------------------
create or replace function public.post_manufacturing_order(
  p_mo_id uuid,
  p_quantity_done numeric default null)
returns uuid
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_mo public.manufacturing_orders;
  v_done numeric;
  v_ratio numeric;
  v_component_cost numeric(18, 2) := 0;
  v_conversion numeric(18, 2) := 0;
  v_finished numeric(18, 2);
  v_row record;
  v_movement_cost numeric(18, 2);
  v_entry uuid;
  v_inventory uuid;
  v_absorbed uuid;
  v_lines jsonb := '[]'::jsonb;
begin
  select * into v_mo from public.manufacturing_orders where id = p_mo_id
    for update;
  if v_mo.id is null then
    raise exception 'No such manufacturing order' using errcode = 'P0002';
  end if;
  if not app.can_post(v_mo.org_id) then
    raise exception 'You may not post a manufacturing order'
      using errcode = '42501';
  end if;
  if v_mo.posted_at is not null then
    raise exception 'This order has already been posted'
      using errcode = '22023';
  end if;
  if v_mo.status not in ('confirmed', 'in_progress') then
    raise exception 'Only a confirmed order can be posted; this one is %',
      v_mo.status using errcode = '22023';
  end if;

  v_done := coalesce(p_quantity_done, v_mo.quantity);
  if v_done <= 0 then
    raise exception 'Nothing was produced' using errcode = '22023';
  end if;

  -- A short run consumes proportionally less. Costing the whole recipe
  -- against half an output is how a finished item ends up carried at
  -- twice what it is worth.
  v_ratio := v_done / v_mo.quantity;

  select id into v_inventory from public.accounts
   where org_id = v_mo.org_id and code = '1310' and not is_group limit 1;
  if v_inventory is null then
    raise exception 'The chart of accounts has no inventory account'
      using errcode = '22023';
  end if;
  v_absorbed := app.absorption_account(v_mo.org_id);

  -- Components out, at what they are carried at. `assembly_out` and
  -- `assembly_in` were in `app.stock_movement_type` from 0006 and had
  -- never had a caller — they were put there for exactly this.
  for v_row in
    select c.*, i.code as item_code
      from public.mo_components c
      join public.items i on i.id = c.item_id
     where c.mo_id = p_mo_id
  loop
    insert into public.stock_movements
      (org_id, movement_no, movement_date, movement_type, item_id,
       warehouse_id, quantity, source_table, source_id)
    values (v_mo.org_id,
            v_mo.order_no || '-C-' || substr(v_row.id::text, 1, 8),
            current_date, 'assembly_out', v_row.item_id, v_mo.warehouse_id,
            -round(v_row.quantity_required * v_ratio, 4),
            'manufacturing_orders', p_mo_id)
    returning total_cost into v_movement_cost;

    -- `total_cost` comes back negative on an issue; the order records
    -- what it consumed, which is a positive amount of money.
    v_component_cost := v_component_cost + abs(v_movement_cost);

    update public.mo_components
       set quantity_issued = round(v_row.quantity_required * v_ratio, 4),
           total_cost = abs(v_movement_cost),
           unit_cost = case when v_row.quantity_required = 0 then 0
                       else round(abs(v_movement_cost) /
                                  round(v_row.quantity_required * v_ratio, 4), 6)
                       end
     where id = v_row.id;
  end loop;

  -- Conversion, at each work centre's rate. Actual minutes where they
  -- were recorded, planned where they were not — a shop that has not
  -- booked its time still has to cost its output.
  select coalesce(sum(round(
           (case when o.actual_minutes > 0 then o.actual_minutes
                 else o.planned_minutes * v_ratio end) / 60.0
           * w.cost_per_hour, 2)), 0)
    into v_conversion
    from public.mo_operations o
    join public.work_centres w on w.id = o.work_centre_id
   where o.mo_id = p_mo_id;

  v_finished := v_component_cost + v_conversion;

  -- Finished goods in, at what they cost to make.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost, source_table, source_id)
  values (v_mo.org_id, v_mo.order_no || '-F', current_date, 'assembly_in',
          v_mo.item_id, v_mo.warehouse_id, v_done,
          round(v_finished / v_done, 6), 'manufacturing_orders', p_mo_id);

  -- The ledger, mirroring it. Inventory rises by the finished value and
  -- falls by the components; the difference is the conversion cost,
  -- taken back out of the profit and loss so the wages already expensed
  -- are not counted a second time.
  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_inventory, 'debit', v_finished,
                       'credit', 0,
                       'description', 'Finished ' || v_mo.order_no),
    jsonb_build_object('account_id', v_inventory, 'debit', 0,
                       'credit', v_component_cost,
                       'description', 'Components ' || v_mo.order_no),
    jsonb_build_object('account_id', v_absorbed, 'debit', 0,
                       'credit', v_conversion,
                       'description', 'Conversion ' || v_mo.order_no));

  v_entry := app.create_gl_entry_internal(
    v_mo.org_id, current_date, 'manufacturing', v_lines,
    'Manufacturing order ' || v_mo.order_no,
    'manufacturing_orders', p_mo_id);

  update public.manufacturing_orders
     set status = 'done',
         quantity_done = v_done,
         component_cost = v_component_cost,
         conversion_cost = v_conversion,
         posted_at = now(),
         gl_entry_id = v_entry,
         updated_at = now()
   where id = p_mo_id;

  return v_entry;
end; $$;

revoke all on function public.post_manufacturing_order(uuid, numeric)
  from public, anon;
grant execute on function public.post_manufacturing_order(uuid, numeric)
  to authenticated;

-- Every company that already exists gets it now rather than on the
-- first order, so the chart of accounts screen shows the whole chart.
do $$
declare v_org uuid;
begin
  for v_org in select id from public.organizations loop
    perform app.absorption_account(v_org);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- What its numbers look like
--
-- The fallback is the first three letters of the document type, which
-- would make a manufacturing order MAN-0001. Everybody who has ever
-- worked in a factory calls it an MO. The rest of the list is copied
-- unchanged.
-- ---------------------------------------------------------------------
create or replace function app.default_doc_prefix(p_doc_type text)
returns text language sql immutable as $$
  select case p_doc_type
    when 'quotation'            then 'QT-'
    when 'sales_order'          then 'SO-'
    when 'delivery_order'       then 'DO-'
    when 'invoice'              then 'INV-'
    when 'credit_note'          then 'CN-'
    when 'debit_note'           then 'DN-'
    when 'refund_note'          then 'RN-'
    when 'proforma'             then 'PF-'
    when 'purchase_request'     then 'PR-'
    when 'purchase_order'       then 'PO-'
    when 'goods_received'       then 'GRN-'
    when 'bill'                 then 'BILL-'
    when 'purchase_credit_note' then 'PCN-'
    when 'purchase_debit_note'  then 'PDN-'
    when 'purchase_return'      then 'PRT-'
    when 'receipt'              then 'RCP-'
    when 'payment'              then 'PAY-'
    when 'expense'              then 'EXP-'
    when 'journal'              then 'JV-'
    when 'stock_adjustment'     then 'ADJ-'
    when 'stock_movement'       then 'SM-'
    when 'lead'                 then 'LD-'
    when 'opportunity'          then 'OPP-'
    when 'contact'              then 'C-'
    when 'item'                 then 'I-'
    when 'withholding'          then 'WHT-'
    when 'bank_transfer'        then 'TRF-'
    when 'manufacturing_order'  then 'MO-'
    else upper(left(p_doc_type, 3)) || '-'
  end;
$$;

insert into public.platform_modules
  (code, name, description, is_core, monthly_price, sort_order)
values ('manufacturing', 'Manufacturing',
        'Bills of materials, work centres and manufacturing orders',
        false, 0, 95)
on conflict (code) do nothing;
