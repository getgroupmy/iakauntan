-- =====================================================================
-- iAkauntan :: 0106 knowing which one you sold
--
-- `stock_movements` has carried `batch_no`, `serial_no` and
-- `expiry_date` since 0006. Nothing has ever written to any of them —
-- four movements on the hosted database, none with a value. The third
-- dead column found this week, after the credit limit and the
-- salesperson.
--
-- Those three columns are the wrong shape and are dropped rather than
-- filled in. One movement issuing ten units may draw on three batches;
-- a scalar column on the movement can hold one. Keeping them beside a
-- child table that can hold the truth would leave two places to look for
-- a batch number, one of them always empty, which is how the dead column
-- got here in the first place.
--
-- ---------------------------------------------------------------------
-- What this deliberately does not do
--
-- **It does not touch costing.** Every item on the hosted database is
-- `weighted_average`, and `app.apply_stock_movement` — a BEFORE INSERT
-- trigger — computes the running average and the balance value that the
-- inventory and cost-of-sales postings rest on. Specific identification
-- would restate all of it.
--
-- So tracking here is about *identity*, not value: which physical unit
-- went where, when it expires, and who has it now. A serialised item
-- still costs at weighted average. MFRS 102 permits weighted average and
-- requires specific identification only for items not ordinarily
-- interchangeable, so this is a defensible split — and it is the only
-- one that does not rewrite figures already filed. Making serials
-- cost-specific is separate work with its own restatement question.
--
-- ---------------------------------------------------------------------
-- Where the numbers are typed, and how they reach the ledger
--
-- On the document line, before posting — `document_line_lots`. Not on
-- the movement, because by the time a movement exists the posting has
-- happened and it is too late to ask anybody anything.
--
-- Posting is then left completely alone. `post_sales_document` and
-- `post_purchase_document` already write `source_line_id` onto every
-- movement they create, and `post_stock_adjustment` does the same, so an
-- AFTER INSERT trigger on `stock_movements` can find the line the
-- movement came from and copy its allocation across. Two functions this
-- migration does not have to reopen is two functions it cannot break.
--
-- ---------------------------------------------------------------------
-- Balances are derived, never stored
--
-- A lot's quantity in a warehouse is the sum of the movements that
-- touched it. There is no `stock_lots.quantity` to drift out of step
-- with `stock_movements`, because the one failure that would make this
-- feature actively harmful is a recall list saying a batch is on the
-- shelf when it was sold last month.
--
-- ---------------------------------------------------------------------
-- Opt-in, and then compulsory
--
-- `items.tracking` defaults to `none`, so nothing that exists today
-- changes. Set it to `batch` or `serial` and the detail stops being
-- optional: posting refuses a line of that item that has not been broken
-- down, and a deferred constraint trigger refuses at commit any movement
-- whose lot lines do not add up to it. Optional traceability is not
-- traceability — it is a field filled in until the week somebody is
-- busy, which is the week of the recall.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Which items are tracked
--
-- Text with a check rather than an enum, matching `costing_method` two
-- columns along. An enum would need its own migration to add a value
-- later, since Postgres will not let one be added and used in the same
-- transaction — the reason 0098 exists.
-- ---------------------------------------------------------------------
alter table public.items
  add column if not exists tracking text not null default 'none';

alter table public.items drop constraint if exists items_tracking_ck;
alter table public.items add constraint items_tracking_ck
  check (tracking in ('none', 'batch', 'serial'));

-- Tracking something that is not stock is meaningless: a service has no
-- units to identify.
alter table public.items drop constraint if exists items_tracking_needs_stock_ck;
alter table public.items add constraint items_tracking_needs_stock_ck
  check (tracking = 'none' or track_inventory);

