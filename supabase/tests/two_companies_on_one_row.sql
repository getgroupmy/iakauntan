-- =====================================================================
-- iAkauntan :: a row that names two companies at once
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/two_companies_on_one_row.sql
--
-- `tenant_foreign_keys.sql` holds every column that names another row
-- to the company the row belongs to, and asserts it for the whole
-- schema rather than for a list. Its filter is the reason this file
-- exists:
--
--   and exists (select 1 from pg_attribute o
--                where o.attrelid = c.conrelid and o.attname = 'org_id')
--
-- A table with no `org_id` at all is invisible to that query. There is
-- no company on the row, so nothing is skipped and nothing is
-- reported. A join table holding two foreign keys and nothing else is
-- exactly that shape, and three POS ones were:
--
--   pos_menu_schedule_items (schedule_id, item_id)
--   pos_promotion_items     (promotion_id, item_id)
--   pos_promotion_outlets   (promotion_id, outlet_id)
--
-- The consequence was found by probe, not by reading. `app.pos_item_off`
-- -- which the counter, the kiosk and the public menu all ask before
-- offering a dish -- matched schedule rows BY ITEM ALONE, so one
-- company putting another's item on a schedule that was shut took the
-- other company's dish off the other company's own menu. It needed
-- nothing but the POS module.
--
-- 0522 gave the three tables an `org_id` and both same-org keys, taught
-- the two upsert RPCs to name the mistake, scoped `pos_item_off` to the
-- outlet's company, and added the same two keys to `organizations`,
-- whose own tenant column is called `id` and which could default its
-- invoices to another company's SST code.
--
-- It also closed `escalate_ticket`, which is not a join table at all
-- and was found in the same sweep: it wrote `tickets.assignee_id`
-- without asking whether the person works here, while its sister
-- `assign_ticket` -- writing the SAME column -- had always asked.
-- `assignee_id` points at `auth.users`, which is platform-wide and
-- carries no company, so no key can hold it and the question has to be
-- asked in the function.
--
-- Every refusal below is compared by its WHOLE message, for the reason
-- deposits.sql sets out: several are belt to the schema's braces, and
-- the whole message is the only thing that tells the two apart. A
-- fragment match would pass against the raw constraint error.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  a uuid; b uuid;
  wh_a uuid; wh_b uuid; wi_a uuid; wi_b uuid;
  out_a uuid; out_b uuid; item_a uuid; item_b uuid;
  sched uuid; promo uuid;
  tk uuid; team_a uuid; stranger uuid; mate uuid;
  cust_b uuid; asset_b uuid;
  tax_a uuid; tax_b uuid;
  v_msg text; v_off text; v_n integer;
