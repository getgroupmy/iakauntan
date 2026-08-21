-- =====================================================================
-- A price the manager takes off
--
-- `add_pos_sale_line` has taken a `p_discount` since 0209 and
-- `pos_sale_lines` has carried `discount_percent` and
-- `discount_amount` since 0208. Nothing has ever passed either. The
-- till has no discount button, so a cashier asked to knock two ringgit
-- off a bill re-rings the line at a made-up price -- which works,
-- reports nothing, and is indistinguishable from theft.
--
-- This is the same shape as modifiers before 0250: the storage was
-- built, the writer never was.
--
-- ---------------------------------------------------------------------
-- Who may, and what they must say
--
-- Giving money away is the void problem again, so it gets the void
-- answer: `pos_discount`, an entry in 0244's `access_permissions`. A
-- company that has never defined an access type is unaffected and every
-- cashier may discount, exactly as every cashier may void. A company
-- that has defined access types must grant it, which is the point.
--
-- A reason is required and not from a list. Voids have an enum because
-- the kitchen cares which of four things happened to the food; a
-- discount has no such short list -- "staff meal", "hair in the soup",
-- "regular, third time this week" are all real and none of them is a
-- category anybody could have written down in advance. What matters is
-- that a person typed something and their name is on it.
--
-- ---------------------------------------------------------------------
-- A rate is not an amount, and the difference shows up later
--
-- "Ten per cent off" and "four ringgit off" are not the same promise.
-- The first still means ten per cent after another plate arrives; the
-- second still means four ringgit. So both are stored and the
-- percentage is re-applied by `recalc_pos_sale` every time the basket
-- changes, which is the only way a bill discount can survive a waiter
-- adding a drink.
--
-- ---------------------------------------------------------------------
-- Where the money comes off
--
-- A line discount reduces that line: its subtotal, its tax, and
-- therefore what the customer is charged for it. That is right, because
-- a discount on a taxed plate reduces the tax on the plate -- SST is
-- charged on what was actually paid.
--
-- A bill discount cannot be pushed into the lines without deciding
-- which plate absorbed it, and any such decision is invented. It sits
-- on the header, exactly where 0212 put the loyalty redemption, and
-- `complete_pos_sale` adds the two together into the invoice's
-- `discount_amount` -- which `prepare_einvoice` already maps to the
-- MyInvois total discount, so LHDN is told the same number the
-- customer paid.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The permission
-- ---------------------------------------------------------------------
insert into public.access_permissions
  (code, module_code, name, description, sort_order)
values
  ('pos_discount', 'pos', 'Take money off a bill',
   'Discounting a line or a whole bill at the counter. Without this a '
   'cashier can still ring items up and take payment; what they cannot '
   'do is change what the shop charges for them.',
   2)
on conflict (code) do update
   set module_code = excluded.module_code,
       name        = excluded.name,
       description = excluded.description,
       sort_order  = excluded.sort_order;

create or replace function app.can_discount_pos(p_org_id uuid)
returns boolean
language sql
stable
set search_path = public, app, pg_temp
as $$
  select app.has_permission(p_org_id, 'pos_discount');
$$;

revoke all on function app.can_discount_pos(uuid) from public, anon;
grant execute on function app.can_discount_pos(uuid) to authenticated;

comment on function app.can_discount_pos(uuid) is
  'Whether this member may reduce what a bill charges. Working the till is the floor, checked inside has_permission; discounting is granted on top of it.';

-- ---------------------------------------------------------------------
-- What the record has to carry
-- ---------------------------------------------------------------------
--
-- On the line and on the sale rather than in a table of their own,
-- because the discount is the live state of the bill and a second copy
-- of live state is a second copy that can disagree with the first. The
-- report at the bottom reads these columns; there is nothing else to
-- keep in step with.
alter table public.pos_sale_lines
  add column if not exists discount_reason text,
  add column if not exists discounted_by uuid references auth.users(id)
    on delete set null,
  add column if not exists discounted_at timestamptz;

alter table public.pos_sales
  add column if not exists bill_discount numeric(18, 2) not null default 0
    check (bill_discount >= 0),
  add column if not exists bill_discount_percent numeric(9, 4) not null default 0
    check (bill_discount_percent >= 0 and bill_discount_percent <= 100),
  add column if not exists bill_discount_reason text,
  add column if not exists bill_discounted_by uuid references auth.users(id)
    on delete set null,
  add column if not exists bill_discounted_at timestamptz;

