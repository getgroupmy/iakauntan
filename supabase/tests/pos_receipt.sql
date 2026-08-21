-- =====================================================================
-- Point of sale :: what goes on the receipt
--
-- The assertion this file is built around is the one a shop finds out
-- about from a customer: every line fits the paper. A receipt rendered
-- 48 columns wide and printed on a 58mm roll wraps every price onto its
-- own line, and the total — the one number anybody reads — ends up
-- split across two.
--
-- The second is that money is not optional. The switches turn off the
-- cashier's name, the table, the item codes; there is deliberately no
-- switch for a discount, a promotion, a delivery fee or a tender, and
-- this file asserts that turning everything off still leaves every sen
-- on the paper.
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
  v_item   uuid;
  v_drink  uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;
  v_sale   uuid;
  v_line   uuid;
  v_txt    text;
  v_n      integer;
  v_cfg    record;
begin
  v_org := pg_temp.test_org('Kedai Resit Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  update public.organizations
     set registration_no = '202301012345 (1234567-A)'
   where id = v_org;
  -- 0181's rule: the boolean, the number, the date and the default tax
  -- code move together or a company believes it is charging tax and is
  -- not. The receipt reads what that function set, so the fixture has
  -- to have a code for it to default to.
  insert into public.tax_codes (
    org_id, code, name, tax_type_code, rate, applies_to,
    sales_tax_account_id, purchase_tax_account_id, is_exempt, is_default)
  values (
    v_org, 'ST8', 'Service Tax 8%', '02', 8, 'both',
    (select id from public.accounts where org_id = v_org and code = '2130'),
    (select id from public.accounts where org_id = v_org and code = '1410'),
    false, false);
  perform public.set_sst_registration(
    v_org, true, current_date - 30, 'W10-1234-56789012', 'ST8');

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'NASI', 'Nasi lemak ayam berempah', 'service', false, 'C62', 12.00, 5.00)
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'TEH', 'Teh tarik', 'service', false, 'C62', 3.00, 1.00)
  returning id into v_drink;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax, receipt_header, receipt_footer)
  values (v_org, 'WARUNG', 'Cawangan Bangsar', 'food_beverage', v_wh, v_walkin,
          false,
          E'KEDAI RESIT\n12 Jalan Maarof, Bangsar\n03-2011 2233',
          E'Terima kasih\nSila datang lagi')
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- An outlet nobody has configured still prints
  -- ------------------------------------------------------------------
  select * into v_cfg from public.pos_receipt_settings_for(v_outlet);
  perform pg_temp.check_eq('an unconfigured outlet reads back the defaults',
    v_cfg.paper_mm, 80);
  perform pg_temp.check_true('with the header it was given in 0206',
    v_cfg.header like 'KEDAI RESIT%');
  perform pg_temp.check_eq('and no row was written to say so',
    (select count(*) from public.pos_receipt_settings where outlet_id = v_outlet), 0);

  -- ------------------------------------------------------------------
  -- A bill for a table that has not paid
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  v_line := public.add_pos_sale_line(v_sale, v_item, 2, 12.00);
  perform public.add_pos_sale_line(v_sale, v_drink, 1, 3.00);

  v_txt := public.pos_receipt_text(v_sale);
  perform pg_temp.check_true('a parked bill prints, and says it is not paid',
    v_txt like '%*** NOT PAID ***%');
  perform pg_temp.check_true('and shows no change',
    v_txt not like '%Change%');
  perform pg_temp.check_true('the shop is at the top, in its own words',
    v_txt like '%KEDAI RESIT%');
  perform pg_temp.check_true('with the registration a receipt has to carry',
    v_txt like '%202301012345 (1234567-A)%');
  perform pg_temp.check_true('and the SST number, because it is registered',
    v_txt like '%SST W10-1234-56789012%');
  perform pg_temp.check_true('the words at the bottom are the shop''s own',
    v_txt like '%Terima kasih%');

  -- ------------------------------------------------------------------
  -- Every line fits the paper
  -- ------------------------------------------------------------------
  -- The assertion this file exists for. The dish name is deliberately
  -- long enough to collide with its own price on the narrow roll.
  select max(length(l)) into v_n
    from regexp_split_to_table(v_txt, E'\n') l;
  perform pg_temp.check_true('nothing overruns 80mm paper', v_n <= 48);

  perform public.upsert_pos_receipt_settings(v_outlet, p_paper_mm => 58::smallint);
  v_txt := public.pos_receipt_text(v_sale);
  select max(length(l)) into v_n
    from regexp_split_to_table(v_txt, E'\n') l;
  perform pg_temp.check_true('nor 58mm paper', v_n <= 32);
  perform pg_temp.check_true('and the long dish is still on it, shortened',
    v_txt like '%Nasi lemak%');

  -- ------------------------------------------------------------------
  -- The switches
  -- ------------------------------------------------------------------
  perform public.upsert_pos_receipt_settings(
    v_outlet,
    p_header => E'KEDAI RESIT\n12 Jalan Maarof, Bangsar\n03-2011 2233',
    p_footer => E'Terima kasih\nSila datang lagi',
    p_paper_mm => 80::smallint,
    p_item_codes => true);
  v_txt := public.pos_receipt_text(v_sale);
  perform pg_temp.check_true('item codes appear when the shop asks for them',
    v_txt like '%NASI%');

  perform public.upsert_pos_receipt_settings(
    v_outlet,
    p_header => E'KEDAI RESIT\n12 Jalan Maarof, Bangsar\n03-2011 2233',
    p_footer => E'Terima kasih\nSila datang lagi',
    p_paper_mm => 80::smallint,
    p_item_codes => false);
  v_txt := public.pos_receipt_text(v_sale);
  perform pg_temp.check_true('and not when it does not',
    v_txt not like '%NASI%');

  -- ------------------------------------------------------------------
  -- Money is not optional
  -- ------------------------------------------------------------------
  -- Everything a shop is allowed to switch off, switched off. What is
  -- left has to be every sen that changed hands.
  perform public.discount_pos_sale(v_sale, null, 3.00, 'Regular customer');
  perform public.upsert_pos_receipt_settings(
    v_outlet,
    p_header => 'KEDAI RESIT',
    p_footer => null,
    p_paper_mm => 80::smallint,
    p_item_codes => false,
    p_cashier => false,
    p_table => false,
    p_channel => false,
    p_tax => false,
    p_customer => false,
    p_points => false,
    p_qr => false);

  v_txt := public.pos_receipt_text(v_sale);
  perform pg_temp.check_true('a discount is on the paper whatever is switched off',
    v_txt like '%Discount - Regular customer%');
  perform pg_temp.check_true('and so is what it took off',
    v_txt like '%-3.00%');
  perform pg_temp.check_true('and the total',
    v_txt like '%TOTAL%24.00%');

  -- ------------------------------------------------------------------
  -- And what was handed over
  -- ------------------------------------------------------------------
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 50.00)));

  v_txt := public.pos_receipt_text(v_sale);
  perform pg_temp.check_true('a settled bill names the tender',
    v_txt like '%Tunai%50.00%');
  perform pg_temp.check_true('and the change that went back',
    v_txt like '%Change%26.00%');
  perform pg_temp.check_true('and stops saying it is not paid',
    v_txt not like '%NOT PAID%');

  -- ------------------------------------------------------------------
  -- In the language the shop prints in
  -- ------------------------------------------------------------------
  perform public.upsert_pos_receipt_settings(
    v_outlet, p_header => 'KEDAI RESIT', p_language => 'ms');
  v_txt := public.pos_receipt_text(v_sale);
  perform pg_temp.check_true('the labels follow the language',
    v_txt like '%JUMLAH%' and v_txt like '%Baki%');
  perform pg_temp.check_true('and the shop''s own words are left as typed',
    v_txt like '%KEDAI RESIT%');
  perform public.upsert_pos_receipt_settings(
    v_outlet, p_header => 'KEDAI RESIT', p_language => 'en');

  -- ------------------------------------------------------------------
  -- A written-off bill says so
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_drink, 1, 3.00);
  perform public.void_pos_sale(v_sale, 'other', 'Rang up twice');
  v_txt := public.pos_receipt_text(v_sale);
  perform pg_temp.check_true('a voided bill is marked on its own paper',
    v_txt like '%*** VOIDED ***%');

  -- ------------------------------------------------------------------
  -- The preview the settings screen shows
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the last settled bill is what gets previewed',
    public.pos_recent_sale(v_outlet) is not null);
end $$;

rollback;
