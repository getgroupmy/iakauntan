-- =====================================================================
-- iAkauntan :: 0787 points buy what is left to pay
--
-- `redeem_loyalty_points` (`0212`) priced a redemption against the
-- basket -- the lines and their tax -- and nothing looked again when a
-- bill discount or a promotion took money off the same sale, before the
-- points or after them. `app.recalc_pos_sale` floored the food at
-- nothing, so the till showed RM0.00 and looked settled. Measured on 9
-- October 2026, locally, on a RM100 sale:
--
--   * a RM50 bill discount, then 10,000 points (RM100) redeemed: all
--     10,000 applied, total RM0.00 -- RM100 of the customer's points
--     for RM50 of goods;
--   * 8,000 points first, then the RM50 discount: total RM0.00, and
--     still 8,000 points on the sale.
--
-- And then neither sale could be completed: the posting carried the
-- whole discount and the whole redemption against a hundred ringgit of
-- revenue -- "Journal does not balance: debits 150.00, credits 100.00".
-- The till was stuck until somebody cleared the points.
--
-- Answered "points buy what's left". A redemption is priced against
-- what is still to pay after the bill discount and the promotions; and
-- when anything later leaves less to pay -- a discount, a promotion, a
-- line taken off -- the recalculation trims the redemption to fit,
-- whole points at the programme's value, and the points it did not need
-- stay on the account (the ledger is only written at completion, from
-- the points the sale finally carries). The sale always completes, and
-- the customer is never charged points for value they did not get.
--
-- What is left to pay is the food and its service charge, after the
-- discounts and before the delivery fee, which is the same figure the
-- recalculation already floored. A trimmed redemption is not grown
-- back if the basket grows again: that would spend points nobody asked
-- to spend.
--
-- Production held one loyalty programme and no sale with points on
-- 9 October. Restated from `0410` and `0212`, whose text production
-- runs exactly (identical source hashes on 9 October) -- `0410`'s for
-- the recalculation, which added the service charge to `0259`'s; and
-- `0212`'s for the redemption AS `0231` REWROTE IT, which moved its
-- guard from the till module to `loyalty` by editing the live function
-- rather than restating it. Copying `0212`'s file text alone would have
-- moved the guard back; the hash check is what said so.
-- =====================================================================

