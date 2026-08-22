-- =====================================================================
-- The food court, and what each stall is owed
--
-- A Malaysian food court is one room, one payment counter, and a dozen
-- businesses that are not the same business. The customer takes nasi
-- kandar from one stall and cendol from another, pays once at the
-- till, and at the end of the week the court hands each operator their
-- takings less its cut.
--
-- Nothing in this module can express that. `pos_outlets` is one shop
-- with one owner, and a line on a bill has no idea whose food it was.
-- A court running on this today has to give every stall its own outlet
-- and its own till, which is a different business — the customer pays
-- three times and queues three times, which is precisely what a food
-- court exists to avoid.
--
-- ---------------------------------------------------------------------
-- The stall is on the line, and it is frozen there
--
-- `items.stall_id` says whose dish it is; `pos_sale_lines.stall_id` is
-- stamped from it when the line is rung up and never read from the item
-- again. A stall that changes hands in March must not rewrite what
-- February's settlement was based on, and an item moved between stalls
-- must not move money with it.
--
-- ---------------------------------------------------------------------
-- The court is a principal here, and that is a judgement
--
-- Two treatments are defensible under MFRS 15, and which one is right
-- turns on who controls the food before it reaches the customer.
--
--   * Agent. The court collects on the stall's behalf. Only the
--     commission is the court's revenue and the rest is a liability
--     from the moment the till closes.
--   * Principal. The court sells the food and buys it from the stall.
--     Revenue is the whole ticket, the stall's share is a cost, and the
--     margin is the commission.
--
-- This takes the principal view, for a reason that is structural rather
-- than a preference: `complete_pos_sale` has recognised the whole
-- ticket as the court's revenue since 0209, on an invoice to the
-- customer with the court's own SST number on it. Settling as an agent
-- would mean that invoice was wrong, and a module that posts one
-- treatment at the till and the other at the settlement is a module
-- that does not add up. A court that genuinely acts as an agent should
-- give each stall its own outlet, which already works.
--
-- ---------------------------------------------------------------------
-- Settlement is a purchase bill, not a journal
--
-- The stall is a supplier. Raising a real bill against the operator's
-- contact means the payable is in the AP ageing, the stall can be paid
-- through the ordinary payment run, the money owed shows up in the
-- reports that already exist, and none of it needs a parallel ledger
-- that would have to be reconciled to the real one. `5150 Stall
-- Purchases` keeps it out of the court's own food cost so the two
-- margins can be told apart.
--
-- A period settled is a period closed. `pos_stall_settlements` records
-- what was covered, and a second run over any of the same days is
-- refused rather than paying twice for a Tuesday.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Where the court's cost of buying from its stalls lands
-- ---------------------------------------------------------------------
create or replace function app.stall_purchases_account(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_id uuid;
begin
  select id into v_id from public.accounts
   where org_id = p_org_id and code = '5150' and not is_group;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_group, is_system,
     sort_order, parent_id)
  values (p_org_id, '5150', 'Stall Purchases', 'expense', 'cost_of_sales',
          false, true, 5150,
          (select id from public.accounts
            where org_id = p_org_id and code = '5000'))
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function app.stall_purchases_account(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The stalls
-- ---------------------------------------------------------------------
create table public.pos_stalls (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations(id)
                        on delete cascade,
  outlet_id           uuid not null references public.pos_outlets(id)
                        on delete cascade,
  code                text not null,
  name                text not null,

  -- Whose business it is. A contact rather than free text, because the
  -- settlement raises a bill against it and a bill needs somebody to
  -- owe.
  operator_contact_id uuid not null references public.contacts(id)
                        on delete restrict,

  -- What the court keeps. Per stall, because the anchor tenant by the
  -- door and the drinks stall at the back never pay the same.
  commission_percent  numeric(9, 4) not null default 0
                        check (commission_percent >= 0
                               and commission_percent < 100),

  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (outlet_id, code)
);

create index pos_stalls_org_idx on public.pos_stalls (org_id) where is_active;

alter table public.items
  add column if not exists stall_id uuid references public.pos_stalls(id)
    on delete set null;

create index if not exists items_stall_idx on public.items (stall_id)
  where stall_id is not null;

alter table public.pos_sale_lines
  add column if not exists stall_id uuid references public.pos_stalls(id)
    on delete set null;

create index if not exists pos_sale_lines_stall_idx
  on public.pos_sale_lines (stall_id) where stall_id is not null;

comment on column public.pos_sale_lines.stall_id is
  'Whose food this was, stamped from the item when the line was rung up and never read again. A stall that changes hands must not rewrite what last month''s settlement was based on.';

-- ---------------------------------------------------------------------
-- What has already been paid for
-- ---------------------------------------------------------------------
create table public.pos_stall_settlements (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id)
                 on delete cascade,
  stall_id     uuid not null references public.pos_stalls(id) on delete cascade,

  period_from  date not null,
  period_to    date not null,

  gross        numeric(18, 2) not null,
  commission   numeric(18, 2) not null,
  net          numeric(18, 2) not null,

  bill_id      uuid references public.purchase_documents(id) on delete set null,
  settled_by   uuid references auth.users(id),
  created_at   timestamptz not null default now(),

  constraint pos_stall_settlements_period check (period_to >= period_from)
);

