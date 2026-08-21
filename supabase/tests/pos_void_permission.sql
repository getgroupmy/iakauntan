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
  perform pg_temp.check_eq('what am I allowed to do names the permission',
    (select a.access from public.my_module_access(v_org) a
      where a.module_code = 'pos_void'), 'write');
  perform pg_temp.sign_in_as(v_plain);
  perform pg_temp.check_eq('and answers for somebody with no access type too',
    (select a.access from public.my_module_access(v_org) a
      where a.module_code = 'pos_void'), 'write');

  raise notice 'point of sale voiding: all assertions passed';
end;
$$;

rollback;