-- ---------------------------------------------------------------------
-- The identities
--
-- One row per batch or serial number of an item, across every
-- warehouse. A serial number that moves between warehouses is the same
-- physical unit and must not become two rows — where it is now is a
-- question about movements, not about identity.
-- ---------------------------------------------------------------------
create table if not exists public.stock_lots (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  item_id     uuid not null references public.items (id) on delete cascade,
  -- The batch number or serial number as printed on the thing itself.
  lot_ref     text not null,
  kind        text not null check (kind in ('batch', 'serial')),
  -- Batches in practice. A serial may carry one, and a warranty date is
  -- the usual reason.
  expiry_date date,
  manufactured_on date,
  -- Who it came from, for the half of a recall that runs upstream.
  supplier_id uuid references public.contacts (id) on delete set null,
  supplier_lot_ref text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (org_id, item_id, lot_ref)
);

create index if not exists stock_lots_expiry_idx
  on public.stock_lots (org_id, expiry_date)
  where expiry_date is not null;

alter table public.stock_lots enable row level security;

drop policy if exists stock_lots_select on public.stock_lots;
create policy stock_lots_select on public.stock_lots
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists stock_lots_insert on public.stock_lots;
create policy stock_lots_insert on public.stock_lots
  for insert to authenticated with check (app.can_write(org_id));
drop policy if exists stock_lots_update on public.stock_lots;
create policy stock_lots_update on public.stock_lots
  for update to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));
drop policy if exists stock_lots_delete on public.stock_lots;
create policy stock_lots_delete on public.stock_lots
  for delete to authenticated using (app.can_admin(org_id));

-- ---------------------------------------------------------------------
-- What the person filling in the document said
--
-- Three nullable line references with exactly one set, rather than a
-- `line_table` text and an unconstrained uuid. The polymorphic version
-- is shorter to write and cannot be enforced by the database at all —
-- the same reasoning `payment_allocations` uses for its source check.
--
-- Quantities are always positive here. Whether this is a receipt or an
-- issue is a property of the movement, not of the line, and asking a
-- screen to get a sign right is asking for a batch to be received when
-- it was shipped.
-- ---------------------------------------------------------------------
create table if not exists public.document_line_lots (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  sales_line_id uuid references public.sales_document_lines (id) on delete cascade,
  purchase_line_id uuid references public.purchase_document_lines (id) on delete cascade,
  adjustment_line_id uuid references public.stock_adjustment_lines (id) on delete cascade,
  lot_ref     text not null,
  quantity    numeric(18, 4) not null check (quantity > 0),
  -- Recorded on receipt and carried onto the lot the first time it is
  -- seen. Meaningless on an issue, where the lot already exists.
  expiry_date date,
  manufactured_on date,
  supplier_lot_ref text,
  created_at  timestamptz not null default now(),
  constraint document_line_lots_one_line_ck check (
    (sales_line_id is not null)::integer
    + (purchase_line_id is not null)::integer
    + (adjustment_line_id is not null)::integer = 1)
);

-- One allocation per lot per line. Two rows for the same batch on one
-- line is not extra information, it is a double count waiting to be
-- summed.
create unique index if not exists document_line_lots_sales_uk
  on public.document_line_lots (sales_line_id, lot_ref) where sales_line_id is not null;
create unique index if not exists document_line_lots_purchase_uk
  on public.document_line_lots (purchase_line_id, lot_ref) where purchase_line_id is not null;
create unique index if not exists document_line_lots_adjustment_uk
  on public.document_line_lots (adjustment_line_id, lot_ref) where adjustment_line_id is not null;

alter table public.document_line_lots enable row level security;

drop policy if exists document_line_lots_select on public.document_line_lots;
create policy document_line_lots_select on public.document_line_lots
  for select to authenticated using (app.is_org_member(org_id));
drop policy if exists document_line_lots_insert on public.document_line_lots;
create policy document_line_lots_insert on public.document_line_lots
  for insert to authenticated with check (app.can_write(org_id));
drop policy if exists document_line_lots_update on public.document_line_lots;
create policy document_line_lots_update on public.document_line_lots
  for update to authenticated
  using (app.can_write(org_id)) with check (app.can_write(org_id));
drop policy if exists document_line_lots_delete on public.document_line_lots;
create policy document_line_lots_delete on public.document_line_lots
  for delete to authenticated using (app.can_write(org_id));

