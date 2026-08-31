-- =====================================================================
-- iAkauntan :: 0361 counting the drawer stops the till
--
-- `app.pos_shift_status` is ('open', 'counting', 'closed') and nothing
-- has ever written the middle one. `open_pos_shift` writes `open` and
-- `close_pos_shift` writes `closed`, in one step, and the state that
-- exists for the minutes in between was never reached.
--
-- Those minutes are the whole reason it is there. A cashier counts the
-- drawer by hand and then presses Close; `close_pos_shift` works out
-- `expected_cash` at the moment it is called. Anything rung up on that
-- register in between — by the same cashier finishing a queue, or by a
-- colleague on the same till — is in the expected figure and not in the
-- pile of notes that was counted. The variance is then wrong by exactly
-- that sale, and it is recorded against the person who counted.
--
-- `0206`'s own comment on selling with no shift open says it: "selling
-- into a drawer nobody has counted is how a variance becomes
-- unattributable". This is the same failure a few minutes later.
--
-- ---------------------------------------------------------------------
-- What the state does
--
-- `begin_pos_count` moves `open` to `counting`, and
-- `open_pos_sale_internal` will not start a basket on a register whose
-- shift is counting. It refuses with the reason rather than the
-- database's own words, because the person reading it is holding a
-- queue and needs to know that somebody is cashing up, not that a
-- constraint failed.
--
-- `resume_pos_shift` goes back. A cashier who starts counting and finds
-- a customer at the counter must not be stuck: the count is not a
-- commitment, and a state with no way out of it is how somebody ends up
-- closing a shift early to take one sale.
--
-- `close_pos_shift` is unchanged and deliberately still accepts an
-- `open` shift. Counting first is the careful way; a manager closing a
-- till directly is ordinary, and forcing two steps would break every
-- existing caller to enforce a discipline the till cannot check anyway.
--
-- The parked-sale guard is the same one `close_pos_shift` has, moved
-- earlier. A basket still on the screen is a customer's shopping and
-- possibly their money in the drawer, and finding that out at the
-- moment the count is finished wastes the count.
-- =====================================================================

create or replace function public.begin_pos_count(p_shift uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org    uuid;
  v_status app.pos_shift_status;
  v_open   integer;
begin
  select s.org_id, s.status into v_org, v_status
    from public.pos_shifts s where s.id = p_shift;
  if v_org is null then
    raise exception 'No such shift.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to cash up this till'
      using errcode = '42501';
  end if;
  if v_status = 'closed' then
    raise exception 'That shift was already closed.' using errcode = '23514';
  end if;
  if v_status = 'counting' then
    return;  -- Idempotent: two cashiers pressing it is not an error.
  end if;

  select count(*) into v_open from public.pos_sales
   where shift_id = p_shift and status = 'parked';
  if coalesce(v_open, 0) > 0 then
    raise exception
      '% sale(s) are still parked on this till. Finish or void them '
      'before counting.', v_open
      using errcode = '23514';
  end if;

  update public.pos_shifts set status = 'counting' where id = p_shift;
end $$;

create or replace function public.resume_pos_shift(p_shift uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org    uuid;
  v_status app.pos_shift_status;
begin
  select s.org_id, s.status into v_org, v_status
    from public.pos_shifts s where s.id = p_shift;
  if v_org is null then
    raise exception 'No such shift.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_org, 'pos') then
    raise exception 'not permitted to reopen this till'
      using errcode = '42501';
  end if;
  -- A closed shift stays closed. Its variance is recorded and its cash
  -- has been taken out of the drawer; reopening it would put sales
  -- against a figure that has already been signed off.
  --
  -- `pos_shifts_closed_ck` already makes it impossible — status `open`
  -- with a `closed_at` set violates it — and the mutation run proved
  -- that by leaving this branch's removal undetected. It stays because
  -- what it adds is the sentence: without it somebody who pressed the
  -- wrong button gets a check constraint violation instead of being
  -- told to open a new shift. The constraint is the control; this is
  -- the wording.
  if v_status = 'closed' then
    raise exception
      'That shift is closed. Open a new one to keep selling.'
      using errcode = '23514';
  end if;

  update public.pos_shifts set status = 'open' where id = p_shift;
end $$;

revoke all on function public.begin_pos_count(uuid) from public, anon;
revoke all on function public.resume_pos_shift(uuid) from public, anon;
grant execute on function public.begin_pos_count(uuid) to authenticated;
grant execute on function public.resume_pos_shift(uuid) to authenticated;

comment on function public.begin_pos_count(uuid) is
  'Stops the till while the drawer is counted. Sales rung up between '
  'the count and the close are in expected_cash and not in the notes '
  'that were counted, so the variance is wrong by exactly that sale.';
comment on function public.resume_pos_shift(uuid) is
  'Puts a counting till back into service. A count is not a '
  'commitment, and a state with no way out of it is how somebody '
  'closes a shift early to take one sale.';

-- ---------------------------------------------------------------------
-- And the till will not sell while it is being counted
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.open_pos_sale_internal(p_register uuid, p_contact uuid DEFAULT NULL::uuid, p_client_uuid uuid DEFAULT NULL::uuid, p_sold_by uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_org uuid; v_outlet uuid; v_shift uuid; v_sale uuid; v_no text;
begin
  select r.org_id, r.outlet_id into v_org, v_outlet
    from public.pos_registers r
   where r.id = p_register and r.deleted_at is null and r.is_active;
  if v_org is null then
    raise exception 'That register does not exist, or has been retired.'
      using errcode = 'P0002';
  end if;

  select s.id into v_shift from public.pos_shifts s
   where s.register_id = p_register and s.status <> 'closed';
  if v_shift is null then
    raise exception
      'No shift is open on this till. Count the float in before selling.'
      using errcode = '23514';
  end if;

  -- 0361. The drawer is being counted, and a sale rung up now would be
  -- in the expected figure and not in the notes on the counter. Said in
  -- the words the person holding the queue needs rather than the
  -- database's.
  if exists (select 1 from public.pos_shifts s
              where s.id = v_shift and s.status = 'counting') then
    raise exception
      'This till is being cashed up. Put it back into service, or use '
      'another register.'
      using errcode = '23514';
  end if;

  -- The till may have sent this before and not heard back. Hand the
  -- same sale back rather than starting a second basket, which is the
  -- whole reason the id is generated on the device.
  if p_client_uuid is not null then
    select s.id into v_sale from public.pos_sales s
     where s.org_id = v_org and s.client_uuid = p_client_uuid;
    if v_sale is not null then
      return v_sale;
    end if;
  end if;

  v_no := app.next_document_number_internal(v_org, 'pos_sale');

  insert into public.pos_sales
    (org_id, shift_id, register_id, outlet_id, sale_no, status,
     client_uuid, contact_id, sold_by)
  values
    (v_org, v_shift, p_register, v_outlet, v_no, 'parked',
     p_client_uuid, p_contact, p_sold_by)
  returning id into v_sale;

  return v_sale;
end;
$function$;
