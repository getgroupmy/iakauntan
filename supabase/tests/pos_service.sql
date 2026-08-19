-- =====================================================================
-- Point of sale :: the diary
--
-- One assertion here matters more than the rest, and it is not that
-- book_appointment refuses a clash. It is that the DATABASE refuses one:
-- a direct insert that never goes near the function is still turned
-- away by the exclusion constraint.
--
-- The distinction is the whole design. A look-then-insert has a window
-- between the look and the insert, two receptionists tapping at once
-- both pass the look, and the salon puts two customers in one chair.
-- The function's own check exists only so the error reads like a
-- sentence; if it were the only guard, this file would be asserting
-- something that is true right up until the shop gets busy.
-- =====================================================================
\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_cut    uuid;
  v_walkin uuid;
  v_cust   uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_cash   uuid;
  v_p1     uuid;
  v_p2     uuid;
  v_shift  uuid;
  v_b1     uuid;
  v_b2     uuid;
  v_sale   uuid;
  v_mon    date;
  v_ten    timestamptz;
  v_plan   uuid;
  v_urut   uuid;
  v_mem    uuid;
  v_sub    uuid;
  v_sale2  uuid;
  v_line   uuid;
  v_covered uuid;
  v_a      numeric;
begin
  v_org := pg_temp.test_org('Salon Seri Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','purchases','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Back room') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'RAHIM', 'Encik Rahim', 'customer') returning id into v_cust;

  -- A service holds no stock, which is most of what makes it a service.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'CUT', 'Gunting rambut', 'service', false, 'C62', 45.00, 0)
  returning id into v_cut;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'SALON', 'The salon', 'service', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Reception') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, true);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', true, true) returning id into v_cash;

  insert into public.pos_service_providers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'AZ', 'Azlina') returning id into v_p1;
  insert into public.pos_service_providers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'BD', 'Badrul') returning id into v_p2;

  -- Forty minutes in the chair, ten to sweep it.
  insert into public.pos_services (org_id, item_id, duration_minutes, buffer_minutes)
  values (v_org, v_cut, 40, 10);
  insert into public.pos_provider_hours (org_id, provider_id, weekday, starts_at, ends_at)
  select v_org, p, 1, time '09:00', time '18:00' from unnest(array[v_p1, v_p2]) p;

  -- Next Monday at ten, in the salon's own time. Derived rather than
  -- written down, so the file does not start failing on a Tuesday.
  v_mon := (date_trunc('week', current_date) + interval '7 days')::date;
  v_ten := (v_mon + time '10:00') at time zone 'Asia/Kuala_Lumpur';

  -- ------------------------------------------------------------------
  -- The slot
  -- ------------------------------------------------------------------
  v_b1 := public.book_appointment(v_p1, v_cut, v_ten, v_cust);
  -- The turnaround is inside the booking, not a number the reader has
  -- to remember to add.
  perform pg_temp.check_eq('the slot runs the service plus the turnaround',
    (select (extract(epoch from (b.ends_at - b.starts_at)) / 60)::integer
       from public.pos_bookings b where b.id = v_b1), 50);
  perform pg_temp.check_eq('and it snapshots what was quoted',
    (select b.price from public.pos_bookings b where b.id = v_b1), 45.0000);

  -- Forty-five minutes in is inside the turnaround, which is the point
  -- of putting the turnaround inside the booking.
  begin
    perform public.book_appointment(v_p1, v_cut, v_ten + interval '45 minutes', v_cust);
    raise exception 'FAIL sold the same slot twice';
  exception when unique_violation then
    raise notice 'ok   a slot cannot be sold twice';
  end;

  -- The assertion this file exists for. No function involved.
  begin
    insert into public.pos_bookings
      (org_id, outlet_id, provider_id, item_id, description, price, starts_at, ends_at)
    values (v_org, v_outlet, v_p1, v_cut, 'Sneaked in', 45.00,
            v_ten + interval '20 minutes', v_ten + interval '60 minutes');
    raise exception 'FAIL the overlap was only refused by the function';
  exception when exclusion_violation then
    raise notice 'ok   the database refuses the overlap, not just the function';
  end;

  -- One provider being busy says nothing about the other.
  v_b2 := public.book_appointment(v_p2, v_cut, v_ten, v_cust);
  perform pg_temp.check_true('the other chair is free at the same moment',
    v_b2 is not null);

  -- ------------------------------------------------------------------
  -- Hours and absence
  -- ------------------------------------------------------------------
  begin
    perform public.book_appointment(v_p1, v_cut,
      (v_mon + time '20:00') at time zone 'Asia/Kuala_Lumpur', v_cust);
    raise exception 'FAIL booked somebody after hours';
  exception when check_violation then
    raise notice 'ok   nobody is booked outside the hours they work';
  end;

  insert into public.pos_provider_time_off (org_id, provider_id, starts_at, ends_at, reason)
  values (v_org, v_p1,
          (v_mon + time '14:00') at time zone 'Asia/Kuala_Lumpur',
          (v_mon + time '16:00') at time zone 'Asia/Kuala_Lumpur', 'Klinik');
  begin
    perform public.book_appointment(v_p1, v_cut,
      (v_mon + time '14:30') at time zone 'Asia/Kuala_Lumpur', v_cust);
    raise exception 'FAIL booked somebody who was away';
  exception when check_violation then
    raise notice 'ok   nor while they are away';
  end;

  -- A cancelled slot really is free again, which is why cancelled
  -- bookings sit outside the exclusion constraint.
  perform public.set_booking_status(v_b1, 'cancelled', 'Rang to say sorry');
  perform pg_temp.check_true('a cancelled slot can be re-let',
    public.book_appointment(v_p1, v_cut, v_ten, v_cust) is not null);

  -- ------------------------------------------------------------------
  -- Arriving, which is where a diary entry becomes money
  -- ------------------------------------------------------------------
  v_shift := public.open_pos_shift(v_reg, 100.00);
  v_sale  := public.check_in_booking(v_b2, v_reg);
  perform pg_temp.check_eq('checking in opens a sale with the service on it',
    (select count(*) from public.pos_sale_lines l where l.sale_id = v_sale), 1);
  perform pg_temp.check_eq('at the price that was quoted',
    (select s.total_amount from public.pos_sales s where s.id = v_sale), 45.00);
  -- A receptionist who taps again because the screen was slow must
  -- reach the same sale, not open a second one against one appointment.
  perform pg_temp.check_true('checking in twice reaches the same sale',
    public.check_in_booking(v_b2, v_reg) = v_sale);
  perform pg_temp.check_true('and the diary says they arrived',
    (select b.status from public.pos_bookings b where b.id = v_b2) = 'arrived');

  begin
    perform public.set_booking_status(v_b2, 'arrived');
    raise exception 'FAIL typed an arrival instead of checking somebody in';
  exception when check_violation then
    raise notice 'ok   arrival is a claim about money, not a status somebody types';
  end;

  -- Nothing about this module changes the money: the sale posts an
  -- ordinary invoice and receipt, and the diary follows it rather than
  -- being told separately.
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 45.00)));
  perform pg_temp.check_true('a service sale posts an invoice like any other',
    (select d.status from public.sales_documents d
      join public.pos_sales s on s.invoice_id = d.id where s.id = v_sale) = 'completed');
  perform pg_temp.check_true('and settling it closes the appointment behind it',
    (select b.status from public.pos_bookings b where b.id = v_b2) = 'completed');
  perform pg_temp.check_eq('a haircut leaves no stock movement behind',
    (select count(*) from public.stock_movements m
      join public.pos_sales s on s.invoice_id = m.source_id where s.id = v_sale), 0);

  -- ------------------------------------------------------------------
  -- The day sheet
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('every provider appears, busy or not',
    (select count(distinct d.provider_id) from public.pos_day_sheet(v_outlet, v_mon) d), 2);
  perform pg_temp.check_eq('and each appointment says how long it runs',
    (select d.minutes from public.pos_day_sheet(v_outlet, v_mon) d
      where d.booking_id = v_b2), 50);
  perform pg_temp.check_eq('a quiet day is a day with no bookings on it',
    (select count(*) from public.pos_day_sheet(v_outlet, v_mon + 1) d
      where d.booking_id is not null), 0);

  -- ------------------------------------------------------------------
  -- Memberships
  -- ------------------------------------------------------------------
  -- Two halves that must not be confused: money arriving every month,
  -- and an entitlement taken one class at a time.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'PLAN', 'Keahlian bulanan', 'service', false, 'C62', 150.00, 0)
  returning id into v_plan;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'URUT', 'Urutan', 'service', false, 'C62', 120.00, 0)
  returning id into v_urut;

  insert into public.pos_memberships
    (org_id, code, name, item_id, period, sessions_included)
  values (v_org, 'GOLD', 'Gold bulanan', v_plan, 'monthly', 2) returning id into v_mem;
  -- Covers haircuts and nothing else. An empty list would mean
  -- everything, which is what "unlimited" is.
  insert into public.membership_items (org_id, membership_id, item_id)
  values (v_org, v_mem, v_cut);

  v_sale2 := public.open_pos_sale(v_reg, v_cust);
  perform public.add_pos_sale_line(v_sale2, v_plan, 1, 150.00);
  begin
    perform public.start_membership(v_sale2, v_mem);
    raise exception 'FAIL started a membership nobody had paid for';
  exception when check_violation then
    raise notice 'ok   a membership cannot start before the money does';
  end;

  perform public.complete_pos_sale(v_sale2, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 150.00)));
  v_sub := public.start_membership(v_sale2, v_mem);
  perform pg_temp.check_true('paying for it starts it', v_sub is not null);

  -- The renewal is the scheduler 0097 already built, not a second one.
  perform pg_temp.check_true('the renewal is on the existing scheduler',
    (select s.recurring_document_id from public.pos_membership_subscriptions s
      where s.id = v_sub) is not null);
  perform pg_temp.check_true('at the membership''s own period',
    (select r.frequency from public.recurring_documents r
      join public.pos_membership_subscriptions s on s.recurring_document_id = r.id
     where s.id = v_sub) = 'monthly');
  perform pg_temp.check_true('starting after the period just paid for',
    (select r.next_run_date from public.recurring_documents r
      join public.pos_membership_subscriptions s on s.recurring_document_id = r.id
     where s.id = v_sub) = (current_date + interval '1 month')::date);
  perform pg_temp.check_eq('so nothing is waiting for a billing schedule',
    (select count(*) from public.membership_billing_gaps(v_org)), 0);

  perform pg_temp.check_eq('two sessions are included',
    (select b.included from public.membership_balance(v_sub) b), 2);

  -- ------------------------------------------------------------------
  -- Taking what was paid for
  -- ------------------------------------------------------------------
  v_sale2 := public.open_pos_sale(v_reg, v_cust);
  v_covered := public.add_pos_sale_line(v_sale2, v_cut, 1, 45.00);
  perform pg_temp.check_eq('a haircut costs forty-five before the membership',
    (select s.total_amount from public.pos_sales s where s.id = v_sale2), 45.00);

  v_a := public.cover_line_with_membership(v_covered, v_sub);
  perform pg_temp.check_eq('the membership covers the whole line', v_a, 45.00);
  perform pg_temp.check_eq('so there is nothing to pay',
    (select s.total_amount from public.pos_sales s where s.id = v_sale2), 0.00);
  -- The line stays, at nothing. A receipt showing "Cut 45.00 —
  -- Membership -45.00" is one the member can check; one showing nothing
  -- looks like they were never there.
  perform pg_temp.check_eq('and the line is still on the bill',
    (select count(*) from public.pos_sale_lines l where l.sale_id = v_sale2), 1);
  perform pg_temp.check_eq('one session used',
    (select b.used from public.membership_balance(v_sub) b), 1);
  perform pg_temp.check_eq('one left',
    (select b.remaining from public.membership_balance(v_sub) b), 1);

  begin
    perform public.cover_line_with_membership(v_covered, v_sub);
    raise exception 'FAIL covered one line with two sessions';
  exception when unique_violation then
    raise notice 'ok   a line cannot be covered twice';
  end;

  -- Rung up OUTSIDE the block. A plpgsql exception handler rolls back
  -- everything done inside its block, so a line added in there vanishes
  -- with the refusal -- and the assertion below would then be checking
  -- a bill the massage had never been on.
  v_line := public.add_pos_sale_line(v_sale2, v_urut, 1, 120.00);
  begin
    perform public.cover_line_with_membership(v_line, v_sub);
    raise exception 'FAIL covered something the membership does not include';
  exception when check_violation then
    raise notice 'ok   a membership does not cover what it does not cover';
  end;
  perform pg_temp.check_eq('so the massage is still chargeable',
    (select s.total_amount from public.pos_sales s where s.id = v_sale2), 120.00);

  -- The allowance runs out, and says so.
  perform public.cover_line_with_membership(
    public.add_pos_sale_line(v_sale2, v_cut, 1, 45.00), v_sub);
  perform pg_temp.check_eq('both sessions are gone',
    (select b.remaining from public.membership_balance(v_sub) b), 0);
  begin
    perform public.cover_line_with_membership(
      public.add_pos_sale_line(v_sale2, v_cut, 1, 45.00), v_sub);
    raise exception 'FAIL gave away a third session on a package of two';
  exception when check_violation then
    raise notice 'ok   a third class on a package of two is not covered';
  end;

  -- The property that makes the ledger worth having: taking the class
  -- off the bill gives the session back, without anybody remembering to.
  delete from public.pos_sale_lines where id = v_covered;
  perform pg_temp.check_eq('removing the line gives the session back',
    (select b.remaining from public.membership_balance(v_sub) b), 1);

  -- And cancelling stops the invoices. A cancelled member who keeps
  -- being billed is the complaint that reaches the regulator.
  perform public.set_membership_status(v_sub, 'cancelled');
  perform pg_temp.check_true('a cancelled member stops being invoiced',
    not (select r.is_active from public.recurring_documents r
          join public.pos_membership_subscriptions s on s.recurring_document_id = r.id
         where s.id = v_sub));

  raise notice 'point of sale service: all assertions passed';
end;
$$;