-- ---------------------------------------------------------------------
-- Which lots a movement actually touched
--
-- The ledger-side record, written by the trigger below rather than by
-- anybody's hand. Same sign convention as the movement it hangs off:
-- positive in, negative out.
-- ---------------------------------------------------------------------
create table if not exists public.stock_movement_lots (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations (id) on delete cascade,
  movement_id uuid not null references public.stock_movements (id) on delete cascade,
  lot_id      uuid not null references public.stock_lots (id) on delete restrict,
  quantity    numeric(18, 4) not null check (quantity <> 0),
  created_at  timestamptz not null default now(),
  unique (movement_id, lot_id)
);

create index if not exists stock_movement_lots_lot_idx
  on public.stock_movement_lots (lot_id);

alter table public.stock_movement_lots enable row level security;

-- Read-only to everybody. These rows are the consequence of a posting,
-- not something to be edited afterwards — the way to change them is to
-- reverse the document, which is the same rule the ledger itself keeps.
drop policy if exists stock_movement_lots_select on public.stock_movement_lots;
create policy stock_movement_lots_select on public.stock_movement_lots
  for select to authenticated using (app.is_org_member(org_id));

-- ---------------------------------------------------------------------
-- The three columns that were never filled in
--
-- Dropped, not kept "just in case". Nothing in the app reads them —
-- checked — and nothing has ever written one.
-- ---------------------------------------------------------------------
alter table public.stock_movements drop column if exists batch_no;
alter table public.stock_movements drop column if exists serial_no;
alter table public.stock_movements drop column if exists expiry_date;

-- ---------------------------------------------------------------------
-- Where a lot is now
--
-- Derived from the movements every time. Small volumes, and the
-- alternative is a stored quantity that can disagree with the ledger —
-- on a recall list, silently, in the direction that matters.
--
-- `security_invoker` is load-bearing. A view without it runs with its
-- owner's rights, so the `grant select` at the bottom would hand every
-- signed-in user every organization's lots and the RLS on the tables
-- underneath would never be consulted. It is the default nobody expects
-- and the failure is silent.
-- ---------------------------------------------------------------------
create or replace view public.v_lot_balances
  with (security_invoker = true) as
  select l.org_id,
         l.id            as lot_id,
         l.item_id,
         l.lot_ref,
         l.kind,
         l.expiry_date,
         m.warehouse_id,
         sum(sml.quantity) as quantity
    from public.stock_lots l
    join public.stock_movement_lots sml on sml.lot_id = l.id
    join public.stock_movements m on m.id = sml.movement_id
   group by l.org_id, l.id, l.item_id, l.lot_ref, l.kind, l.expiry_date,
            m.warehouse_id
  having sum(sml.quantity) <> 0;

-- ---------------------------------------------------------------------
-- From the document line onto the movement
--
-- Fires immediately after the movement is written, so a posting that is
-- missing its detail fails at the call rather than at commit. The
-- deferred check below is the backstop; this is the one that produces a
-- message somebody can act on while they still have the document open.
--
-- Nothing is scaled. If the movement quantity and the allocation
-- disagree the deferred check refuses the transaction, because quietly
-- pro-rating somebody's batch numbers to fit is how a recall list ends
-- up plausible and wrong.
-- ---------------------------------------------------------------------
create or replace function app.materialise_movement_lots()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_track text;
  v_code  text;
  v_sign  numeric := sign(new.quantity);
  v_found integer := 0;
  r       record;
  v_lot   uuid;
