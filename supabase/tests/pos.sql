-- =====================================================================
-- Point of sale :: the money
--
-- Everything here is a figure a customer is handed back across a
-- counter, so every one is checked against a worked example rather than
-- against whatever the code currently returns.
--
-- Three properties get their own assertions because they are the errors
-- that look right:
--
--   * rounding belongs to the CASH, not to the document. The same
--     basket is 10.85 across the counter and 10.83 on a card, and a
--     system that rounds the invoice charges the wrong customer two sen
--     on every card sale for ever.
--
--   * change is what came back out of a tender, not a smaller tender.
--     Recording 43.15 instead of "50.00 in, 6.85 out" loses the fifty
--     that went into the drawer, which is the only thing the cash-up
--     is about.
--
--   * a completed sale is a POSTED invoice and a POSTED receipt. Any
--     other state is a till that took money and recorded nothing, which
--     is the failure this whole module is arranged around.
-- =====================================================================
\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_item   uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_card   uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_n      integer;
  v_a      numeric;
  v_b      numeric;
  v_c      numeric;
  v_d      numeric;
  v_txt    text;
begin
  -- ------------------------------------------------------------------
  -- The rounding rule, on its own
  -- ------------------------------------------------------------------
  -- Bank Negara rounds the coins. A card does not have coins.
  perform pg_temp.check_eq('cash rounds up to the nearest five sen',
    app.pos_cash_due(10.03, 0, true), 10.05);
  perform pg_temp.check_eq('and down',
    app.pos_cash_due(10.02, 0, true), 10.00);
  perform pg_temp.check_eq('a basket settled entirely by card is not rounded',
    app.pos_cash_due(10.03, 10.03, true), 0);
  perform pg_temp.check_eq('and its adjustment is nothing at all',
    app.pos_rounding_adjustment(10.03, 10.03, true), 0);
  -- The case that separates "round the remainder" from "round the
  -- basket and then subtract". A card charged 5.01 leaves 5.02 in cash,
  -- which rounds DOWN to 5.00. Round the basket first and you get
  -- 10.05 - 5.01 = 5.04, which is not a coin.
  perform pg_temp.check_eq(
    'the remainder is rounded, not the basket then split',
    app.pos_cash_due(10.03, 5.01, true), 5.00);

  perform pg_temp.check_eq('a company that does not round is left alone',
    app.pos_cash_due(10.03, 0, false), 10.03);
  perform pg_temp.check_eq('over-tendering by card owes no coins',
    app.pos_cash_due(10.00, 12.00, true), 0);

  -- The identity the rounding account depends on. If this drifts, the
  -- difference has to go somewhere and there is nowhere for it to go.
  v_n := 0;
  for v_a in select g / 100.0 from generate_series(0, 200) g loop
    perform pg_temp.check_true(
      format('cash due at %s is exact plus the adjustment', v_a),
      app.pos_cash_due(v_a, 0, true)
        = v_a + app.pos_rounding_adjustment(v_a, 0, true));
    v_n := v_n + 1;
  end loop;
  -- The control. A loop over an empty range reports no failures just as
  -- quietly as a loop that passes.
  perform pg_temp.check_eq('sen amounts actually checked', v_n, 201);

  -- ------------------------------------------------------------------
  -- A till, and a sale rung through it
  -- ------------------------------------------------------------------
  v_org := pg_temp.test_org('Kedai Runcit Sdn Bhd');

  -- A till posts to the ledger on every sale, so it needs somewhere to
  -- post to. Period control refuses an entry outside a fiscal year, and
  -- rightly — but it means a shop that opens in January and never has a
  -- year created cannot sell at all, which is the correct refusal
  -- arriving at the worst possible moment. Worth knowing about.
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;

  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;

  -- Priced before tax and with no tax code, so the basket is the price
  -- and every figure below can be checked by hand.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'ROTI', 'Roti', 'stock', true, 'C62', 10.03, 4.00)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;

  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;

  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, true);

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true)
  returning id into v_cash;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CARD', 'Card', 'card', '04', false, false)
  returning id into v_card;

  -- A till with no shift open cannot sell. Selling into a drawer nobody
  -- has counted is how a variance becomes unattributable.
  begin
    perform public.open_pos_sale(v_reg);
    raise exception 'FAIL sold with no shift open';
  exception when check_violation then
    raise notice 'ok   a till with no open shift will not sell';
  end;

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- Cash: the coins round, the change comes back
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.03);

  select s.total_amount into v_a from public.pos_sales s where s.id = v_sale;
  perform pg_temp.check_eq('the basket is the price, before anything rounds',
    v_a, 10.03);

  select r.total, r.cash_due, r.change_due, r.rounding
    into v_a, v_b, v_c, v_d
    from public.complete_pos_sale(
      v_sale, jsonb_build_array(
        jsonb_build_object('type', v_cash, 'amount', 50.00))) r;
  perform pg_temp.check_eq('the sale totals to the rounded figure', v_a, 10.05);
  perform pg_temp.check_eq('which is what the drawer asks for', v_b, 10.05);
  perform pg_temp.check_eq('and 39.95 comes back from fifty', v_c, 39.95);
  perform pg_temp.check_eq('two sen of rounding', v_d, 0.02);

  -- The tender remembers the fifty, not the 10.05.
  select t.amount, t.change_given into v_a, v_b
    from public.pos_tenders t where t.sale_id = v_sale;
  perform pg_temp.check_eq('the drawer took a fifty', v_a, 50.00);
  perform pg_temp.check_eq('and gave 39.95 back', v_b, 39.95);

  -- And what it became.
  select d.status::text, d.total_amount, d.balance_amount
    into v_txt, v_a, v_b
    from public.sales_documents d
    join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale;
  perform pg_temp.check_true('a completed sale leaves a posted invoice',
    v_txt = 'completed');
  perform pg_temp.check_eq('for the rounded amount', v_a, 10.05);
  perform pg_temp.check_eq('owing nothing, because it was paid', v_b, 0);

  perform pg_temp.check_true('the receipt is posted too',
    (select r.gl_entry_id is not null from public.receipts r
      join public.pos_sales s on s.receipt_id = r.id where s.id = v_sale));

  perform pg_temp.check_eq('and the stock left the shelf',
    (select count(*) from public.stock_movements m
      join public.pos_sales s on s.invoice_id = m.source_id
     where s.id = v_sale), 1);

  -- ------------------------------------------------------------------
  -- Card: the same basket, and not a sen of rounding
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.03);
  select r.total, r.rounding, r.change_due into v_a, v_b, v_c
    from public.complete_pos_sale(
      v_sale, jsonb_build_array(
        jsonb_build_object('type', v_card, 'amount', 10.03))) r;
  perform pg_temp.check_eq('a card pays the basket to the sen', v_a, 10.03);
  perform pg_temp.check_eq('with nothing rounded', v_b, 0);
  perform pg_temp.check_eq('and no change from a card', v_c, 0);

  -- ------------------------------------------------------------------
  -- Split: only the cash half rounds
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.03);
  select r.cash_due, r.change_due, r.rounding into v_a, v_b, v_c
    from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_card, 'amount', 5.00),
      jsonb_build_object('type', v_cash, 'amount', 10.00))) r;
  perform pg_temp.check_eq('5.03 of cash is asked for as 5.05', v_a, 5.05);
  perform pg_temp.check_eq('and 4.95 comes back from ten', v_b, 4.95);
  perform pg_temp.check_eq('two sen again, on the cash half only', v_c, 0.02);

  -- ------------------------------------------------------------------
  -- What the till refuses
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.03);
  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 5.00)));
    raise exception 'FAIL took a short payment';
  exception when check_violation then
    raise notice 'ok   a short payment is refused';
  end;

  -- That sale is still parked, and a drawer cannot be counted over it:
  -- it is a decision nobody has made and possibly money already in the
  -- till.
  begin
    perform * from public.close_pos_shift(v_shift, 100.00);
    raise exception 'FAIL closed a shift over a parked sale';
  exception when check_violation then
    raise notice 'ok   a shift will not close over a parked sale';
  end;

  -- ------------------------------------------------------------------
  -- The drawer
  -- ------------------------------------------------------------------
  -- 100 float, plus 50.00 - 39.95 from the cash sale, plus
  -- 10.00 - 4.95 from the split. The card sale put nothing in it.
  perform pg_temp.check_eq(
    'the drawer expects the float plus the net cash, and not the card',
    app.pos_expected_cash(v_shift), 115.10);

  raise notice 'point of sale: all assertions passed';
end;
$$;
