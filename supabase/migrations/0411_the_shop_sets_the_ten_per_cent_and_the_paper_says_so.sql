-- ---------------------------------------------------------------------
-- 0411  The shop sets the ten per cent, and the paper says so
-- ---------------------------------------------------------------------
--
-- `0410` gave the outlet a service charge, taxed it, totalled it and
-- posted it. Nothing could set it and no receipt showed it, which is a
-- column in a table and not a feature: the whole of `docs/unreachable.md`
-- is about the difference.
--
-- Two things here, and they are the two halves of "a shop can use it".
--
-- ## Setting it
--
-- `set_pos_service_charge(outlet, percent, tax_code)`, guarded by
-- `app.can_write_module(org, 'pos')` — the same guard
-- `upsert_pos_receipt_settings` uses, because this is the same person
-- setting up the same shop.
--
-- The tax code is checked to belong to the same organization. Without
-- that, a uuid from another company's tax table would be accepted and
-- the charge would be taxed at a rate this company never chose — the
-- kind of cross-tenant reach `no_tenant_sees_another.sql` exists for,
-- arriving through a parameter rather than through a policy.
--
-- ## Printing it
--
-- A Malaysian bill puts the service charge between the food and the
-- tax, with the percentage on it: "Service charge 10%". That position
-- is not decoration — it is what tells the customer why the tax line
-- underneath is more than eight per cent of the food.
--
-- Deliberately not behind `show_tax_summary`. A shop may choose not to
-- print a tax breakdown; it may not choose to add ten per cent to a
-- bill without saying so on the paper.
-- ---------------------------------------------------------------------

create or replace function public.set_pos_service_charge(
  p_outlet   uuid,
  p_percent  numeric,
  p_tax_code uuid default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'app', 'pg_temp'
as $fn$
declare
  v_org uuid;
begin
  select o.org_id into v_org from public.pos_outlets o where o.id = p_outlet;
  if v_org is null then
    raise exception 'No such outlet.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to set up this shop' using errcode = '42501';
  end if;

  if coalesce(p_percent, 0) < 0 or coalesce(p_percent, 0) > 100 then
    raise exception
      'A service charge is a percentage of the bill: % is not one.',
      p_percent using errcode = '23514';
  end if;

  -- The tax code has to be this company's. A uuid from another
  -- company's tax table would otherwise be accepted here and the charge
  -- taxed at a rate nobody in this company chose.
  if p_tax_code is not null
     and not exists (select 1 from public.tax_codes t
                      where t.id = p_tax_code and t.org_id = v_org) then
    raise exception 'That tax code does not belong to this company.'
      using errcode = '23503';
  end if;

  update public.pos_outlets o
     set service_charge_percent = coalesce(p_percent, 0),
         service_charge_tax_code_id = p_tax_code,
         updated_at = now()
   where o.id = p_outlet;
end
$fn$;

-- `0165`'s event trigger strips PUBLIC and anon from every new
-- function, which is right and also means a new one reaches nobody
-- until it is granted. The assertion at the foot is what caught this
-- one having been left unreachable.
grant execute on function
  public.set_pos_service_charge(uuid, numeric, uuid) to authenticated;

comment on function public.set_pos_service_charge(uuid, numeric, uuid) is
  'Sets the service charge an outlet adds to a bill and the tax that '
  'rides it. Null tax code means a charge with nothing on top, which is '
  'what an outlet not registered for service tax has.';

CREATE OR REPLACE FUNCTION app.receipt_label(p_key text, p_lang text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
  select case when coalesce(p_lang, 'en') = 'ms' then
    case p_key
      when 'sale'      then 'Jualan'
      when 'cashier'   then 'Juruwang'
      when 'table'     then 'Meja'
      when 'customer'  then 'Pelanggan'
      when 'subtotal'  then 'Jumlah kecil'
      when 'discount'  then 'Diskaun'
      when 'delivery'  then 'Penghantaran'
      when 'service_charge' then 'Caj perkhidmatan'
      when 'tax'       then 'Cukai'
      when 'rounding'  then 'Pembundaran'
      when 'total'     then 'JUMLAH'
      when 'change'    then 'Baki'
      when 'points'    then 'Mata ganjaran'
      when 'balance'   then 'Baki mata'
      when 'voided'    then '*** DIBATALKAN ***'
      when 'unpaid'    then '*** BELUM DIBAYAR ***'
      when 'reprint'   then '(salinan)'
      else p_key
    end
  else
    case p_key
      when 'sale'      then 'Sale'
      when 'cashier'   then 'Cashier'
      when 'table'     then 'Table'
      when 'customer'  then 'Customer'
      when 'subtotal'  then 'Subtotal'
      when 'discount'  then 'Discount'
      when 'delivery'  then 'Delivery'
      when 'service_charge' then 'Service charge'
      when 'tax'       then 'Tax'
      when 'rounding'  then 'Rounding'
      when 'total'     then 'TOTAL'
      when 'change'    then 'Change'
      when 'points'    then 'Points earned'
      when 'balance'   then 'Points balance'
      when 'voided'    then '*** VOIDED ***'
      when 'unpaid'    then '*** NOT PAID ***'
      when 'reprint'   then '(copy)'
      else p_key
    end
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
    select o.service_charge_percent into v_pct
      from public.pos_outlets o where o.id = v_sale.outlet_id;
    v_out := v_out || app.receipt_pair(
      app.receipt_label('service_charge', v_lang)
        || coalesce(' ' || trim(to_char(v_pct, 'FM990.99')) || '%', ''),
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

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'pos_receipt_text';

  if v_src !~ 'service_charge' then
    raise exception
      'FAIL 0411: the receipt does not show the service charge, so a '
      'customer is charged ten per cent the paper never mentions';
  end if;

  -- Above the tax and below the food. Asserted on the order because
  -- that order is what makes the tax line beneath make sense.
  if position('receipt_label(''service_charge''' in v_src)
     > position('receipt_label(''tax''' in v_src) then
    raise exception
      'FAIL 0411: the service charge prints after the tax it is taxed '
      'with, which reads as though the tax were on the food alone';
  end if;

  if app.receipt_label('service_charge', 'en') = 'service_charge'
     or app.receipt_label('service_charge', 'ms') = 'service_charge' then
    raise exception
      'FAIL 0411: the receipt has no words for the service charge in '
      'one of the two languages it prints';
  end if;

  -- And a client role can reach the setter. `0165` strips PUBLIC and
  -- anon from a new function, and this one is no use to a shop that
  -- cannot call it.
  if not has_function_privilege('authenticated',
       'public.set_pos_service_charge(uuid,numeric,uuid)', 'EXECUTE') then
    raise exception
      'FAIL 0411: the shop cannot call the function that sets its own '
      'service charge';
  end if;

  raise notice
    '0411: the shop sets the charge, and the receipt says what it is';
end
$do$;