begin
  select i.tracking, i.code into v_track, v_code
    from public.items i where i.id = new.item_id;

  if v_track is null or v_track = 'none' then
    return null;
  end if;

  for r in
    select d.lot_ref, d.quantity, d.expiry_date, d.manufactured_on,
           d.supplier_lot_ref
      from public.document_line_lots d
     where new.source_line_id is not null
       and ((new.source_table = 'sales_documents'    and d.sales_line_id = new.source_line_id)
         or (new.source_table = 'purchase_documents' and d.purchase_line_id = new.source_line_id)
         or (new.source_table = 'stock_adjustments'  and d.adjustment_line_id = new.source_line_id))
  loop
    -- Seen for the first time on a receipt; already there on an issue.
    -- The dates are only ever filled in, never overwritten with
    -- nothing — a later receipt that omits the expiry must not erase
    -- the one the first receipt recorded.
    insert into public.stock_lots
      (org_id, item_id, lot_ref, kind, expiry_date, manufactured_on,
       supplier_lot_ref)
    values (new.org_id, new.item_id, r.lot_ref, v_track,
            r.expiry_date, r.manufactured_on, r.supplier_lot_ref)
    on conflict (org_id, item_id, lot_ref) do update
      set expiry_date      = coalesce(excluded.expiry_date, stock_lots.expiry_date),
          manufactured_on  = coalesce(excluded.manufactured_on,
                                      stock_lots.manufactured_on),
          supplier_lot_ref = coalesce(excluded.supplier_lot_ref,
                                      stock_lots.supplier_lot_ref),
          updated_at       = now()
    returning id into v_lot;

    insert into public.stock_movement_lots
      (org_id, movement_id, lot_id, quantity)
    values (new.org_id, new.id, v_lot, r.quantity * v_sign);

    v_found := v_found + 1;
  end loop;

  if v_found = 0 then
    raise exception
      'Item % is tracked by %, so every unit has to be named before this '
      'can be posted. Nothing was recorded against this line.',
      v_code, v_track using errcode = '23514';
  end if;

  return null;
end;
$$;

-- Numbered, not named for what they do. Both are AFTER INSERT on the
-- same table and PostgreSQL fires those in *name* order, so a check
-- called `..._lots_ck` would have run before the `..._materialise_lots`
-- that writes the rows it checks. That is invisible while the check is
-- deferred to commit and instantly fatal the moment anybody sets
-- constraints immediate — which is exactly what the tests do to reach
-- it. The digits are the contract.
drop trigger if exists stock_movements_materialise_lots on public.stock_movements;
drop trigger if exists stock_movements_lots_1_materialise on public.stock_movements;
create trigger stock_movements_lots_1_materialise
  after insert on public.stock_movements
  for each row execute function app.materialise_movement_lots();

-- ---------------------------------------------------------------------
-- The invariant
--
-- Deferred to commit, because the lot rows are written after the
-- movement and the check is only meaningful once both are in. Four
-- things:
--
--   * a tracked item's movement is fully accounted for by lot lines;
--   * an untracked item has none, so a batch number cannot be recorded
--     against something nobody is tracking and then relied on;
--   * a serial moves one unit at a time, and is never on hand twice;
--   * no lot goes negative in a warehouse — you cannot ship what you do
--     not have, and a negative lot balance is where a recall list starts
--     lying.
-- ---------------------------------------------------------------------
create or replace function app.check_movement_lots()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_track text;
  v_code  text;
  v_lots  numeric(18, 4);
  v_bad   record;
begin
  select i.tracking, i.code into v_track, v_code
    from public.items i where i.id = new.item_id;

  select coalesce(sum(sml.quantity), 0) into v_lots
    from public.stock_movement_lots sml where sml.movement_id = new.id;

  if v_track is null or v_track = 'none' then
    if exists (select 1 from public.stock_movement_lots sml
                where sml.movement_id = new.id) then
      raise exception
        'Item % is not tracked, so it cannot carry batch or serial detail',
        v_code using errcode = '23514';
    end if;
    return null;
  end if;

  if v_lots <> new.quantity then
    raise exception
      'Item % is tracked by %: a movement of % is accounted for by %. '
      'Every unit has to be named.',
      v_code, v_track, new.quantity, v_lots using errcode = '23514';
  end if;

  if v_track = 'serial'
     and exists (select 1 from public.stock_movement_lots sml
                  where sml.movement_id = new.id and abs(sml.quantity) <> 1) then
    raise exception
      'Item % is serialised, so each serial moves exactly one unit', v_code
      using errcode = '23514';
  end if;

  for v_bad in
    select distinct b.lot_ref, b.quantity, b.kind
      from public.v_lot_balances b
      join public.stock_movement_lots sml on sml.lot_id = b.lot_id
     where sml.movement_id = new.id
       and (b.quantity < 0 or (b.kind = 'serial' and b.quantity > 1))
  loop
    if v_bad.quantity < 0 then
      raise exception
        'That would leave % of item % at % in this warehouse',
        v_bad.lot_ref, v_code, v_bad.quantity using errcode = '23514';
    else
      -- Two units under one serial number means one of them is
      -- mislabelled, and a warranty claim will find it before you do.
      raise exception
        'Serial % of item % would be on hand % times',
        v_bad.lot_ref, v_code, v_bad.quantity using errcode = '23514';
    end if;
  end loop;

  return null;
