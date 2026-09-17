-- =====================================================================
-- iAkauntan :: the till stops while the drawer is counted
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_counting.sql
--
-- `app.pos_shift_status` is ('open', 'counting', 'closed') and until
-- `0361` nothing wrote the middle one. `open_pos_shift` wrote `open`
-- and `close_pos_shift` wrote `closed`, and the state that exists for
-- the minutes in between was never reached.
--
-- Those minutes are the point. `close_pos_shift` works out
-- `expected_cash` at the moment it is called, so a sale rung up between
-- the count and the close is in the expected figure and not in the pile
-- of notes on the counter. The variance is then wrong by exactly that
-- sale, and it is recorded against whoever counted.
--
-- The refusal is asserted from both ends: a counting till will not sell,
-- and a till put back into service will. The second half matters as
-- much — a state with no way out of it is how somebody closes a shift
-- early to take one customer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_item   uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;
  v_sale   uuid;
  v_refused boolean;
  v_msg    text;
  v_var    numeric;
begin
  v_org := pg_temp.test_org('Kedai Kira Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KOPI', 'Kopi', 'stock', false, 'C62', 5.00)
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

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- One ordinary sale, so the drawer has something in it to count.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 5.00);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 5.00)));

  -- ------------------------------------------------------------------
  -- The cashier starts counting
  -- ------------------------------------------------------------------
  perform public.begin_pos_count(v_shift);
  perform pg_temp.check_eq('the till is counting',
    (select s.status::text from public.pos_shifts s where s.id = v_shift),
    'counting');

  v_refused := false;
  begin
    perform public.open_pos_sale(v_reg);
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true(
    'and will not start a basket while the notes are on the counter',
    v_refused);
  -- The words matter. Somebody is holding a queue and needs to know a
  -- colleague is cashing up, not that a constraint failed.
  perform pg_temp.check_true('saying why, in words: ' || coalesce(v_msg, ''),
    v_msg like '%cashed up%');

  -- Pressing it twice is not an error. Two cashiers reaching for the
  -- same button is an ordinary Saturday.
  perform public.begin_pos_count(v_shift);
  perform pg_temp.check_eq('counting twice is still counting',
    (select s.status::text from public.pos_shifts s where s.id = v_shift),
    'counting');

  -- ------------------------------------------------------------------
  -- A customer arrives, and the count goes back in the drawer
  -- ------------------------------------------------------------------
  perform public.resume_pos_shift(v_shift);
  perform pg_temp.check_eq('the till is open again',
    (select s.status::text from public.pos_shifts s where s.id = v_shift),
    'open');

  -- The control: the refusal above was about the state and not about
  -- the register. Same call, same till, and it goes through.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 5.00);
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 5.00)));
  perform pg_temp.check_eq('and takes the sale',
    (select s.status::text from public.pos_sales s where s.id = v_sale),
    'completed');

  -- ------------------------------------------------------------------
  -- A basket still on the screen stops the count, not the close
  -- ------------------------------------------------------------------
  -- The same guard `close_pos_shift` has, moved earlier: finding out at
  -- the moment the count is finished wastes the count.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 5.00);
  v_refused := false;
  begin
    perform public.begin_pos_count(v_shift);
  exception when others then v_refused := true;
  end;
  perform pg_temp.check_true(
    'a parked basket is somebody''s shopping, and stops the count',
    v_refused);
  perform public.void_pos_sale(
    v_sale, 'customer_cancelled', 'Abandoned at the counter');

  -- ------------------------------------------------------------------
  -- Counting, then closing, and the figure is the one that was counted
  -- ------------------------------------------------------------------
  perform public.begin_pos_count(v_shift);
  select r.variance into v_var
    from public.close_pos_shift(v_shift, 110.00) r;
  perform pg_temp.check_eq(
    'a hundred float and two five-ringgit sales is a hundred and ten, '
    'exactly counted', v_var, 0.00);
  perform pg_temp.check_eq('and the shift is closed',
    (select s.status::text from public.pos_shifts s where s.id = v_shift),
    'closed');

  -- A closed shift stays closed. Its cash is out of the drawer and its
  -- variance has been signed off; reopening it would put sales against
  -- a figure somebody has already accepted.
  v_refused := false;
  begin
    perform public.resume_pos_shift(v_shift);
  exception when others then v_refused := true; v_msg := sqlerrm;
  end;
  perform pg_temp.check_true('a closed shift is not reopened', v_refused);
  -- The sentence, not just the refusal, and the mutation run is why.
  -- `pos_shifts_closed_ck` already makes reopening impossible — status
  -- `open` with a `closed_at` set violates it — so removing the guard
  -- in `resume_pos_shift` failed nothing while the person pressing the
  -- button went from a plain sentence to a check constraint violation.
  -- The constraint is the control; the guard is the wording, and the
  -- wording is the only thing it adds.
  perform pg_temp.check_true('in words somebody can act on: ' || coalesce(v_msg, ''),
    v_msg like '%Open a new one%');

  perform pg_temp.sign_out();
