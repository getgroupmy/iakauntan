-- =====================================================================
-- Two refusals on one path, wearing the same sentence
--
-- `place_public_pos_order` refuses an empty order twice: once before it
-- opens anything, when the array the phone sent has nothing in it, and
-- once at the end, if the loop added no line. Both said
--
--     There is nothing in this order.
--
-- and a sweep found that the first of them could be DELETED without a
-- test noticing, because the second raised the same words for what an
-- assertion reads as the same reason. That is the masking pattern
-- `pg_temp.check_refused` was written for, and its own note says the
-- answer: where two guards on one path word themselves identically
-- there is nothing to tell them apart, which is an argument for wording
-- them differently rather than for asserting less.
--
-- The second guard is unreachable as the loop stands — a non-empty
-- array either adds a line or raises — so it is the belt behind the
-- braces and its wording is one nobody should ever read. Naming it for
-- what it would mean leaves the first guard's sentence to the customer
-- and gives the sweep two refusals it can tell apart.
--
-- Nothing else in the function changes.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.place_public_pos_order(p_token text, p_items jsonb, p_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_line1 text DEFAULT NULL::text, p_line2 text DEFAULT NULL::text, p_city text DEFAULT NULL::text, p_state text DEFAULT NULL::text, p_postcode text DEFAULT NULL::text)
 RETURNS TABLE(sale_id uuid, sale_no text, total numeric, fee numeric, blocked_reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
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
$function$

;
grant execute on function public.public_pos_menu(text) to anon, authenticated;
grant execute on function public.public_pos_menu_modifiers(text, uuid) to anon, authenticated;
grant execute on function public.place_public_pos_order(
  text, jsonb, text, text, text, text, text, text, text, text) to anon, authenticated;
