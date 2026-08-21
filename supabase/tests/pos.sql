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
\set ON_ERROR_STOP on

begin;

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
  v_cash_sale uuid;
  v_card_sale uuid;
  v_named  uuid;
  v_n      integer;
  v_a      numeric;
  v_b      numeric;
  v_c      numeric;
  v_d      numeric;
  v_due    date;
  v_pend   date;
  v_txt    text;
  v_board  record;
  v_line   uuid;
  v_promo  uuid;
  v_drink  uuid;
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
  select v_org, m, true from unnest(array['pos','purchases','inventory','einvoice']) m
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
  v_cash_sale := v_sale;
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
  v_card_sale := v_sale;
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

  -- ------------------------------------------------------------------
  -- What the shop owes LHDN, and how it is not one document per drink
  -- ------------------------------------------------------------------
  -- Three sales completed above, all to the walk-in. Nobody identified
  -- themselves, so under the guideline they roll into one monthly
  -- submission rather than three.
  update public.organizations
     set einvoice_enabled = true, tin = 'C24680135790' where id = v_org;
  insert into public.contacts
    (org_id, code, name, contact_type, tin, id_type, id_value)
  values (v_org, 'BERDAFTAR', 'Syarikat Berdaftar', 'customer',
          'C99887766550', 'BRN', '202301999999')
  returning id into v_named;

  select o.sales_waiting, o.due_date, o.consolidation_status
    into v_n, v_due, v_txt
    from public.pos_einvoice_outstanding(v_org) o
   where o.period_start = date_trunc('month', current_date)::date;
  perform pg_temp.check_eq('three counter sales are waiting to be rolled up',
    v_n, 3);
  perform pg_temp.check_true('and no consolidation has been started',
    v_txt = 'not started');
  perform pg_temp.check_true('due seven days after month end',
    v_due = (date_trunc('month', current_date) + interval '1 month - 1 day')::date + 7);

  -- "Boss, I need it under the company name" -- which arrives after the
  -- money, not before it.
  perform public.request_einvoice_for_sale(v_card_sale, v_named);
  perform pg_temp.check_true('a claimed sale is no longer anonymous',
    not app.pos_invoice_is_anonymous(
      (select s.invoice_id from public.pos_sales s where s.id = v_card_sale)));
  perform pg_temp.check_true('and it has an e-Invoice of its own',
    (select d.einvoice_id is not null from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_card_sale));

  -- A buyer with no TIN cannot be named on one: LHDN needs the number,
  -- and a blank there is the walk-in by another route.
  begin
    perform public.request_einvoice_for_sale(v_cash_sale, v_walkin);
    raise exception 'FAIL named an e-Invoice to a customer with no TIN';
  exception when check_violation then
    raise notice 'ok   a customer with no TIN cannot be named on one';
  end;

  select r.document_count, r.total_amount, r.added, r.due_date, r.period_end
    into v_n, v_a, v_b, v_due, v_pend
    from public.consolidate_pos_einvoices(v_org, current_date) r;
  perform pg_temp.check_eq('two anonymous sales roll up', v_n, 2);
  perform pg_temp.check_eq('both added on the first run', v_b, 2);
  perform pg_temp.check_eq('for the cash sale plus the split sale',
    v_a, 20.10);
  perform pg_temp.check_true('the deadline is generated from the period',
    v_due = v_pend + 7);
  perform pg_temp.check_true('and the claimed sale stayed out of it',
    not exists (select 1 from public.einvoice_consolidation_items i
                  join public.pos_sales s on s.invoice_id = i.sales_document_id
                 where s.id = v_card_sale));

  -- The property that matters most here. This is the kind of function
  -- somebody runs a second time because they are not sure the first one
  -- worked, and a roll-up that double-counts on the second run files a
  -- return for twice the month's takings.
  select r.document_count, r.total_amount, r.added into v_n, v_a, v_b
    from public.consolidate_pos_einvoices(v_org, current_date) r;
  perform pg_temp.check_eq('running it again adds nothing', v_b, 0);
  perform pg_temp.check_eq('the count does not move', v_n, 2);
  perform pg_temp.check_eq('nor the total', v_a, 20.10);
  perform pg_temp.check_eq('and there is still one consolidation for the month',
    (select count(*) from public.einvoice_consolidations c
      where c.org_id = v_org), 1);

  -- Too late to ask. That submission has already told LHDN this sale
  -- had no identified buyer.
  begin
    perform public.request_einvoice_for_sale(v_cash_sale, v_named);
    raise exception 'FAIL re-billed a sale already consolidated';
  exception when check_violation then
    raise notice 'ok   a consolidated sale cannot be re-billed';
  end;

  -- Nothing is outstanding once it has been rolled up: what the screen
  -- shows and what the roll-up takes are the same predicate, and this
  -- is the assertion that keeps them so.
  perform pg_temp.check_eq('nothing waits for this month any more',
    (select count(*) from public.pos_einvoice_outstanding(v_org) o
      where o.period_start = date_trunc('month', current_date)::date), 0);

  -- Once it has gone to LHDN it stops absorbing. A consolidation that
  -- keeps growing after submission is a return that no longer matches
  -- what was filed.
  update public.einvoice_consolidations set status = 'submitted'
   where org_id = v_org;
  begin
    perform * from public.consolidate_pos_einvoices(v_org, current_date);
    raise exception 'FAIL absorbed a sale into a submitted consolidation';
  exception when check_violation then
    raise notice 'ok   a submitted consolidation takes no more sales';
  end;

  -- ------------------------------------------------------------------
  -- The day, across every outlet (0252)
  -- ------------------------------------------------------------------
  -- The owner's view rather than the shop's. Everything on the row is
  -- about the trading day named except the open count, which is about
  -- now -- a parked bill has no day yet.

  select * into v_board from public.pos_day_board(v_org, current_date);
  perform pg_temp.check_true('the shop is on the board',
    v_board.outlet_id = v_outlet);
  perform pg_temp.check_eq('with every bill it settled today',
    v_board.bills,
    (select count(*) from public.pos_sales s
      where s.org_id = v_org and s.status = 'completed'
        and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
            = current_date));
  perform pg_temp.check_eq('and what they came to',
    v_board.gross,
    (select coalesce(sum(s.total_amount), 0) from public.pos_sales s
      where s.org_id = v_org and s.status = 'completed'
        and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
            = current_date));

  -- Cash is net of change: the fifty handed over less the change given
  -- back, which is what should actually be in the drawer. It is the one
  -- number an owner compares between shops.
  perform pg_temp.check_eq('cash is what the drawer should hold',
    v_board.cash,
    (select coalesce(sum(t.amount - t.change_given), 0)
       from public.pos_tenders t
       join public.pos_sales s on s.id = t.sale_id
      where s.org_id = v_org and s.status = 'completed'
        and t.kind = 'cash'
        and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
            = current_date));
  perform pg_temp.check_eq('and cash plus the rest is the takings',
    v_board.cash + v_board.non_cash, v_board.gross);
  perform pg_temp.check_eq('the average is the takings over the bills',
    v_board.average_bill, round(v_board.gross / v_board.bills, 2));

  -- A shop that sold nothing is still on the board. Its absence would
  -- read as "no problem" when it is the problem.
  select * into v_board from public.pos_day_board(v_org, current_date - 400);
  perform pg_temp.check_true('a shop with a quiet day is still listed',
    v_board.outlet_id = v_outlet);
  perform pg_temp.check_eq('with nothing against it', v_board.bills, 0);
  perform pg_temp.check_eq('and no division by nothing',
    v_board.average_bill, 0);

  -- ------------------------------------------------------------------
  -- A price the manager takes off
  -- ------------------------------------------------------------------
  --
  -- 0209 has taken a discount since the beginning and nothing ever
  -- passed one. 0255 gave it a caller, and these are the four things
  -- that caller has to get right, all of which look right when wrong:
  --
  --   * a percentage measured against the FULL price, so discounting a
  --     line twice replaces rather than compounds,
  --   * a rate on the bill that survives another plate arriving, and a
  --     flat amount that does not move when one does,
  --   * tax charged on what was paid, not on what was asked,
  --   * the invoice's header discount naming both the redemption and
  --     the bill discount, because `prepare_einvoice` passes that field
  --     to LHDN.
  v_sale := public.open_pos_sale(v_reg);
  v_line := public.add_pos_sale_line(v_sale, v_item, 2, 10.00);

  perform public.discount_pos_sale_line(v_line, 10, null, 'burnt');
  perform pg_temp.check_eq('a tenth off a 20.00 line is 2.00',
    (select l.discount_amount from public.pos_sale_lines l where l.id = v_line),
    2.00);
  perform pg_temp.check_eq('and the line charges 18.00',
    (select l.line_total from public.pos_sale_lines l where l.id = v_line),
    18.00);

  -- The one that compounds if it is measured against what is left.
  perform public.discount_pos_sale_line(v_line, 25, null, 'burnt again');
  perform pg_temp.check_eq('a second discount replaces the first',
    (select l.discount_amount from public.pos_sale_lines l where l.id = v_line),
    5.00);

  perform public.discount_pos_sale_line(v_line, null, null, null);
  perform pg_temp.check_eq('and clearing it puts the line back',
    (select l.line_total from public.pos_sale_lines l where l.id = v_line),
    20.00);
  perform pg_temp.check_true('with nobody''s name against it',
    (select l.discounted_by is null and l.discount_reason is null
       from public.pos_sale_lines l where l.id = v_line));

  begin
    perform public.discount_pos_sale_line(v_line, 10, null, '   ');
    raise exception 'FAIL a discount was given with no reason';
  exception when check_violation then
    raise notice 'ok   a discount needs a reason';
  end;

  begin
    perform public.discount_pos_sale_line(v_line, null, 25.00, 'why not');
    raise exception 'FAIL more was taken off than the line comes to';
  exception when check_violation then
    raise notice 'ok   a discount cannot exceed the line';
  end;

  -- A rate on the bill is re-applied every time the basket changes.
  -- The alternative -- storing the amount once -- means a waiter adding
  -- a drink silently shrinks the discount the customer was promised.
  perform public.discount_pos_sale(v_sale, 10, null, 'staff');
  perform pg_temp.check_eq('a tenth off a 20.00 bill is 2.00',
    (select s.bill_discount from public.pos_sales s where s.id = v_sale), 2.00);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  perform pg_temp.check_eq('and it is 3.00 once a 10.00 plate arrives',
    (select s.bill_discount from public.pos_sales s where s.id = v_sale), 3.00);
  perform pg_temp.check_eq('so the bill comes to 27.00',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 27.00);

  -- A flat amount is a promise of ringgit, not of proportion.
  perform public.discount_pos_sale(v_sale, null, 4.00, 'voucher');
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  perform pg_temp.check_eq('a flat 4.00 is still 4.00 a plate later',
    (select s.bill_discount from public.pos_sales s where s.id = v_sale), 4.00);
  perform pg_temp.check_eq('and 40.00 of food comes to 36.00',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 36.00);

  -- What LHDN is told. The money was already right without this; what
  -- was wrong before 0255 was the description of it -- an invoice
  -- charging 36.00 for 40.00 of food, declaring a discount of nothing.
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 40.00)));
  perform pg_temp.check_eq('the invoice header carries the bill discount',
    (select d.discount_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale),
    4.00);
  perform pg_temp.check_eq('and charges what the customer paid',
    (select d.total_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale),
    36.00);

  -- The report the permission exists for.
  perform pg_temp.check_eq('the discount report names who gave it away',
    (select d.bill_value from public.pos_discount_summary(
       v_org, current_date, current_date) d),
    4.00);

  -- ------------------------------------------------------------------
  -- A price the shop decided in advance
  -- ------------------------------------------------------------------
  --
  -- 0256's promotions. Four things are asserted because all four are
  -- wrong in the obvious implementation:
  --
  --   * a rate is re-derived from the basket every time, so it follows
  --     the bill up AND down,
  --   * switching a promotion off leaves no row behind — nothing was
  --     ever written into a line, so there is no price to restore,
  --   * three-for-two discounts the cheapest of each COMPLETE block and
  --     charges full price for the remainder,
  --   * the invoice header carries it, which is not cosmetic: the
  --     posting routine derives credits from the lines less the header
  --     discount and refuses to post when the two disagree.
  -- A second dish, built exactly like the fixture above so nothing
  -- here is testing a different kind of item by accident.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'TEH', 'Teh tarik', 'stock', true, 'C62', 3.00, 1.00)
  returning id into v_drink;

  insert into public.pos_promotions (org_id, name, kind, percent)
  values (v_org, 'Ten off', 'percent_off', 10) returning id into v_promo;

  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 2, 10.00);
  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('a tenth off a 20.00 basket is 2.00',
    (select s.promo_discount from public.pos_sales s where s.id = v_sale), 2.00);
  perform pg_temp.check_eq('so the bill comes to 18.00',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 18.00);

  -- The case a stored amount gets wrong: another plate arrives.
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('and 3.00 once a third plate arrives',
    (select s.promo_discount from public.pos_sales s where s.id = v_sale), 3.00);

  -- Switching it off leaves nothing behind, because nothing was ever
  -- written into a line.
  update public.pos_promotions set is_active = false where id = v_promo;
  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('switching it off takes nothing off',
    (select s.promo_discount from public.pos_sales s where s.id = v_sale), 0);
  perform pg_temp.check_eq('and leaves no row on the bill',
    (select count(*) from public.pos_sale_promotions sp
      where sp.sale_id = v_sale), 0);
  perform pg_temp.check_eq('and the bill is back to full price',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 30.00);

  -- Three for two, on one dish only.
  insert into public.pos_promotions
    (org_id, name, kind, percent, buy_quantity, get_quantity)
  values (v_org, 'Three for two', 'buy_x_get_y', 100, 2, 1)
  returning id into v_promo;
  insert into public.pos_promotion_items (promotion_id, item_id)
  values (v_promo, v_drink);

  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_drink, 6, 3.00);
  perform public.add_pos_sale_line(v_sale, v_item, 3, 10.00);
  perform public.refresh_pos_sale_promotions(v_sale);
  -- Six qualifying units, two complete blocks, the cheapest of each
  -- free. The 10.00 dish is not on the promotion and is not touched.
  perform pg_temp.check_eq('three for two on six drinks frees two',
    (select s.promo_discount from public.pos_sales s where s.id = v_sale), 6.00);

  -- Five units is one complete block and two left over.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_drink, 5, 3.00);
  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('an incomplete block pays full price',
    (select s.promo_discount from public.pos_sales s where s.id = v_sale), 3.00);
  update public.pos_promotions set is_active = false where id = v_promo;

  -- A voucher, its minimum spend, and what it says when it is not met.
  insert into public.pos_promotions
    (org_id, code, name, kind, amount, min_subtotal, max_uses)
  values (v_org, 'raya5', 'Raya five', 'amount_off', 5.00, 50.00, 1)
  returning id into v_promo;

  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  begin
    perform public.apply_pos_coupon(v_sale, 'RAYA5');
    raise exception 'FAIL a voucher was taken on a bill below its minimum';
  exception when check_violation then
    raise notice 'ok   a voucher below its minimum is refused';
  end;

  perform public.add_pos_sale_line(v_sale, v_item, 5, 10.00);
  -- Typed the way a cashier types it, off a printed slip.
  perform public.apply_pos_coupon(v_sale, '  RaYa5 ');
  perform pg_temp.check_eq('a voucher takes its amount off',
    (select s.promo_discount from public.pos_sales s where s.id = v_sale), 5.00);

  -- The basket shrinks under the minimum. The voucher stays on the
  -- bill saying why it is worth nothing, rather than vanishing and
  -- leaving a cashier to explain something they cannot see.
  perform public.remove_pos_sale_line(
    (select l.id from public.pos_sale_lines l
      where l.sale_id = v_sale order by l.line_no desc limit 1));
  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('shrinking the bill makes the voucher worth nothing',
    (select sp.amount from public.pos_sale_promotions sp
      where sp.sale_id = v_sale), 0);
  perform pg_temp.check_true('and it says why, on the bill',
    (select sp.blocked_reason like '%needs 50.00%'
       from public.pos_sale_promotions sp where sp.sale_id = v_sale));
  perform pg_temp.check_eq('and the customer is charged full price',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 10.00);

  perform public.add_pos_sale_line(v_sale, v_item, 5, 10.00);
  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('putting it back brings the voucher back',
    (select sp.amount from public.pos_sale_promotions sp
      where sp.sale_id = v_sale), 5.00);

  -- Settling it. The header discount is load-bearing: without it
  -- post_sales_document_internal refuses, because the credit side is
  -- the lines less the header discount and the debit side is the
  -- total. This completing at all is that assertion.
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 100.00)));
  perform pg_temp.check_eq('the invoice header carries the promotion',
    (select d.discount_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale),
    5.00);
  perform pg_temp.check_eq('and charges 60.00 of food at 55.00',
    (select d.total_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale),
    55.00);
  perform pg_temp.check_true('and the ledger balances',
    (select e.total_debit = e.total_credit and e.total_debit > 0
       from public.gl_entries e
       join public.pos_sales s on s.invoice_id = e.source_id
      where s.id = v_sale and e.source_table = 'sales_documents'
      limit 1));

  -- One use, used up. Counted from completed sales rather than a
  -- counter, so a parked bill never burns it and a written-off bill
  -- gives it back.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 6, 10.00);
  begin
    perform public.apply_pos_coupon(v_sale, 'RAYA5');
    raise exception 'FAIL a one-use voucher was taken twice';
  exception when check_violation then
    raise notice 'ok   a one-use voucher is used up once a bill settles';
  end;

  raise notice 'point of sale: all assertions passed';
end;
$$;

rollback;
