-- =====================================================================
-- Point of sale :: who may void
--
-- Taking a line off a bill after the kitchen has it is the oldest way
-- to steal from a till: ring the food up, take the cash, void the line,
-- keep the difference. Both books balance afterwards. The only trace is
-- the void record, which is why one is written — and why who may write
-- one is a question a shop has to be able to answer for itself.
--
-- The assertion this file is built around is the pair either side of
-- one grant: the same cashier, on the same line, refused and then
-- allowed, with nothing between the two but `pos_void` appearing on
-- their access type.
--
-- The other half matters as much: a shop that has never defined an
-- access type must be untouched, because a release that stopped every
-- cashier in the country voiding would be an outage, not a control.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_plain  uuid;
  v_limited uuid;
  v_type   uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_item   uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_sale   uuid;
  v_line   uuid;
  v_can    boolean;
  v_msg    text;
  v_stn    uuid;
  v_bill   uuid;
  v_free   uuid;
  v_lost   integer;
begin
  v_org := pg_temp.test_org('Kedai Void Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  v_plain   := pg_temp.another_user('cashier@void.test');
  v_limited := pg_temp.another_user('junior@void.test');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_plain, 'sales'), (v_org, v_limited, 'sales');

  -- ------------------------------------------------------------------
  -- The catalog knows what it can enforce
  -- ------------------------------------------------------------------
  -- Without a row here the permission is unnameable: the screen that
  -- hands out access types has nothing to offer, so the grant could
  -- never be given and the refusal would be permanent.
  perform pg_temp.check_eq('voiding is a permission a company can hand out',
    (select p.module_code from public.access_permissions p
      where p.code = 'pos_void'), 'pos');

  -- ------------------------------------------------------------------
  -- Nothing changes for a shop that never asked
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the owner may void',
    app.can_void_pos(v_org));
  -- The trap this replaced, kept as an assertion so nobody walks back
  -- into it: 0232 made `module_access` answer `none` for any code the
  -- company has not bought, and nobody buys a permission. Routing the
  -- grant through it denied every void in the product, including the
  -- shop owner's.
  perform pg_temp.check_true('a permission is not on the price list',
    app.module_access(v_org, 'pos_void') = 'none'
      and app.can_void_pos(v_org));
  -- And an unknown code is not held, so a typo at a call site fails
  -- closed rather than opening the thing it was guarding.
  perform pg_temp.check_true('an invented permission is held by nobody',
    not app.has_permission(v_org, 'pos_nonsense'));
  perform pg_temp.sign_in_as(v_plain);
  perform pg_temp.check_true('and so may a cashier with no access type',
    app.can_void_pos(v_org));

  -- ------------------------------------------------------------------
  -- Until one does
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  insert into public.access_types (org_id, name)
  values (v_org, 'Till, no voids') returning id into v_type;
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos', 'write'), (v_type, 'inventory', 'read');
  update public.org_members set access_type_id = v_type
   where org_id = v_org and user_id = v_limited;

  perform pg_temp.sign_in_as(v_limited);
  perform pg_temp.check_true('a cashier granted the till may work it',
    app.can_write_module(v_org, 'pos'));
  -- The rule 0127 set: an access type grants what it lists and nothing
  -- else, which is why an action can be added to it later without
  -- quietly opening it to everybody who already had one.
  perform pg_temp.check_true('but not void, because it was not listed',
    not app.can_void_pos(v_org));

  -- ------------------------------------------------------------------
  -- The refusal, on a real line
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'ROTI', 'Roti john', 'service', false, 'C62', 8.00, 3.00)
  returning id into v_item;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'KEDAI', 'The shop', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Counter') returning id into v_reg;

  v_shift := public.open_pos_shift(v_reg, 100.00);
  v_sale  := public.open_pos_sale(v_reg);
  v_line  := public.add_pos_sale_line(v_sale, v_item, 1, 8.00);

  perform pg_temp.sign_in_as(v_limited);
  begin
    perform public.void_pos_sale_line(v_line, 'wrong_item');
    raise exception 'FAIL a cashier without the grant voided a line';
  exception when insufficient_privilege then
    get stacked diagnostics v_msg = message_text;
    raise notice 'ok   voiding is refused without the grant';
  end;
  -- Said as the thing a supervisor can fix. Somebody reading this is
  -- standing at a till with a customer waiting.
  perform pg_temp.check_true('and the refusal says who to ask',
    v_msg like '%Ask a manager%');
  perform pg_temp.check_eq('the line is still on the bill',
    (select count(*) from public.pos_sale_lines l where l.id = v_line), 1);
  perform pg_temp.check_eq('and nothing was written to the void record',
    (select count(*) from public.pos_sale_line_voids v where v.sale_id = v_sale), 0);

  -- ------------------------------------------------------------------
  -- And the grant, with nothing else changed
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  insert into public.access_type_modules (access_type_id, module_code, access)
  values (v_type, 'pos_void', 'write');

  perform pg_temp.sign_in_as(v_limited);
  perform pg_temp.check_true('granted, the same cashier may void',
    app.can_void_pos(v_org));
  perform public.void_pos_sale_line(v_line, 'wrong_item');
  perform pg_temp.check_eq('the line came off',
    (select count(*) from public.pos_sale_lines l where l.id = v_line), 0);
  perform pg_temp.check_eq('with their name on the loss',
    (select v.voided_by from public.pos_sale_line_voids v
      where v.sale_id = v_sale), v_limited);

  -- ------------------------------------------------------------------
  -- Working the till is the floor
  -- ------------------------------------------------------------------
  -- Somebody who may not sell has no business voiding whatever else
  -- they were given, or the permission becomes a way around the module
  -- rather than a restriction inside it.
  perform pg_temp.sign_in_as(v_owner);
  update public.access_type_modules set access = 'read'
   where access_type_id = v_type and module_code = 'pos';
  perform pg_temp.sign_in_as(v_limited);
  perform pg_temp.check_true('a void grant does not let somebody into the till',
    not app.can_void_pos(v_org));

  -- ------------------------------------------------------------------
  -- And the till can ask before it offers the button
  -- ------------------------------------------------------------------
  -- Hiding is a courtesy, not the control — but a button that always
  -- fails is worse than no button, and the answer has to come from the
  -- same function the refusal uses or a screen could disagree with the
  -- database about it.
  --
  -- Asked in both directions, because an answer that is only ever
  -- checked one way is an answer nobody has tested. The till floor is
  -- still down from the assertion above, so the honest answer here is
  -- none — and the screen must say so rather than offering a button
  -- the database will refuse.
  perform pg_temp.check_eq('with the till taken away, so is the button',
    (select a.access from public.my_module_access(v_org) a
      where a.module_code = 'pos_void'), 'none');

  perform pg_temp.sign_in_as(v_owner);
  update public.access_type_modules set access = 'write'
   where access_type_id = v_type and module_code = 'pos';
  perform pg_temp.sign_in_as(v_limited);
  perform pg_temp.check_eq('and given back, so is it',
    (select a.access from public.my_module_access(v_org) a
      where a.module_code = 'pos_void'), 'write');

  perform pg_temp.sign_in_as(v_plain);
  perform pg_temp.check_eq('and it answers for somebody with no access type',
    (select a.access from public.my_module_access(v_org) a
      where a.module_code = 'pos_void'), 'write');

  -- ------------------------------------------------------------------
  -- Writing off the whole bill
  -- ------------------------------------------------------------------
  --
  -- A party walks out on six lines. Before 0246 that was six voids,
  -- six reasons and six records for one event -- and 0206 had been
  -- telling cashiers to "finish or void" a parked bill before closing
  -- a shift since long before there was a way to void one.
  perform pg_temp.sign_in_as(v_owner);
  insert into public.pos_kitchen_stations
    (org_id, outlet_id, code, name, is_default)
  values (v_org, v_outlet, 'KIT', 'Kitchen', true) returning id into v_stn;

  -- ------------------------------------------------------------------
  -- Even a bill nobody cooked from
  -- ------------------------------------------------------------------
  --
  -- 0246 let this one through, on the reasoning that the lines were
  -- keystrokes the cashier could remove one at a time anyway. 0247
  -- closed it: taking a line off leaves the bill and the cashier still
  -- has to account for it, while making the bill disappear before
  -- anything reached the kitchen is the shape of an order rung up,
  -- paid in cash and quietly removed.
  perform pg_temp.sign_in_as(v_owner);
  update public.access_type_modules set access = 'none'
   where access_type_id = v_type and module_code = 'pos_void';
  v_free := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_free, v_item, 1, 8.00);

  perform pg_temp.sign_in_as(v_limited);
  perform pg_temp.check_true('a cashier without the grant does not hold it',
    not app.can_void_pos(v_org));
  begin
    perform public.void_pos_sale(v_free, 'customer_cancelled');
    raise exception 'FAIL wrote off a bill without the grant';
  exception when insufficient_privilege then
    get stacked diagnostics v_msg = message_text;
    raise notice 'ok   writing off a bill is refused without the grant';
  end;
  perform pg_temp.check_true('and the refusal says who to ask',
    v_msg like '%Ask a manager%');
  perform pg_temp.check_eq('the bill is still open',
    (select s.status::text from public.pos_sales s where s.id = v_free), 'parked');
  perform pg_temp.check_eq('and nothing was written to the void record',
    (select count(*) from public.pos_sale_line_voids v where v.sale_id = v_free), 0);

  -- Taking one unsent line off is still theirs to do: it leaves the
  -- bill, and the bill is what they have to account for.
  perform public.remove_pos_sale_line(
    (select l.id from public.pos_sale_lines l where l.sale_id = v_free));
  perform pg_temp.check_eq('a line still comes off without the grant',
    (select count(*) from public.pos_sale_lines l where l.sale_id = v_free), 0);
  perform pg_temp.check_eq('and the bill is still there to answer for',
    (select s.status::text from public.pos_sales s where s.id = v_free), 'parked');

  -- ------------------------------------------------------------------
  -- Once the kitchen has cooked, it is a write-off
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  v_bill := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_bill, v_item, 2, 8.00);
  perform public.add_pos_sale_line(v_bill, v_item, 1, 8.00);
  perform public.send_order_to_kitchen(v_bill);
  perform pg_temp.check_eq('the kitchen has a docket',
    (select count(*) from public.pos_kitchen_tickets k
      where k.sale_id = v_bill and k.status = 'new'), 1);

  perform pg_temp.sign_in_as(v_limited);
  begin
    perform public.void_pos_sale(v_bill, 'customer_cancelled');
    raise exception 'FAIL wrote off cooked food without the grant';
  exception when insufficient_privilege then
    get stacked diagnostics v_msg = message_text;
    raise notice 'ok   writing off cooked food is refused without the grant';
  end;
  perform pg_temp.check_true('and the refusal says who to ask',
    v_msg like '%Ask a manager%');
  perform pg_temp.check_eq('the bill is untouched',
    (select s.status::text from public.pos_sales s where s.id = v_bill), 'parked');

  -- ------------------------------------------------------------------
  -- And with the grant
  -- ------------------------------------------------------------------
  perform pg_temp.sign_in_as(v_owner);
  update public.access_type_modules set access = 'write'
   where access_type_id = v_type and module_code = 'pos_void';

  perform pg_temp.sign_in_as(v_limited);
  -- Returns how many lines became a loss, which is how many were
  -- cooked -- not how many were on the bill.
  v_lost := public.void_pos_sale(v_bill, 'other', '  they walked out  ');
  perform pg_temp.check_eq('both cooked lines are recorded as a loss', v_lost, 2);
  perform pg_temp.check_eq('the bill is written off',
    (select s.status::text from public.pos_sales s where s.id = v_bill), 'voided');
  perform pg_temp.check_eq('with a reason on it',
    (select s.void_reason from public.pos_sales s where s.id = v_bill), 'other');
  -- Trimmed, so a note that is only spaces is no note at all.
  perform pg_temp.check_eq('and what was said, tidied',
    (select s.void_note from public.pos_sales s where s.id = v_bill),
    'they walked out');
  perform pg_temp.check_eq('and a name against it',
    (select s.voided_by from public.pos_sales s where s.id = v_bill), v_limited);

  -- The lines stay. They are what was written off, and a voided bill
  -- of nothing tells a manager nothing.
  perform pg_temp.check_eq('the lines are kept',
    (select count(*) from public.pos_sale_lines l where l.sale_id = v_bill), 2);
  perform pg_temp.check_eq('and so is what it came to',
    (select s.total_amount from public.pos_sales s where s.id = v_bill), 24.00);

  -- The kitchen is told to stop.
  perform pg_temp.check_eq('the docket is cancelled',
    (select count(*) from public.pos_kitchen_tickets k
      where k.sale_id = v_bill and k.status = 'cancelled'), 1);

  -- It falls out of everything that counts open bills, which is what
  -- lets a shift close over it.
  perform pg_temp.check_eq('and it is no longer an open order',
    (select count(*) from public.pos_open_orders(v_outlet) o
      where o.sale_id = v_bill), 0);
  -- And the one that was refused still is, which is the point of the
  -- refusal: nothing disappeared.
  perform pg_temp.check_eq('while the bill nobody could write off still is',
    (select count(*) from public.pos_open_orders(v_outlet) o
      where o.sale_id = v_free), 1);

  -- One event, one row per plate, in the report a manager already has.
  perform pg_temp.check_eq('the loss reaches the void report',
    (select v.lines from public.pos_void_summary(v_org) v
      where v.reason = 'other'), 2);

  -- ------------------------------------------------------------------
  -- And it only happens once
  -- ------------------------------------------------------------------
  begin
    perform public.void_pos_sale(v_bill, 'customer_cancelled');
    raise exception 'FAIL wrote off a bill twice';
  exception when check_violation then
    raise notice 'ok   a bill already written off cannot be written off again';
  end;

  -- "Something else" that says nothing is not a reason. The same rule
  -- 0225 set for one line, because the report is only worth having if
  -- the catch-all is answerable.
  perform pg_temp.sign_in_as(v_owner);
  v_free := public.open_pos_sale(v_reg);
  begin
    perform public.void_pos_sale(v_free, 'other', '   ');
    raise exception 'FAIL wrote off a bill with an empty explanation';
  exception when check_violation then
    raise notice 'ok   something else has to say what happened';
  end;
  perform public.void_pos_sale(v_free, 'wrong_item');

  -- ------------------------------------------------------------------
  -- And a written-off bill shows up somewhere
  -- ------------------------------------------------------------------
  --
  -- The hole 0246 and 0247 left between them, and the one the grant was
  -- tightened for: `pos_void_summary` reads line voids, and a bill
  -- written off before the kitchen cooked anything writes none. Without
  -- 0248 that case -- an order rung up, paid in cash and made to go
  -- away -- appears in no report at all.
  perform pg_temp.sign_in_as(v_limited);
  perform pg_temp.check_eq('the written-off bill is listed',
    (select count(*) from public.pos_voided_bills(v_org) b
      where b.sale_id = v_bill), 1);
  perform pg_temp.check_eq('for what it came to',
    (select b.total_amount from public.pos_voided_bills(v_org) b
      where b.sale_id = v_bill), 24.00);
  perform pg_temp.check_eq('with the reason given',
    (select b.reason from public.pos_voided_bills(v_org) b
      where b.sale_id = v_bill), 'other');
  perform pg_temp.check_eq('and what was said',
    (select b.note from public.pos_voided_bills(v_org) b
      where b.sale_id = v_bill), 'they walked out');
  perform pg_temp.check_eq('and whose it was',
    (select b.voided_by from public.pos_voided_bills(v_org) b
      where b.sale_id = v_bill), v_limited);
  -- Food lost and an order that never existed are different facts, and
  -- a manager reads them differently.
  perform pg_temp.check_eq('and how much of it had been cooked',
    (select b.cooked_count from public.pos_voided_bills(v_org) b
      where b.sale_id = v_bill), 2);

  -- The case that the line report cannot see at all: a bill written off
  -- with nothing cooked.
  perform pg_temp.sign_in_as(v_owner);
  v_free := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_free, v_item, 1, 8.00);
  perform public.void_pos_sale(v_free, 'customer_cancelled');
  perform pg_temp.check_eq('a bill nobody cooked from leaves no void lines',
    (select count(*) from public.pos_sale_line_voids v where v.sale_id = v_free), 0);
  perform pg_temp.check_eq('and would be invisible in the line report',
    (select coalesce(sum(v.lines), 0) from public.pos_void_summary(v_org) v
      where v.reason = 'customer_cancelled'), 0);
  -- But not here, which is the whole point of 0248.
  perform pg_temp.check_eq('yet it is listed as a bill written off',
    (select b.total_amount from public.pos_voided_bills(v_org) b
      where b.sale_id = v_free), 8.00);
  perform pg_temp.check_eq('with nothing cooked, said plainly',
    (select b.cooked_count from public.pos_voided_bills(v_org) b
      where b.sale_id = v_free), 0);

  -- A day the shop did not have is not a day to report on.
  perform pg_temp.check_eq('yesterday holds none of it',
    (select count(*) from public.pos_voided_bills(
       v_org,
       ((now() at time zone 'Asia/Kuala_Lumpur')::date - 1),
       ((now() at time zone 'Asia/Kuala_Lumpur')::date - 1))), 0);

  raise notice 'point of sale voiding: all assertions passed';
end;
$$;

rollback;
