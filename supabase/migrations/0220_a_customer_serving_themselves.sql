-- The kiosk: the customer works the till.
--
-- ## What is different, and what is not
--
-- Not the sale. A kiosk order is a `pos_sales` row that posts the same
-- invoice and receipt as one rung up by a cashier. Three things do
-- change, and each of them is a rule rather than a screen:
--
--   * there is no drawer. A machine in a lobby cannot take a fifty and
--     give change, so a kiosk refuses cash tenders. Not because cash is
--     wrong, but because a shift that counted a drawer the kiosk could
--     add to would be counting money nobody put in it.
--
--   * there is no cashier. `sold_by` is whoever the device is signed in
--     as, and that is the machine, not a person. A kiosk sale that
--     claimed a member of staff served it would be evidence against
--     somebody who was on a break.
--
--   * the customer needs a NUMBER. At a counter the customer is the
--     person standing there; at a kiosk they walk away and watch a
--     screen. That number is the only thing connecting them to their
--     food, so it is short, per outlet, and starts again each day.
--
-- ## The number has to be safe to hand out twice at once
--
-- Two kiosks finishing at the same instant must not both be told 41.
-- The counter is a row, incremented by the insert that reads it, so the
-- database serialises them: `on conflict do update ... returning` is one
-- statement and one lock. A read-then-write in the application would
-- hand out the same number to both, and two customers would come to the
-- counter for one bag.

-- ---------------------------------------------------------------------
-- A till nobody stands behind
-- ---------------------------------------------------------------------
alter table public.pos_registers
  add column if not exists is_kiosk boolean not null default false;

comment on column public.pos_registers.is_kiosk is
  'A register the customer operates. No drawer, no cashier, and orders carry a number the customer watches for.';

alter table public.pos_sales
  add column if not exists order_no integer,
  add column if not exists is_kiosk boolean not null default false;

comment on column public.pos_sales.order_no is
  'The number called out. Per outlet, restarting daily — short enough to read across a room, which is the whole job it has.';

-- ---------------------------------------------------------------------
-- The number
-- ---------------------------------------------------------------------
create table if not exists public.pos_order_counters (
  outlet_id uuid not null references public.pos_outlets (id) on delete cascade,
  on_date   date not null,
  last_no   integer not null default 0,
  primary key (outlet_id, on_date)
);

-- One statement, so two kiosks cannot read the same number. The insert
-- takes the row lock and the update happens inside it; there is no
-- moment between the read and the write for a second caller to slip
-- into, which is exactly the moment a read-then-write leaves open.
create or replace function app.next_kiosk_order_no(p_outlet uuid)
returns integer
language sql
security definer
set search_path = public, app, pg_temp
as $$
  insert into public.pos_order_counters (outlet_id, on_date, last_no)
  values (p_outlet, (now() at time zone 'Asia/Kuala_Lumpur')::date, 1)
  on conflict (outlet_id, on_date)
    do update set last_no = pos_order_counters.last_no + 1
  returning last_no;
$$;

