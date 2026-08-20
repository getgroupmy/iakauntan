-- =====================================================================
-- Point of sale :: retail
--
-- Two claims are checked here that are easy to state and easy to get
-- wrong:
--
--   * a variant is an item, so stock knows about it. The assertion that
--     matters is not that the rows appear -- it is that ringing up a
--     variant moves stock for THAT variant, because a shape where it
--     did not is exactly the shape this file exists to rule out.
--
--   * a scan means one thing. One barcode resolves to one item, and a
--     carton label rings up what is in the carton. A till that reads a
--     six-pack as one unit undercharges by five sixths and nothing
--     notices until the stock count.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_style  uuid;
  v_navy   uuid;
  v_white  uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_n      integer;
  v_a      numeric;
  v_txt    text;
begin
  v_org := pg_temp.test_org('Butik Nusantara Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  -- ------------------------------------------------------------------
  -- One shirt, six SKUs
  -- ------------------------------------------------------------------
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'SHIRT', 'Kemeja Batik', 'stock', true, 'C62', 89.00, 40.00)
  returning id into v_style;

  perform pg_temp.check_eq('three sizes and two colours make six variants',
    (select count(*) from public.create_item_variants(v_style,
      '{"Size": ["S", "M", "L"], "Colour": ["Navy", "White"]}'::jsonb)), 6);
  perform pg_temp.check_eq('and six items exist under the style',
    (select count(*) from public.items i where i.parent_item_id = v_style), 6);

  select i.id into v_navy from public.items i
   where i.parent_item_id = v_style
     and i.variant_attributes = '{"Size":"M","Colour":"Navy"}'::jsonb;
  select i.id into v_white from public.items i
   where i.parent_item_id = v_style
     and i.variant_attributes = '{"Size":"M","Colour":"White"}'::jsonb;
  perform pg_temp.check_true('the navy medium is one of them', v_navy is not null);

  select i.code into v_txt from public.items i where i.id = v_navy;
  perform pg_temp.check_true('its code is derived from the style, not typed',
    v_txt = 'SHIRT-NAVY-M');
  perform pg_temp.check_eq('and it inherits the style price',
    (select i.unit_price from public.items i where i.id = v_navy), 89.0000);

  -- Re-runnable. A shop that adds a colour in March runs it again with
  -- the whole list and gets three rows, not nine.
  perform pg_temp.check_eq('adding a colour creates only the new combinations',
    (select count(*) from public.create_item_variants(v_style,
      '{"Size": ["S", "M", "L"], "Colour": ["Navy", "White", "Sage"]}'::jsonb) r
      where r.created), 3);
  perform pg_temp.check_eq('for nine in total',
    (select count(*) from public.items i where i.parent_item_id = v_style), 9);

  -- The style became a heading.
  perform pg_temp.check_true('the style is no longer for sale',
    not (select i.is_sold from public.items i where i.id = v_style));
  begin
    update public.items set is_sold = true where id = v_style;
    raise exception 'FAIL made a style sellable';
  exception when check_violation then
    raise notice 'ok   a style cannot be made sellable again';
  end;

  -- One level. A size does not have sizes.
  begin
    perform public.create_item_variants(v_navy, '{"Fit": ["Slim"]}'::jsonb);
    raise exception 'FAIL nested a variant under a variant';
  exception when check_violation then
    raise notice 'ok   a variant cannot have variants';
  end;

  -- The picker grid, read out of the variants rather than out of a
  -- second copy of the same fact.
  perform pg_temp.check_eq('the matrix has two axes',
    (select count(*) from public.item_variant_matrix(v_style)), 2);
  perform pg_temp.check_eq('with three colours on one of them',
    (select array_length(m.axis_values, 1) from public.item_variant_matrix(v_style) m
      where m.axis = 'Colour'), 3);

  -- ------------------------------------------------------------------
  -- Labels
  -- ------------------------------------------------------------------
  insert into public.item_barcodes
    (org_id, item_id, barcode, uom_code, pack_quantity, is_primary)
  values (v_org, v_navy,  '9556001234567',  'C62', 1, true),
         (v_org, v_navy,  '19556001234564', 'C62', 6, false),
         (v_org, v_white, '9556001234574',  'C62', 1, true);

  begin
    insert into public.item_barcodes (org_id, item_id, barcode)
    values (v_org, v_white, '9556001234567');
    raise exception 'FAIL one barcode meant two items';
  exception when unique_violation then
    raise notice 'ok   a barcode resolves to one item, or it is not a barcode';
  end;

  begin
    insert into public.item_barcodes (org_id, item_id, barcode, is_primary)
    values (v_org, v_navy, '111', true);
    raise exception 'FAIL two primary labels on one item';
  exception when unique_violation then
    raise notice 'ok   an item has one primary label';
  end;

  -- ------------------------------------------------------------------
  -- The till
  -- ------------------------------------------------------------------
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true) returning id into v_cash;

  -- The gun. One row, and the till can act without asking anybody.
  perform pg_temp.check_eq('a scan resolves to exactly one item',
    (select count(*) from public.pos_lookup_item(v_outlet, '9556001234567')), 1);
  select l.item_id, l.quantity, l.matched_on into v_navy, v_a, v_txt
    from public.pos_lookup_item(v_outlet, '9556001234567') l;
  perform pg_temp.check_true('and says it matched a barcode', v_txt = 'barcode');
  perform pg_temp.check_eq('for one of them', v_a, 1);

  -- The case that pays for the table. The outer box is six.
  select l.quantity into v_a
    from public.pos_lookup_item(v_outlet, '19556001234564') l;
  perform pg_temp.check_eq('the carton label rings up six', v_a, 6);

  -- Typed, and squinted at.
  select l.matched_on into v_txt from public.pos_lookup_item(v_outlet, 'shirt-navy-m') l;
  perform pg_temp.check_true('a typed code is case-insensitive', v_txt = 'code');
  perform pg_temp.check_eq('the style name finds its nine variants, not the style',
    (select count(*) from public.pos_lookup_item(v_outlet, 'Kemeja Batik')), 9);
  perform pg_temp.check_eq('and an unknown label finds nothing at all',
    (select count(*) from public.pos_lookup_item(v_outlet, '0000000000000')), 0);

  -- ------------------------------------------------------------------
  -- What a style is not
  -- ------------------------------------------------------------------
  v_shift := public.open_pos_shift(v_reg, 100.00);
  v_sale  := public.open_pos_sale(v_reg);
  begin
    perform public.add_pos_sale_line(v_sale, v_style, 1, 89.00);
    raise exception 'FAIL rang up a style';
  exception when check_violation then
    raise notice 'ok   a style cannot be put in a bag';
  end;

  -- ------------------------------------------------------------------
  -- The claim the whole shape rests on
  -- ------------------------------------------------------------------
  -- A variant is an item, so selling one moves stock for that variant
  -- and not for its style or its sibling. If this ever fails, the
  -- variant model has stopped being real and the stock count is fiction.
  perform public.add_pos_sale_line(v_sale, v_navy, 2, 89.00);
  select s.total_amount into v_a from public.pos_sales s where s.id = v_sale;
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', v_a + 20)));

  perform pg_temp.check_eq('the stock that moved was the variant''s',
    (select coalesce(sum(m.quantity), 0) from public.stock_movements m
      join public.pos_sales s on s.invoice_id = m.source_id
     where s.id = v_sale and m.item_id = v_navy), -2);
  perform pg_temp.check_eq('the sibling colour did not move',
    (select count(*) from public.stock_movements m
      join public.pos_sales s on s.invoice_id = m.source_id
     where s.id = v_sale and m.item_id = v_white), 0);
  perform pg_temp.check_eq('and neither did the style',
    (select count(*) from public.stock_movements m
      join public.pos_sales s on s.invoice_id = m.source_id
     where s.id = v_sale and m.item_id = v_style), 0);

  -- The control. Every "did not move" above passes just as quietly when
  -- nothing moved at all.
  select count(*) into v_n from public.stock_movements m
    join public.pos_sales s on s.invoice_id = m.source_id where s.id = v_sale;
  perform pg_temp.check_eq('one stock movement was actually made', v_n, 1);

  -- ------------------------------------------------------------------
  -- Splitting an item that already holds stock
  -- ------------------------------------------------------------------
  -- Refused, because the stock counted against the old item has nowhere
  -- to go once the item stops holding any.
  begin
    perform public.create_item_variants(v_navy, '{"Fit": ["Slim"]}'::jsonb);
    raise exception 'FAIL split an item that holds stock';
  exception when check_violation then
    raise notice 'ok   an item with stock cannot be split into variants';
  end;

  -- ------------------------------------------------------------------
  -- What the till offers when nobody has scanned anything
  -- ------------------------------------------------------------------
  --
  -- `pos_menu` fills the pane that used to say "Ready — scan an item",
  -- and its whole risk is that a grid tile is easier to hit than a
  -- search result is to misread. So it must offer exactly what the sale
  -- line will accept: the style whose variants exist is not sellable,
  -- and a tile for it would raise under somebody's thumb.
  perform pg_temp.check_eq(
    'the style is not offered as something to tap',
    (select count(*)::integer from public.pos_menu(v_outlet) m
      where m.item_id = v_style), 0);
  perform pg_temp.check_true(
    'but its variants are',
    (select count(*) from public.pos_menu(v_outlet) m
      where m.item_id in (select i.id from public.items i
                           where i.parent_item_id = v_style)) > 0);
  perform pg_temp.check_eq(
    'and an item nobody sells is not on the menu either',
    (select count(*)::integer from public.pos_menu(v_outlet) m
       join public.items i on i.id = m.item_id
      where not i.is_sold), 0);
  -- The positive control: an assertion that only counts absences passes
  -- just as well when the function returns nothing at all.
  perform pg_temp.check_true('the menu is not simply empty',
    (select count(*) from public.pos_menu(v_outlet)) > 0);

  raise notice 'point of sale retail: all assertions passed';
end;
$$;

rollback;