end;
$$;

drop trigger if exists stock_movements_lots_ck on public.stock_movements;
drop trigger if exists stock_movements_lots_2_check on public.stock_movements;
create constraint trigger stock_movements_lots_2_check
  after insert on public.stock_movements
  deferrable initially deferred
  for each row execute function app.check_movement_lots();

-- ---------------------------------------------------------------------
-- Naming the units on a document line
--
-- Replaces whatever was there, so a screen can send the whole allocation
-- for a line and not reason about what it sent last time. `p_lots` is
-- [{"lot_ref":"B-2026-03","quantity":4,"expiry_date":"2027-01-31"}].
-- ---------------------------------------------------------------------
create or replace function public.set_line_lots(
  p_line_table text,
  p_line_id uuid,
  p_lots jsonb)
returns integer
language plpgsql security definer
set search_path = public, app, pg_temp as $$
declare
  v_org   uuid;
  v_item  uuid;
  v_qty   numeric(18, 4);
  v_track text;
  r       jsonb;
  v_ref   text;
  v_n     numeric(18, 4);
  v_total numeric(18, 4) := 0;
  v_count integer := 0;
begin
  if p_line_table = 'sales_document_lines' then
    select l.org_id, l.item_id, l.quantity into v_org, v_item, v_qty
      from public.sales_document_lines l where l.id = p_line_id;
  elsif p_line_table = 'purchase_document_lines' then
    select l.org_id, l.item_id, l.quantity into v_org, v_item, v_qty
      from public.purchase_document_lines l where l.id = p_line_id;
  elsif p_line_table = 'stock_adjustment_lines' then
    select l.org_id, l.item_id, abs(l.difference) into v_org, v_item, v_qty
      from public.stock_adjustment_lines l where l.id = p_line_id;
  else
    raise exception 'Lots cannot be recorded against %', p_line_table
      using errcode = '23514';
  end if;

  if v_org is null then
    raise exception 'No such line' using errcode = 'P0002';
  end if;
  if not app.can_write(v_org) then
    raise exception 'Not allowed to write to organization %', v_org
      using errcode = '42501';
  end if;

  select i.tracking into v_track from public.items i where i.id = v_item;
  if coalesce(v_track, 'none') = 'none' then
    raise exception 'That item is not tracked by batch or serial'
      using errcode = '23514';
  end if;

  delete from public.document_line_lots d
   where (p_line_table = 'sales_document_lines'    and d.sales_line_id = p_line_id)
      or (p_line_table = 'purchase_document_lines' and d.purchase_line_id = p_line_id)
      or (p_line_table = 'stock_adjustment_lines'  and d.adjustment_line_id = p_line_id);

  for r in select value from jsonb_array_elements(coalesce(p_lots, '[]'::jsonb))
  loop
    v_ref := nullif(trim(r ->> 'lot_ref'), '');
    if v_ref is null then
      raise exception 'Every line needs a batch or serial number'
        using errcode = '23514';
    end if;

    -- A serial is one unit by definition, so the screen does not have to
    -- say so and cannot say otherwise.
    v_n := case when v_track = 'serial' then 1
                else nullif(r ->> 'quantity', '')::numeric end;
    if v_n is null or v_n <= 0 then
      raise exception 'Line for % needs a quantity above nothing', v_ref
        using errcode = '23514';
    end if;

    insert into public.document_line_lots
      (org_id, sales_line_id, purchase_line_id, adjustment_line_id,
       lot_ref, quantity, expiry_date, manufactured_on, supplier_lot_ref)
    values (v_org,
            case when p_line_table = 'sales_document_lines' then p_line_id end,
            case when p_line_table = 'purchase_document_lines' then p_line_id end,
            case when p_line_table = 'stock_adjustment_lines' then p_line_id end,
            v_ref, v_n,
            nullif(r ->> 'expiry_date', '')::date,
            nullif(r ->> 'manufactured_on', '')::date,
            nullif(trim(r ->> 'supplier_lot_ref'), ''));

    v_total := v_total + v_n;
    v_count := v_count + 1;
  end loop;

  -- Refused here rather than at posting. The person who knows which
  -- boxes they picked is the person looking at this line right now; the
  -- one who finds out at posting is whoever presses the button a week
  -- later, and they will guess.
  if v_count > 0 and v_total <> v_qty then
    raise exception
      'The line is for % but % has been broken down', v_qty, v_total
      using errcode = '23514';
  end if;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- What a line already says
