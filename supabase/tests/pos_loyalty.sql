-- =====================================================================
-- Point of sale :: loyalty
--
-- The balance is a sum over an append-only ledger, so most of what can
-- go wrong here is arithmetic that looks right. Three assertions carry
-- the file:
--
--   * points are earned on what was PAID, not on the basket. Redeeming
--     five ringgit off a hundred-ringgit basket must earn ninety-five
--     points, not a hundred -- otherwise the scheme pays points for
--     money nobody handed over, and compounds every time.
--
--   * a parked sale holds no points. The ledger does not move until the
--     sale completes, because a balance that fell when a cashier
--     changed their mind is money taken for a transaction that never
--     happened.
--
--   * a basket cleared entirely by points still completes -- posted
--     invoice, posted receipt, stock off the shelf, nothing allocated
--     because nothing was owed. A customer who has saved enough points
--     to pay must not find the till refuses to ring it up.
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
  v_member uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_prog   uuid;
  v_acct   uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_n      integer;
  v_a      numeric;
  v_b      numeric;
  v_c      numeric;
  v_mrow   record;
  v_tier   record;
begin
  v_org := pg_temp.test_org('Pasaraya Mesra Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','loyalty','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'AMINAH', 'Puan Aminah', 'customer') returning id into v_member;

  -- Priced before tax and with no tax code, so every figure below can
  -- be worked by hand.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'TIN', 'Tin susu', 'stock', true, 'C62', 100.00, 40.00)
  returning id into v_item;

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

  -- ------------------------------------------------------------------
  -- The programme, and somebody on it
  -- ------------------------------------------------------------------
  -- One point per ringgit, one sen a point: a 1% scheme, stated as the
  -- two numbers a shopkeeper actually sets.
  insert into public.loyalty_programs
    (org_id, code, name, earn_points_per_myr, redeem_value_per_point, min_redeem_points)
  values (v_org, 'KAD', 'Kad Mesra', 1, 0.01, 100) returning id into v_prog;

  begin
    insert into public.loyalty_programs (org_id, code, name)
    values (v_org, 'KAD2', 'Second scheme');
    raise exception 'FAIL two live schemes at once';
  exception when unique_violation then
    raise notice 'ok   a company runs one scheme at a time';
  end;

  v_acct := public.enrol_loyalty_member(v_member, 'CARD-0001');
  perform pg_temp.check_true('enrolling twice enrols once',
    public.enrol_loyalty_member(v_member, 'CARD-0001') = v_acct);
  perform pg_temp.check_eq('a new member starts at nothing',
    app.loyalty_balance(v_acct), 0);

  perform pg_temp.check_eq('an opening adjustment lands',
    public.adjust_loyalty_points(v_acct, 1000, 'Opening balance carried over'), 1000);

  -- Handing out points is handing out money.
  begin
    perform public.adjust_loyalty_points(v_acct, 50, '   ');
    raise exception 'FAIL adjusted points with no reason given';
  exception when check_violation then
    raise notice 'ok   an unexplained adjustment is refused';
  end;
  begin
    perform public.adjust_loyalty_points(v_acct, -5000, 'Clawback');
    raise exception 'FAIL took an account below zero';
  exception when check_violation then
    raise notice 'ok   an adjustment cannot take an account below zero';
  end;

  -- ------------------------------------------------------------------
  -- What a parked sale does to the ledger, which is nothing
  -- ------------------------------------------------------------------
  v_shift := public.open_pos_shift(v_reg, 100.00);
  v_sale  := public.open_pos_sale(v_reg, v_member);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);
  perform pg_temp.check_eq('the basket is the price', 
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 100.00);

  begin
    perform * from public.redeem_loyalty_points(v_sale, 50);
    raise exception 'FAIL redeemed below the programme minimum';
  exception when check_violation then
    raise notice 'ok   below the minimum is refused';
  end;
  begin
    perform * from public.redeem_loyalty_points(v_sale, 99999);
    raise exception 'FAIL redeemed points the account does not have';
  exception when check_violation then
    raise notice 'ok   more points than the account holds is refused';
  end;

  select r.discount, r.new_total, r.points_after into v_a, v_b, v_n
    from public.redeem_loyalty_points(v_sale, 500) r;
  perform pg_temp.check_eq('five hundred points is five ringgit', v_a, 5.00);
  perform pg_temp.check_eq('so the basket falls to ninety-five', v_b, 95.00);
  perform pg_temp.check_eq('the ledger has not moved', app.loyalty_balance(v_acct), 1000);
  perform pg_temp.check_eq('though the till can say what it will be', v_n, 500);

  -- Applied twice is applied once. A second call that stacked would let
  -- a cashier tap until the sale was free.
  perform * from public.redeem_loyalty_points(v_sale, 500);
  perform pg_temp.check_eq('redeeming again replaces rather than stacks',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 95.00);

  -- And thought better of.
  perform * from public.redeem_loyalty_points(v_sale, 0);
  perform pg_temp.check_eq('clearing the redemption restores the basket',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 100.00);
  perform * from public.redeem_loyalty_points(v_sale, 500);

  -- A line rung up after the redemption keeps it applied, which is why
  -- the recalculation reads the redemption rather than being told it.
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  perform pg_temp.check_eq('the redemption survives another line',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 105.00);

  -- ------------------------------------------------------------------
  -- Completing it: the arithmetic that looks right either way
  -- ------------------------------------------------------------------
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 110.00)));

  perform pg_temp.check_eq('the invoice carries the redemption as a discount',
    (select d.discount_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale), 5.00);
  perform pg_temp.check_eq('and bills a hundred and five',
    (select d.total_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale), 105.00);
  perform pg_temp.check_eq('owing nothing, because it was paid',
    (select d.balance_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale), 0);

  -- 110 basket, 5 off, 105 paid. Earning on the basket would give 110.
  perform pg_temp.check_eq('points are earned on what was paid, not on the basket',
    (select s.loyalty_points_earned from public.pos_sales s where s.id = v_sale), 105);
  perform pg_temp.check_eq('the ledger records the redemption and the earning',
    (select count(*) from public.loyalty_entries e where e.sale_id = v_sale), 2);
  perform pg_temp.check_eq('and the balance is 1000 - 500 + 105',
    app.loyalty_balance(v_acct), 605);

  -- ------------------------------------------------------------------
  -- The walk-in
  -- ------------------------------------------------------------------
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 100.00)));
  perform pg_temp.check_eq('somebody who is nobody earns nothing',
    (select s.loyalty_points_earned from public.pos_sales s where s.id = v_sale), 0);
  perform pg_temp.check_eq('and their invoice carries no discount',
    (select d.discount_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale), 0);

  -- ------------------------------------------------------------------
  -- Points cannot buy more than the basket
  -- ------------------------------------------------------------------
  perform public.adjust_loyalty_points(v_acct, 100000, 'Long-standing customer');
  v_sale := public.open_pos_sale(v_reg, v_member);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  select r.points_applied, r.discount, r.new_total into v_n, v_a, v_b
    from public.redeem_loyalty_points(v_sale, 100000) r;
  perform pg_temp.check_eq('only the points the basket is worth are taken', v_n, 1000);
  perform pg_temp.check_eq('for a discount of exactly the basket', v_a, 10.00);
  perform pg_temp.check_eq('leaving nothing to pay', v_b, 0.00);

  -- And a sale with nothing to pay is a completed sale, not a stuck one.
  v_c := app.loyalty_balance(v_acct);
  perform public.complete_pos_sale(v_sale, '[]'::jsonb);
  perform pg_temp.check_true('a basket cleared by points still completes',
    (select s.status = 'completed' from public.pos_sales s where s.id = v_sale));
  perform pg_temp.check_eq('with an invoice for nothing',
    (select d.total_amount from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale), 0);
  perform pg_temp.check_true('a posted receipt behind it',
    (select r.gl_entry_id is not null from public.receipts r
      join public.pos_sales s on s.receipt_id = r.id where s.id = v_sale));
  -- `payment_allocations` checks its amount is positive, and is right
  -- to: an allocation of nothing is not an allocation.
  perform pg_temp.check_eq('nothing allocated, because nothing was owed',
    (select count(*) from public.payment_allocations a
      join public.pos_sales s on s.receipt_id = a.receipt_id where s.id = v_sale), 0);
  perform pg_temp.check_eq('the stock still left the shelf',
    (select count(*) from public.stock_movements m
      join public.pos_sales s on s.invoice_id = m.source_id where s.id = v_sale), 1);
  perform pg_temp.check_eq('the points went', app.loyalty_balance(v_acct), v_c - 1000);
  perform pg_temp.check_eq('and nothing was paid, so nothing was earned',
    (select s.loyalty_points_earned from public.pos_sales s where s.id = v_sale), 0);

  -- A sale with something still to pay is refused as before.
  v_sale := public.open_pos_sale(v_reg, v_member);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 10.00);
  begin
    perform * from public.complete_pos_sale(v_sale, '[]'::jsonb);
    raise exception 'FAIL completed a sale nobody paid for';
  exception when check_violation then
    raise notice 'ok   a sale with something left to pay still needs paying for';
  end;

  -- ------------------------------------------------------------------
  -- Dormancy
  -- ------------------------------------------------------------------
  update public.loyalty_programs set dormancy_expiry_months = 12 where id = v_prog;
  perform pg_temp.check_eq('an account that has been used expires nothing',
    (select count(*) from public.expire_loyalty_points(v_org)), 0);

  update public.loyalty_entries set created_at = now() - interval '3 years'
   where account_id = v_acct;
  update public.loyalty_accounts set joined_on = current_date - 1500 where id = v_acct;

  v_c := app.loyalty_balance(v_acct);
  perform pg_temp.check_true('there were points there to lose', v_c > 0);
  perform pg_temp.check_eq('a dormant account is swept',
    (select count(*) from public.expire_loyalty_points(v_org)), 1);
  perform pg_temp.check_eq('and lands at exactly zero',
    app.loyalty_balance(v_acct), 0);
  perform pg_temp.check_eq('by one entry saying so',
    (select count(*) from public.loyalty_entries e
      where e.account_id = v_acct and e.kind = 'expire'), 1);
  -- Idempotent, because the sweep is the kind of thing that gets run
  -- twice by a scheduler nobody is watching.
  perform pg_temp.check_eq('running the sweep again writes nothing',
    (select count(*) from public.expire_loyalty_points(v_org)), 0);

  -- ------------------------------------------------------------------
  -- What the screen shows
  -- ------------------------------------------------------------------
  -- The same number by a second route. A card screen that computed the
  -- balance its own way would be the second copy of the fact this whole
  -- design exists to avoid.
  perform public.adjust_loyalty_points(v_acct, 250, 'Goodwill');
  select b.points, b.worth into v_n, v_a
    from public.loyalty_account_balance(v_member) b;
  perform pg_temp.check_eq('the screen shows the ledger', v_n,
    app.loyalty_balance(v_acct));
  perform pg_temp.check_eq('and what it is worth at the counter', v_a, 2.50);
  perform pg_temp.check_eq('one card, not one per sale',
    (select count(*) from public.loyalty_account_balance(v_member)), 1);

  -- ------------------------------------------------------------------
  -- Finding the member from what the customer said
  -- ------------------------------------------------------------------
  --
  -- `loyalty_account_balance` answers the question you can only ask
  -- once you already know who somebody is. At a counter you have what
  -- they said: a card, a mobile, half a name.
  update public.contacts set mobile = '012-3456789' where id = v_member;

  perform pg_temp.check_eq('a card number finds one member',
    (select count(*) from public.loyalty_lookup(v_org, 'CARD-0001')), 1);
  perform pg_temp.check_eq('and says that is what matched',
    (select l.matched_on from public.loyalty_lookup(v_org, 'CARD-0001') l),
    'card');
  perform pg_temp.check_eq('a phone number finds them too',
    (select l.contact_id from public.loyalty_lookup(v_org, '3456789') l),
    v_member);
  perform pg_temp.check_eq('so does part of a name',
    (select l.contact_id from public.loyalty_lookup(v_org, 'minah') l),
    v_member);

  -- The positive control. Every assertion above would pass on an empty
  -- table if it only counted absences, so this one counts a search that
  -- must find nothing against searches that must find something.
  perform pg_temp.check_eq('and a stranger finds nobody',
    (select count(*) from public.loyalty_lookup(v_org, 'Nobody At All')), 0);
  perform pg_temp.check_eq('an empty box is not a wildcard',
    (select count(*) from public.loyalty_lookup(v_org, '   ')), 0);

  -- ------------------------------------------------------------------
  -- Saying whose bill this is, at the counter
  -- ------------------------------------------------------------------
  --
  -- Redemption reads `pos_sales.contact_id`, and until 0227 nothing
  -- could set it on a parked sale: the contact was passed when the sale
  -- opened or when it completed, and neither is the moment somebody
  -- produces a card.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 10, 10.00);

  begin
    perform public.redeem_loyalty_points(v_sale, 100);
    raise exception 'FAIL redeemed against a bill with nobody on it';
  exception when no_data_found then
    raise notice 'ok   points need a member on the bill';
  end;

  perform public.name_pos_sale_customer(v_sale, v_member);
  perform pg_temp.check_eq('naming the bill puts them on it',
    (select s.contact_id from public.pos_sales s where s.id = v_sale), v_member);

  -- ------------------------------------------------------------------
  -- The panel the tender sheet draws
  -- ------------------------------------------------------------------
  select * into v_mrow from public.pos_sale_member(v_sale);
  perform pg_temp.check_eq('the panel finds the card', v_mrow.card_no, 'CARD-0001');
  perform pg_temp.check_eq('and reads the same ledger everything else does',
    v_mrow.points, app.loyalty_balance(v_acct));
  perform pg_temp.check_eq('and knows what joining is worth per point',
    v_mrow.value_per_point, 0.0100);
  perform pg_temp.check_eq('and what paying this bill would earn',
    v_mrow.would_earn, 100);

  perform public.redeem_loyalty_points(v_sale, 200);
  select * into v_mrow from public.pos_sale_member(v_sale);
  perform pg_temp.check_eq('a redemption shows on the panel',
    v_mrow.points_redeemed, 200);
  perform pg_temp.check_eq('with what it takes off', v_mrow.discount, 2.00);

  -- The one that stops a cashier reading out a number the customer
  -- will not have. The ledger is deliberately untouched until the sale
  -- completes, so `points` is still the old balance and `points_after`
  -- is the figure worth saying out loud.
  perform pg_temp.check_eq('the balance has not moved yet',
    v_mrow.points, app.loyalty_balance(v_acct));
  perform pg_temp.check_eq('and the panel says what it will be',
    v_mrow.points_after, app.loyalty_balance(v_acct) - 200);

  -- Points belong to an account, so a bill moved to somebody else with
  -- a redemption still on it would be spending the wrong balance.
  begin
    perform public.name_pos_sale_customer(v_sale, v_walkin);
    raise exception 'FAIL moved a bill carrying somebody else''s points';
  exception when check_violation then
    raise notice 'ok   points come off before the bill changes hands';
  end;

  perform public.redeem_loyalty_points(v_sale, 0);
  perform public.name_pos_sale_customer(v_sale, v_walkin);
  perform pg_temp.check_eq('and once they are off, it moves',
    (select s.contact_id from public.pos_sales s where s.id = v_sale), v_walkin);

  -- ------------------------------------------------------------------
  -- Loyalty is a module of its own
  -- ------------------------------------------------------------------
  --
  -- 0231 moved every guard here off `pos`. The assertion that matters
  -- is the negative one: a company with the till and without loyalty
  -- must be refused, because until 0231 it was not.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'loyalty';

  perform pg_temp.check_eq('with the module off, the card is invisible',
    (select count(*) from public.loyalty_account_balance(v_member)), 0);
  perform pg_temp.check_eq('and so is the search',
    (select count(*) from public.loyalty_lookup(v_org, 'CARD-0001')), 0);

  begin
    perform public.enrol_loyalty_member(v_member, 'CARD-0002');
    raise exception 'FAIL enrolled a member without the loyalty module';
  exception when insufficient_privilege then
    raise notice 'ok   enrolling needs the loyalty module';
  end;

  -- The one that was never guarded at all before 0231: handing out
  -- points is handing out money, and an owner of a company that never
  -- bought the feature could do it.
  begin
    perform public.adjust_loyalty_points(v_acct, 100, 'Should be refused');
    raise exception 'FAIL adjusted points without the loyalty module';
  exception when insufficient_privilege then
    raise notice 'ok   adjusting points needs the loyalty module';
  end;

  -- A sale still completes. Turning the module off must not stop the
  -- shop selling -- it stops the sale earning.
  v_sale := public.open_pos_sale(v_reg, v_member);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 50.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 50.00)));
  perform pg_temp.check_true('the till keeps selling without loyalty',
    (select s.status = 'completed' from public.pos_sales s where s.id = v_sale));
  perform pg_temp.check_eq('and the sale earns nothing',
    (select coalesce(s.loyalty_points_earned, 0) from public.pos_sales s
      where s.id = v_sale), 0);

  -- The positive control. Every refusal above would also hold if the
  -- functions were simply broken, so switch it back on and watch them
  -- work again.
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'loyalty';
  perform pg_temp.check_eq('switched back on, the card is there again',
    (select count(*) from public.loyalty_account_balance(v_member)), 1);

  -- ------------------------------------------------------------------
  -- The name a member keeps (0253)
  -- ------------------------------------------------------------------
  -- Tiers are bands over what was EARNED, never over the balance. A
  -- scheme that demoted somebody for redeeming would punish the exact
  -- behaviour it exists to encourage, and that is the assertion this
  -- whole section is built around.

  -- Nothing configured: the plain rate, and no name.
  select * into v_tier from public.loyalty_member_tier(v_acct);
  perform pg_temp.check_true('with no tiers, a member has no tier',
    v_tier.tier_name is null);
  perform pg_temp.check_eq('and earns at the plain rate',
    v_tier.multiplier, 1);

  -- Bands placed around what this member has actually earned, rather
  -- than at round numbers that would depend on every assertion above
  -- this one still spending the same amounts.
  v_n := v_tier.earned;
  perform public.upsert_loyalty_tier(v_prog, 'AHLI',  'Ahli',  0, 1);
  perform public.upsert_loyalty_tier(v_prog, 'PERAK', 'Perak',
    greatest(v_n - 1, 1), 1.25);
  perform public.upsert_loyalty_tier(v_prog, 'EMAS',  'Emas', v_n + 500, 1.5);

  select * into v_tier from public.loyalty_member_tier(v_acct);
  perform pg_temp.check_eq('the member is in the band their earnings reach',
    v_tier.tier_name, 'Perak');
  perform pg_temp.check_eq('and the next one is named',
    v_tier.next_name, 'Emas');
  perform pg_temp.check_eq('with the gap said in points',
    v_tier.points_to_next, 500);

  -- The assertion the design exists for. Spending points must not take
  -- the name away.
  v_n := v_tier.earned;
  perform public.adjust_loyalty_points(v_acct, -40,
    'Spent at the counter, for the test');
  select * into v_tier from public.loyalty_member_tier(v_acct);
  perform pg_temp.check_eq('redeeming does not demote anybody',
    v_tier.tier_name, 'Perak');
  perform pg_temp.check_eq('because the tier reads what was earned',
    v_tier.earned, v_n);

  -- And an adjustment cannot buy one: a goodwill gesture is not
  -- spending, so `app.loyalty_earned` counts `earn` entries only.
  perform public.adjust_loyalty_points(v_acct, 5000,
    'A very generous manager, for the test');
  select * into v_tier from public.loyalty_member_tier(v_acct);
  perform pg_temp.check_eq('and an adjustment buys no tier at all',
    v_tier.tier_name, 'Perak');

  -- What the band is for: the member earns at their own rate. 1.25 on
  -- a hundred ringgit is 125, floored after the multiplier rather than
  -- before, because rounding up pays points for money nobody handed
  -- over.
  v_sale := public.open_pos_sale(v_reg, v_member);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 100.00)));
  perform pg_temp.check_eq('a Perak member earns at Perak''s rate',
    (select s.loyalty_points_earned from public.pos_sales s
      where s.id = v_sale), 125);

  -- Retiring a band drops its members to whichever is below it, and
  -- nothing is deleted.
  perform public.retire_loyalty_tier(
    (select t.id from public.loyalty_tiers t
      where t.program_id = v_prog and t.code = 'PERAK'));
  select * into v_tier from public.loyalty_member_tier(v_acct);
  perform pg_temp.check_eq('retiring a band drops its members to the one below',
    v_tier.tier_name, 'Ahli');
  perform pg_temp.check_eq('and the band itself is still there',
    (select count(*) from public.loyalty_tiers t
      where t.program_id = v_prog and t.code = 'PERAK'), 1);

  -- ------------------------------------------------------------------
  -- The bands belong to the loyalty module too
  -- ------------------------------------------------------------------
  --
  -- 0253 wrote every tier guard against `pos`, which is what the
  -- loyalty code said before 0231 split the two apart, and 0254 put
  -- them right. These are the assertions that would have caught it:
  -- the same negative test as the block above, aimed at the half of
  -- the feature that did not exist when that block was written.
  update public.org_modules set is_enabled = false
   where org_id = v_org and module_code = 'loyalty';

  perform pg_temp.check_eq('with the module off, the bands are invisible',
    (select count(*) from public.loyalty_tiers_admin(v_org)), 0);
  perform pg_temp.check_eq('and so is what tier a member is in',
    (select count(*) from public.loyalty_member_tier(v_acct)), 0);

  begin
    perform public.upsert_loyalty_tier(v_prog, 'PLAT', 'Platinum', 9999, 2);
    raise exception 'FAIL named a tier without the loyalty module';
  exception when insufficient_privilege then
    raise notice 'ok   naming a tier needs the loyalty module';
  end;

  begin
    perform public.retire_loyalty_tier(
      (select t.id from public.loyalty_tiers t
        where t.program_id = v_prog and t.code = 'EMAS'));
    raise exception 'FAIL retired a tier without the loyalty module';
  exception when insufficient_privilege then
    raise notice 'ok   retiring a tier needs the loyalty module';
  end;

  -- The positive control again, so the four refusals above cannot be
  -- passing because the functions are simply broken.
  update public.org_modules set is_enabled = true
   where org_id = v_org and module_code = 'loyalty';
  perform pg_temp.check_eq('switched back on, the bands are there again',
    (select count(*) from public.loyalty_tiers_admin(v_org)), 3);

  raise notice 'point of sale loyalty: all assertions passed';
end;
$$;

rollback;