begin
  a := pg_temp.test_org('Two Companies A');
  b := pg_temp.test_org('Two Companies B');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  insert into public.warehouses (org_id, code, name) values (a,'M','A store') returning id into wh_a;
  insert into public.warehouses (org_id, code, name) values (b,'M','B store') returning id into wh_b;
  insert into public.contacts (org_id, code, name, contact_type)
    values (a,'WI','A counter','customer') returning id into wi_a;
  insert into public.contacts (org_id, code, name, contact_type)
    values (b,'WI','B counter','customer') returning id into wi_b;
  insert into public.contacts (org_id, code, name, contact_type)
    values (b,'CUST','A customer of B''s','customer') returning id into cust_b;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
    values (a,'NASI','A''s nasi lemak','stock',true,'C62',5,2) returning id into item_a;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
    values (b,'NASI','B''s nasi lemak','stock',true,'C62',5,2) returning id into item_b;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
    values (a,'S','A''s shop','food_beverage',wh_a,wi_a,false) returning id into out_a;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
    values (b,'S','B''s shop','food_beverage',wh_b,wi_b,false) returning id into out_b;

  -- ==================================================================
  -- 1. A shop's timetable is over its own dishes
  -- ==================================================================
  begin
    perform public.upsert_pos_menu_schedule(
      a, 'Breakfast', array[1,2,3,4,5,6,7]::smallint[],
      '07:00'::time, '11:00'::time, null, null, array[item_b]);
    raise exception
      'a company was allowed to put another company''s dish on its menu '
      'schedule';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a schedule naming another company''s dish is refused, in words',
      v_msg, 'No such dish on this company''s menu.');
  end;

  -- And nothing was written on the way to the refusal. The check runs
  -- before the insert deliberately: a bad list must not leave a
  -- half-built schedule behind it for somebody to find later.
  perform pg_temp.check_eq('and no schedule was left behind',
    (select count(*) from public.pos_menu_schedules where org_id = a), 0);

  -- The keys refuse it too, which is what makes the sentence above
  -- belt rather than the only thing holding the line. The client holds
  -- insert on this table directly.
  sched := public.upsert_pos_menu_schedule(
             a, 'Breakfast', array[1,2,3,4,5,6,7]::smallint[],
             '07:00'::time, '11:00'::time, null, null, array[item_a]);
  begin
    insert into public.pos_menu_schedule_items (org_id, schedule_id, item_id)
    values (a, sched, item_b);
    raise exception
      'a schedule row naming another company''s dish went in directly';
  exception
    when foreign_key_violation then null;
    when others then
      get stacked diagnostics v_msg = returned_sqlstate;
      if v_msg = 'P0001' then raise; end if;
      raise exception 'the direct-insert probe failed early: % %', v_msg, sqlerrm;
  end;

  -- Nor with somebody else's org_id on it: that would satisfy the item
  -- key and break the schedule key instead.
  begin
    insert into public.pos_menu_schedule_items (org_id, schedule_id, item_id)
    values (b, sched, item_b);
    raise exception
      'a schedule row was allowed to claim another company''s org';
  exception
    when foreign_key_violation then null;
    when others then
      get stacked diagnostics v_msg = returned_sqlstate;
      if v_msg = 'P0001' then raise; end if;
      raise exception 'the wrong-org probe failed early: % %', v_msg, sqlerrm;
  end;

  -- ==================================================================
  -- 2. And the question the counter asks is asked of its own company
  --
  -- A's breakfast schedule is shut outside its hours, so A's dish is
  -- off at A's shop. Asked about B's shop the same schedule must not
  -- count at all -- not because the dish is A's (pos_item_off is not
  -- given a company and cannot tell), but because the schedules it
  -- reads are the ones belonging to the outlet being asked about.
  -- Without `sc.org_id = v_org` this returns 'From 07:00' for a shop
  -- that has no timetable of its own.
  -- ==================================================================
  perform public.upsert_pos_menu_schedule(
    a, 'Small hours', array[1,2,3,4,5,6,7]::smallint[],
    '03:00'::time, '03:30'::time, null, null, array[item_a],
    sched, true);

  perform pg_temp.check_eq('B''s shop has no timetable, so nothing is off',
    coalesce(app.pos_item_off(item_a, out_b), '(on)'), '(on)');

  -- ==================================================================
  -- 3. A promotion's scope, both lists, separately
  -- ==================================================================
  begin
    perform public.upsert_pos_promotion(
      a, 'Ten off', 'percent_off', null, 10, 0, 0, 0,
      null, null, null, null, null, 0, null, null,
      array[item_b], null);
    raise exception 'a promotion was allowed to name another company''s item';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a promotion naming another company''s item is refused, in words',
      v_msg, 'No such item in this company''s catalogue.');
  end;

  begin
    perform public.upsert_pos_promotion(
      a, 'Ten off', 'percent_off', null, 10, 0, 0, 0,
      null, null, null, null, null, 0, null, null,
      array[item_a], array[out_b]);
    raise exception 'a promotion was allowed to run in another company''s shop';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'and one naming another company''s outlet, differently',
      v_msg, 'No such outlet in this company.');
  end;

  -- Its own item in its own shop still saves, or the two refusals above
  -- are satisfied by a function that refuses everything.
  promo := public.upsert_pos_promotion(
             a, 'Ten off', 'percent_off', null, 10, 0, 0, 0,
             null, null, null, null, null, 0, null, null,
             array[item_a], array[out_a]);
  perform pg_temp.check_eq('its own item and its own shop go in',
    (select count(*)::numeric from public.pos_promotion_items
      where promotion_id = promo), 1);
  perform pg_temp.check_eq('and the scope row carries the company',
    (select org_id from public.pos_promotion_items
      where promotion_id = promo limit 1), a);

  -- ==================================================================
  -- 4. Escalating a ticket to somebody who works here
  -- ==================================================================
  tk := public.create_ticket(a, 'The printer again');
  insert into public.ticket_teams (org_id, code, name)
    values (a, 'DESK', 'A''s desk') returning id into team_a;
  stranger := pg_temp.another_user('two-companies-stranger@example.com');
  perform pg_temp.sign_in_as(pg_temp.test_user());

  begin
    perform public.escalate_ticket(tk, 'hierarchic', null, stranger, 'up');
    raise exception
      'a ticket was escalated to somebody who does not work at the company';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'escalating to a stranger is refused, in the words assign_ticket uses',
      v_msg, 'That person is not an active member of this organization');
  end;

  perform pg_temp.check_eq('and the ticket was not escalated anyway',
    (select escalation_level::numeric from public.tickets where id = tk), 0);

  -- Somebody who does work here still gets it.
  select user_id into mate from public.org_members
   where org_id = a and status = 'active' limit 1;
  perform public.escalate_ticket(tk, 'hierarchic', null, mate, 'up');
  perform pg_temp.check_eq('a colleague can be escalated to',
    (select assignee_id from public.tickets where id = tk), mate);
  perform pg_temp.check_eq('and the level moved',
    (select escalation_level::numeric from public.tickets where id = tk), 1);

  -- ==================================================================
  -- 5. Raising one for a customer, and against an asset, this company has
  -- ==================================================================
  insert into public.fixed_assets
    (org_id, asset_no, name, acquisition_date, cost, residual_value,
     method, useful_life_months)
    values (b, 'FA-1', 'B''s printer', app.today(), 1000, 0,
            'straight_line', 60)
  returning id into asset_b;

  begin
    perform public.create_ticket(a, 'x', p_requester_contact_id => cust_b);
    raise exception 'a ticket was raised for another company''s customer';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a ticket for another company''s customer is refused, in words',
      v_msg, 'No such contact.');
  end;

  begin
    perform public.create_ticket(a, 'x', p_asset_id => asset_b);
    raise exception 'a ticket was raised against another company''s asset';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'and one against another company''s asset',
      v_msg, 'No such asset.');
  end;

  -- ==================================================================
  -- 6. A company's default tax code is one of its own
  --
  -- `organizations` is the one table whose tenant column is `id`, so
  -- the whole-schema query in tenant_foreign_keys.sql could not see it
  -- either -- from that query's point of view the table has no org_id.
  -- ==================================================================
  insert into public.tax_codes (org_id, code, name, rate, tax_type_code)
    values (a, 'SST-A', 'A''s service tax', 6, '01')
  returning id into tax_a;
  insert into public.tax_codes (org_id, code, name, rate, tax_type_code)
    values (b, 'SST-B', 'B''s service tax', 6, '01')
  returning id into tax_b;

  begin
    update public.organizations set default_sales_tax_code_id = tax_b
     where id = a;
    raise exception
      'a company was allowed to default its invoices to another '
      'company''s tax code';
  exception
    when foreign_key_violation then null;
    when others then
      get stacked diagnostics v_msg = returned_sqlstate;
      if v_msg = 'P0001' then raise; end if;
      raise exception 'the tax code probe failed early: % %', v_msg, sqlerrm;
  end;

  update public.organizations set default_sales_tax_code_id = tax_a where id = a;
  perform pg_temp.check_eq('its own tax code is accepted',
    (select default_sales_tax_code_id from public.organizations where id = a),
    tax_a);

  -- And deleting it empties the default rather than raising. A
  -- composite `on delete set null` with no column list would try to
  -- null `id` as well -- 0511's defect, and the reason 0522 names the
  -- column.
  delete from public.tax_codes where id = tax_a;
  perform pg_temp.check_true('deleting it empties the default, and the company lives',
    (select default_sales_tax_code_id is null from public.organizations where id = a));

  raise notice 'two companies on one row: every probe behaved';
end $$;

rollback;