-- ---------------------------------------------------------------------
create or replace function public.line_lots(
  p_line_table text,
  p_line_id uuid)
returns table (
  lot_ref     text,
  quantity    numeric,
  expiry_date date,
  manufactured_on date,
  supplier_lot_ref text)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  select d.org_id into v_org from public.document_line_lots d
   where (p_line_table = 'sales_document_lines'    and d.sales_line_id = p_line_id)
      or (p_line_table = 'purchase_document_lines' and d.purchase_line_id = p_line_id)
      or (p_line_table = 'stock_adjustment_lines'  and d.adjustment_line_id = p_line_id)
   limit 1;

  if v_org is null then return; end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of that organization' using errcode = '42501';
  end if;

  return query
  select d.lot_ref, d.quantity, d.expiry_date, d.manufactured_on,
         d.supplier_lot_ref
    from public.document_line_lots d
   where (p_line_table = 'sales_document_lines'    and d.sales_line_id = p_line_id)
      or (p_line_table = 'purchase_document_lines' and d.purchase_line_id = p_line_id)
      or (p_line_table = 'stock_adjustment_lines'  and d.adjustment_line_id = p_line_id)
   order by d.lot_ref;
end;
$$;

-- ---------------------------------------------------------------------
-- What is missing before this can be posted
--
-- So the screen can say it, in one call, rather than posting and reading
-- an exception back. Empty means the document is ready.
-- ---------------------------------------------------------------------
create or replace function public.document_lot_problems(
  p_document_id uuid,
  p_kind text)
returns table (
  line_no     integer,
  item_code   text,
  needed      numeric,
  allocated   numeric,
  problem     text)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare v_org uuid;
begin
  if p_kind not in ('sales', 'purchase') then
    raise exception 'Unknown document kind %', p_kind using errcode = '23514';
  end if;

  select case when p_kind = 'sales'
              then (select org_id from public.sales_documents where id = p_document_id)
              else (select org_id from public.purchase_documents where id = p_document_id)
         end into v_org;
  if v_org is null then
    raise exception 'No such document' using errcode = 'P0002';
  end if;
  if not app.is_org_member(v_org) then
    raise exception 'Not a member of that organization' using errcode = '42501';
  end if;

  return query
  with lines as (
    select l.id, l.line_no, l.item_id, l.quantity
      from public.sales_document_lines l
     where p_kind = 'sales' and l.document_id = p_document_id
       and l.line_type = 'item' and l.quantity > 0
    union all
    select l.id, l.line_no, l.item_id, l.quantity
      from public.purchase_document_lines l
     where p_kind = 'purchase' and l.document_id = p_document_id
       and l.line_type = 'item' and l.quantity > 0)
  select ln.line_no, i.code, ln.quantity,
         coalesce(a.total, 0),
         case when coalesce(a.total, 0) = 0
              then format('%s is tracked by %s and nothing has been named',
                          i.code, i.tracking)
              else format('%s of %s has been named, the line is for %s',
                          a.total, i.code, ln.quantity)
         end
    from lines ln
    join public.items i on i.id = ln.item_id
    left join lateral (
      select sum(d.quantity) as total
        from public.document_line_lots d
       where (p_kind = 'sales' and d.sales_line_id = ln.id)
          or (p_kind = 'purchase' and d.purchase_line_id = ln.id)) a on true
   where i.tracking <> 'none'
     and coalesce(a.total, 0) <> ln.quantity
   order by ln.line_no;