create index pos_stall_settlements_stall_idx
  on public.pos_stall_settlements (stall_id, period_from);

-- A day can only be settled once. Postgres will do this itself with a
-- range exclusion rather than leaving it to a function somebody might
-- one day call twice at the same moment.
alter table public.pos_stall_settlements
  add constraint pos_stall_settlements_no_overlap
  exclude using gist (
    stall_id with =,
    daterange(period_from, period_to, '[]') with &&
  );

-- ---------------------------------------------------------------------
-- Stamping the stall onto the line
-- ---------------------------------------------------------------------
--
-- Re-created from 0264 -- which is the migration that last defined it,
-- checked rather than assumed -- with one assignment. Everything else,
-- including 0264's two guards and 0266's arithmetic, is carried
-- unchanged.
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

  select i.id, i.name, i.uom_code, i.unit_price, i.sales_tax_code_id, i.stall_id
    into v_item
    from public.items i
   where i.id = p_item and i.org_id = v_org and i.deleted_at is null;
  if v_item.id is null then
    raise exception 'That item is not on this company''s list.'
      using errcode = 'P0002';
  end if;

  v_off := app.pos_item_off(p_item, v_outlet);
  if v_off is not null then
    raise exception '%: %', v_item.name, v_off using errcode = '23514';
  end if;

  select coalesce(ps.block_out_of_stock, false) into v_block
    from public.pos_settings ps where ps.org_id = v_org;
  if coalesce(v_block, false) then
    select p.portions into v_port
      from public.pos_item_portions(v_outlet) p where p.item_id = p_item;
    if v_port is not null then
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
    is_tax_inclusive, line_subtotal, line_total, warehouse_id, note,
    stall_id)
  values (
    v_org, p_sale, v_no, p_item, v_item.name, p_quantity, v_item.uom_code,
    v_price, coalesce(p_discount, 0), v_taxcode, v_rate, v_tax,
    coalesce(v_incl, false), v_net, v_net + v_tax, v_wh, p_note,
    -- The one new line. Frozen here; see the column's comment.
    v_item.stall_id)
  returning id into v_line;

  perform app.recalc_pos_sale(p_sale);
  return v_line;
end;
$$;