comment on column public.pos_sales.bill_discount is
  'Money taken off the whole bill. Recomputed from bill_discount_percent on every recalculation when a percentage was given, so a rate survives another plate arriving.';
comment on column public.pos_sales.bill_discount_percent is
  'The rate, when the discount was given as one. Zero means the amount in bill_discount was given flat and stays flat.';
comment on column public.pos_sale_lines.discount_reason is
  'Why this line was reduced, in the words of whoever reduced it. Free text on purpose: unlike a void there is no short list of reasons a shop knocks money off.';

-- ---------------------------------------------------------------------
-- Recalculating a basket that now has two headers' worth of discount
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0212. What is new is the bill discount, and the
-- order in which the two headers apply: the percentage is taken off the
-- taxed basket first, then the redemption comes off what is left. That
-- order matters and it is the one that favours the customer -- a member
-- with a 10% staff discount and 500 points spends the points on the
-- discounted price, not the shelf price.
create or replace function app.recalc_pos_sale(p_sale uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sub numeric; v_tax numeric; v_disc numeric;
  v_loy numeric; v_pct numeric; v_bill numeric; v_gross numeric;
begin
  select coalesce(sum(l.line_subtotal), 0),
         coalesce(sum(l.tax_amount), 0),
         coalesce(sum(l.discount_amount), 0)
    into v_sub, v_tax, v_disc
    from public.pos_sale_lines l where l.sale_id = p_sale;

  select coalesce(s.loyalty_discount, 0),
         coalesce(s.bill_discount_percent, 0),
         coalesce(s.bill_discount, 0)
    into v_loy, v_pct, v_bill
    from public.pos_sales s where s.id = p_sale;

  v_gross := round(v_sub + v_tax, 2);

  -- A rate is re-applied; a flat amount is left where it was put. Both
  -- are capped at the basket, because a discount that exceeds the bill
  -- is a shop handing out cash.
  if v_pct > 0 then
    v_bill := round(v_gross * v_pct / 100.0, 2);
  end if;
  v_bill := least(greatest(v_bill, 0), v_gross);

  update public.pos_sales s
     set subtotal = v_sub,
         tax_amount = v_tax,
         discount_amount = v_disc,
         bill_discount = v_bill,
         -- Never below zero: points and discounts together cannot buy
         -- more than the basket and hand back the difference in cash.
         total_amount = greatest(round(v_gross - v_bill - v_loy, 2), 0)
   where s.id = p_sale;
end;
$$;

-- ---------------------------------------------------------------------
-- Taking money off one line
-- ---------------------------------------------------------------------
--
-- Pass a percentage or an amount, not both. Pass neither to put the
-- line back to its full price, which is how a discount typed on the
-- wrong line is undone.
create or replace function public.discount_pos_sale_line(
  p_line    uuid,
  p_percent numeric default null,
  p_amount  numeric default null,
  p_reason  text default null)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_line   public.pos_sale_lines;
  v_status app.pos_sale_status;
  v_pct    numeric := 0;
  v_amt    numeric := 0;
  v_full   numeric;
  v_gross  numeric;
  v_net    numeric;
  v_tax    numeric;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into v_line from public.pos_sale_lines where id = p_line;
  if v_line.id is null then
    raise exception 'No such line.' using errcode = 'P0002';
  end if;

  if not app.can_discount_pos(v_line.org_id) then
    raise exception
      'Taking money off a bill needs the discount permission. Ask a '
      'manager to ring it in.'
      using errcode = '42501';
  end if;

  select s.status into v_status from public.pos_sales s where s.id = v_line.sale_id;
  if v_status <> 'parked' then
    raise exception
      'That bill is % and what it charged cannot be changed. Refund it '
      'instead.', v_status
      using errcode = '23514';
  end if;

  if p_percent is not null and p_amount is not null then
    raise exception
      'A discount is either a percentage or an amount, not both.'
      using errcode = '23514';
  end if;

  -- What the line would come to at full price. Everything below is
  -- measured against this rather than against `line_subtotal`, which
  -- already has any earlier discount taken out of it -- discounting a
  -- discounted line twice would otherwise compound quietly.
  v_full := round(v_line.unit_price * v_line.quantity, 2);

  if p_percent is not null then
    if p_percent < 0 or p_percent > 100 then
      raise exception 'A discount runs from nought to a hundred per cent.'
        using errcode = '23514';
    end if;
    v_pct := p_percent;
    v_amt := round(v_full * v_pct / 100.0, 2);
  elsif p_amount is not null then
    if p_amount < 0 then
      raise exception 'A discount cannot add money to a line.'
        using errcode = '23514';
    end if;
    if p_amount > v_full then
      raise exception
        'That is more than the line comes to (%). Take the line off '
        'instead.', v_full
        using errcode = '23514';
    end if;
    v_amt := p_amount;
  end if;

  -- Something given away needs a name against it. Putting a line back
  -- to full price does not: nothing was given.
  if v_amt > 0 and v_reason is null then
    raise exception 'Say why the price is coming down.' using errcode = '23514';
  end if;

  -- The same split `add_pos_sale_line` performs, redone because the
  -- amount being taxed has changed.
  v_gross := v_full - v_amt;
  if v_line.is_tax_inclusive and v_line.tax_rate > 0 then
    v_net := round(v_gross / (1 + v_line.tax_rate / 100.0), 2);
    v_tax := round(v_gross - v_net, 2);
  else
    v_net := round(v_gross, 2);
    v_tax := round(v_net * v_line.tax_rate / 100.0, 2);
  end if;

  update public.pos_sale_lines l
     set discount_percent = v_pct,
         discount_amount  = v_amt,
         line_subtotal    = v_net,
         tax_amount       = v_tax,
         line_total       = v_net + v_tax,
         discount_reason  = case when v_amt > 0 then v_reason end,
         discounted_by    = case when v_amt > 0 then auth.uid() end,
         discounted_at    = case when v_amt > 0 then now() end
   where l.id = p_line;

  perform app.recalc_pos_sale(v_line.sale_id);
  return p_line;
end;
$$;

revoke all on function public.discount_pos_sale_line(uuid, numeric, numeric, text)
  from public, anon;
grant execute on function public.discount_pos_sale_line(uuid, numeric, numeric, text)
  to authenticated;

comment on function public.discount_pos_sale_line(uuid, numeric, numeric, text) is
  'Reduces one line, by a percentage or by an amount, with a reason and a name against it. Neither argument clears the discount. Measured against the full price so discounting twice does not compound.';

-- ---------------------------------------------------------------------
-- Taking money off the whole bill
-- ---------------------------------------------------------------------
create or replace function public.discount_pos_sale(
  p_sale    uuid,
  p_percent numeric default null,
  p_amount  numeric default null,
  p_reason  text default null)
returns numeric
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale   public.pos_sales;
  v_gross  numeric;
  v_pct    numeric := 0;
  v_amt    numeric := 0;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;

  if not app.can_discount_pos(v_sale.org_id) then
    raise exception
      'Taking money off a bill needs the discount permission. Ask a '
      'manager to ring it in.'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception
      'That bill is % and what it charged cannot be changed. Refund it '
      'instead.', v_sale.status
      using errcode = '23514';
  end if;

  if p_percent is not null and p_amount is not null then
    raise exception
      'A discount is either a percentage or an amount, not both.'
      using errcode = '23514';
  end if;

  v_gross := round(coalesce(v_sale.subtotal, 0) + coalesce(v_sale.tax_amount, 0), 2);

  if p_percent is not null then
    if p_percent < 0 or p_percent > 100 then
      raise exception 'A discount runs from nought to a hundred per cent.'
        using errcode = '23514';
    end if;
    v_pct := p_percent;
    v_amt := round(v_gross * v_pct / 100.0, 2);
  elsif p_amount is not null then
    if p_amount < 0 then
      raise exception 'A discount cannot add money to a bill.'
        using errcode = '23514';
    end if;
    if p_amount > v_gross then
      raise exception
        'That is more than the bill comes to (%).', v_gross
        using errcode = '23514';
    end if;
    v_amt := p_amount;
  end if;

  if v_amt > 0 and v_reason is null then
    raise exception 'Say why the bill is coming down.' using errcode = '23514';
  end if;

  update public.pos_sales s
     set bill_discount_percent = v_pct,
         bill_discount         = v_amt,
         bill_discount_reason  = case when v_amt > 0 then v_reason end,
         bill_discounted_by    = case when v_amt > 0 then auth.uid() end,
         bill_discounted_at    = case when v_amt > 0 then now() end
   where s.id = p_sale;

  -- Which recomputes `bill_discount` from the rate when one was given,
  -- and caps it at the basket either way.
  perform app.recalc_pos_sale(p_sale);

  select s.bill_discount into v_amt from public.pos_sales s where s.id = p_sale;
  return v_amt;
end;
$$;

revoke all on function public.discount_pos_sale(uuid, numeric, numeric, text)
  from public, anon;
grant execute on function public.discount_pos_sale(uuid, numeric, numeric, text)
  to authenticated;

comment on function public.discount_pos_sale(uuid, numeric, numeric, text) is
  'Reduces a whole bill, by a percentage or by an amount. A percentage is re-applied whenever the basket changes; an amount stays as given. Returns what came off.';

-- ---------------------------------------------------------------------
-- Splitting and merging, now that a bill can carry a discount
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0216, for one paragraph each.
--
-- A rate travels: ten per cent off applies to whatever ends up on each
-- half, and re-applies itself through `recalc_pos_sale`. A flat amount
-- does not travel, because there is no honest way to decide how much of
-- four ringgit belongs to the plates that moved. It stays on the bill
-- it was given on and the till can give the second bill its own.
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
  v_line  record;
  v_no    integer := 0;
  v_moved integer;
  v_total integer;
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
         note = v_sale.note,
         -- The rate follows the food; the flat amount does not. See
         -- the note above this function.
         bill_discount_percent = v_sale.bill_discount_percent,
         bill_discount_reason  =
           case when coalesce(v_sale.bill_discount_percent, 0) > 0
                then v_sale.bill_discount_reason end,
         bill_discounted_by    =
           case when coalesce(v_sale.bill_discount_percent, 0) > 0
                then v_sale.bill_discounted_by end,
         bill_discounted_at    =
           case when coalesce(v_sale.bill_discount_percent, 0) > 0
                then v_sale.bill_discounted_at end
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

  -- Same rule for a discount, and for the same reason: the bill it was
  -- given on is about to stop existing, and two discounts on one basket
  -- is nobody's decision. Note the asymmetry with a split -- here a
  -- flat amount does travel, because the food it was given against is
  -- travelling with it and the alternative is losing it silently.
  if (coalesce(v_from.bill_discount, 0) > 0
      or coalesce(v_from.bill_discount_percent, 0) > 0)
     and coalesce(v_into.bill_discount, 0) = 0
     and coalesce(v_into.bill_discount_percent, 0) = 0 then
    update public.pos_sales s
       set bill_discount_percent = v_from.bill_discount_percent,
           bill_discount         = v_from.bill_discount,
           bill_discount_reason  = v_from.bill_discount_reason,
           bill_discounted_by    = v_from.bill_discounted_by,
           bill_discounted_at    = v_from.bill_discounted_at
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

-- ---------------------------------------------------------------------
-- Who gave what away
-- ---------------------------------------------------------------------
--
-- The report the permission exists for. `pos_void_summary` answers
-- "where did the food go"; this answers "where did the price go", and
-- the two together are what an owner reads on a Monday morning.
--
-- One row per person per day, because the pattern worth seeing is a
-- person: one cashier discounting every Tuesday afternoon is visible
-- here and invisible in a total. Line discounts and bill discounts are
-- separate columns rather than one sum, since they are different acts
-- -- knocking a burnt steak off a bill is not the same as taking ten
-- per cent off the whole table for a regular.
--
-- Voided bills are excluded. A discount on a bill that was then written
-- off never reduced anything the shop was paid, and counting it would
-- report the same money twice, once here and once in the void report.
create or replace function public.pos_discount_summary(
  p_org  uuid,
  p_from date,
  p_to   date)
returns table (
  on_date        date,
  outlet_id      uuid,
  outlet_name    text,
  given_by       uuid,
  given_by_name  text,
  line_count     integer,
  line_value     numeric,
  bill_count     integer,
  bill_value     numeric,
  total_value    numeric)
language sql
stable
security definer
set search_path = public, app, pg_temp
as $$
  with given_on_lines as (
    select (s.opened_at at time zone 'Asia/Kuala_Lumpur')::date as d,
           s.outlet_id as oid,
           l.discounted_by as who,
           count(*)::integer as n,
           sum(l.discount_amount) as v
      from public.pos_sale_lines l
      join public.pos_sales s on s.id = l.sale_id
     where s.org_id = p_org
       and s.status <> 'voided'
       and l.discount_amount > 0
       and (s.opened_at at time zone 'Asia/Kuala_Lumpur')::date
             between p_from and p_to
     group by 1, 2, 3
  ),
  given_on_bills as (
    select (s.opened_at at time zone 'Asia/Kuala_Lumpur')::date as d,
           s.outlet_id as oid,
           s.bill_discounted_by as who,
           count(*)::integer as n,
           sum(s.bill_discount) as v
      from public.pos_sales s
     where s.org_id = p_org
       and s.status <> 'voided'
       and s.bill_discount > 0
       and (s.opened_at at time zone 'Asia/Kuala_Lumpur')::date
             between p_from and p_to
     group by 1, 2, 3
  ),
  -- Every day-shop-person that appears in either half. Unqualified
  -- column names are avoided throughout: the OUT parameters of this
  -- function share their names with the columns being read, and an
  -- unqualified reference is ambiguous rather than merely unclear.
  every_pair as (
    select gl.d, gl.oid, gl.who from given_on_lines gl
    union
    select gb.d, gb.oid, gb.who from given_on_bills gb
  )
  select b.d,
         b.oid,
         o.name,
         b.who,
         -- Null when the person has since been deleted from the
         -- company. The row stays, because the money still went.
         coalesce(p.full_name, 'Somebody who has left'),
         coalesce(l.n, 0),
         coalesce(l.v, 0),
         coalesce(bi.n, 0),
         coalesce(bi.v, 0),
         coalesce(l.v, 0) + coalesce(bi.v, 0)
    from every_pair b
    join public.pos_outlets o on o.id = b.oid
    left join public.profiles p on p.id = b.who
    left join given_on_lines l  on l.d = b.d and l.oid = b.oid
                               and l.who is not distinct from b.who
    left join given_on_bills bi on bi.d = b.d and bi.oid = b.oid
                               and bi.who is not distinct from b.who
   where app.can_read_module(p_org, 'pos')
   order by b.d desc, coalesce(l.v, 0) + coalesce(bi.v, 0) desc;
$$;

grant execute on function public.pos_discount_summary(uuid, date, date)
  to authenticated;

comment on function public.pos_discount_summary(uuid, date, date) is
  'What was discounted, by whom, on which day and in which shop. One row per person per day, line and bill discounts kept apart, written-off bills excluded so the same money is not reported twice.';

-- ---------------------------------------------------------------------
-- Completing a sale that carries a bill discount
-- ---------------------------------------------------------------------
--
-- Replaced whole from 0212 for one addition: the invoice header's
-- discount is now the redemption plus the bill discount rather than the
-- redemption alone.
--
-- The money was already right without this -- `total_amount` comes from
-- `pos_sales.total_amount`, which `recalc_pos_sale` has already reduced.
-- What was wrong was the *description* of it: an invoice charging 26.00
-- for 30.00 of food would have said its discount was nought, and
-- `prepare_einvoice` would have passed that nought to LHDN. A customer
-- reading the e-Invoice would find lines that do not add up to the
-- total, which is exactly the discrepancy an audit is looking for.
create or replace function public.complete_pos_sale(
  p_sale    uuid,
  p_tenders jsonb,
  p_contact uuid default null)
returns table (
  sale_id     uuid,
  invoice_no  text,
  total       numeric,
  cash_due    numeric,
  change_due  numeric,
  rounding    numeric)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale     public.pos_sales;
  v_outlet   public.pos_outlets;
  v_round    boolean;
  v_noncash  numeric := 0;
  v_cashin   numeric := 0;
  v_cashdue  numeric;
  v_adj      numeric;
  v_change   numeric;
  v_contact  uuid;
  v_inv      uuid;
  v_rcp      uuid;
  v_no       text;
  v_line     record;
  v_t        record;
  v_n        integer := 0;
  v_kind     app.pos_tender_kind;
  v_bank     uuid;
  v_mode     text;
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
  -- Aliased, because `sale_id` is also an OUT parameter of this
  -- function and plpgsql cannot tell which one an unqualified reference
  -- means. It refuses rather than guessing, which is the right choice
  -- and only says so at run time.
  if not exists (select 1 from public.pos_sale_lines l where l.sale_id = p_sale) then
    raise exception 'There is nothing on this sale to pay for.'
      using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  select coalesce(ps.round_cash_to_5sen, true) into v_round
    from public.pos_settings ps where ps.org_id = v_sale.org_id;
  v_round := coalesce(v_round, true);

  -- --------------------------------------------------------------
  -- What is being paid with what
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid   as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference'     as reference
      from jsonb_array_elements(coalesce(p_tenders, '[]'::jsonb)) e
  loop
    if v_t.amount is null or v_t.amount <= 0 then
      raise exception 'A tender needs an amount.' using errcode = '23514';
    end if;
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id and tt.org_id = v_sale.org_id and tt.is_active;
    if v_kind is null then
      raise exception 'That is not a tender this company accepts.'
        using errcode = 'P0002';
    end if;
    if v_kind = 'cash' then
      v_cashin := v_cashin + v_t.amount;
    else
      v_noncash := v_noncash + v_t.amount;
    end if;
    v_n := v_n + 1;
  end loop;

  -- A basket covered entirely by points has nothing left to tender,
  -- and that is a completed sale rather than an unpaid one. Without
  -- this, a customer with enough points to clear the till could put
  -- them all against the basket and then find the sale could not be
  -- rung up at all -- a dead end reachable from the screen that offers
  -- the redemption.
  if v_n = 0 and v_sale.total_amount > 0 then
    raise exception 'A sale has to be paid for.' using errcode = '23514';
  end if;

  -- 0208's rule: round what is left after everything that is not cash.
  v_cashdue := app.pos_cash_due(v_sale.total_amount, v_noncash, v_round);
  v_adj     := app.pos_rounding_adjustment(v_sale.total_amount, v_noncash, v_round);
  v_change  := round(v_cashin - v_cashdue, 2);

  if v_change < 0 then
    raise exception
      'Short by %. The customer still owes that much.', -v_change
      using errcode = '23514';
  end if;
  -- Non-cash cannot over-pay: a card charged more than the basket is a
  -- refund waiting to happen, not a sale.
  if v_noncash > v_sale.total_amount + 0.005 and v_cashin = 0 then
    raise exception
      'That is more than the basket comes to. Charge the card the right '
      'amount, or take the difference as a refund.'
      using errcode = '23514';
  end if;

  v_contact := coalesce(p_contact, v_sale.contact_id, v_outlet.walk_in_contact_id);
  if v_contact is null then
    raise exception
      'This outlet has no walk-in customer set, so an anonymous sale has '
      'nobody to bill. Set one on the outlet.'
      using errcode = '23502';
  end if;

  -- --------------------------------------------------------------
  -- The invoice
  -- --------------------------------------------------------------
  v_no := app.next_document_number_internal(v_sale.org_id, 'invoice');

  -- No salesperson. `sales_documents.salesperson_id` points at
  -- `public.salespeople` — a commission record — and not at the user
  -- who rang the sale up. A cashier is not automatically one of those,
  -- and 0105 has a trigger that says so. Who served the customer is on
  -- `pos_sales.sold_by`, which is the right place for it; a shop that
  -- pays counter commission can map the two later.
  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, notes, created_by)
  values (
    v_sale.org_id, 'invoice', v_no, current_date, current_date, v_contact,
    'MYR', 1, 'draft',
    'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_inv;

  for v_line in
    select * from public.pos_sale_lines l where l.sale_id = p_sale order by l.line_no
  loop
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, discount_amount, tax_code_id,
      tax_rate, is_tax_inclusive, warehouse_id)
    values (
      v_sale.org_id, v_inv, v_line.line_no, 'item', v_line.item_id,
      v_line.description, v_line.quantity, v_line.uom_code,
      v_line.unit_price, v_line.discount_amount, v_line.tax_code_id,
      v_line.tax_rate, v_line.is_tax_inclusive, v_line.warehouse_id);
  end loop;

  -- After the lines, because the totals trigger fires on line changes
  -- and would otherwise impose the organization's rounding on a card
  -- sale. See the header: this is POS taking a number the trigger
  -- normally owns, and the test asserts the result.
  update public.sales_documents d
     set rounding_amount = v_adj,
         -- The redemption AND the bill discount, on the header rather
         -- than spread across the lines. `sales_documents.discount_amount`
         -- is exactly the field for a discount that belongs to the
         -- document, and `prepare_einvoice` already maps it to the
         -- MyInvois total discount, so what LHDN is told matches what
         -- was charged. Both are added because both came off the same
         -- header: reporting only one of them would understate the
         -- discount on every bill a manager touched.
         discount_amount = coalesce(v_sale.loyalty_discount, 0)
                         + coalesce(v_sale.bill_discount, 0),
         total_amount    = round(v_sale.total_amount + v_adj, 2),
         base_total_amount = round(v_sale.total_amount + v_adj, 2),
         balance_amount  = round(v_sale.total_amount + v_adj, 2)
   where d.id = v_inv;

  perform app.post_sales_document_internal(v_inv);

  -- --------------------------------------------------------------
  -- The receipt, and the debt closing behind it
  -- --------------------------------------------------------------
  -- Banked against the first tender's account. A shop splitting one
  -- sale across two accounts is real and is not this migration's
  -- problem; what matters here is that the money lands somewhere named
  -- rather than in the current account by default.
  select tt.bank_account_id, tt.payment_mode_code
    into v_bank, v_mode
    from public.pos_tender_types tt
   where tt.id = ((p_tenders -> 0) ->> 'type')::uuid;

  v_no := app.next_document_number_internal(v_sale.org_id, 'receipt');

  insert into public.receipts (
    org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
    bank_account_id, currency, exchange_rate, amount, base_amount,
    status, notes, created_by)
  values (
    v_sale.org_id, v_no, current_date, v_contact, v_mode, v_bank,
    'MYR', 1,
    round(v_sale.total_amount + v_adj, 2),
    round(v_sale.total_amount + v_adj, 2),
    'draft', 'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_rcp;

  -- Only when there is something to allocate. `payment_allocations`
  -- checks that its amount is positive, and it is right to: an
  -- allocation of nothing is not an allocation. A basket cleared by
  -- points leaves an invoice for zero, which already owes nothing, so
  -- there is nothing for a receipt to settle against it.
  if round(v_sale.total_amount + v_adj, 2) > 0 then
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, allocated_by)
    values
      (v_sale.org_id, v_rcp, v_inv, round(v_sale.total_amount + v_adj, 2),
       v_sale.sold_by);
  end if;

  perform app.post_receipt_internal(v_rcp);

  -- --------------------------------------------------------------
  -- And the tenders, now that they are known to be good
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference' as reference,
           row_number() over () as rn,
           count(*) over () as total_rows
      from jsonb_array_elements(p_tenders) e
  loop
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id;
    insert into public.pos_tenders
      (org_id, sale_id, tender_type_id, kind, amount, change_given, reference)
    values
      (v_sale.org_id, p_sale, v_t.type_id, v_kind, v_t.amount,
       -- Change comes out of the last tender offered, which is the one
       -- the customer is standing there waiting for.
       case when v_t.rn = v_t.total_rows then v_change else 0 end,
       v_t.reference);
  end loop;

  update public.pos_sales s
     set status = 'completed',
         completed_at = now(),
         contact_id = v_contact,
         rounding_amount = v_adj,
         total_amount = round(v_sale.total_amount + v_adj, 2),
         invoice_id = v_inv,
         receipt_id = v_rcp
   where s.id = p_sale;

  -- --------------------------------------------------------------
  -- And the points, last
  -- --------------------------------------------------------------
  -- Nothing above this line touches the loyalty ledger. A parked sale
  -- holds no points: it can be abandoned, and a customer whose balance
  -- fell when a cashier changed their mind has been robbed by a
  -- transaction that never happened.
  perform app.pos_settle_loyalty(p_sale, round(v_sale.total_amount + v_adj, 2));

  sale_id := p_sale;
  select d.doc_no into invoice_no from public.sales_documents d where d.id = v_inv;
  -- Scaled to the sen on the way out. `numeric` with no declared scale
  -- is exact and prints as 10.8500000000000000, which reaches the till
  -- as a string and is the one number a customer reads back off a
  -- receipt. Correct is not the same as legible.
  total := round(v_sale.total_amount + v_adj, 2);
  cash_due := round(v_cashdue, 2);
  change_due := round(v_change, 2);
  rounding := round(v_adj, 2);
  return next;
end;
$$;
