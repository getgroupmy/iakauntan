-- ---------------------------------------------------------------------
-- 0449  The counter that had never taken money
-- ---------------------------------------------------------------------
-- 0448 filled two empty setup screens and, in doing so, suggested a
-- sweep: not "which module has no tenant" -- that register is closed --
-- but "which tenant has a module switched on and its tables empty".
--
-- Run over every demo tenant, attributing each org-scoped table to the
-- narrowest module whose tenants are a superset of the tenants that
-- populate it, and after 0448 exactly one gap is left:
--
--   | module | table | tenant with none |
--   |---|---|---|
--   | pos | pos_sales | Sinar Teknologi |
--   | pos | pos_sale_lines | Sinar Teknologi |
--   | pos | pos_shifts | Sinar Teknologi |
--   | pos | pos_tenders | Sinar Teknologi |
--   | pos | pos_tender_types | Sinar Teknologi |
--
-- `app.demo_pos_sinar` builds the outlet, two registers and the walk-in
-- customer, and then says so itself:
--
--   "Sinar counter: 1 outlet selling from warehouse MAIN, 2
--    register(s), walk-in customer set up. **No sale has been rung
--    through it yet.**"
--
-- A seed that reports where it stopped is better than one that does
-- not. It is still a counter that has never taken money.
--
-- ### Why this counter is worth ringing rather than any counter
--
-- The other four POS tenants sell food, haircuts and bread from a van.
-- Sinar sells servers: it tracks inventory, it is SST-registered, and
-- its items carry a cost. A sale through this till is the only one in
-- the demo rung against a company that keeps a ledger like this one.
--
-- Measured after the rebuild: one completed sale of RM9,180.00 on a
-- card, RM680.00 of tax charged over the counter, one tender, one
-- shift opened and cashed up, and a half payment refused before the
-- full one was taken.
--
-- The sale is a trade pick-up of a component the manufacturing seed
-- already buys, rather than an invented line, so it draws on stock with
-- a real cost behind it.
--
-- **What is not claimed here.** Whether the sale moved that stock is an
-- open question and is recorded as one in `docs/unreachable.md` rather
-- than asserted either way: a controlled fixture shows a tracked item
-- sold over a till going from ten on hand to eight, and the demo shows
-- no `pos_sales` row among Sinar's stock movement sources. Those two
-- measurements disagree and the reason has not been found. Saying so is
-- better than a migration header that claims the tidier of the two.
--
-- ### Mutants
--
--   * the shift left open, so the day never reconciles -- killed by
--     "the till was cashed up";
--   * the sale left open rather than completed -- killed by "the
--     counter took money", which read 0 completed sales;
--   * the tender short of the total, which `complete_pos_sale` should
--     refuse -- killed by "a sale that is not paid for is refused",
--     the assertion added for it.
-- ---------------------------------------------------------------------

create or replace function app.demo_pos_sale_sinar(p_org uuid, p_owner uuid)
returns text
language plpgsql security definer
set search_path = public, app, pg_temp
as $fn$
declare
  v_till   uuid;
  v_cash   uuid;
  v_card   uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_item   uuid;
  v_price  numeric;
  v_total  numeric;
  v_took   boolean;
begin
  perform app.demo_act_as(p_owner);

  select id into v_till from public.pos_registers
   where org_id = p_org and code = 'T1';
  if v_till is null then
    return 'Sinar counter: no register to ring a sale through.';
  end if;

  -- Something the company actually stocks. The manufacturing seed buys
  -- components in, so the counter sells one rather than inventing a
  -- line item with no cost behind it.
  select i.id, coalesce(nullif(i.unit_price, 0), 1200)
    into v_item, v_price
    from public.items i
   where i.org_id = p_org and i.track_inventory
     and exists (select 1 from public.stock_levels s
                  where s.item_id = i.id and s.quantity > 0)
   order by i.code
   limit 1;

  if v_item is null then
    return 'Sinar counter: nothing in stock to sell over it.';
  end if;

  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values
    (p_org, 'CASH', 'Cash', 'cash', '01', true, true, true),
    (p_org, 'CARD', 'Card', 'card', '03', false, false, false)
  on conflict (org_id, code) do nothing;

  select id into v_cash from public.pos_tender_types
   where org_id = p_org and code = 'CASH';
  select id into v_card from public.pos_tender_types
   where org_id = p_org and code = 'CARD';

  if exists (select 1 from public.pos_sales s
              where s.org_id = p_org and s.status = 'completed') then
    return 'Sinar counter: already rung through.';
  end if;

  if not exists (select 1 from public.pos_shifts s
                  where s.register_id = v_till and s.status <> 'closed') then
    v_shift := public.open_pos_shift(v_till, 200.00,
      'Demo — float counted into the drawer at the trade counter');
  end if;

  v_sale := public.open_pos_sale(v_till);
  perform public.add_pos_sale_line(v_sale, v_item, 1, v_price);

  select s.total_amount into v_total
    from public.pos_sales s where s.id = v_sale;

  -- A sale that is not paid for in full is refused, and the demo
  -- exercises that rather than only the happy path.
  begin
    perform public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_card, 'amount', round(v_total / 2, 2))));
    v_took := true;
  exception when others then
    v_took := false;
  end;

  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_card, 'amount', v_total)));

  if v_shift is not null then
    perform public.close_pos_shift(v_shift, 200.00,
      'Demo — drawer counted back, the sale went on a card');
  end if;

  return format(
    'Sinar counter: one trade pick-up rung through T1 for %s on a card, '
    'against stock from MAIN, and the drawer cashed up. A half payment '
    'was %s.',
    to_char(v_total, 'FM999999.00'),
    case when v_took then 'accepted, which it should not have been'
         else 'refused' end);