revoke all on function app.add_pos_sale_line_internal(
  uuid, uuid, numeric, numeric, numeric, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Setting a stall up
-- ---------------------------------------------------------------------
create or replace function public.upsert_pos_stall(
  p_id         uuid,
  p_outlet     uuid,
  p_code       text,
  p_name       text,
  p_operator   uuid,
  p_commission numeric default 0,
  p_active     boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid; v_id uuid := p_id;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if coalesce(btrim(p_code), '') = '' or coalesce(btrim(p_name), '') = '' then
    raise exception 'A stall needs a number and a name.' using errcode = '23514';
  end if;
  if coalesce(p_commission, 0) < 0 or coalesce(p_commission, 0) >= 100 then
    raise exception
      'A commission is a share of the takings, so it is somewhere between '
      'nothing and all of them.'
      using errcode = '23514';
  end if;
  if not exists (select 1 from public.contacts c
                  where c.id = p_operator and c.org_id = v_org
                    and c.deleted_at is null) then
    raise exception
      'A stall is somebody''s business, so it needs a contact to settle '
      'with.'
      using errcode = 'P0002';
  end if;

  if v_id is null then
    insert into public.pos_stalls (
      org_id, outlet_id, code, name, operator_contact_id, commission_percent,
      is_active)
    values (
      v_org, p_outlet, btrim(p_code), btrim(p_name), p_operator,
      coalesce(p_commission, 0), coalesce(p_active, true))
    returning id into v_id;
  else
    update public.pos_stalls s
       set code = btrim(p_code), name = btrim(p_name),
           operator_contact_id = p_operator,
           commission_percent = coalesce(p_commission, 0),
           is_active = coalesce(p_active, true), updated_at = now()
     where s.id = v_id and s.org_id = v_org;
    if not found then
      raise exception 'No such stall.' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;

revoke all on function public.upsert_pos_stall(
  uuid, uuid, text, text, uuid, numeric, boolean) from public, anon;
grant execute on function public.upsert_pos_stall(
  uuid, uuid, text, text, uuid, numeric, boolean) to authenticated;

-- Which stall sells this dish.
create or replace function public.set_item_stall(
  p_item uuid, p_stall uuid)
returns boolean
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select i.org_id into v_org from public.items i
   where i.id = p_item and i.deleted_at is null;
  if v_org is null then
    raise exception 'No such item.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to write for this organization'
      using errcode = '42501';
  end if;
  if p_stall is not null
     and not exists (select 1 from public.pos_stalls s
                      where s.id = p_stall and s.org_id = v_org) then
    raise exception 'That stall is not this company''s.' using errcode = 'P0002';
  end if;

  update public.items i set stall_id = p_stall, updated_at = now()
   where i.id = p_item;
  return true;
end;
$$;

revoke all on function public.set_item_stall(uuid, uuid) from public, anon;
grant execute on function public.set_item_stall(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What each stall took
-- ---------------------------------------------------------------------
--
-- Settled bills only, and the sale's own completion day in Kuala
-- Lumpur. A parked bill is not takings, and a voided one never was.
--
-- Gross is the line total *net of what the customer did not pay*: a
-- bill discount or a promotion the court gave away comes off the
-- stall's share in proportion, because the court did not collect it
-- either. A court that discounts a whole basket and then settles the
-- stalls on the undiscounted figure is paying for its own promotion
-- twice.
create or replace function public.pos_stall_takings(
  p_outlet uuid,
  p_from   date,
  p_to     date)
returns table (
  stall_id      uuid,
  stall_code    text,
  stall_name    text,
  operator      text,
  line_count    integer,
  gross         numeric,
  commission_percent numeric,
  commission    numeric,
  net           numeric,
  settled       boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;

  return query
  with sold as (
    select l.stall_id,
           l.line_total,
           -- What the whole bill actually came to against what its
           -- lines add up to. One is the customer's money and the other
           -- is the list price. The ride and the rounding are the
           -- court's own -- a stall did not deliver anything and did not
           -- gain two sen by Bank Negara's rule -- so both come off
           -- before the share is worked out.
           s.total_amount
             - coalesce(s.delivery_fee, 0)
             - coalesce(s.rounding_amount, 0) as collected,
           (select sum(x.line_total) from public.pos_sale_lines x
             where x.sale_id = s.id) as listed
      from public.pos_sale_lines l
      join public.pos_sales s on s.id = l.sale_id
     where s.outlet_id = p_outlet
       and s.status = 'completed'
       and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
             between p_from and p_to
       and l.stall_id is not null
  ),
  shared as (
    select sold.stall_id,
           round(sold.line_total
                 * case when coalesce(sold.listed, 0) = 0 then 1
                        else least(sold.collected / sold.listed, 1) end, 2)
             as amount
      from sold
  ),
  totals as (
    select shared.stall_id, count(*)::integer as n, sum(shared.amount) as gross
      from shared group by shared.stall_id
  )
  select st.id, st.code, st.name, c.name,
         coalesce(t.n, 0),
         round(coalesce(t.gross, 0), 2),
         st.commission_percent,
         round(coalesce(t.gross, 0) * st.commission_percent / 100.0, 2),
         round(coalesce(t.gross, 0), 2)
           - round(coalesce(t.gross, 0) * st.commission_percent / 100.0, 2),
         exists (select 1 from public.pos_stall_settlements ss
                  where ss.stall_id = st.id
                    and daterange(ss.period_from, ss.period_to, '[]')
                        && daterange(p_from, p_to, '[]'))
    from public.pos_stalls st
    join public.contacts c on c.id = st.operator_contact_id
    left join totals t on t.stall_id = st.id
   where st.outlet_id = p_outlet
   order by st.code;
end;
$$;

revoke all on function public.pos_stall_takings(uuid, date, date)
  from public, anon;
grant execute on function public.pos_stall_takings(uuid, date, date)
  to authenticated;

comment on function public.pos_stall_takings(uuid, date, date) is
  'What each stall sold over a period and what it is owed. A bill discount comes off the stall''s share in proportion, because the court did not collect it either.';

-- ---------------------------------------------------------------------
-- Paying them
-- ---------------------------------------------------------------------
--
-- One posted purchase bill per stall that sold anything. The stall is a
-- supplier and this is the court buying its food; see the header for
-- why that is the treatment rather than an agent's.
create or replace function public.settle_pos_stalls(
  p_outlet uuid,
  p_from   date,
  p_to     date)
returns table (
  stall_id   uuid,
  stall_name text,
  net        numeric,
  bill_no    text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org   uuid;
  v_row   record;
  v_bill  uuid;
  v_no    text;
  v_acct  uuid;
  v_any   boolean := false;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'purchases') then
    raise exception
      'Settling a stall raises a bill, which needs the purchases module.'
      using errcode = '42501';
  end if;
  if p_to < p_from then
    raise exception 'That period ends before it starts.' using errcode = '23514';
  end if;
  if p_to >= (now() at time zone 'Asia/Kuala_Lumpur')::date then
    raise exception
      'That period is not over yet. Settle up to yesterday at the '
      'earliest, or the last hour of trading is paid for twice.'
      using errcode = '23514';
  end if;

  v_acct := app.stall_purchases_account(v_org);

  for v_row in
    select * from public.pos_stall_takings(p_outlet, p_from, p_to) t
     where t.gross > 0
  loop
    if v_row.settled then
      raise exception
        '% has already been settled for days inside this period. Settling '
        'it again would pay for the same Tuesday twice.', v_row.stall_name
        using errcode = '23514';
    end if;

    v_no := app.next_document_number_internal(v_org, 'bill');

    insert into public.purchase_documents (
      org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
      exchange_rate, status, reference, notes, created_by)
    values (
      v_org, 'bill', v_no, p_to, p_to,
      (select s.operator_contact_id from public.pos_stalls s
        where s.id = v_row.stall_id),
      'MYR', 1, 'draft',
      'Stall ' || v_row.stall_name,
      'Takings ' || to_char(p_from, 'DD/MM/YYYY') || ' to '
                 || to_char(p_to, 'DD/MM/YYYY')
        || ', less ' || trim(to_char(v_row.commission_percent, '999D99'))
        || '% commission',
      auth.uid())
    returning id into v_bill;

    -- One line, at the net. The commission is not a separate charge the
    -- court invoices back: it is the difference between what the
    -- customer paid and what the stall is owed, and inventing a second
    -- document for it would put the same money through the books twice.
    insert into public.purchase_document_lines (
      org_id, document_id, line_no, line_type, description,
      quantity, unit_price, account_id)
    values (
      v_org, v_bill, 1, 'item',
      v_row.stall_name || ' takings less commission',
      1, v_row.net, v_acct);

    perform public.post_purchase_document(v_bill);

    insert into public.pos_stall_settlements (
      org_id, stall_id, period_from, period_to, gross, commission, net,
      bill_id, settled_by)
    values (
      v_org, v_row.stall_id, p_from, p_to, v_row.gross, v_row.commission,
      v_row.net, v_bill, auth.uid());

    v_any := true;

    stall_id   := v_row.stall_id;
    stall_name := v_row.stall_name;
    net        := v_row.net;
    bill_no    := v_no;
    return next;
  end loop;

  if not v_any then
    raise exception 'No stall sold anything over those days.'
      using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.settle_pos_stalls(uuid, date, date)
  from public, anon;
grant execute on function public.settle_pos_stalls(uuid, date, date)
  to authenticated;

comment on function public.settle_pos_stalls(uuid, date, date) is
  'Raises one posted purchase bill per stall for its takings less the court''s commission, and records the period so the same days cannot be paid for twice.';

-- ---------------------------------------------------------------------
-- Reading it back
-- ---------------------------------------------------------------------
create or replace function public.pos_stalls_list(p_outlet uuid)
returns table (
  id                 uuid,
  code               text,
  name               text,
  operator           text,
  operator_contact_id uuid,
  commission_percent numeric,
  item_count         integer,
  is_active          boolean)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select s.id, s.code, s.name, c.name, s.operator_contact_id,
         s.commission_percent,
         (select count(*)::integer from public.items i
           where i.stall_id = s.id and i.deleted_at is null),
         s.is_active
    from public.pos_stalls s
    join public.contacts c on c.id = s.operator_contact_id
   where s.outlet_id = p_outlet
   order by s.code;
end;
$$;

revoke all on function public.pos_stalls_list(uuid) from public, anon;
grant execute on function public.pos_stalls_list(uuid) to authenticated;

create or replace function public.pos_stall_settlements_list(p_outlet uuid)
returns table (
  id          uuid,
  stall_name  text,
  period_from date,
  period_to   date,
  gross       numeric,
  commission  numeric,
  net         numeric,
  bill_no     text,
  paid        numeric,
  created_at  timestamptz)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare v_org uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_org, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  return query
  select ss.id, st.name, ss.period_from, ss.period_to, ss.gross,
         ss.commission, ss.net, d.doc_no, coalesce(d.paid_amount, 0),
         ss.created_at
    from public.pos_stall_settlements ss
    join public.pos_stalls st on st.id = ss.stall_id
    left join public.purchase_documents d on d.id = ss.bill_id
   where st.outlet_id = p_outlet
   order by ss.period_from desc, st.code;
end;
$$;

revoke all on function public.pos_stall_settlements_list(uuid)
  from public, anon;
grant execute on function public.pos_stall_settlements_list(uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------
alter table public.pos_stalls             enable row level security;
alter table public.pos_stall_settlements  enable row level security;

create policy pos_stalls_read on public.pos_stalls for select
  to authenticated using (app.can_read_module(org_id, 'pos'));
create policy pos_stall_settlements_read on public.pos_stall_settlements
  for select to authenticated using (app.can_read_module(org_id, 'pos'));

-- No write policies. A settlement row is what stops a period being paid
-- for twice, and a client that could insert or delete one directly
-- could pay a stall as many times as it liked.

revoke all on public.pos_stalls            from anon, authenticated;
revoke all on public.pos_stall_settlements from anon, authenticated;

grant select on public.pos_stalls            to authenticated;
grant select on public.pos_stall_settlements to authenticated;

create trigger set_updated_at before update on public.pos_stalls
  for each row execute function app.set_updated_at();
