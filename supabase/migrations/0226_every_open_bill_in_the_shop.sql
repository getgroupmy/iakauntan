-- ---------------------------------------------------------------------
-- 0226  Every open bill in the shop, and moving one to the drawer that
--       is going to take the money for it
-- ---------------------------------------------------------------------
--
-- Until now a till could only see the bills parked on itself. That is
-- right for a corner shop with one register and wrong for everything
-- else the module sells to: a waiter opens table 6 on a tablet, the
-- customer walks to the counter, and the counter cannot see the bill at
-- all. The same hole hides a kiosk order somebody wants to add to, and
-- a bill left on a till whose battery died.
--
-- So `pos_open_orders` answers the question the room actually asks —
-- what is open in this shop — rather than the question one device can
-- answer about itself.
--
-- ## Seeing a bill is not the same as taking it
--
-- The listing is read-only and outlet-wide. Settling somebody else's
-- bill is a second, deliberate act, because it moves money between
-- drawers:
--
--   * `pos_sales.shift_id` is what `app.pos_expected_cash` counts, so a
--     bill settled in cash at the counter while it still belongs to the
--     tablet's shift puts the counter's cash into the tablet's expected
--     figure. Both drawers then fail their count, in opposite
--     directions, for a reason neither cashier can see.
--   * `close_pos_shift` refuses while a sale is parked against the
--     shift. A waiter whose tablet holds a bill the counter is about to
--     settle cannot go home.
--
-- `claim_pos_sale` moves the bill — register and shift together, since
-- separating them is what causes the first problem — and records where
-- it started in `opened_on_register_id`. That column exists so the
-- question "why is a bill from the tablet in my drawer" has an answer
-- in the row rather than in somebody's memory.
--
-- Nothing else moves. The lines, the modifiers, the kitchen tickets and
-- the invoice numbering are untouched: this is a change of till, not a
-- change of sale.

-- ---------------------------------------------------------------------
-- Where the bill started
-- ---------------------------------------------------------------------
alter table public.pos_sales
  add column if not exists opened_on_register_id uuid
    references public.pos_registers(id) on delete set null;

comment on column public.pos_sales.opened_on_register_id is
  'The till the bill was opened on, set only when another till later claimed it. Null means it never moved.';

-- ---------------------------------------------------------------------
-- What is open in this shop
-- ---------------------------------------------------------------------
--
-- Everything parked in the outlet, whichever till holds it, with enough
-- on each row to be recognised without opening it: the table it is on,
-- how many are sitting there, whose name is on it, how long it has been
-- open, and whether the kitchen already has some of it.
create or replace function public.pos_open_orders(p_outlet uuid)
returns table (
  sale_id       uuid,
  sale_no       text,
  register_id   uuid,
  register_code text,
  register_name text,
  is_kiosk      boolean,
  order_no      integer,
  table_id      uuid,
  table_name    text,
  covers        integer,
  contact_name  text,
  opened_at     timestamptz,
  minutes       integer,
  line_count    integer,
  sent_count    integer,
  total         numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  select s.id,
         s.sale_no,
         s.register_id,
         r.code,
         r.name,
         s.is_kiosk,
         s.order_no,
         s.table_id,
         -- A table's name is optional and its code is not, so the label
         -- falls back rather than showing a blank chip on the one row a
         -- waiter is looking for.
         coalesce(t.name, t.code),
         s.covers,
         c.name,
         s.opened_at,
         floor(extract(epoch from (now() - s.opened_at)) / 60)::integer,
         (select count(*)::integer from public.pos_sale_lines l
           where l.sale_id = s.id),
         -- Sent, not cooked. What a cashier needs off this row is
         -- whether anything on the bill is beyond taking back, which is
         -- the same rule `void_pos_sale_line` applies one line at a
         -- time.
         (select count(*)::integer from public.pos_sale_lines l
           where l.sale_id = s.id and l.sent_to_kitchen_at is not null),
         s.total_amount
    from public.pos_sales s
    join public.pos_registers r on r.id = s.register_id
    left join public.pos_tables t on t.id = s.table_id
    left join public.contacts c on c.id = s.contact_id
   where s.outlet_id = p_outlet
     and s.status = 'parked'
     and app.can_read_module(s.org_id, 'pos')
   order by s.opened_at;
$$;

grant execute on function public.pos_open_orders(uuid) to authenticated;

comment on function public.pos_open_orders(uuid) is
  'Every bill still open in an outlet, whichever till holds it. Read-only: taking one onto this till is claim_pos_sale.';

-- ---------------------------------------------------------------------
-- Taking one onto this till
-- ---------------------------------------------------------------------
create or replace function public.claim_pos_sale(
  p_sale     uuid,
  p_register uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale  public.pos_sales;
  v_reg   public.pos_registers;
  v_shift uuid;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status
      using errcode = '23514';
  end if;

  select * into v_reg from public.pos_registers where id = p_register;
  if v_reg.id is null or v_reg.org_id <> v_sale.org_id then
    raise exception 'No such register.' using errcode = 'P0002';
  end if;

  -- Already here. A cashier who taps a bill that is on their own till
  -- wants to open it, not to be told off.
  if v_sale.register_id = p_register then
    return p_sale;
  end if;

  -- One outlet. A bill cannot walk to another shop: the stock it will
  -- move comes out of the outlet's warehouse and the receipt carries
  -- the outlet's header.
  if v_reg.outlet_id <> v_sale.outlet_id then
    raise exception
      'That bill belongs to another outlet. It has to be settled where '
      'it was rung up.'
      using errcode = '23514';
  end if;

  -- The drawer that is going to take the money has to be open, for the
  -- same reason a sale cannot start without one: takings that belong to
  -- no count belong to nobody.
  select s.id into v_shift from public.pos_shifts s
   where s.register_id = p_register and s.status <> 'closed'
   limit 1;
  if v_shift is null then
    raise exception
      'Open this till''s drawer before taking a bill onto it.'
      using errcode = '23514';
  end if;

  update public.pos_sales s
     set register_id = p_register,
         shift_id    = v_shift,
         -- Where it started, kept once. A bill claimed twice still says
         -- where it was rung up rather than where it last stopped.
         opened_on_register_id =
           coalesce(s.opened_on_register_id, s.register_id),
         updated_at  = now()
   where s.id = p_sale;

  return p_sale;
end;
$$;

revoke all on function public.claim_pos_sale(uuid, uuid) from public, anon;
grant execute on function public.claim_pos_sale(uuid, uuid) to authenticated;

comment on function public.claim_pos_sale(uuid, uuid) is
  'Moves an open bill onto this till, register and shift together, so the drawer that takes the money is the drawer it counts against.';
