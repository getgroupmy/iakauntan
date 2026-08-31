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

rollback;