end;
$$;

-- ---------------------------------------------------------------------
-- What to pick, and in what order
--
-- First expired, first out — not first in, first out. For anything with
-- a shelf life those differ, and picking the older-but-longer-dated box
-- is how stock gets written off at the back of the warehouse. Lots with
-- no expiry fall to the end.
--
-- Advisory. Nothing makes anybody take the suggestion; a physical pick
-- is a physical fact, and a system that refused the box actually in
-- somebody's hand would be worked around inside a week.
-- ---------------------------------------------------------------------
create or replace function public.suggest_lots(
  p_item_id uuid,
  p_warehouse_id uuid,
  p_quantity numeric)
returns table (
  lot_ref     text,
  expiry_date date,
  available   numeric,
  take        numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
declare
  v_org  uuid;
  v_left numeric(18, 4) := abs(coalesce(p_quantity, 0));
  r      record;
begin
  select org_id into v_org from public.items where id = p_item_id;
  if v_org is null or not app.is_org_member(v_org) then
    raise exception 'Not a member of that organization' using errcode = '42501';
  end if;

  for r in
    select b.lot_ref, b.expiry_date, b.quantity
      from public.v_lot_balances b
     where b.item_id = p_item_id
       and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id)
       and b.quantity > 0
     order by b.expiry_date asc nulls last, b.lot_ref
  loop
    exit when v_left <= 0;
    lot_ref := r.lot_ref;
    expiry_date := r.expiry_date;
    available := r.quantity;
    take := least(r.quantity, v_left);
    v_left := v_left - take;
    return next;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- What is on hand, by lot
-- ---------------------------------------------------------------------
create or replace function public.report_lot_balances(
  p_org_id uuid,
  p_item_id uuid default null,
  p_warehouse_id uuid default null)