CREATE OR REPLACE FUNCTION app.recalc_pos_sale(p_sale uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sub numeric; v_tax numeric; v_disc numeric;
  v_loy numeric; v_pct numeric; v_bill numeric;
  v_promo numeric; v_gross numeric; v_fee numeric;
  v_svc_pct numeric; v_svc numeric; v_svc_tax numeric; v_svc_rate numeric;
  v_room numeric; v_per_point numeric; v_points integer;
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

  -- Derived, never stored twice: the rows are the promotions.
  select coalesce(sum(sp.amount), 0) into v_promo
    from public.pos_sale_promotions sp where sp.sale_id = p_sale;

  -- ------------------------------------------------------------------
  -- The service charge, and the tax that sits on top of it
  -- ------------------------------------------------------------------
  -- A Malaysian bill reads "subject to 10% service charge and 8%
  -- service tax", and the service tax is charged on the amount that
  -- already includes the charge. Charged on the food net of the
  -- discounts that belong to the lines, which is what `line_subtotal`
  -- already is.
  --
  -- The compound falls out of the per-line tax without any tax being
  -- charged twice: the lines already carry service tax on the food, so
  -- taxing the charge at the same rate gives
  -- rate x food + rate x charge = rate x (food + charge), which is the
  -- figure the Act asks for.
  select coalesce(o.service_charge_percent, 0), t.rate
    into v_svc_pct, v_svc_rate
    from public.pos_sales s
    join public.pos_outlets o on o.id = s.outlet_id
    left join public.tax_codes t on t.id = o.service_charge_tax_code_id
   where s.id = p_sale;

  v_svc := round(coalesce(v_sub, 0) * coalesce(v_svc_pct, 0) / 100.0, 2);
  v_svc_tax := round(v_svc * coalesce(v_svc_rate, 0) / 100.0, 2);

  v_gross := round(v_sub + v_tax + v_svc + v_svc_tax, 2);

  -- The ride, rebuilt from the zone against the food. Measured on the
  -- goods before any discount, because "spend RM 50 and delivery is
  -- free" is a promise about what was ordered, not about what was
  -- charged after the manager knocked something off.
  update public.pos_deliveries d
     set fee = app.pos_delivery_fee(d.zone_id, v_gross),
         updated_at = now()
   where d.sale_id = p_sale
     and not d.fee_is_manual
     and d.fee <> app.pos_delivery_fee(d.zone_id, v_gross);

  select coalesce(d.fee, 0) into v_fee
    from public.pos_deliveries d where d.sale_id = p_sale;
  v_fee := coalesce(v_fee, 0);

  if v_pct > 0 then
    v_bill := round(v_gross * v_pct / 100.0, 2);
  end if;
  v_bill := least(greatest(v_bill, 0), v_gross);
  -- Whatever is left after the manual discount, so the two together can
  -- never hand money back across the counter.
  v_promo := least(greatest(v_promo, 0), v_gross - v_bill);

  -- `0787`. Points buy what is left after the discounts, and no more.
  -- A redemption that something later outgrew -- a discount, a
  -- promotion, a line taken off -- is trimmed to whole points that fit,
  -- and the rest stay on the account: the ledger is written at
  -- completion, from what the sale finally carries.
  v_room := greatest(round(v_gross - v_bill - v_promo, 2), 0);
  if v_loy > v_room then
    select p.redeem_value_per_point into v_per_point
      from public.pos_sales s
      join public.loyalty_accounts a on a.id = s.loyalty_account_id
      join public.loyalty_programs p on p.id = a.program_id
     where s.id = p_sale;
    v_points := coalesce(
      floor(v_room / nullif(v_per_point, 0))::integer, 0);
    v_loy := round(v_points * coalesce(v_per_point, 0), 2);
    update public.pos_sales s
       set loyalty_points_redeemed = least(s.loyalty_points_redeemed, v_points),
           loyalty_discount = v_loy
     where s.id = p_sale;
  end if;

  update public.pos_sales s
     set subtotal = v_sub,
         service_charge = v_svc,
         service_charge_tax = v_svc_tax,
         tax_amount = v_tax,
         discount_amount = v_disc,
         bill_discount = v_bill,
         promo_discount = v_promo,
         delivery_fee = v_fee,
         -- The food, floored at nothing, and then the ride on top.
         total_amount = round(
           greatest(round(v_gross - v_bill - v_promo - v_loy, 2), 0) + v_fee, 2)
   where s.id = p_sale;
end;
$function$;

create or replace function public.redeem_loyalty_points(
  p_sale   uuid,
  p_points integer)
returns table (
  points_applied integer,
  discount       numeric,
  new_total      numeric,
  -- What the account will hold once this sale completes. Not what it
  -- holds now: the ledger is untouched until then, and a till that
  -- said otherwise would be reporting a balance that does not exist.
  points_after   integer)
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_sale    public.pos_sales;
  v_outlet  public.pos_outlets;
  v_program public.loyalty_programs;
  v_account uuid;
  v_contact uuid;
  v_balance integer;
  v_worth   numeric;
  v_basket  numeric;
  v_points  integer;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'loyalty') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status using errcode = '23514';
  end if;
  if p_points is null or p_points < 0 then
    raise exception 'Points redeemed cannot be negative.' using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  v_contact := coalesce(v_sale.contact_id, v_outlet.walk_in_contact_id);

  select * into v_program from public.loyalty_programs p
   where p.org_id = v_sale.org_id and p.is_active;
  if v_program.id is null then
    raise exception 'This company has no loyalty programme running.'
      using errcode = 'P0002';
  end if;

  select a.id into v_account from public.loyalty_accounts a
   where a.program_id = v_program.id and a.contact_id = v_contact and a.is_active;
  if v_account is null then
    raise exception
      'This sale is not on a member''s account. Say who the customer is first.'
      using errcode = 'P0002';
  end if;

  -- Zero clears a redemption that was applied and then thought better
  -- of, which is a thing that happens at a counter and should not need
  -- the sale to be voided.
  if p_points = 0 then
    update public.pos_sales s
       set loyalty_account_id = v_account,
           loyalty_points_redeemed = 0,
           loyalty_discount = 0
     where s.id = p_sale;
    perform app.recalc_pos_sale(p_sale);
    select s.total_amount into v_basket from public.pos_sales s where s.id = p_sale;
    points_applied := 0;
    discount := 0;
    new_total := v_basket;
    points_after := app.loyalty_balance(v_account);
    return next;
    return;
  end if;

  if p_points < v_program.min_redeem_points then
    raise exception
      'This programme redeems from % points.', v_program.min_redeem_points
      using errcode = '23514';
  end if;

  -- The balance is checked against the ledger, not against the column
  -- that would have been easier to read.
  v_balance := app.loyalty_balance(v_account);
  if p_points > v_balance then
    raise exception
      'That is % points and the account has %.', p_points, v_balance
      using errcode = '23514';
  end if;

  -- What is left to pay before this redemption: any earlier redemption
  -- taken off first, so two calls replace rather than stack, and then
  -- the sale recalculated -- which leaves the bill discount and the
  -- promotions already taken. `0787`: it read the lines before, so
  -- points paid for value a discount had already given away.
  update public.pos_sales s
     set loyalty_points_redeemed = 0, loyalty_discount = 0
   where s.id = p_sale;
  perform app.recalc_pos_sale(p_sale);
  select greatest(s.total_amount - coalesce(s.delivery_fee, 0), 0)
    into v_basket from public.pos_sales s where s.id = p_sale;

  v_worth  := round(p_points * v_program.redeem_value_per_point, 2);
  v_points := p_points;

  -- Points cannot buy more than the basket. Rather than refuse, take
  -- only what is needed and leave the rest on the account: a customer
  -- who says "use my points" means "use what they are worth here".
  if v_worth > v_basket then
    -- Floor, not ceiling. Rounding the points up would take one more
    -- than the basket is worth and give nothing back for it, which is
    -- a sen-sized theft repeated on every over-redemption.
    v_points := least(
      floor(v_basket / nullif(v_program.redeem_value_per_point, 0))::integer,
      p_points);
    v_worth  := round(v_points * v_program.redeem_value_per_point, 2);
  end if;

  update public.pos_sales s
     set loyalty_account_id = v_account,
         loyalty_points_redeemed = v_points,
         loyalty_discount = v_worth
   where s.id = p_sale;

  perform app.recalc_pos_sale(p_sale);

  -- What the sale carries after the recalculation, which is the figure
  -- completion will use.
  select s.loyalty_points_redeemed, s.loyalty_discount, s.total_amount
    into points_applied, discount, new_total
    from public.pos_sales s where s.id = p_sale;
  points_after := v_balance - points_applied;
  return next;
end;
$$;

comment on function public.redeem_loyalty_points(uuid, integer) is
  'Spends points against a parked bill and returns what was applied. '
  'Points buy only what is LEFT TO PAY after the bill discount and the '
  'promotions (`0787`): rather than refuse, it takes only what is needed '
  'and LEAVES THE REST ON THE ACCOUNT, rounding the points DOWN, and a '
  'discount that comes later trims the redemption the same way. Zero '
  'clears a redemption thought better of, without voiding the sale. A '
  'second call replaces the first rather than stacking. Refuses a bill '
  'that is not parked, a sale not on a member''s account, and anything '
  'under the programme''s minimum. Needs '
  '`can_write_module(''loyalty'')`.';
