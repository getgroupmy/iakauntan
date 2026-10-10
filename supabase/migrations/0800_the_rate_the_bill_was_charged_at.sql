-- =====================================================================
-- iAkauntan :: 0800 the rate the bill was charged at
--
-- `0410` adds an outlet's service charge to every bill, and `0411`
-- prints it on the receipt with its percentage, "because 'Service charge
-- 10%' is what a customer checks the arithmetic against". But the bill
-- kept only the amount, and the receipt read the percentage from the
-- outlet as it is today. Measured on 10 October 2026, locally: a bill
-- charged 10% -- RM10.00 on RM100 of food -- reprinted after the outlet
-- had moved to 5% read "Service charge 5.% ... 10.00". The "5." is the
-- second fault: `to_char(.., 'FM990.99')` keeps the point, so a fresh
-- receipt read "Service charge 10.%" too. The assertion that was meant
-- to hold it asked `like '%Service charge 10%%'`, in which the percent
-- after the 10 is a wildcard, not a percent sign.
--
-- Answered "store the rate on the bill". `pos_sales` keeps
-- `service_charge_percent`, written by `recalc_pos_sale` beside the
-- amount; the receipt prints the bill's own rate, as "10%" or "7.5%".
-- Bills charged before this get their rate worked back from their own
-- amounts. Both functions are otherwise restated as production runs
-- them (`recalc_pos_sale` 2438e054..., `pos_receipt_text` 6cff0bd2...,
-- identical to the local bodies).
--
-- Production held fourteen sales, none with a service charge, and no
-- outlet charging one, on 10 October.
-- =====================================================================

alter table public.pos_sales
  add column if not exists service_charge_percent numeric(5, 2) not null default 0,
  add constraint pos_sales_service_charge_percent_check
    check (service_charge_percent >= 0 and service_charge_percent <= 100);

comment on column public.pos_sales.service_charge_percent is
  'The service charge rate this bill was charged at, kept beside the '
  'amount so a reprint says what the amount was worked at. 0800.';

-- Bills charged before now: the rate worked back from the bill's own
-- food and charge, which is what the charge was worked out from.
update public.pos_sales s
   set service_charge_percent = least(round(s.service_charge * 100 / b.food, 2), 100)
  from (select l.sale_id, sum(l.line_subtotal) as food
          from public.pos_sale_lines l group by l.sale_id) b
 where b.sale_id = s.id
   and coalesce(s.service_charge, 0) > 0
   and b.food > 0;

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
         -- `0800`. The rate this bill was charged at, kept with it: the
         -- receipt prints it, and a reprint after the outlet changes its
         -- rate must say the rate the amount beside it was worked at.
         service_charge_percent = coalesce(v_svc_pct, 0),
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

