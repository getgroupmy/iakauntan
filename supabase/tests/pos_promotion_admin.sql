-- =====================================================================
-- iAkauntan :: setting a promotion up, and taking one off a bill
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_promotion_admin.sql
--
-- pos.sql covers the promotion engine at length -- the rate re-derived
-- from the basket every time, three-for-two discounting the cheapest of
-- each complete block, switching one off leaving no row behind. It does
-- all of that by inserting into pos_promotions directly, so the three
-- functions a shop actually uses to administer them are never called:
-- upsert_pos_promotion, retire_pos_promotion and
-- remove_pos_sale_promotion.
--
-- The first is mostly refusals, and 0256 says why they are there: "each
-- kind has one number that makes it mean anything, and a promotion
-- saved without it is a promotion that takes nothing off and looks like
-- it is working." A percentage of nought, saved happily, is a sign in
-- the window that discounts nothing.
--
-- The third is the one with money in it. Taking a promotion off a bill
-- deletes the row and then recalculates the sale; drop the recalculation
-- and the bill keeps the discount in its total with nothing left to
-- explain where it came from.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_other  uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_roti   uuid;
  v_teh    uuid;
  v_promo  uuid;
  v_open   uuid;
  v_empty_sale uuid;
  r2       record;
  v_again  uuid;
  v_sale   uuid;
  v_row    uuid;
  v_took   boolean;
  v_cash   uuid;
  v_done   uuid;
  r        record;
