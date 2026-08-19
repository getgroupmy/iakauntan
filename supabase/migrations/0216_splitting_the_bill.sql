-- "Can we pay separately?"
--
-- ## Two different questions wearing the same words
--
-- Splitting by ITEM is structural: this person had the fish, that
-- person had the steak, and the two want separate bills. Lines move to
-- a second sale and each is settled on its own -- two invoices, two
-- receipts, two e-Invoices if anybody asks for one.
--
-- Splitting EVENLY is arithmetic: one bill, four people, one card each.
-- Nothing moves. The sale already takes several tenders, so an even
-- split is four card tenders against one invoice -- which is also the
-- correct answer for LHDN, because there was one supply.
--
-- Conflating them is how a POS ends up issuing four invoices for one
-- meal, or one invoice that three of the four have no record of paying.
--
-- ## The sen that has to go somewhere
--
-- Ten ringgit three ways is 3.3333. Somebody pays 3.34. A split that
-- rounds each share independently collects 9.99 and leaves a sen on the
-- table for ever; one that rounds up collects 10.02 and hands back
-- change nobody asked for. The shares are computed so they sum to the
-- total exactly, with the remainder on the first share, and the test
-- asserts the sum rather than the shares -- because the sum is the
-- property that matters and the shares are just how it is reached.
--
-- ## What moving a line does not disturb
--
-- A moved line keeps its id, so anything pointing at it still does: the
-- modifiers hanging off it, and the kitchen docket line that says it
-- was cooked. Only which bill it is on changes, which is the only thing
-- the customer asked to change.

-- ---------------------------------------------------------------------
-- Splitting by item
-- ---------------------------------------------------------------------
create or replace function public.split_pos_sale(
  p_sale  uuid,
  p_lines uuid[])
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale  public.pos_sales;
  v_new   uuid;
  v_total integer;
  v_moved integer;
  v_line  record;
  v_no    integer := 0;
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
    raise exception 'That bill is % and cannot be split.', v_sale.status
      using errcode = '23514';
  end if;
  if p_lines is null or array_length(p_lines, 1) is null then
    raise exception 'Say which items go on the second bill.'
      using errcode = '23514';
  end if;

  select count(*)::integer into v_total
    from public.pos_sale_lines l where l.sale_id = p_sale;
  select count(*)::integer into v_moved
    from public.pos_sale_lines l
   where l.sale_id = p_sale and l.id = any (p_lines);

  if v_moved = 0 then
    raise exception 'None of those items are on this bill.'
      using errcode = 'P0002';
  end if;
  if v_moved = v_total then
    raise exception
      'That is the whole bill. Move it to another table instead of '
      'splitting it into an empty one.'
      using errcode = '23514';
  end if;

  -- The second bill is the same bill in every way except which lines
  -- are on it: same shift, same till, same table, same customer.
  v_new := public.open_pos_sale(v_sale.register_id, v_sale.contact_id);
  update public.pos_sales s
     set table_id = v_sale.table_id,
         covers = v_sale.covers,
         note = v_sale.note
   where s.id = v_new;

  for v_line in
    select l.id from public.pos_sale_lines l
     where l.sale_id = p_sale and l.id = any (p_lines)
     order by l.line_no
  loop
    v_no := v_no + 1;
    update public.pos_sale_lines l
       set sale_id = v_new, line_no = v_no
     where l.id = v_line.id;
  end loop;

  -- The lines left behind keep their numbers. Renumbering them would
  -- mean an UPDATE that transiently collides with its own unique index,
  -- and a gap in the numbering costs nobody anything -- the bill is
  -- read in line order, not by counting.
  perform app.recalc_pos_sale(p_sale);
  perform app.recalc_pos_sale(v_new);

  return v_new;
end;
$$;

revoke all on function public.split_pos_sale(uuid, uuid[]) from public, anon;
grant execute on function public.split_pos_sale(uuid, uuid[]) to authenticated;

comment on function public.split_pos_sale(uuid, uuid[]) is
  'Moves the named lines onto a second bill on the same table. A moved line keeps its id, so its modifiers and its kitchen docket line follow it.';

-- ---------------------------------------------------------------------
-- Putting one back
-- ---------------------------------------------------------------------
create or replace function public.merge_pos_sales(
  p_into uuid,
  p_from uuid)
