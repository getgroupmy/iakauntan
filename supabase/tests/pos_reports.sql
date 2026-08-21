-- =====================================================================
-- Point of sale :: a report somebody builds
--
-- The assertion this file is built around is the one that decides
-- whether a report builder is safe to have at all: nothing a person
-- types reaches the SQL. Every dimension and every measure is a key in
-- an allow-list, a key that is not on it raises rather than being
-- interpolated, and this file tries the obvious injection and checks it
-- comes back as a refusal rather than as a query.
--
-- The second is that a saved period is a word. A report saved as "last
-- month" means last month whenever it is opened, not the two dates that
-- happened to be true on the day it was built.
--
-- The third is that the arithmetic is the same arithmetic: what the
-- builder totals for a day has to equal what `pos_day_board` says the
-- shop took that day, or the shop has two answers and no way to choose.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_other  uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_item   uuid;
  v_drink  uuid;
  v_outlet uuid;
  v_out2   uuid;
  v_reg    uuid;
  v_reg2   uuid;
  v_cash   uuid;
  v_sale   uuid;
  v_rep    uuid;
  v_mine   uuid;
  v_row    record;
  v_head   record;
  v_board  record;
  v_n      integer;
  v_kl     date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  v_org := pg_temp.test_org('Kedai Laporan Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Store') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'NASI', 'Nasi lemak', 'service', false, 'C62', 12.00, 5.00)
  returning id into v_item;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price, cost_price)
  values (v_org, 'TEH', 'Teh tarik', 'service', false, 'C62', 3.00, 1.00)
  returning id into v_drink;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'BANGSAR', 'Bangsar', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id, prices_include_tax)
  values (v_org, 'CHERAS', 'Cheras', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_out2;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'Counter') returning id into v_reg;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_out2, 'C2', 'Branch counter') returning id into v_reg2;
  insert into public.pos_settings (org_id, round_cash_to_5sen) values (v_org, false);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer, gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;

  perform public.open_pos_shift(v_reg, 100.00);
  perform public.open_pos_shift(v_reg2, 100.00);

  -- Three bills at Bangsar and one at Cheras, so a report cut by outlet
  -- has something to say.
  for v_n in 1..3 loop
    v_sale := public.open_pos_sale(v_reg);
    perform public.add_pos_sale_line(v_sale, v_item, 2, 12.00);
    perform public.add_pos_sale_line(v_sale, v_drink, 1, 3.00);
    perform public.complete_pos_sale(v_sale, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 27.00)));
  end loop;
  v_sale := public.open_pos_sale(v_reg2);
  perform public.add_pos_sale_line(v_sale, v_drink, 4, 3.00);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object('type', v_cash, 'amount', 12.00)));

  -- ------------------------------------------------------------------
  -- Nothing a person types reaches the SQL
  -- ------------------------------------------------------------------
  -- The assertion this file exists for.
  begin
    perform public.upsert_pos_report(
      v_org, 'Injected', 'sales',
      array['s.total_amount) as x, (select current_setting(''x'')'],
      array['gross']);
    raise exception 'FAIL saved a report with SQL in a column name';
  exception when check_violation then
    raise notice 'ok   a column name that is not on the list is refused';
  end;

  begin
    perform public.upsert_pos_report(
      v_org, 'Injected', 'sales', array['outlet'],
      array['(select count(*) from auth.users)']);
    raise exception 'FAIL saved a report with SQL in a measure';
  exception when check_violation then
    raise notice 'ok   and so is a measure that is not on the list';
  end;

  begin
    perform public.upsert_pos_report(
      v_org, 'No period', 'sales', array['outlet'], array['gross'],
      'whenever_i_like');
    raise exception 'FAIL saved a report with a period nobody defined';
  exception when check_violation then
    raise notice 'ok   and a period this report does not know';
  end;

  begin
    perform public.upsert_pos_report(
      v_org, 'Item by day', 'sales', array['item'], array['gross']);
    raise exception 'FAIL grouped bills by something only a line has';
  exception when check_violation then
    raise notice 'ok   a dimension belongs to its own source';
  end;

  -- ------------------------------------------------------------------
  -- The report a shopkeeper actually wanted
  -- ------------------------------------------------------------------
  v_rep := public.upsert_pos_report(
    v_org, 'Takings by outlet', 'sales',
    array['outlet'], array['bills', 'gross', 'average_bill'],
    'today', null, null, '{}', '{}', 'gross', true, 200, true);

  select * into v_head from public.pos_report_headers(v_rep);
  perform pg_temp.check_eq('the columns are named for a person',
    v_head.dim_labels[1], 'Outlet');
  perform pg_temp.check_eq('and so are the numbers',
    v_head.val_labels[2], 'Takings');
  perform pg_temp.check_eq('and the period is resolved when it runs',
    v_head.from_date::text, v_kl::text);

  select count(*) into v_n from public.run_pos_report(v_rep);
  perform pg_temp.check_eq('a row per outlet that sold something', v_n, 2);

  select * into v_row from public.run_pos_report(v_rep) limit 1;
  perform pg_temp.check_eq('sorted with the biggest first',
    v_row.dims[1], 'Bangsar');
  perform pg_temp.check_eq('three bills at Bangsar', v_row.vals[1], 3);
  perform pg_temp.check_eq('and eighty-one ringgit', v_row.vals[2], 81.00);
  perform pg_temp.check_eq('and the average of them', v_row.vals[3], 27.00);

  -- The arithmetic has to be the same arithmetic. Two answers to "what
  -- did Bangsar take today" is one answer too many.
  select * into v_board from public.pos_day_board(v_org, v_kl) b
   where b.outlet_id = v_outlet;
  perform pg_temp.check_eq('and it agrees with the day board',
    v_row.vals[2], v_board.gross);

  -- ------------------------------------------------------------------
  -- The other kind of question
  -- ------------------------------------------------------------------
  v_rep := public.upsert_pos_report(
    v_org, 'What sells', 'lines',
    array['item'], array['quantity', 'gross'],
    'today', null, null, '{}', '{}', 'quantity', true);

  select * into v_row from public.run_pos_report(v_rep) limit 1;
  perform pg_temp.check_eq('the most-sold item is the one sold most',
    v_row.dims[1], 'Teh tarik');
  perform pg_temp.check_eq('by the quantity that went out',
    v_row.vals[1], 7);

  -- ------------------------------------------------------------------
  -- Narrowed to one shop
  -- ------------------------------------------------------------------
  v_rep := public.upsert_pos_report(
    v_org, 'Cheras only', 'lines',
    array['item'], array['gross'],
    'today', null, null, array[v_out2], '{}');
  select count(*) into v_n from public.run_pos_report(v_rep);
  perform pg_temp.check_eq('a report narrowed to one shop shows one shop',
    v_n, 1);

  -- ------------------------------------------------------------------
  -- One number is a report too
  -- ------------------------------------------------------------------
  v_rep := public.upsert_pos_report(
    v_org, 'What did we take', 'sales', '{}', array['gross'], 'today');
  select * into v_row from public.run_pos_report(v_rep);
  perform pg_temp.check_eq('a report with no dimensions is one row',
    v_row.dims[1], 'All');
  perform pg_temp.check_eq('and one number', v_row.vals[1], 93.00);

  -- ------------------------------------------------------------------
  -- A period is a word
  -- ------------------------------------------------------------------
  v_rep := public.upsert_pos_report(
    v_org, 'Last month', 'sales', '{}', array['gross'], 'last_month');
  select * into v_head from public.pos_report_headers(v_rep);
  perform pg_temp.check_eq('last month starts on the first of it',
    v_head.from_date::text,
    date_trunc('month', v_kl - interval '1 month')::date::text);
  perform pg_temp.check_eq('and ends on the last day of it',
    v_head.to_date::text,
    (date_trunc('month', v_kl) - interval '1 day')::date::text);
  perform pg_temp.check_eq('and a month with no trading is no rows',
    (select count(*) from public.run_pos_report(v_rep)), 0);

  -- ------------------------------------------------------------------
  -- A report somebody built for themselves
  -- ------------------------------------------------------------------
  v_other := pg_temp.another_user('nosey@laporan.test');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_other, 'sales');

  v_mine := public.upsert_pos_report(
    v_org, 'My own', 'sales', array['cashier'], array['gross'],
    'today', null, null, '{}', '{}', null, true, 200, false);

  perform pg_temp.check_eq('a private report is on its owner''s list',
    (select count(*) from public.pos_reports_list(v_org) l where l.id = v_mine), 1);

  perform pg_temp.sign_in_as(v_other);
  perform pg_temp.check_eq('and not on anybody else''s',
    (select count(*) from public.pos_reports_list(v_org) l where l.id = v_mine), 0);
  begin
    perform * from public.run_pos_report(v_mine);
    raise exception 'FAIL ran somebody else''s private report';
  exception when insufficient_privilege then
    raise notice 'ok   nor can anybody else run it';
  end;

  -- The shared ones are everybody's, which is the point of sharing.
  perform pg_temp.check_true('the shared ones are the company''s',
    (select count(*) from public.pos_reports_list(v_org)) >= 4);
  perform pg_temp.sign_in_as(v_owner);

  -- ------------------------------------------------------------------
  -- What the picker may offer
  -- ------------------------------------------------------------------
  -- The screen and the query read one list, so a column cannot be
  -- offered that the query would then refuse.
  perform pg_temp.check_true('every dimension offered can be grouped by',
    not exists (
      select 1 from public.pos_report_fields('sales') f
       where f.kind = 'dimension'
         and app.pos_report_dimension('sales', f.key) is null));
  perform pg_temp.check_true('and every measure offered can be added up',
    not exists (
      select 1 from public.pos_report_fields('lines') f
       where f.kind = 'measure'
         and app.pos_report_measure('lines', f.key) is null));

  -- ------------------------------------------------------------------
  -- And a report is a question, so it can be thrown away
  -- ------------------------------------------------------------------
  perform public.delete_pos_report(v_mine);
  perform pg_temp.check_eq('a deleted report is gone',
    (select count(*) from public.pos_reports where id = v_mine), 0);
end $$;

rollback;
