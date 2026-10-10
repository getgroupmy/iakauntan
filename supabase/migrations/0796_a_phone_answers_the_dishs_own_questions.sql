-- =====================================================================
-- iAkauntan :: 0796 a phone answers the dish's own questions
--
-- `place_public_pos_order` is the order a phone places from a QR menu,
-- with no login: a token is the whole credential. Its test file is built
-- around one assertion -- "the price is the shop's" -- and it takes an
-- item and a quantity and never a price. But each dish's answers
-- ("extra sambal", "small portion") carry their own price, and the
-- function took any answer the shop had, on any dish: it asked only that
-- the answer was the same company's (`add_line_modifier_internal`) and
-- that its question's maximum was not passed (`pos_modifier_max`).
--
-- Measured on 10 October 2026, locally, with no login: one nasi lemak
-- (RM12) and three teh tarik (RM3), each carrying the nasi lemak's
-- neighbour's "small portion" (-RM4). The bill came to RM9, the teh
-- tarik line -RM3 at -RM1 each. A bill wholly below nothing was refused
-- -- by the bill discount's own check, which is an accident, not a rule.
-- Nor did anything ask that a question the dish must have answered
-- ("how spicy?", a minimum of one) was answered; `pos_line_modifier_gaps`
-- then held the bill back from the kitchen with the customer gone.
--
-- The phone page offers only the dish's own questions and asks the
-- required ones, so only a request written by hand reaches either.
--
-- Answered "refuse on the public road". The order now refuses an answer
-- to a question the dish does not ask -- or no longer asks: the same
-- active questions `public_pos_menu_modifiers` shows the phone -- and a
-- dish whose required question went unanswered, by the rule
-- `pos_line_modifier_gaps` holds the kitchen to, asked of the lines this
-- order made (a table's bill may carry the staff's own). The till's
-- functions are unchanged. Otherwise restated from `0535` (production's
-- body hashes identically, 8ad03b77...).
--
-- Production held no menu link and no answer priced below nothing on
-- 10 October.
-- =====================================================================

create or replace function public.place_public_pos_order(
  p_token text,
  p_items jsonb,
  p_name text default null,
  p_phone text default null,
  p_note text default null,
  p_line1 text default null,
  p_line2 text default null,
  p_city text default null,
  p_state text default null,
  p_postcode text default null)
returns table(sale_id uuid, sale_no text, total numeric, fee numeric, blocked_reason text)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $function$
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
  v_name   text;
  v_gap    record;
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

    select i.name into v_name from public.items i where i.id = v_item;

    for v_mod in
      select * from jsonb_array_elements(coalesce(v_e -> 'modifiers', '[]'::jsonb))
    loop
      -- `0796`. An answer to a question this dish asks, and nothing
      -- else: the questions the phone was shown (`public_pos_menu_modifiers`
      -- -- the dish's own, still in use). Another dish's "small portion,
      -- RM4 off" on a RM3 drink is a price the phone wrote.
      if not exists (
        select 1
          from public.item_modifier_groups img
          join public.pos_modifier_groups g on g.id = img.group_id and g.is_active
          join public.pos_modifiers pm on pm.group_id = g.id
         where img.item_id = v_item
           and pm.id = (v_mod ->> 'modifier')::uuid) then
        raise exception 'That is not one of the choices for %.', v_name
          using errcode = '23514';
      end if;

      perform app.add_line_modifier_internal(
        v_line, (v_mod ->> 'modifier')::uuid,
        coalesce((v_mod ->> 'quantity')::integer, 1));
    end loop;

    -- `0796`. And every question it must have answered, answered: the
    -- rule `pos_line_modifier_gaps` holds the kitchen to, asked here of
    -- the line the phone just made, because that function answers only
    -- somebody who may read the till and the phone is nobody. Without
    -- it the bill sits on the till unable to go to the cooks.
    select g.name, g.min_select into v_gap
      from public.item_modifier_groups img
      join public.pos_modifier_groups g on g.id = img.group_id and g.is_active
     where img.item_id = v_item
       and g.min_select > 0
       and coalesce((select sum(m.quantity)::integer
                       from public.pos_sale_line_modifiers m
                      where m.line_id = v_line and m.group_id = g.id), 0)
           < g.min_select
     order by img.sort_order, g.name
     limit 1;
    if found then
      raise exception '% needs % to "%".', v_name,
        case when v_gap.min_select = 1 then 'an answer'
             else v_gap.min_select || ' answers' end,
        v_gap.name
        using errcode = '23514';
    end if;
  end loop;

  if v_n = 0 then
    -- Unreachable as the loop stands, and worded so that it cannot be
    -- mistaken for the guard at the top of this function if it ever is.
    raise exception 'Nothing in this order could be added to a bill.'
      using errcode = '23514';
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
$function$;

-- Written after the create, as `0535` wrote it: `0165`'s event trigger
-- takes EXECUTE from `anon` on every create or replace, and this is the
-- one function a phone with no login places its order through.
grant execute on function public.place_public_pos_order(
  text, jsonb, text, text, text, text, text, text, text, text) to anon, authenticated;

comment on function public.place_public_pos_order(
  text, jsonb, text, text, text, text, text, text, text, text) is
  'Places an order from a published menu. The price is the shop''s, the '
  'availability is checked at the moment of ordering, and it lands as a '
  'parked sale on a till with a shift open — so the kitchen, the floor '
  'plan and the money all work as if a waiter had rung it up. Each dish '
  'takes answers only to its own questions, and every one it requires. '
  '0796.';