begin
  v_org := pg_temp.test_org('Kedai Promosi Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'ROTI', 'Roti', 'stock', true, 'C62', 10.00, 4.00)
  returning id into v_roti;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'TEH', 'Teh tarik', 'stock', true, 'C62', 3.00, 1.00)
  returning id into v_teh;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true)
  returning id into v_cash;
  perform public.open_pos_shift(v_reg, 100.00);

  -- ==================================================================
  -- A promotion has to mean something
  -- ==================================================================
  begin
    perform public.upsert_pos_promotion(v_org, '   ', 'percent_off',
      p_percent => 10);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('a promotion needs a name for the receipt',
    not v_took);

  begin
    perform public.upsert_pos_promotion(v_org, 'Nothing off', 'percent_off');
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('a percentage off needs a percentage', not v_took);

  begin
    perform public.upsert_pos_promotion(v_org, 'Nothing off', 'amount_off');
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('an amount off needs an amount', not v_took);

  begin
    perform public.upsert_pos_promotion(v_org, 'Three for two', 'buy_x_get_y',
      p_percent => 100);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('buy x get y needs the x and the y', not v_took);

  -- Buy two get one, and nothing said about how much comes off the free
  -- one, is a promotion that gives away nothing.
  begin
    perform public.upsert_pos_promotion(v_org, 'Three for two', 'buy_x_get_y',
      p_buy => 2, p_get => 1);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('and how much comes off the free ones',
    not v_took);

  begin
    perform public.upsert_pos_promotion(v_org, 'Happy hour', 'percent_off',
      p_percent => 20, p_starts_at => time '17:00');
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('an hours window needs both ends', not v_took);

  begin
    perform public.upsert_pos_promotion(v_org, 'Sunday special', 'percent_off',
      p_percent => 20, p_weekdays => array[0]::smallint[]);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('and weekdays run 1 to 7, not 0 to 6', not v_took);

  -- ==================================================================
  -- One that does
  -- ==================================================================
  v_promo := public.upsert_pos_promotion(
    v_org, '  Ten off  ', 'percent_off', p_code => '  ', p_percent => 10,
    p_items => array[v_roti]);
  select * into r from public.pos_promotions where id = v_promo;
  perform pg_temp.check_eq('the name is trimmed', r.name, 'Ten off');
  perform pg_temp.check_true('and a blank code is stored as no code',
    r.code is null);
  perform pg_temp.check_eq('the percentage is kept', r.percent, 10);
  perform pg_temp.check_true('and it is live', r.is_active);
  perform pg_temp.check_eq('scoped to the one item named',
    (select count(*) from public.pos_promotion_items
      where promotion_id = v_promo), 1);

  -- ==================================================================
  -- Editing one, rather than making a second
  -- ==================================================================
  v_again := public.upsert_pos_promotion(
    v_org, 'Ten off', 'percent_off', p_percent => 15, p_id => v_promo,
    p_items => array[v_roti, v_teh]);
  perform pg_temp.check_eq('editing returns the same promotion',
    v_again, v_promo);
  perform pg_temp.check_eq('and does not make a second one',
    (select count(*) from public.pos_promotions where org_id = v_org), 1);
  perform pg_temp.check_eq('the new rate took', 
    (select percent from public.pos_promotions where id = v_promo), 15);
  -- The scope is replaced, not added to. Appending would leave last
  -- month's items on a promotion somebody has just narrowed.
  perform pg_temp.check_eq('and the scope is replaced, not added to',
    (select count(*) from public.pos_promotion_items
      where promotion_id = v_promo), 2);

  -- Passing nothing for the scope leaves it alone, which is what lets a
  -- screen save the name without knowing the item list.
  perform public.upsert_pos_promotion(
    v_org, 'Ten off, renamed', 'percent_off', p_percent => 15, p_id => v_promo);
  perform pg_temp.check_eq('saying nothing about the scope leaves it alone',
    (select count(*) from public.pos_promotion_items
      where promotion_id = v_promo), 2);
  -- An empty array is a different statement from silence: it clears it.
  perform public.upsert_pos_promotion(
    v_org, 'Ten off, everything', 'percent_off', p_percent => 15,
    p_id => v_promo, p_items => array[]::uuid[]);
  perform pg_temp.check_eq('an empty list clears it',
    (select count(*) from public.pos_promotion_items
      where promotion_id = v_promo), 0);

  -- Somebody else's promotion is not there to be edited.
  v_other := pg_temp.test_org('Kedai Lain Sdn Bhd');
  insert into public.org_modules (org_id, module_code, is_enabled)
  values (v_other, 'pos', true)
  on conflict (org_id, module_code) do update set is_enabled = true;
  begin
    perform public.upsert_pos_promotion(v_other, 'Stolen', 'percent_off',
      p_percent => 50, p_id => v_promo);
    v_took := true;
  exception when sqlstate 'P0002' then v_took := false;
  end;
  perform pg_temp.check_true('another shop cannot edit this one''s promotion',
    not v_took);
  perform pg_temp.check_eq('and it is unchanged',
    (select percent from public.pos_promotions where id = v_promo), 15);

  -- ==================================================================
  -- Taking one off a bill
  -- ==================================================================
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_roti, 2, 10.00);
  perform public.refresh_pos_sale_promotions(v_sale);

  perform pg_temp.check_eq('the promotion lands on the bill',
    (select count(*) from public.pos_sale_promotions where sale_id = v_sale), 1);
  perform pg_temp.check_eq('taking 15% off 20.00',
    (select promo_discount from public.pos_sales where id = v_sale), 3.00);
  perform pg_temp.check_eq('so the bill is 17.00',
    (select total_amount from public.pos_sales where id = v_sale), 17.00);

  select id into v_row from public.pos_sale_promotions where sale_id = v_sale;
  perform pg_temp.check_eq('removing it returns the bill it was on',
    public.remove_pos_sale_promotion(v_row), v_sale);
  perform pg_temp.check_eq('the row is gone',
    (select count(*) from public.pos_sale_promotions where sale_id = v_sale), 0);
  -- The assertion with the money in it: the total has to be rebuilt, or
  -- the bill keeps a discount nothing on it explains.
  perform pg_temp.check_eq('and the discount comes off the bill',
    (select promo_discount from public.pos_sales where id = v_sale), 0);
  perform pg_temp.check_eq('leaving the full 20.00',
    (select total_amount from public.pos_sales where id = v_sale), 20.00);

  begin
    perform public.remove_pos_sale_promotion(gen_random_uuid());
    v_took := true;
  exception when sqlstate 'P0002' then v_took := false;
  end;
  perform pg_temp.check_true('a row that is not on any bill is refused',
    not v_took);

  -- A bill that has been paid is history. Taking a promotion off it
  -- afterwards would move a total that has already been tendered,
  -- invoiced and posted to the ledger.
  v_done := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_done, v_roti, 1, 10.00);
  perform public.refresh_pos_sale_promotions(v_done);
  perform pg_temp.check_eq('a promotion is on the second bill too',
    (select count(*) from public.pos_sale_promotions where sale_id = v_done), 1);
  perform public.complete_pos_sale(v_done, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 20.00)));
  -- Read the row after completing, not before: complete_pos_sale
  -- refreshes the promotions as its last act, which rebuilds these rows
  -- and gives them new ids. The promotion survives the sale being paid,
  -- which is what makes the guard below reachable at all.
  select id into v_row from public.pos_sale_promotions where sale_id = v_done;
  perform pg_temp.check_true('and survives the bill being paid',
    v_row is not null);
  begin
    perform public.remove_pos_sale_promotion(v_row);
    v_took := true;
  exception when sqlstate '23514' then v_took := false;
  end;
  perform pg_temp.check_true('a promotion cannot be taken off a paid bill',
    not v_took);
  perform pg_temp.check_eq('and it is still on it',
    (select count(*) from public.pos_sale_promotions where sale_id = v_done), 1);

  -- ==================================================================
  -- The list the shop sets them up from
  -- ==================================================================
  --
  -- `pos_promotions_admin` and `pos_sale_promotions_on` are the two
  -- readers behind the promotions screen and the tender sheet, and
  -- neither was called. The columns worth pinning are the two counts:
  -- `times_used` and `given_away` are computed over **completed** bills
  -- only, matching what the usage cap counts. A promotion sitting on a
  -- parked bill has not been used, and a cap that counted it would stop
  -- honouring a promotion because of baskets nobody has paid for.
  perform pg_temp.check_eq('the paid bill counts as a use',
    (select a.times_used from public.pos_promotions_admin(v_org) a
      where a.id = v_promo), 1);
  perform pg_temp.check_eq('and what it gave away is what came off it',
    (select a.given_away from public.pos_promotions_admin(v_org) a
      where a.id = v_promo), 1.50::numeric);

  -- A basket somebody is still standing at the counter with.
  v_open := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_open, v_roti, 4, 10.00);
  perform public.refresh_pos_sale_promotions(v_open);
  perform pg_temp.check_eq('the promotion is on the open bill',
    (select count(*) from public.pos_sale_promotions where sale_id = v_open), 1);
  perform pg_temp.check_eq('which is still not a use',
    (select a.times_used from public.pos_promotions_admin(v_org) a
      where a.id = v_promo), 1);
  perform pg_temp.check_eq('nor given anything away yet',
    (select a.given_away from public.pos_promotions_admin(v_org) a
      where a.id = v_promo), 1.50::numeric);

  -- What the tender sheet shows against that open bill.
  select * into r2 from public.pos_sale_promotions_on(v_open);
  perform pg_temp.check_eq('the sheet names the promotion',
    r2.name, 'Ten off, everything');
  perform pg_temp.check_eq('and what it took off', r2.amount, 6.00::numeric);
  perform pg_temp.check_true('and that nobody typed a code for it',
    not r2.by_code);
  -- A bill with nothing on it at all, so the empty answer is an empty
  -- answer rather than a bill this promotion happens to miss.
  v_empty_sale := public.open_pos_sale(v_reg);
  perform pg_temp.check_eq('a bill with none on it shows none',
    (select count(*) from public.pos_sale_promotions_on(v_empty_sale)), 0);

  -- The scope arrays, which the editor reads back to fill its form.
  perform pg_temp.check_eq('the scope cleared earlier reads back as empty',
    (select array_length(a.item_ids, 1) from public.pos_promotions_admin(v_org) a
      where a.id = v_promo), null);

  perform pg_temp.check_eq('and one shop''s promotions are not another''s',
    (select count(*) from public.pos_promotions_admin(v_other)), 0);

  -- ==================================================================
  -- Retiring one
  -- ==================================================================
  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('the promotion comes back while it is live',
    (select count(*) from public.pos_sale_promotions where sale_id = v_sale), 1);

  perform pg_temp.check_eq('retiring returns the promotion',
    public.retire_pos_promotion(v_promo), v_promo);
  perform pg_temp.check_true('which is switched off, not deleted',
    (select not is_active from public.pos_promotions where id = v_promo));
  perform pg_temp.check_eq('the row itself survives',
    (select count(*) from public.pos_promotions where id = v_promo), 1);

  perform public.refresh_pos_sale_promotions(v_sale);
  perform pg_temp.check_eq('and a retired promotion stops applying',
    (select promo_discount from public.pos_sales where id = v_sale), 0);

  begin
    perform public.retire_pos_promotion(gen_random_uuid());
    v_took := true;
  exception when sqlstate 'P0002' then v_took := false;
  end;
  perform pg_temp.check_true('a promotion that does not exist is refused',
    not v_took);

  -- ==================================================================
  -- Not for somebody outside the shop
  -- ==================================================================
  perform pg_temp.sign_in_as(pg_temp.another_user('stranger@example.test'));
  begin
    perform public.upsert_pos_promotion(v_org, 'Mine now', 'percent_off',
      p_percent => 90);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('a stranger cannot set up a promotion', not v_took);
  begin
    perform public.retire_pos_promotion(v_promo);
    v_took := true;
  exception when sqlstate '42501' then v_took := false;
  end;
  perform pg_temp.check_true('nor retire one', not v_took);

  -- Nor read them. A shop's promotions are its pricing strategy — what
  -- it discounts, when, and by how much — and both readers answer about
  -- a named organization rather than about the caller's own, so the
  -- module check is the only thing between a stranger and it.
  perform pg_temp.check_eq('nor see what this shop discounts',
    (select count(*) from public.pos_promotions_admin(v_org)), 0);
  perform pg_temp.check_eq('nor what came off a bill in it',
    (select count(*) from public.pos_sale_promotions_on(v_open)), 0);
  perform pg_temp.sign_out();
end $$;

rollback;