end $$;


-- ---------------------------------------------------------------------
-- The bill nobody came back for (0375)
--
-- `pos_settings.park_expiry_hours` has been a column since `0206`, with
-- a comment saying exactly what it is for, and nothing ever read it. A
-- basket somebody opened and walked away from stayed parked — and both
-- the shift close and `begin_pos_count` above refuse while one is open,
-- so a forgotten bill stops a cashier counting their own drawer, and the
-- way out needs a grant they do not have.
--
-- The sweep clears only what nothing has happened to. The two it must
-- not touch are asserted beside it, because a sweep that voids a
-- part-paid bill loses a payment that was taken.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_item   uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;
  v_stale  uuid;
  v_fresh  uuid;
  v_paid   uuid;
  v_cooked uuid;
  v_n      integer;
begin
  v_org := pg_temp.test_org('Kedai Lupa Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Shop floor') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KOPI', 'Kopi', 'stock', false, 'C62', 5.00)
  returning id into v_item;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'SHOP', 'The shop', 'retail', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;
  -- Six hours, so the fixture does not have to pretend a day has passed.
  insert into public.pos_settings (org_id, park_expiry_hours)
  values (v_org, 6);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true)
  returning id into v_cash;

  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- Four baskets, all parked. Only the first is keystrokes.
  v_stale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_stale, v_item, 1, 5.00);
  v_fresh := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_fresh, v_item, 1, 5.00);
  v_paid := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_paid, v_item, 2, 5.00);
  v_cooked := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_cooked, v_item, 1, 5.00);

  -- Somebody's money: a part payment taken and the bill left open.
  insert into public.pos_tenders
    (org_id, sale_id, tender_type_id, kind, amount)
  values (v_org, v_paid, v_cash, 'cash', 5.00);
  -- Something that became food.
  update public.pos_sale_lines set sent_to_kitchen_at = now() - interval '2 days'
   where sale_id = v_cooked;

  -- Age three of them past the six hours. The fresh one stays today.
  update public.pos_sales set created_at = now() - interval '2 days'
   where id in (v_stale, v_paid, v_cooked);

  v_n := app.expire_parked_sales(v_org);
  perform pg_temp.check_eq('one forgotten basket is cleared', v_n, 1);
  perform pg_temp.check_eq('and it is the one nothing happened to',
    (select status::text from public.pos_sales where id = v_stale), 'voided');

  -- The note is the whole audit trail for a void nobody authorised, so
  -- it has to say what happened rather than pick a reason off a list.
  perform pg_temp.check_eq('recorded as other, not as a cancellation',
    (select void_reason from public.pos_sales where id = v_stale), 'other');
  perform pg_temp.check_true('with a note saying why and how old it was',
    (select void_note like '%Cleared automatically%'
        and void_note like '%48 hours%'
       from public.pos_sales where id = v_stale));
  -- Null on purpose: no person did this.
  perform pg_temp.check_true('and nobody''s name on it',
    (select voided_by is null from public.pos_sales where id = v_stale));

  perform pg_temp.check_eq('a basket from today is left alone',
    (select status::text from public.pos_sales where id = v_fresh), 'parked');
  perform pg_temp.check_eq('a part-paid bill is somebody''s money',
    (select status::text from public.pos_sales where id = v_paid), 'parked');
  perform pg_temp.check_eq('and a bill the kitchen cooked from is a decision',
    (select status::text from public.pos_sales where id = v_cooked), 'parked');

  -- Running it again clears nothing: the stale one is already gone and
  -- the other three are still not eligible.
  perform pg_temp.check_eq('a second sweep finds nothing new',
    app.expire_parked_sales(v_org), 0);

  -- A shop with no settings row has no till to sweep, and must not fall
  -- over on the way past. Asserted as the outcome rather than as the
  -- guard: the mutation run showed the query gives the same answer with
  -- the explicit check removed, because a null interval matches nothing.
  -- The check stays for the reader, and this holds either way.
  perform pg_temp.check_eq('and a company with no POS settings is skipped',
    app.expire_parked_sales(pg_temp.test_org('Tiada Kaunter Sdn Bhd')), 0);

  perform pg_temp.sign_out();
end $$;

rollback;
