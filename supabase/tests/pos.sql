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
  -- The trading day in the shop's own time. `current_date` is the
  -- session's, which is UTC in CI: between 16:00 and midnight UTC it is
  -- already tomorrow in Kuala Lumpur, the board finds no bills for the
  -- day it is asked about, and the average-bill assertion divides by
  -- zero. Every reader in the module uses this expression; so does this.
  v_kl_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
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
  -- `0402`. The invoice posted against the outlet's walk-in contact and
  -- the receivable line was filed under it. Renaming the buyer has to
  -- take the sub-ledger with it, or an aged receivables report built
  -- from `gl_lines` and one built from `sales_documents` name different
  -- people for the same money. The document's own contact is asserted
  -- as well, so a mutant that moved only the ledger would be caught too.
  perform pg_temp.check_eq('the invoice now names the customer',
    (select d.contact_id from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_card_sale),
    v_named);
  perform pg_temp.check_eq(
    'and the receivable in the ledger was refiled under them with it',
    (select count(*) from public.gl_lines l
       join public.sales_documents d on d.gl_entry_id = l.entry_id
       join public.pos_sales s on s.invoice_id = d.id
      where s.id = v_card_sale and l.contact_id is not null
        and l.contact_id is distinct from v_named),
    0);
  perform pg_temp.check_true('on a line that is actually there',
    (select count(*) from public.gl_lines l
       join public.sales_documents d on d.gl_entry_id = l.entry_id
       join public.pos_sales s on s.invoice_id = d.id
      where s.id = v_card_sale and l.contact_id = v_named) > 0);

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

  select * into v_board from public.pos_day_board(v_org, v_kl_today);
  perform pg_temp.check_true('the shop is on the board',
    v_board.outlet_id = v_outlet);
  perform pg_temp.check_eq('with every bill it settled today',
    v_board.bills,
    (select count(*) from public.pos_sales s
      where s.org_id = v_org and s.status = 'completed'
        and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
            = v_kl_today));
  perform pg_temp.check_eq('and what they came to',
    v_board.gross,
    (select coalesce(sum(s.total_amount), 0) from public.pos_sales s
      where s.org_id = v_org and s.status = 'completed'
        and (s.completed_at at time zone 'Asia/Kuala_Lumpur')::date
            = v_kl_today));

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
            = v_kl_today));
  perform pg_temp.check_eq('and cash plus the rest is the takings',
    v_board.cash + v_board.non_cash, v_board.gross);
  perform pg_temp.check_eq('the average is the takings over the bills',
    v_board.average_bill, round(v_board.gross / v_board.bills, 2));

  -- A shop that sold nothing is still on the board. Its absence would
  -- read as "no problem" when it is the problem.
  select * into v_board from public.pos_day_board(v_org, v_kl_today - 400);
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
       v_org, v_kl_today, v_kl_today) d),
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
  insert into public.pos_promotion_items (org_id, promotion_id, item_id)
  values (v_org, v_promo, v_drink);

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

  -- Settling it.
  --
  -- The header discount is load-bearing rather than descriptive, and
  -- this line is the assertion of that. `post_sales_document_internal`
  -- derives the credit side from the lines less the header discount and
  -- checks it against the debit side; leave the promotion out and the
  -- two disagree by exactly what it took off, and
  -- `create_gl_entry_internal` raises
  --
  --     Journal does not balance: debits 55.00, credits 60.00
  --
  -- So this call completing IS the ledger check. A separate assertion
  -- reading `gl_entries` back would add nothing and would depend on
  -- that table being visible to whatever role the fixture is signed in
  -- as, which is a different question from whether the books balance.
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