returns table (
  lot_id      uuid,
  item_code   text,
  item_name   text,
  lot_ref     text,
  kind        text,
  expiry_date date,
  days_to_expiry integer,
  warehouse   text,
  quantity    numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select b.lot_id, i.code, i.name, b.lot_ref, b.kind, b.expiry_date,
         case when b.expiry_date is null then null
              else (b.expiry_date - current_date)::integer end,
         w.name, b.quantity
    from public.v_lot_balances b
    join public.items i on i.id = b.item_id
    left join public.warehouses w on w.id = b.warehouse_id
   where b.org_id = p_org_id
     and (p_item_id is null or b.item_id = p_item_id)
     and (p_warehouse_id is null or b.warehouse_id = p_warehouse_id)
   order by i.code, b.expiry_date asc nulls last, b.lot_ref;
end;
$$;

-- ---------------------------------------------------------------------
-- What is about to go out of date
--
-- The report this feature exists for in a food or pharmacy business, and
-- the one that has to be read before it matters rather than after.
-- Already-expired stock is included with a negative number of days,
-- because it is still on the shelf and still on the balance sheet at
-- cost.
-- ---------------------------------------------------------------------
create or replace function public.report_expiring_stock(
  p_org_id uuid,
  p_within_days integer default 90)
returns table (
  item_code   text,
  item_name   text,
  lot_ref     text,
  expiry_date date,
  days_to_expiry integer,
  warehouse   text,
  quantity    numeric,
  value_at_average numeric)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select i.code, i.name, b.lot_ref, b.expiry_date,
         (b.expiry_date - current_date)::integer,
         w.name, b.quantity,
         -- At the item's weighted average, because that is what this
         -- stock is carried at. It is what would be written off, not a
         -- cost specific to the batch — see the header.
         round(b.quantity * coalesce(i.average_cost, 0), 2)
    from public.v_lot_balances b
    join public.items i on i.id = b.item_id
    left join public.warehouses w on w.id = b.warehouse_id
   where b.org_id = p_org_id
     and b.expiry_date is not null
     and b.expiry_date <= current_date + p_within_days
     and b.quantity > 0
   order by b.expiry_date, i.code;
end;
$$;

-- ---------------------------------------------------------------------
-- Where did it come from, where did it go
--
-- The recall question, and the only thing that justifies making anybody
-- type a batch number on every receipt. Both directions from one lot.
-- ---------------------------------------------------------------------
create or replace function public.trace_lot(
  p_org_id uuid,
  p_lot_id uuid)
returns table (
  direction      text,
  movement_date  date,
  movement_type  text,
  quantity       numeric,
  warehouse      text,
  contact_name   text,
  document_no    text,
  source_table   text,
  source_id      uuid)
language plpgsql stable security definer
set search_path = public, app, pg_temp as $$
begin
  if not app.is_org_member(p_org_id) then
    raise exception 'Not a member of organization %', p_org_id
      using errcode = '42501';
  end if;

  return query
  select case when sml.quantity > 0 then 'in' else 'out' end,
         m.movement_date,
         m.movement_type::text,
         sml.quantity,
         w.name,
         coalesce(sd.who, pd.who),
         coalesce(sd.doc_no, pd.doc_no),
         m.source_table,
         m.source_id
    from public.stock_movement_lots sml
    join public.stock_movements m on m.id = sml.movement_id
    left join public.warehouses w on w.id = m.warehouse_id
    left join lateral (
      select d.doc_no, c.name as who
        from public.sales_documents d
        left join public.contacts c on c.id = d.contact_id
       where m.source_table = 'sales_documents' and d.id = m.source_id) sd on true
    left join lateral (
      select d.doc_no, c.name as who
        from public.purchase_documents d
        left join public.contacts c on c.id = d.contact_id
       where m.source_table = 'purchase_documents' and d.id = m.source_id) pd on true
   where sml.lot_id = p_lot_id
     and m.org_id = p_org_id
   order by m.movement_date, m.created_at;
end;
$$;

-- ---------------------------------------------------------------------
-- Reachability
--
-- Postgres grants EXECUTE to PUBLIC on a new function, so each one has
-- to be taken away before it is given back — the lesson 0080 exists for.
-- Both trigger functions are revoked outright: they fire as triggers
-- regardless of privilege, and nothing should call them by hand.
-- ---------------------------------------------------------------------
revoke all on function app.check_movement_lots() from public, anon, authenticated;
revoke all on function app.materialise_movement_lots() from public, anon, authenticated;

revoke all on function public.set_line_lots(text, uuid, jsonb) from public, anon;
grant execute on function public.set_line_lots(text, uuid, jsonb)
  to authenticated, service_role;

revoke all on function public.line_lots(text, uuid) from public, anon;
grant execute on function public.line_lots(text, uuid)
  to authenticated, service_role;

revoke all on function public.document_lot_problems(uuid, text) from public, anon;
grant execute on function public.document_lot_problems(uuid, text)
  to authenticated, service_role;

revoke all on function public.suggest_lots(uuid, uuid, numeric) from public, anon;
grant execute on function public.suggest_lots(uuid, uuid, numeric)
  to authenticated, service_role;

revoke all on function public.report_lot_balances(uuid, uuid, uuid) from public, anon;
grant execute on function public.report_lot_balances(uuid, uuid, uuid)
  to authenticated, service_role;

revoke all on function public.report_expiring_stock(uuid, integer) from public, anon;
grant execute on function public.report_expiring_stock(uuid, integer)
  to authenticated, service_role;

revoke all on function public.trace_lot(uuid, uuid) from public, anon;
grant execute on function public.trace_lot(uuid, uuid)
  to authenticated, service_role;

-- Supabase grants `anon` and `authenticated` every table privilege on a
-- new table in `public` by default, so RLS is the only barrier unless
-- this is said out loud. The view has no policies of its own — with
-- `security_invoker` it reads the tables above under the caller's rights
-- and inherits theirs.
revoke all on public.v_lot_balances from anon;
grant select on public.v_lot_balances to authenticated, service_role;
revoke all on public.stock_lots from anon;
revoke all on public.document_line_lots from anon;
revoke all on public.stock_movement_lots from anon;
-- Written only by the trigger, which runs as its definer. Nobody edits a
-- posting's consequences by hand.
revoke insert, update, delete on public.stock_movement_lots
  from authenticated;
