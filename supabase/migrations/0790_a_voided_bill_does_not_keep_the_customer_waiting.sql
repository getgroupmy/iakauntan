-- =====================================================================
-- iAkauntan :: 0790 a voided bill does not keep the customer waiting
--
-- `check_in_booking` (`0217`) opens a bill for an appointment and links
-- it, and a second check-in returns the linked bill -- so a
-- receptionist who taps twice reaches the same sale. Nothing looked at
-- what had become of that bill since. Measured on 9 October 2026,
-- locally: check a customer in, void the bill (the wrong service rung
-- up), check them in again -- and the same voided bill came back, which
-- refuses every line ("That sale is voided and cannot be added to.").
-- `set_booking_status` could put the appointment back to 'booked' but
-- left the link, so checking in still returned the voided bill. The
-- only way on was to cancel the appointment and book a new one while
-- the customer waited.
--
-- Answered "check-in opens a new bill". A linked bill that was voided
-- counts as no bill: check-in opens a fresh one and links that. The
-- voided bill is left as it is -- the record of what was voided, and
-- by whom, for the drawer count. A linked bill still parked or already
-- settled is returned exactly as before.
--
-- Restated from `0217`, whose text production runs exactly (identical
-- source hash on 9 October). Production held five bookings, none of
-- them linked to a voided bill, so none checks in differently.
-- =====================================================================

create or replace function public.check_in_booking(
  p_booking  uuid,
  p_register uuid)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_b    public.pos_bookings;
  v_out  uuid;
  v_sale uuid;
begin
  select * into v_b from public.pos_bookings where id = p_booking;
  if v_b.id is null then
    raise exception 'No such booking.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_b.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_b.status in ('cancelled', 'no_show') then
    raise exception 'That appointment was %.', v_b.status using errcode = '23514';
  end if;

  -- Checked in twice is checked in once. A receptionist who taps again
  -- because the screen was slow should reach the same sale, not open a
  -- second one against the same appointment.
  --
  -- `0790`: unless that sale was voided. Returning it handed the
  -- receptionist a bill that refuses every line, with the customer
  -- still in the chair. The voided bill stays as the record of what was
  -- voided; the appointment gets a new one.
  if v_b.sale_id is not null
     and exists (select 1 from public.pos_sales s
                  where s.id = v_b.sale_id and s.status <> 'voided') then
    return v_b.sale_id;
  end if;

  select r.outlet_id into v_out from public.pos_registers r where r.id = p_register;
  if v_out is null then
    raise exception 'No such register.' using errcode = 'P0002';
  end if;
  if v_out <> v_b.outlet_id then
    raise exception 'That appointment is at another outlet.' using errcode = '23514';
  end if;

  v_sale := public.open_pos_sale(p_register, v_b.contact_id);
  if v_b.item_id is not null then
    perform public.add_pos_sale_line(v_sale, v_b.item_id, 1, v_b.price);
  end if;

  update public.pos_bookings b
     set status = 'arrived', sale_id = v_sale where b.id = p_booking;

  return v_sale;
end;
$$;

revoke all on function public.check_in_booking(uuid, uuid) from public, anon;
grant execute on function public.check_in_booking(uuid, uuid) to authenticated;

comment on function public.check_in_booking(uuid, uuid) is
  'Marks the customer as arrived and opens the sale for the '
  'appointment, returning it. IDEMPOTENT ON PURPOSE: a booking that '
  'already has a sale returns that same sale rather than opening a '
  'second one, because a receptionist whose screen was slow will tap '
  'again, and two bills against one appointment is the kind of mess '
  'that is found at close of day -- UNLESS that sale was voided, when '
  'a fresh one is opened and linked, the voided one kept as the record '
  '(0790). Refuses an appointment that was cancelled or marked a '
  'no-show, and refuses a register at a different outlet. Needs the POS '
  'module.';