-- =====================================================================
-- What the till refuses
--
-- The block above asserts what the till DOES: the rounding, the change,
-- the posted invoice and the posted receipt. A mutation sweep over
-- `complete_pos_sale` found that side well covered and the refusals
-- almost entirely open — every `raise exception` in the function has a
-- message written for a particular counter mistake, and most of them
-- had never been reached.
--
-- Each one below is a way a till can take money and record the wrong
-- thing:
--
--   * a tender of nothing, which is a keying slip that would otherwise
--     complete a sale nobody paid for;
--   * a tender type belonging to another company, or one this shop has
--     withdrawn. Both are foreign keys that resolve; only the org and
--     the active flag keep them off this till;
--   * a basket with nothing tendered at all;
--   * a card charged more than the basket, which is a refund waiting to
--     happen rather than a sale;
--   * a completed sale rung up a second time. This is the one that
--     costs a customer money: without it the same basket takes payment
--     twice and raises a second invoice;
--   * an outlet with no walk-in customer set, where an anonymous sale
--     has nobody to bill;
--   * and somebody selling for a company they are not a member of.
--
-- One refusal is deliberately not here. `if v_change < 0` is masked: a
-- short payment is already refused further down, by the constraint that
-- will not let a sale be completed without a receipt or an on-account
-- amount that covers it. Checked rather than assumed -- the guard was
-- removed and "a short payment is refused" above still held. It stays
-- in the function because it is the message a cashier should see, and
-- the assertion above still pins the behaviour.
-- =====================================================================

do $$
declare
  v_org uuid; v_them uuid; v_wh uuid; v_walkin uuid; v_item uuid;
  v_outlet uuid; v_bare uuid; v_reg uuid; v_reg2 uuid;
  v_cash uuid; v_card uuid; v_gone uuid; v_theirs uuid;
  v_sale uuid; v_stranger uuid; v_msg text;
  v_owner uuid := pg_temp.test_user();
begin
  v_org := pg_temp.test_org('Kaunter Ujian Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org,'MAIN','Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org,'WALK-IN','Counter sales','customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org,'SVC','Servis','service',false,'C62',10.00,0)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org,'SHOP','The shop','retail',v_wh,v_walkin,false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet,'T1','Counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, false);

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org,'CASH','Cash','cash','01',true,true) returning id into v_cash;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org,'CARD','Card','card','03',false,false) returning id into v_card;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change,
     is_active)
  values (v_org,'OLD','Withdrawn voucher','voucher','06',false,false,false)
  returning id into v_gone;

  -- Another company, with a till of its own.
  v_them := pg_temp.test_org('Kedai Lain Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_them,'pos',true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_them,'CASH','Cash','cash','01',true,true) returning id into v_theirs;

  perform public.open_pos_shift(v_reg, 100.00);

  -- ==================================================================
  -- What the till will not take
  -- ==================================================================
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);

  -- The message matters as much as the refusal. Every one of these is
  -- also stopped further down -- by the short-payment check, or by a
  -- NOT NULL column -- so a cashier would be refused either way. What
  -- the guard buys is being told what to fix: "a tender needs an
  -- amount" is a keying slip, "short by ten ringgit" is a customer who
  -- has not finished paying, and they are different problems.
  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 0)));
    raise exception 'FAIL: a tender of nothing was accepted';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a tender of nothing is a keying slip, and says so',
      v_msg like '%tender needs an amount%');
  end;

  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_theirs, 'amount', 10.00)));
    raise exception 'FAIL: another company''s tender type was accepted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   another company''s tender type is not one of ours';
  end;

  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_gone, 'amount', 10.00)));
    raise exception 'FAIL: a withdrawn tender type was accepted';
  exception when sqlstate 'P0002' then
    raise notice 'ok   nor is one the shop has withdrawn';
  end;

  begin
    perform * from public.complete_pos_sale(v_sale, '[]'::jsonb);
    raise exception 'FAIL: a basket was rung up with nothing tendered';
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a basket with something on it has to be paid for',
      v_msg like '%has to be paid for%');
  end;

  -- A card is not cash: it cannot over-pay, because the difference has
  -- nowhere to go but a refund.
  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_card, 'amount', 50.00)));
    raise exception 'FAIL: a card was charged more than the basket';
  exception when check_violation then
    raise notice 'ok   a card cannot be charged more than the basket';
  end;

  -- ==================================================================
  -- And what it will not take twice
  -- ==================================================================
  perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 10.00)));
  perform pg_temp.check_true('the sale completes once',
    (select status = 'completed' from public.pos_sales where id = v_sale));

  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 10.00)));
    raise exception 'FAIL: a completed sale was rung up again';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'and a completed sale cannot be rung up again',
      v_msg like '%already completed%');
  end;
  perform pg_temp.check_eq('with one invoice against it, not two',
    (select count(*)::integer from public.sales_documents
      where org_id = v_org and doc_type = 'invoice'), 1);

  -- ==================================================================
  -- An outlet with nobody to bill
  -- ==================================================================
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, prices_include_tax)
  values (v_org,'BARE','No walk-in set','retail',v_wh,false)
  returning id into v_bare;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_bare,'T2','Second counter') returning id into v_reg2;
  perform public.open_pos_shift(v_reg2, 0);
  v_sale := public.open_pos_sale(v_reg2);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 10.00)));
    raise exception 'FAIL: an anonymous sale was billed to nobody';
  exception when not_null_violation then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'an outlet with no walk-in customer says what to set',
      v_msg like '%walk-in customer%');
  end;

  -- ==================================================================
  -- Somebody else's till
  -- ==================================================================
  v_stranger := pg_temp.another_user('stranger@example.test');
  perform pg_temp.sign_in_as(v_stranger);
  begin
    perform * from public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 10.00)));
    raise exception 'FAIL: a stranger rang up a sale';
  exception when insufficient_privilege then
    raise notice 'ok   a stranger cannot sell for a company they are not in';
  end;
  perform pg_temp.sign_in_as(v_owner);