revoke all on function app.next_kiosk_order_no(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Starting an order
-- ---------------------------------------------------------------------
create or replace function public.start_kiosk_order(
  p_register    uuid,
  p_client_uuid uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_reg  public.pos_registers;
  v_sale uuid;
begin
  select * into v_reg from public.pos_registers where id = p_register;
  if v_reg.id is null then
    raise exception 'No such register.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_reg.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if not v_reg.is_kiosk then
    raise exception
      'That register is a staff till. A kiosk order on one would be a '
      'sale with nobody behind it and a drawer that could take cash.'
      using errcode = '23514';
  end if;

  -- Still needs a shift. A kiosk selling into a day nobody opened is a
  -- day whose takings belong to no count at all.
  v_sale := public.open_pos_sale(p_register, null, p_client_uuid);
  update public.pos_sales s set is_kiosk = true where s.id = v_sale;
  return v_sale;
end;
$$;

revoke all on function public.start_kiosk_order(uuid, uuid) from public, anon;
grant execute on function public.start_kiosk_order(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Paying at the machine
-- ---------------------------------------------------------------------
--
-- One tender, because a kiosk cannot split a payment across a card and
-- a handful of coins -- there is nowhere to put the coins.
create or replace function public.complete_kiosk_order(
  p_sale      uuid,
  p_tender    uuid,
  p_amount    numeric default null,
  p_reference text default null)
returns table (
  sale_id    uuid,
  order_no   integer,
  invoice_no text,
  total      numeric)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale public.pos_sales;
  v_kind app.pos_tender_kind;
  v_no   integer;
  v_done record;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such order.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;

  select tt.kind into v_kind from public.pos_tender_types tt
   where tt.id = p_tender and tt.org_id = v_sale.org_id and tt.is_active;
  if v_kind is null then
    raise exception 'That is not a tender this company accepts.'
      using errcode = 'P0002';
  end if;
  if v_kind = 'cash' then
    raise exception
      'A kiosk has no drawer. Send the customer to the counter to pay '
      'in cash.'
      using errcode = '23514';
  end if;

  -- The number is taken BEFORE the sale completes, so a customer who
  -- has paid always has one. Taking it afterwards leaves a window in
  -- which the money is gone and nothing on the screen belongs to them.
  v_no := app.next_kiosk_order_no(v_sale.outlet_id);
  update public.pos_sales s set order_no = v_no where s.id = p_sale;

  select r.sale_id, r.invoice_no, r.total into v_done
    from public.complete_pos_sale(p_sale, jsonb_build_array(jsonb_build_object(
      'type', p_tender,
      'amount', coalesce(p_amount, v_sale.total_amount),
      'reference', p_reference))) r;

  -- Straight to the kitchen, because there is nobody at a kiosk to tap
  -- "send" and the customer is already watching the board for their
  -- number. Only when the outlet has somewhere to send it: a kiosk that
  -- sells cold drinks out of a fridge has no kitchen at all.
  if exists (select 1 from public.pos_kitchen_stations st
              where st.outlet_id = v_sale.outlet_id and st.is_active) then
    perform public.send_order_to_kitchen(p_sale);
  end if;

  sale_id    := v_done.sale_id;
  order_no   := v_no;
  invoice_no := v_done.invoice_no;
  total      := v_done.total;
  return next;
end;
$$;

revoke all on function public.complete_kiosk_order(uuid, uuid, numeric, text)
  from public, anon;
grant execute on function public.complete_kiosk_order(uuid, uuid, numeric, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Paid, then cooked
-- ---------------------------------------------------------------------
--
-- 0215's send refused any sale that was not parked, which was a table-
-- service assumption wearing a general rule: order first, pay at the
-- end. A kiosk is the other way round and so is every fast-food
-- counter -- the money arrives, and only then does anybody start
-- cooking. Restated here so a paid order can reach the kitchen, which
-- is where the probe for this migration found the assumption.

create or replace function public.send_order_to_kitchen(p_sale uuid)
returns table (
  station    text,
  ticket_id  uuid,
  ticket_no  bigint,
  line_count integer)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_table  text;
  v_gaps   integer;
  v_line   record;
  v_st     uuid;
  v_ticket uuid;
  -- Which station got which ticket in THIS call. Keyed rather than
  -- re-queried by timestamp: `now()` is the transaction's clock, so two
  -- sends inside one transaction would look identical to a lookup on
  -- `sent_at` and the second round would be added to the first round's
  -- docket.
  v_made   jsonb := '{}'::jsonb;
  v_now    timestamptz := clock_timestamp();
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  -- Paid is not too late. 0215 refused anything that was not parked,
  -- which quietly assumed table service -- order first, pay at the end.
  -- A kiosk and a fast-food counter take the money and THEN cook, and
  -- an order that has been paid for is the one a quick-service kitchen
  -- most obviously should be making. Only a voided sale has nothing to
  -- send, because nothing about it happened.
  if v_sale.status = 'voided' then
    raise exception 'That order was voided, so there is nothing to send.'
      using errcode = '23514';
  end if;

  -- A cook cannot guess "choose one". 0214 reports the gaps; this is
  -- the first moment at which an unanswered question actually matters,
  -- and refusing here is cheaper than refusing every line as it is rung.
  select count(*)::integer into v_gaps from public.pos_line_modifier_gaps(p_sale);
  if v_gaps > 0 then
    raise exception
      'There are % choices still to make on this order.', v_gaps
      using errcode = '23514';
  end if;

  select t.code into v_table from public.pos_tables t where t.id = v_sale.table_id;

  -- Exactly the lines the kitchen has never seen. See the header: this
  -- is the whole point of the column.
  for v_line in
    select l.* from public.pos_sale_lines l
     where l.sale_id = p_sale
       and l.sent_to_kitchen_at is null
     order by l.line_no
  loop
    v_st := app.pos_route_item(v_sale.outlet_id, v_line.item_id);
    if v_st is null then
      raise exception
        'Nothing tells the kitchen where "%" is made, and this outlet '
        'has no default station.', v_line.description
        using errcode = '23514';
    end if;

    -- One ticket per station per send. A station that already has a
    -- ticket from THIS send gets the line added to it; one from an
    -- earlier round is left alone, because it may already be cooking.
    v_ticket := (v_made ->> v_st::text)::uuid;
    if v_ticket is null then
      insert into public.pos_kitchen_tickets
        (org_id, outlet_id, station_id, sale_id, table_code, covers, sent_at, sent_by)
      values (v_sale.org_id, v_sale.outlet_id, v_st, p_sale, v_table,
              v_sale.covers, v_now, auth.uid())
      returning id into v_ticket;
      v_made := v_made || jsonb_build_object(v_st::text, v_ticket::text);
    end if;

    insert into public.pos_kitchen_ticket_lines
      (org_id, ticket_id, sale_line_id, description, quantity, modifiers, note)
    values (v_sale.org_id, v_ticket, v_line.id, v_line.description, v_line.quantity,
            app.pos_line_modifier_text(v_line.id), v_line.note);

    update public.pos_sale_lines l
       set sent_to_kitchen_at = v_now where l.id = v_line.id;
  end loop;

  return query
    select st.name, k.id, k.ticket_no,
           (select count(*)::integer from public.pos_kitchen_ticket_lines kl
             where kl.ticket_id = k.id)
      from public.pos_kitchen_tickets k
      join public.pos_kitchen_stations st on st.id = k.station_id
     where k.id in (select (value #>> '{}')::uuid from jsonb_each(v_made))
     order by st.sort_order, st.name;
end;
$$;

-- ---------------------------------------------------------------------
-- The screen the customer watches
-- ---------------------------------------------------------------------
--
-- Two columns, because that is what the board over the counter says:
-- being made, and ready. The kitchen's own statuses are collapsed into
-- those two, since "cooking" and "new" are the same thing to somebody
-- holding a receipt.
create or replace function public.kiosk_order_board(p_outlet uuid)
returns table (
  order_no  integer,
  state     text,
  placed_at timestamptz,
  minutes   integer)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.order_no,
         case when not exists (
                select 1 from public.pos_kitchen_tickets k
                 where k.sale_id = s.id and k.status in ('new', 'cooking'))
              then 'ready' else 'making' end,
         s.completed_at,
         floor(extract(epoch from (now() - s.completed_at)) / 60)::integer
    from public.pos_sales s
   where s.outlet_id = p_outlet
     and s.order_no is not null
     and s.status = 'completed'
     and s.completed_at > now() - interval '4 hours'
     and exists (select 1 from public.pos_kitchen_tickets k
                  where k.sale_id = s.id and k.status <> 'served')
     and app.can_read_module(s.org_id, 'pos')
   order by s.order_no;
$$;

grant execute on function public.kiosk_order_board(uuid) to authenticated;

comment on function public.kiosk_order_board(uuid) is
  'Order numbers still waiting, and whether they are being made or ready. An order whose food has been handed over drops off, because the customer has gone.';

-- ---------------------------------------------------------------------
-- Who may look
-- ---------------------------------------------------------------------
alter table public.pos_order_counters enable row level security;

-- Read only, and barely that. The counter is machinery, not a record:
-- it is written by the one statement that hands numbers out, and a
-- client that could set it could give two customers the same number.
create policy pos_order_counters_read on public.pos_order_counters for select
  using (app.can_read_module(
           (select o.org_id from public.pos_outlets o where o.id = outlet_id), 'pos'));

grant select on public.pos_order_counters to authenticated;