CREATE OR REPLACE FUNCTION public.pos_receipt_text(p_sale uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sale   public.pos_sales;
  v_cfg    public.pos_receipt_settings;
  v_org    public.organizations;
  v_outlet public.pos_outlets;
  v_w      integer;
  v_lang   text;
  v_out    text := '';
  v_line   record;
  v_t      record;
  v_txt    text;
  v_paid   numeric := 0;
  v_change numeric := 0;
  v_name    text;
  v_pct     numeric;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_read_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to read this shop' using errcode = '42501';
  end if;

  select * into v_org from public.organizations where id = v_sale.org_id;
  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  v_cfg  := app.pos_receipt_config(v_sale.outlet_id);
  v_w    := app.receipt_width(v_cfg.paper_mm);
  v_lang := v_cfg.language;

  -- ----------------------------------------------------------------
  -- The head
  -- ----------------------------------------------------------------
  -- The shop's own words first if it wrote any, and its name if it did
  -- not. A blank receipt with no shop on it is a receipt nobody can
  -- take back to anybody.
  if coalesce(btrim(v_outlet.receipt_header), '') <> '' then
    foreach v_txt in array string_to_array(v_outlet.receipt_header, E'\n') loop
      v_out := v_out || app.receipt_centre(btrim(v_txt), v_w) || E'\n';
    end loop;
  else
    v_out := v_out || app.receipt_centre(coalesce(v_org.name, ''), v_w) || E'\n';
    if coalesce(v_outlet.name, '') <> '' then
      v_out := v_out || app.receipt_centre(v_outlet.name, v_w) || E'\n';
    end if;
  end if;

  -- The registration a Malaysian receipt is expected to carry. Printed
  -- from the company record rather than typed into the header, because
  -- a number retyped per outlet is a number wrong at one of them.
  if coalesce(v_org.registration_no, '') <> '' then
    v_out := v_out || app.receipt_centre(v_org.registration_no, v_w) || E'\n';
  end if;
  if v_org.is_sst_registered and coalesce(v_org.sst_registration_no, '') <> '' then
    v_out := v_out
      || app.receipt_centre('SST ' || v_org.sst_registration_no, v_w) || E'\n';
  end if;

  v_out := v_out || repeat('-', v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- Which sale, and when
  -- ----------------------------------------------------------------
  v_out := v_out || app.receipt_pair(
    app.receipt_label('sale', v_lang) || ' ' || coalesce(v_sale.sale_no, ''),
    to_char(coalesce(v_sale.completed_at, v_sale.opened_at)
            at time zone 'Asia/Kuala_Lumpur', 'DD/MM/YY HH24:MI'),
    v_w) || E'\n';

  if v_cfg.show_cashier then
    select p.full_name into v_name from public.profiles p where p.id = v_sale.sold_by;
    if coalesce(v_name, '') <> '' then
      v_out := v_out || app.receipt_label('cashier', v_lang) || ': ' || v_name || E'\n';
    end if;
  end if;

  if v_cfg.show_table and v_sale.table_id is not null then
    select t.code into v_name from public.pos_tables t where t.id = v_sale.table_id;
    v_out := v_out || app.receipt_pair(
      app.receipt_label('table', v_lang) || ': ' || coalesce(v_name, ''),
      case when coalesce(v_sale.covers, 0) > 0
           then v_sale.covers || ' pax' else '' end,
      v_w) || E'\n';
  end if;

  if v_cfg.show_channel and v_sale.order_channel is not null then
    v_out := v_out || replace(v_sale.order_channel::text, '_', ' ') || E'\n';
  end if;

  if v_cfg.show_customer and v_sale.contact_id is not null then
    select c.name into v_name from public.contacts c where c.id = v_sale.contact_id;
    if coalesce(v_name, '') <> '' then
      v_out := v_out
        || app.receipt_label('customer', v_lang) || ': ' || v_name || E'\n';
    end if;
  end if;

  v_out := v_out || repeat('-', v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- What was bought
  -- ----------------------------------------------------------------
  for v_line in
    select l.*, i.code as item_code
      from public.pos_sale_lines l
      left join public.items i on i.id = l.item_id
     where l.sale_id = p_sale
     order by l.line_no
  loop
    v_out := v_out || app.receipt_pair(
      trim(to_char(v_line.quantity, 'FM999999990.###')) || ' x '
        || coalesce(v_line.description, ''),
      to_char(v_line.line_total, 'FM999999990.00'),
      v_w) || E'\n';

    if v_cfg.show_item_codes and coalesce(v_line.item_code, '') <> '' then
      v_out := v_out || '  ' || v_line.item_code || E'\n';
    end if;

    -- What was asked for on the plate. Always printed: a customer
    -- charged two ringgit for an extra egg is entitled to see the egg.
    for v_t in
      select m.name, m.price_delta, m.quantity
        from public.pos_sale_line_modifiers m
       where m.line_id = v_line.id
       order by m.created_at
    loop
      v_out := v_out || app.receipt_pair(
        '  + ' || v_t.name,
        case when v_t.price_delta = 0 then ''
             else to_char(v_t.price_delta * v_t.quantity, 'FM999999990.00') end,
        v_w) || E'\n';
    end loop;

    -- The money somebody took off this line, and why they said they
    -- did. Never optional: see the header.
    if coalesce(v_line.discount_amount, 0) > 0 then
      v_out := v_out || app.receipt_pair(
        '  ' || app.receipt_label('discount', v_lang)
          || coalesce(' - ' || v_line.discount_reason, ''),
        '-' || to_char(v_line.discount_amount, 'FM999999990.00'),
        v_w) || E'\n';
    end if;
  end loop;

  v_out := v_out || repeat('-', v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- What it came to
  -- ----------------------------------------------------------------
  v_out := v_out || app.receipt_pair(
    app.receipt_label('subtotal', v_lang),
    to_char(coalesce(v_sale.subtotal, 0), 'FM999999990.00'), v_w) || E'\n';

  if coalesce(v_sale.bill_discount, 0) > 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('discount', v_lang)
        || coalesce(' - ' || v_sale.bill_discount_reason, ''),
      '-' || to_char(v_sale.bill_discount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  -- Named, one per row. "Less RM 6.00" with no name on it is the line
  -- customers ask about and cashiers cannot answer.
  for v_t in
    select p.name, sp.amount
      from public.pos_sale_promotions sp
      join public.pos_promotions p on p.id = sp.promotion_id
     where sp.sale_id = p_sale and sp.amount > 0
     order by p.name
  loop
    v_out := v_out || app.receipt_pair(
      v_t.name, '-' || to_char(v_t.amount, 'FM999999990.00'), v_w) || E'\n';
  end loop;

  if coalesce(v_sale.loyalty_discount, 0) > 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('points', v_lang),
      '-' || to_char(v_sale.loyalty_discount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  -- The ride. On the paper whatever the settings say, because it is
  -- money the customer is being charged.
  if coalesce(v_sale.delivery_fee, 0) > 0 then
    select z.name into v_name
      from public.pos_deliveries d
      left join public.pos_delivery_zones z on z.id = d.zone_id
     where d.sale_id = p_sale;
    v_out := v_out || app.receipt_pair(
      app.receipt_label('delivery', v_lang) || coalesce(' - ' || v_name, ''),
      to_char(v_sale.delivery_fee, 'FM999999990.00'), v_w) || E'\n';
  end if;

  -- The service charge, above the tax and below the food, which is
  -- where a Malaysian bill puts it and why the tax line beneath reads
  -- higher than the food alone would explain. Printed with the
  -- percentage on it, because "Service charge 10%" is what a customer
  -- checks the arithmetic against. Not behind `show_tax_summary`: a
  -- shop may choose not to print a tax breakdown, and it may not choose
  -- to charge ten per cent without saying so.
  if coalesce(v_sale.service_charge, 0) > 0 then
    -- `0800`. The bill's own rate, not the outlet's today, and written
    -- as a person writes it: '10%', '7.5%' -- `FM990.99` alone leaves
    -- the point behind ('10.%').
    v_pct := nullif(v_sale.service_charge_percent, 0);
    v_out := v_out || app.receipt_pair(
      app.receipt_label('service_charge', v_lang)
        || coalesce(' ' || rtrim(to_char(v_pct, 'FM990.99'), '.') || '%', ''),
      to_char(v_sale.service_charge, 'FM999999990.00'), v_w) || E'\n';
  end if;

  if v_cfg.show_tax_summary and coalesce(v_sale.tax_amount, 0) <> 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('tax', v_lang),
      to_char(v_sale.tax_amount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  if coalesce(v_sale.rounding_amount, 0) <> 0 then
    v_out := v_out || app.receipt_pair(
      app.receipt_label('rounding', v_lang),
      to_char(v_sale.rounding_amount, 'FM999999990.00'), v_w) || E'\n';
  end if;

  v_out := v_out || app.receipt_pair(
    app.receipt_label('total', v_lang),
    to_char(coalesce(v_sale.total_amount, 0), 'FM999999990.00'), v_w) || E'\n';

  -- ----------------------------------------------------------------
  -- What was handed over
  -- ----------------------------------------------------------------
  v_out := v_out || repeat('-', v_w) || E'\n';

  if v_sale.status = 'parked' then
    -- A bill printed for a table that has not paid yet. It says so
    -- rather than showing a change of nothing, which reads like a
    -- settled sale to anybody glancing at it.
    v_out := v_out || app.receipt_centre(
      app.receipt_label('unpaid', v_lang), v_w) || E'\n';
  else
    for v_t in
      select tt.name, t.amount, t.change_given
        from public.pos_tenders t
        join public.pos_tender_types tt on tt.id = t.tender_type_id
       where t.sale_id = p_sale
       order by t.created_at
    loop
      v_out := v_out || app.receipt_pair(
        v_t.name, to_char(v_t.amount, 'FM999999990.00'), v_w) || E'\n';
      v_paid := v_paid + v_t.amount;
      v_change := v_change + coalesce(v_t.change_given, 0);
    end loop;

    if v_change <> 0 then
      v_out := v_out || app.receipt_pair(
        app.receipt_label('change', v_lang),
        to_char(v_change, 'FM999999990.00'), v_w) || E'\n';
    end if;
  end if;

  if v_sale.status = 'voided' then
    v_out := v_out || app.receipt_centre(
      app.receipt_label('voided', v_lang), v_w) || E'\n';
  end if;

  -- ----------------------------------------------------------------
  -- The points, and the words at the bottom
  -- ----------------------------------------------------------------
  if v_cfg.show_points
     and app.can_read_module(v_sale.org_id, 'loyalty')
     and v_sale.loyalty_account_id is not null then
    v_out := v_out || repeat('-', v_w) || E'\n';
    v_out := v_out || app.receipt_pair(
      app.receipt_label('points', v_lang),
      coalesce(v_sale.loyalty_points_earned, 0)::text, v_w) || E'\n';
    select coalesce(sum(e.points), 0)::text into v_name
      from public.loyalty_entries e
     where e.account_id = v_sale.loyalty_account_id;
    v_out := v_out || app.receipt_pair(
      app.receipt_label('balance', v_lang), coalesce(v_name, '0'), v_w) || E'\n';
  end if;

  if coalesce(btrim(v_outlet.receipt_footer), '') <> '' then
    v_out := v_out || E'\n';
    foreach v_txt in array string_to_array(v_outlet.receipt_footer, E'\n') loop
      v_out := v_out || app.receipt_centre(btrim(v_txt), v_w) || E'\n';
    end loop;
  end if;

  return v_out;
end;
$function$;

-- `0165`'s event trigger takes EXECUTE on every create or replace; the
-- receipt is the till's to print, and the recalculation nobody's.
grant execute on function public.pos_receipt_text(uuid) to authenticated, service_role;
revoke all on function app.recalc_pos_sale(uuid) from public, anon, authenticated;