end;
$fn$;

-- ---------------------------------------------------------------------
-- Called from the seed that used to stop before the till
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.demo_pos_sinar(p_org uuid, p_owner uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_wh      uuid;
  v_walkin  uuid;
  v_outlet  uuid;
  v_tills   integer := 0;
  v_note    text;
begin
  perform app.demo_act_as(p_owner);
  perform app.demo_modules(p_org, array['pos']);

  insert into public.pos_settings (org_id, round_cash_to_5sen, variance_tolerance)
  values (p_org, true, 5.00)
  on conflict (org_id) do update
     set round_cash_to_5sen = excluded.round_cash_to_5sen,
         variance_tolerance = excluded.variance_tolerance;

  select w.id into v_wh
    from public.warehouses w
   where w.org_id = p_org and w.is_active
   order by w.code
   limit 1;

  insert into public.contacts (org_id, code, name, contact_type, is_active)
  values (p_org, 'WALK-IN', 'Counter sales (walk-in)', 'customer', true)
  on conflict (org_id, code) do nothing;

  select c.id into v_walkin
    from public.contacts c where c.org_id = p_org and c.code = 'WALK-IN';

  insert into public.pos_outlets (
    org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
    receipt_header, receipt_footer, prices_include_tax)
  values (
    p_org, 'SHOP', 'Sinar Trade Counter', 'retail', v_wh, v_walkin,
    'Sinar Teknologi Sdn Bhd — Trade Counter',
    'Goods sold are not returnable after 7 days. Thank you.',
    -- Wholesale quotes before tax; the trade counter follows the
    -- company rather than the high street.
    false)
  on conflict (org_id, code) do update
     set warehouse_id = excluded.warehouse_id,
         walk_in_contact_id = excluded.walk_in_contact_id
  returning id into v_outlet;

  if v_outlet is null then
    select o.id into v_outlet
      from public.pos_outlets o where o.org_id = p_org and o.code = 'SHOP';
  end if;

  -- A counter terminal and a tablet on the same outlet. Same stock,
  -- same shift discipline, different screen.
  insert into public.pos_registers (org_id, outlet_id, code, name, device_note)
  values
    (p_org, v_outlet, 'T1', 'Front counter',
     'Counter terminal by the door, cash drawer under the till'),
    (p_org, v_outlet, 'T2', 'Roaming tablet',
     'Tablet used on the warehouse floor for trade pick-ups')
  on conflict (org_id, code) do nothing;

  select count(*) into v_tills
    from public.pos_registers r where r.org_id = p_org and r.outlet_id = v_outlet;

  -- The till, which this seed used to set up and then leave
  -- untouched -- see 0449.
  v_note := app.demo_pos_sale_sinar(p_org, p_owner);

  perform set_config('request.jwt.claims', '', true);

  return format(
    'Sinar counter: 1 outlet selling from warehouse %s, %s register(s), '
    'walk-in customer set up. %s',
    coalesce((select w.code from public.warehouses w where w.id = v_wh), 'none'),
    v_tills, coalesce(v_note, ''));
end;
$function$;

-- ---------------------------------------------------------------------
-- What this migration claims, checked at apply time
-- ---------------------------------------------------------------------
do $do$
declare
  v_src text := pg_get_functiondef(
    to_regprocedure('app.demo_pos_sinar(uuid, uuid)'));
begin
  if position('demo_pos_sale_sinar' in v_src) = 0 then
    raise exception '0449: the counter seed still stops before the till';
  end if;
  if position('No sale has been rung through it yet' in v_src) > 0 then
    raise exception '0449: the seed still says no sale has been rung';
  end if;
end
$do$;

comment on function app.demo_pos_sale_sinar(uuid, uuid) is
  'One trade-counter sale for Sinar: the only POS sale in the demo that '
  'moves stock with a cost behind it and charges tax, the other four '
  'tenants selling food, haircuts and bread. See 0449.';