end $$;

-- ---------------------------------------------------------------------
-- The twenty-one a second sweep found
--
-- Seventy-six one-line mutants of `complete_pos_sale` against
-- thirty-odd POS files. Fifty-four died: the money is well asserted,
-- which is what the block above was written for. What survived is the
-- SCOPING, the ORDERING, and what each row CARRIES.
--
-- The three worth naming first:
--
--   * `p_contact` was not held to this company. 0523 added the check
--     and nothing asserted it; a counter could bill another company's
--     customer, and the only thing stopping it was a foreign key
--     firing three hundred lines later with a constraint name on it.
--
--   * The invoice is linked to the sale BEFORE it posts, because
--     `app.enforce_credit_limit` asks `pos_sales` by `invoice_id` to
--     learn how much credit this counter sale is extending. Written
--     after the posting, the link is not there when the question is
--     asked and every on-account sale passes the limit. That is 0467,
--     and it was unasserted.
--
--   * Rounding applies to what is left AFTER the non-cash tender, and
--     only when the shop rounds at all. `pos_rounding.sql` asserts the
--     pure function completely; nothing asserted that the till PASSES
--     it the right arguments.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_owner uuid := pg_temp.test_user();
  v_them uuid; v_their_cust uuid;
  v_wh uuid; v_walkin uuid; v_item uuid; v_ride uuid;
  v_outlet uuid; v_reg uuid; v_cash uuid; v_card uuid; v_acct uuid;
  v_cust uuid; v_sale uuid; v_msg text; r record;
  v_inv uuid; v_rcp uuid;
