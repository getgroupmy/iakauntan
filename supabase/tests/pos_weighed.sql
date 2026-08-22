-- =====================================================================
-- Point of sale :: two hundred grams of it
--
-- Three things, and the third is the one that would cost a customer
-- money.
--
--   1. The check digit. A misread label is five plausible digits of the
--      right item at the wrong weight, and a shop would never notice.
--      A label whose check digit does not agree has to find nothing.
--
--   2. The weight, in the unit the shop stocks in. A scale prints grams
--      and a grocer counts kilograms, and a system out by a thousand on
--      rice is out by a thousand on every reorder it suggests after it.
--
--   3. The sticker. A price-embedded label is a price the shop printed,
--      stuck on a package and handed to somebody. The line has to come
--      to exactly that, not to what today's unit price times a derived
--      weight happens to make.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_wh     uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;

  v_ikan   uuid;   -- stocked in kilograms, priced per kilogram
  v_kuih   uuid;   -- priced per kilogram, label carries the ringgit
  v_tin    uuid;   -- an ordinary thing, counted

  v_fmt    uuid;
  v_body   text;
  v_code   text;
  v_r      record;
  v_msg    text;
  v_sale   uuid;
  v_n      integer;
begin
  v_org := pg_temp.test_org('Pasar Timbang Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'The shop', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'IKAN', 'Ikan kembung', 'stock', true, 'KGM', 25.90)
  returning id into v_ikan;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KUIH', 'Kuih lapis', 'stock', true, 'KGM', 32.00)
  returning id into v_kuih;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'MILO', 'Milo tin', 'stock', true, 'C62', 18.50)
  returning id into v_tin;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'KEDAI', 'The shop', 'retail', v_wh, v_walkin, true)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id) values (v_org);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;

  v_shift := public.open_pos_shift(v_reg, 100.00);

  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values
    (v_org, 'OB-1', current_date, 'opening_balance', v_ikan, v_wh, 50, 18.00),
    (v_org, 'OB-2', current_date, 'opening_balance', v_kuih, v_wh, 20, 20.00);

  -- ------------------------------------------------------------------
  -- 1. The check digit
  -- ------------------------------------------------------------------
  -- GS1's own worked example: 590123412345 has a check digit of 7.
  perform pg_temp.check_eq('the published example checks out',
    app.ean_check_digit('590123412345'), 7);
  perform pg_temp.check_eq('and the other published one',
    app.ean_check_digit('12345678901'), 2);
  perform pg_temp.check_eq('an EAN-8 body is the same arithmetic',
    app.ean_check_digit('9638507'), 4);
  perform pg_temp.check_true('anything that is not digits is not a barcode',
    app.ean_check_digit('20ABC') is null);

  -- ------------------------------------------------------------------
  -- 2. Saying what is sold by weight
  -- ------------------------------------------------------------------
  begin
    perform public.set_item_weighed(v_tin, true, '1000');
    perform pg_temp.check_true('a tin is not sold by weight', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a thing counted in pieces cannot be sold by weight',
      v_msg like '%rather than an amount%');
  end;

  perform public.set_item_weighed(v_ikan, true, '101');
  perform public.set_item_weighed(v_kuih, true, '202');
  perform pg_temp.check_eq('and the ones that are, are',
    (select count(*)::integer from public.weighed_items(v_org)), 2);
  perform pg_temp.check_eq('with the number the scale knows it by',
    (select w.scale_plu from public.weighed_items(v_org) w
      where w.item_id = v_ikan), '101');

  -- ------------------------------------------------------------------
  -- 3. The layout the scale prints
  -- ------------------------------------------------------------------
  -- A prefix of 20, five digits of item, five of weight in grams, and a
  -- check digit: thirteen in all, which is an EAN-13.
  begin
    perform public.upsert_scale_format(
      null, v_org, 'Deli scale', '20', 4, 3, 'weight_grams');
    perform pg_temp.check_true('a layout has to add up to a barcode', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a layout has to add up to a barcode, and it says what it came to',
      v_msg like '%10 digits%');
  end;
  begin
    perform public.upsert_scale_format(
      null, v_org, 'Deli scale', 'AB', 4, 5, 'weight_grams');
    perform pg_temp.check_true('a prefix is digits', false);
  exception when others then
    perform pg_temp.check_true('a prefix is digits', true);
  end;

  v_fmt := public.upsert_scale_format(
    null, v_org, 'Deli scale', '20', 5, 5, 'weight_grams');
  perform pg_temp.check_eq('the layout is thirteen digits long',
    (select f.total_digits from public.scale_formats_list(v_org) f
      where f.id = v_fmt), 13);

  -- ------------------------------------------------------------------
  -- 4. Reading a label
  -- ------------------------------------------------------------------
  -- 20 + 00101 + 00246 grams, plus whatever check digit that needs. The
  -- shop typed 101 into its scale and the label pads it to five, which
  -- is the leading-zero case the parser has to survive.
  v_body := '20' || '00101' || '00246';
  v_code := v_body || app.ean_check_digit(v_body)::text;

  select * into v_r from app.parse_scale_barcode(v_org, v_code);
  perform pg_temp.check_eq('a label names the item its number stands for',
    v_r.item_id, v_ikan);
  perform pg_temp.check_eq(
    '246 grams out of a store kept in kilograms is 0.246',
    round(v_r.quantity, 6), 0.246::numeric);
  perform pg_temp.check_eq('at the shelf price, the label carrying no price',
    v_r.unit_price, 25.90::numeric);

  -- The assertion that stops a silent overcharge.
  select count(*)::integer into v_n
    from app.parse_scale_barcode(
      v_org, v_body || ((app.ean_check_digit(v_body) + 1) % 10)::text);
  perform pg_temp.check_eq('a label whose check digit disagrees is not a label',
    v_n, 0);

  -- A number no item answers to.
  select count(*)::integer into v_n from app.parse_scale_barcode(
    v_org, '20' || '99999' || '00246'
      || app.ean_check_digit('20' || '99999' || '00246')::text);
  perform pg_temp.check_eq('nor is one for something this shop does not sell',
    v_n, 0);

  -- And an ordinary barcode goes straight past.
  select count(*)::integer into v_n
    from app.parse_scale_barcode(v_org, '9556001234567');
  perform pg_temp.check_eq('an ordinary barcode is not a scale label', v_n, 0);
  select count(*)::integer into v_n
    from app.parse_scale_barcode(v_org, 'MILO');
  perform pg_temp.check_eq('and neither is a typed word', v_n, 0);

  -- ------------------------------------------------------------------
  -- 5. Through the counter's own lookup
  -- ------------------------------------------------------------------
  select * into v_r from public.pos_lookup_item(v_outlet, v_code);
  perform pg_temp.check_eq('the till gets one answer and no list',
    (select count(*)::integer from public.pos_lookup_item(v_outlet, v_code)), 1);
  perform pg_temp.check_eq('and can tell the scale from the gun',
    v_r.matched_on, 'scale');
  perform pg_temp.check_eq('carrying the weight rather than a one',
    round(v_r.quantity, 6), 0.246::numeric);
  perform pg_temp.check_true('and saying the item is one that is weighed',
    v_r.is_weighed);

  -- An ordinary search still behaves.
  select * into v_r from public.pos_lookup_item(v_outlet, 'MILO');
  perform pg_temp.check_eq('a typed code still finds its item',
    v_r.item_id, v_tin);
  perform pg_temp.check_eq('one of it', v_r.quantity, 1::numeric);
  perform pg_temp.check_true('and it is not weighed', not v_r.is_weighed);

  -- ------------------------------------------------------------------
  -- 6. What the customer is actually charged
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  select * into v_r from public.pos_lookup_item(v_outlet, v_code);
  perform public.add_pos_sale_line(
    v_sale, v_r.item_id, v_r.quantity, v_r.unit_price);

  -- 0.246 kg at RM 25.90 is RM 6.3714, which is RM 6.37.
  perform pg_temp.check_eq('a fraction of a kilogram rings up',
    (select round(l.quantity, 6) from public.pos_sale_lines l
      where l.sale_id = v_sale), 0.246::numeric);
  perform pg_temp.check_eq('at what that weight comes to',
    (select l.line_total from public.pos_sale_lines l
      where l.sale_id = v_sale), 6.37::numeric);

  -- ------------------------------------------------------------------
  -- 7. A label that carries the ringgit instead
  -- ------------------------------------------------------------------
  perform public.upsert_scale_format(
    null, v_org, 'Kuih scale', '21', 5, 5, 'price_sen');

  -- 21 + 00202 + 00795 sen. Whatever weight that is, the sticker says
  -- RM 7.95 and the customer was shown RM 7.95.
  v_body := '21' || '00202' || '00795';
  v_code := v_body || app.ean_check_digit(v_body)::text;

  select * into v_r from app.parse_scale_barcode(v_org, v_code);
  perform pg_temp.check_eq('a price label names its item too',
    v_r.item_id, v_kuih);
  perform pg_temp.check_eq('the weight is worked back from the money',
    round(v_r.quantity, 3), 0.248::numeric);

  v_sale := public.open_pos_sale(v_reg);
  select * into v_r from public.pos_lookup_item(v_outlet, v_code);
  perform public.add_pos_sale_line(
    v_sale, v_r.item_id, v_r.quantity, v_r.unit_price);

  -- The one that matters. 0.248 kg at the shelf's RM 32.00 would be
  -- RM 7.94, and the sticker says RM 7.95.
  perform pg_temp.check_eq(
    'the line comes to exactly what the sticker said, not to the sen the '
    'shelf price would have made it',
    (select l.line_total from public.pos_sale_lines l
      where l.sale_id = v_sale), 7.95::numeric);

  -- ------------------------------------------------------------------
  -- 8. Two scales, and the right one reads each label
  -- ------------------------------------------------------------------
  v_body := '20' || '00101' || '01500';
  v_code := v_body || app.ean_check_digit(v_body)::text;
  select * into v_r from app.parse_scale_barcode(v_org, v_code);
  perform pg_temp.check_eq('the deli scale is still read as grams',
    round(v_r.quantity, 6), 1.5::numeric);
  perform pg_temp.check_eq('and says which kind it was',
    v_r.value_kind::text, 'weight_grams');

  -- Switched off is switched off.
  perform public.upsert_scale_format(
    v_fmt, v_org, 'Deli scale', '20', 5, 5, 'weight_grams', true, false);
  select count(*)::integer into v_n from app.parse_scale_barcode(v_org, v_code);
  perform pg_temp.check_eq('a retired scale reads nothing', v_n, 0);

  perform pg_temp.check_true('and can be deleted',
    public.delete_scale_format(v_fmt));
  perform pg_temp.check_eq('leaving the other one',
    (select count(*)::integer from public.scale_formats_list(v_org)), 1);

  -- ------------------------------------------------------------------
  -- 9. And the grid knows which tiles have to ask
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the menu says a weighed item is weighed',
    (select m.is_weighed from public.pos_menu(v_outlet) m
      where m.item_id = v_ikan));
  perform pg_temp.check_true('and that a tin is not',
    not (select m.is_weighed from public.pos_menu(v_outlet) m
          where m.item_id = v_tin));

  raise notice 'ok   pos_weighed';
end $$;

rollback;