returns integer
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_into public.pos_sales;
  v_from public.pos_sales;
  v_no   integer;
  v_line record;
  v_n    integer := 0;
begin
  if p_into = p_from then
    raise exception 'A bill cannot be merged into itself.' using errcode = '23514';
  end if;

  select * into v_into from public.pos_sales where id = p_into;
  select * into v_from from public.pos_sales where id = p_from;
  if v_into.id is null or v_from.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_into.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_into.status <> 'parked' or v_from.status <> 'parked' then
    raise exception
      'Both bills have to still be open. One of these is already settled.'
      using errcode = '23514';
  end if;
  if v_into.outlet_id <> v_from.outlet_id then
    raise exception 'Those bills are in different outlets.' using errcode = '23514';
  end if;

  select coalesce(max(l.line_no), 0) into v_no
    from public.pos_sale_lines l where l.sale_id = p_into;

  for v_line in
    select l.id from public.pos_sale_lines l where l.sale_id = p_from order by l.line_no
  loop
    v_no := v_no + 1;
    v_n  := v_n + 1;
    update public.pos_sale_lines l set sale_id = p_into, line_no = v_no
     where l.id = v_line.id;
  end loop;

  -- A redemption on the bill being absorbed would otherwise vanish with
  -- it. Carried across only when the bill it is joining has none of its
  -- own, because two redemptions on one basket is a decision nobody has
  -- made -- the till should re-apply it and let somebody look.
  if coalesce(v_from.loyalty_points_redeemed, 0) > 0
     and coalesce(v_into.loyalty_points_redeemed, 0) = 0 then
    update public.pos_sales s
       set loyalty_account_id = v_from.loyalty_account_id,
           loyalty_points_redeemed = v_from.loyalty_points_redeemed,
           loyalty_discount = v_from.loyalty_discount
     where s.id = p_into;
  end if;

  -- Dockets follow the food. The kitchen was told by a bill that is
  -- about to stop existing, and a ticket pointing at nothing is a
  -- ticket nobody can trace back to a table.
  update public.pos_kitchen_tickets k set sale_id = p_into where k.sale_id = p_from;

  -- The emptied bill goes. It has no lines, no tenders and no
  -- documents; leaving it parked would put a phantom on the floor plan.
  delete from public.pos_sales where id = p_from;

  perform app.recalc_pos_sale(p_into);
  return v_n;
end;
$$;

revoke all on function public.merge_pos_sales(uuid, uuid) from public, anon;
grant execute on function public.merge_pos_sales(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Splitting evenly, which moves nothing
-- ---------------------------------------------------------------------
--
-- Returns the shares, not a set of bills. One meal is one supply and
-- one invoice; the sale already accepts several tenders, so four people
-- paying by card is four tenders against it.
--
-- The remainder goes on the first share. Some tills put it on the last,
-- which is the same arithmetic and a worse experience: the person who
-- pays last is usually the one who organised the table.
create or replace function public.pos_even_split(
  p_sale uuid,
  p_ways integer)
returns table (
  share_no integer,
  amount   numeric)
language plpgsql
stable
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale  public.pos_sales;
  v_each  numeric;
  v_rest  numeric;
  i       integer;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to read this organization'
      using errcode = '42501';
  end if;
  if coalesce(p_ways, 0) < 1 then
    raise exception 'Split between how many?' using errcode = '23514';
  end if;

  -- Rounded DOWN, so the shares can only be short and the shortfall is
  -- a whole number of sen that lands on one person. Rounding to nearest
  -- can overshoot, and a bill that collects more than it asks for is
  -- the harder mistake to notice.
  v_each := floor(v_sale.total_amount * 100.0 / p_ways) / 100.0;
  v_rest := round(v_sale.total_amount - (v_each * p_ways), 2);

  for i in 1 .. p_ways loop
    share_no := i;
    amount := round(v_each + case when i = 1 then v_rest else 0 end, 2);
    return next;
  end loop;
end;
$$;

grant execute on function public.pos_even_split(uuid, integer) to authenticated;

comment on function public.pos_even_split(uuid, integer) is
  'Equal shares of one bill that sum to it exactly, remainder on the first. Moves nothing: one meal is one supply and one invoice, settled by several tenders.';