begin
  v_org := pg_temp.test_org('Kaunter Sapu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Lantai') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Jualan kaunter', 'customer') returning id into v_walkin;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan Berakaun', 'customer') returning id into v_cust;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'SVC', 'Servis', 'service', false, 'C62', 10.00, 0)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'Kedai', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Kaunter') returning id into v_reg;

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Tunai', 'cash', '01', true, true) returning id into v_cash;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CARD', 'Kad', 'card', '03', false, false) returning id into v_card;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'ACCT', 'Akaun', 'on_account', '07', false, false)
  returning id into v_acct;

  -- Another company, with a customer of its own.
  v_them := pg_temp.test_org('Kedai Sapu Lain Sdn Bhd');
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_them, 'C-X', 'Orang Lain', 'customer') returning id into v_their_cust;
  perform pg_temp.sign_in_as(v_owner);

  perform public.open_pos_shift(v_reg, 100.00);

  -- ==================================================================
  -- 1. Whose customer is being billed
  -- ==================================================================
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  begin
    perform * from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 10.00)),
      v_their_cust);
    raise exception 'a counter billed another company''s customer';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a customer of another company cannot be billed',
      v_msg, 'No such contact.');
  end;
  perform pg_temp.check_eq('and the sale is still parked, not half rung up',
    (select status::text from public.pos_sales where id = v_sale), 'parked');

  begin
    perform * from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 10.00)),
      gen_random_uuid());
    raise exception 'a counter billed nobody at all';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('nor one that does not exist',
      v_msg, 'No such contact.');
  end;

  -- And a basket with nothing on it.
  declare v_empty uuid;
  begin
    v_empty := public.open_pos_sale(v_reg);
    begin
      perform * from public.complete_pos_sale(v_empty,
        jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 10.00)));
      raise exception 'an empty basket was rung up';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      perform pg_temp.check_eq('an empty basket is not a sale',
        v_msg, 'There is nothing on this sale to pay for.');
    end;
  end;

  begin
    perform * from public.complete_pos_sale(gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 10.00)));
    raise exception 'a sale that does not exist was rung up';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('nor is a sale that does not exist',
      v_msg, 'No such sale.');
  end;

  -- ==================================================================
  -- 2. Short by
  --
  -- Masked further down by the receipt constraint, but the MESSAGE is
  -- the point: a cashier told "short by 3.00" knows the customer has
  -- not finished paying. Asserted on the whole sentence.
  -- ==================================================================
  begin
    perform * from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 7.00)));
    raise exception 'a customer short of the total was let go';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a short payment says how short',
      v_msg, 'Short by 3.00. The customer still owes that much.');
  end;

  -- ==================================================================
  -- 3. What the till passes the rounding rule
  --
  -- pos_rounding.sql asserts app.pos_cash_due completely. This asserts
  -- that the till asks it the right question: the remainder after the
  -- card, and only when the shop rounds.
  -- ==================================================================
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, true)
  on conflict (org_id) do update set round_cash_to_5sen = true;

  declare v_r record;
  begin
    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 1, 10.03);
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(
        jsonb_build_object('type', v_card, 'amount', 5.01),
        jsonb_build_object('type', v_cash, 'amount', 5.00)));
    -- 10.03 less the 5.01 card is 5.02, which rounds DOWN to 5.00.
    -- Round the basket first and it is 10.05 - 5.01 = 5.04, which is
    -- not a coin.
    perform pg_temp.check_eq('the cash due is the remainder, rounded',
      v_r.cash_due, 5.00::numeric);
    perform pg_temp.check_eq('and the adjustment is what that moved',
      v_r.rounding, -0.02::numeric);
    perform pg_temp.check_eq('with no change owed', v_r.change_due, 0::numeric);
    perform pg_temp.check_eq('and the total is the basket plus the adjustment',
      v_r.total, 10.01::numeric);
  end;

  -- A shop that has turned rounding off is asked for the sen.
  update public.pos_settings set round_cash_to_5sen = false where org_id = v_org;
  declare v_r record;
  begin
    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 1, 10.03);
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 10.03)));
    perform pg_temp.check_eq('a shop that does not round asks for the sen',
      v_r.cash_due, 10.03::numeric);
    perform pg_temp.check_eq('and nothing is adjusted',
      v_r.rounding, 0::numeric);
  end;
  update public.pos_settings set round_cash_to_5sen = true where org_id = v_org;

  -- ==================================================================
  -- 4. On account: the credit limit has to be able to see it
  --
  -- 0467. The invoice is linked to the sale before it posts, so
  -- app.enforce_credit_limit can read on_account_amount and know how
  -- much credit this sale extends. Asserted by giving the customer a
  -- limit the basket exceeds and requiring the refusal.
  -- ==================================================================
  -- The limit only refuses when the company has asked it to:
  -- organizations.credit_control defaults to 'warn', under which the
  -- trigger returns without deciding anything. A probe that leaves it
  -- there asserts nothing at all.
  update public.organizations set credit_control = 'block' where id = v_org;
  update public.contacts set credit_limit = 5.00 where id = v_cust;
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  begin
    perform * from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_acct, 'amount', 10.00)),
      v_cust);
    raise exception 'a counter extended credit past the limit';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a sale on account is held to the credit limit',
      v_msg like '%credit limit%');
  end;
  update public.contacts set credit_limit = 10000 where id = v_cust;
  update public.organizations set credit_control = 'warn' where id = v_org;

  -- And a sale on account has to name somebody. The walk-in contact is
  -- one row every anonymous sale is billed to; a balance on it belongs
  -- to nobody and is chased by nobody.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  begin
    perform * from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_acct, 'amount', 10.00)));
    raise exception 'the walk-in customer took a sale on account';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('the walk-in customer cannot take one on account',
      v_msg like 'A sale on account has to name the customer%');
  end;

  -- The whole basket on a named account: a receipt for nothing, and the
  -- invoice left outstanding for the customer to settle.
  declare v_r record;
  begin
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_acct, 'amount', 10.00)),
      v_cust);
    select invoice_id, receipt_id into v_inv, v_rcp
      from public.pos_sales where id = v_sale;
    perform pg_temp.check_true('a basket entirely on account writes no receipt',
      v_rcp is null);
    perform pg_temp.check_eq('and the invoice is still owed',
      (select balance_amount from public.sales_documents where id = v_inv),
      10.00::numeric);
    perform pg_temp.check_eq('with the credit extended recorded on the sale',
      (select on_account_amount from public.pos_sales where id = v_sale),
      10.00::numeric);
    perform pg_temp.check_eq('and the customer on it',
      (select contact_id from public.pos_sales where id = v_sale), v_cust);
  end;

  -- ==================================================================
  -- 5. What the invoice and its lines carry
  -- ==================================================================
  declare v_r record; v_l record;
  begin
    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 3, 10.00, 5.00);
    perform public.add_pos_sale_line(v_sale, v_item, 1, 4.00);
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 30.00)));
    select invoice_id into v_inv from public.pos_sales where id = v_sale;

    perform pg_temp.check_eq('the counter sale is named on the invoice',
      (select notes from public.sales_documents where id = v_inv),
      'Counter sale ' || (select sale_no from public.pos_sales where id = v_sale));
    perform pg_temp.check_eq('the lines are copied in the order they were rung',
      (select string_agg(l.quantity::text, ',' order by l.line_no)
         from public.sales_document_lines l where l.document_id = v_inv),
      '3.0000,1.0000');
    perform pg_temp.check_eq('and the discount taken at the till is on the line',
      (select l.discount_amount from public.sales_document_lines l
        where l.document_id = v_inv and l.line_no = 1), 5.00::numeric);
    perform pg_temp.check_eq('and the warehouse the goods left',
      (select count(*) from public.sales_document_lines l
        where l.document_id = v_inv and l.warehouse_id = v_wh), 2);
  end;

  -- ==================================================================
  -- 6. The receipt, and where the money was banked
  -- ==================================================================
  declare v_r record; v_bank uuid; v_bank2 uuid; v_acct_id uuid;
  begin
    select id into v_acct_id from public.accounts
     where org_id = v_org and code = '1120';
    insert into public.bank_accounts
      (org_id, account_id, name, bank_name, account_number, currency,
       opening_balance, current_balance)
    values (v_org, v_acct_id, 'Kad', 'Maybank', '9001', 'MYR', 0, 0)
    returning id into v_bank;
    insert into public.bank_accounts
      (org_id, account_id, name, bank_name, account_number, currency,
       opening_balance, current_balance)
    values (v_org, v_acct_id, 'Tunai', 'Maybank', '9002', 'MYR', 0, 0)
    returning id into v_bank2;
    update public.pos_tender_types set bank_account_id = v_bank where id = v_card;
    update public.pos_tender_types set bank_account_id = v_bank2 where id = v_cash;

    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
    -- Card first, cash second. The money is banked against the FIRST
    -- tender that is not on account.
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(
        jsonb_build_object('type', v_card, 'amount', 6.00),
        jsonb_build_object('type', v_cash, 'amount', 4.00)),
      v_cust);
    select receipt_id into v_rcp from public.pos_sales where id = v_sale;
    perform pg_temp.check_eq('the money is banked against the first tender',
      (select bank_account_id from public.receipts where id = v_rcp), v_bank);
    perform pg_temp.check_eq('and the receipt records how it was paid',
      (select payment_mode_code from public.receipts where id = v_rcp), '03');
  end;

  -- A sale part on account: the receipt is for what actually arrived,
  -- and it is banked against the tender that is not the account.
  declare v_r record;
  begin
    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(
        jsonb_build_object('type', v_acct, 'amount', 6.00),
        jsonb_build_object('type', v_cash, 'amount', 4.00)),
      v_cust);
    select invoice_id, receipt_id into v_inv, v_rcp
      from public.pos_sales where id = v_sale;
    perform pg_temp.check_eq('a part-account sale receipts what arrived',
      (select amount from public.receipts where id = v_rcp), 4.00::numeric);
    perform pg_temp.check_eq('and leaves the rest on the invoice',
      (select balance_amount from public.sales_documents where id = v_inv),
      6.00::numeric);
    perform pg_temp.check_true('banked somewhere that is not the account',
      (select bank_account_id is not null from public.receipts where id = v_rcp));
  end;


  -- ==================================================================
  -- 6. What the basket is worth is worked out again at the tender
  --
  -- Three mutants survived the first sweep together and they are one
  -- fault: the promotions re-read, the basket recalculated, and the
  -- totals re-read afterwards. Every probe above adds its lines and
  -- pays for them in the same breath, so the header total was already
  -- right and nothing could tell whether the till had recomputed it or
  -- simply believed what the screen handed it.
  -- ==================================================================
  -- A header total that is wrong is not believed. This is the parked
  -- bill somebody edited around, or a till that posted a stale total
  -- from a queued sale; either way the lines are the truth.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  update public.pos_sales set total_amount = 999.00 where id = v_sale;
  declare v_r record;
  begin
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 10.00)));
    perform pg_temp.check_eq('a stale basket total is worked out again',
      v_r.total, 10.00::numeric);
    select invoice_id into v_inv from public.pos_sales where id = v_sale;
    perform pg_temp.check_eq('and the invoice is for what the lines come to',
      (select total_amount from public.sales_documents where id = v_inv),
      10.00::numeric);
    perform pg_temp.check_eq('and so is the sale it was rung up on',
      (select total_amount from public.pos_sales where id = v_sale),
      10.00::numeric);
  end;

  -- The happy hour that began while the bill was parked. Nothing else
  -- re-reads the promotions: `add_pos_sale_line` recalculates the
  -- basket but does not go looking for new offers, so a promotion
  -- created after the last line is only found at the tender.
  declare v_pr uuid; v_r record;
  begin
    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
    insert into public.pos_promotions (org_id, name, kind, percent)
    values (v_org, 'Sepuluh peratus', 'percent_off', 10)
    returning id into v_pr;
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 9.00)));
    perform pg_temp.check_eq(
      'a promotion that began after the bill was parked still comes off it',
      v_r.total, 9.00::numeric);
    update public.pos_promotions set is_active = false where id = v_pr;
  end;

  -- ==================================================================
  -- 7. The limit is told what is being LENT, not what was sold
  --
  -- The refusal above is satisfied by a link written at any point
  -- before the posting -- and by no link at all, because a sale the
  -- trigger cannot find is charged for the whole invoice, which is
  -- larger. It is the sale that must be ALLOWED that pins the link:
  -- a hundred ringgit basket settled almost entirely in cash extends
  -- five ringgit of credit and nothing more.
  -- ==================================================================
  declare v_c2 uuid; v_r record;
  begin
    insert into public.contacts (org_id, code, name, contact_type, credit_limit)
    values (v_org, 'C-2', 'Pelanggan Tunai', 'customer', 50.00)
    returning id into v_c2;
    update public.organizations set credit_control = 'block' where id = v_org;

    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 10, 10.00);
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(
        jsonb_build_object('type', v_cash, 'amount', 95.00),
        jsonb_build_object('type', v_acct, 'amount', 5.00)),
      v_c2);
    perform pg_temp.check_eq(
      'a basket over the limit goes through when only 5.00 is on account',
      v_r.total, 100.00::numeric);
    perform pg_temp.check_eq('and the limit was told that five and no more',
      (select on_account_amount from public.pos_sales where id = v_sale),
      5.00::numeric);
    update public.organizations set credit_control = 'warn' where id = v_org;
  end;

  -- ==================================================================
  -- 8. What the line carries onto the invoice
  --
  -- A shop whose menu prices include the tax charges 108.00 and owes
  -- eight of it. Carried onto the invoice as tax-exclusive, the same
  -- plate owes 8.64 -- sixty-four sen of tax on money nobody paid, on
  -- every line of every bill, and the SST-02 return is built from that
  -- figure.
  -- ==================================================================
  declare v_st8 uuid; v_taxed uuid; v_r record;
  begin
    insert into public.tax_codes
      (org_id, code, name, tax_type_code, rate, applies_to,
       sales_tax_account_id, purchase_tax_account_id)
    values (v_org, 'ST8', 'Service Tax 8%', '02', 8, 'both',
            (select id from public.accounts where org_id = v_org and code = '2130'),
            (select id from public.accounts where org_id = v_org and code = '1410'))
    returning id into v_st8;
    insert into public.items
      (org_id, code, name, item_type, track_inventory, uom_code,
       unit_price, cost_price, sales_tax_code_id)
    values (v_org, 'SET', 'Set makan', 'service', false, 'C62', 108.00, 0, v_st8)
    returning id into v_taxed;

    -- The flag is stamped on the line when the line is added, from the
    -- outlet. Put back afterwards so nothing below reads a different
    -- shop from the one above.
    update public.pos_outlets set prices_include_tax = true where id = v_outlet;
    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_taxed, 1, 108.00);
    update public.pos_outlets set prices_include_tax = false where id = v_outlet;

    perform pg_temp.check_true('the line is stamped tax-inclusive',
      (select is_tax_inclusive from public.pos_sale_lines
        where sale_id = v_sale));
    select * into v_r from public.complete_pos_sale(v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 108.00)));
    select invoice_id into v_inv from public.pos_sales where id = v_sale;
    perform pg_temp.check_true('and so is the invoice line it becomes',
      (select is_tax_inclusive from public.sales_document_lines
        where document_id = v_inv));
    perform pg_temp.check_eq('so the tax is carved out of the 108, not added to it',
      (select tax_amount from public.sales_documents where id = v_inv),
      8.00::numeric);
    perform pg_temp.check_eq('and the customer is charged the menu price',
      v_r.total, 108.00::numeric);
  end;

  perform pg_temp.sign_in_as(v_owner);
  raise notice 'ok   the counter: the twenty-one a second sweep found';
end $$;


rollback;
