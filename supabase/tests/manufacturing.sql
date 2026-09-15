-- =====================================================================
-- iAkauntan :: manufacturing
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/manufacturing.sql
--
-- A manufacturing order is not a note about work. It takes components
-- out of stock, absorbs the cost of the time spent, and puts a finished
-- thing back in — and the ledger has to say the same thing the stock
-- report says, to the sen, or the two disagree with each other forever.
--
-- The numbers here are deliberately round so a person can check them
-- without a calculator:
--
--   a chair is 4 boards at RM 12.00 and 8 screws at RM 0.50
--     = RM 48.00 + RM 4.00 = RM 52.00 of components;
--   half an hour of assembly at RM 60.00 an hour = RM 30.00 of
--     conversion;
--   so a chair costs RM 82.00 to make, and ten of them RM 820.00.
--
-- If any of those move, this file fails, which is the point.
--
-- Everything that touches a policy runs as `authenticated`: the
-- connection is a superuser and a superuser bypasses row level security.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

-- ---------------------------------------------------------------------
-- A furniture company with parts on the shelf and a recipe
-- ---------------------------------------------------------------------
create or replace function pg_temp.mfg_org(p_name text)
returns uuid language plpgsql as $$
declare v_org uuid;
begin
  v_org := pg_temp.test_org(p_name);
  perform public.create_fiscal_year(v_org, date '2026-01-01');
  perform app.default_warehouse(v_org);
  return v_org;
end; $$;

create or replace function pg_temp.stocked(
  p_org uuid, p_code text, p_qty numeric, p_cost numeric)
returns uuid language plpgsql as $$
declare v_item uuid;
begin
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (p_org, p_code, p_code, 'stock', true, 'C62', p_cost)
  returning id into v_item;

  if p_qty > 0 then
    insert into public.stock_movements
      (org_id, movement_no, movement_date, movement_type, item_id,
       warehouse_id, quantity, unit_cost)
    values (p_org, 'OPEN-' || p_code, date '2026-01-01', 'opening_balance',
            v_item, app.default_warehouse(p_org), p_qty, p_cost);
  end if;
  return v_item;
end; $$;

-- The recipe, its operation, and the item it makes, all in one place so
-- each test below reads as the thing it is testing rather than as
-- twenty lines of setup.
create or replace function pg_temp.chair_bom(
  p_org uuid, p_board uuid, p_screw uuid, p_chair uuid,
  p_scrap numeric default 0)
returns uuid language plpgsql as $$
declare v_bom uuid; v_wc uuid;
begin
  insert into public.bills_of_materials
    (org_id, item_id, code, name, output_quantity)
  values (p_org, p_chair, 'BOM-CHAIR', 'Chair', 1) returning id into v_bom;

  insert into public.bom_lines
    (org_id, bom_id, line_no, item_id, quantity, scrap_percent)
  values (p_org, v_bom, 1, p_board, 4, p_scrap),
         (p_org, v_bom, 2, p_screw, 8, 0);

  insert into public.work_centres (org_id, code, name, cost_per_hour)
  values (p_org, 'ASSY', 'Assembly', 60) returning id into v_wc;

  insert into public.bom_operations
    (org_id, bom_id, step_no, work_centre_id, name, minutes)
  values (p_org, v_bom, 1, v_wc, 'Assemble', 30);

  return v_bom;
end; $$;

create or replace function pg_temp.order_for(
  p_org uuid, p_bom uuid, p_chair uuid, p_qty numeric)
returns uuid language plpgsql as $$
declare v_mo uuid;
begin
  insert into public.manufacturing_orders
    (org_id, order_no, bom_id, item_id, warehouse_id, quantity)
  values (p_org, 'MO-' || substr(gen_random_uuid()::text, 1, 6), p_bom,
          p_chair, app.default_warehouse(p_org), p_qty)
  returning id into v_mo;
  return v_mo;
end; $$;

-- ---------------------------------------------------------------------
-- Ten chairs, start to finish
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Perabot Ujian Sdn Bhd');
  v_board uuid := pg_temp.stocked(v_org, 'BOARD', 100, 12);
  v_screw uuid := pg_temp.stocked(v_org, 'SCREW', 1000, 0.5);
  v_chair uuid := pg_temp.stocked(v_org, 'CHAIR', 0, 0);
  v_bom uuid := pg_temp.chair_bom(v_org, v_board, v_screw, v_chair);
  v_mo uuid := pg_temp.order_for(v_org, v_bom, v_chair, 10);
  v_entry uuid;
begin
  -- Confirming takes the snapshot. It is a snapshot on purpose: the
  -- recipe may change tomorrow and this order was costed against the one
  -- that existed today.
  perform public.confirm_manufacturing_order(v_mo);

  perform pg_temp.check_eq('the order needs two components',
    (select count(*) from public.mo_components where mo_id = v_mo), 2);
  perform pg_temp.check_eq('forty boards',
    (select quantity_required from public.mo_components
      where mo_id = v_mo and item_id = v_board), 40);
  perform pg_temp.check_eq('and eighty screws',
    (select quantity_required from public.mo_components
      where mo_id = v_mo and item_id = v_screw), 80);
  perform pg_temp.check_eq('five hours of assembly, in minutes',
    (select planned_minutes from public.mo_operations where mo_id = v_mo), 300);
  perform pg_temp.check_eq('and nothing is short',
    (select coalesce(sum(quantity_short), 0) from public.mo_shortages(v_mo)), 0);

  v_entry := public.post_manufacturing_order(v_mo);

  -- What it cost.
  perform pg_temp.check_eq('components consumed',
    (select component_cost from public.manufacturing_orders where id = v_mo),
    520);
  perform pg_temp.check_eq('conversion absorbed',
    (select conversion_cost from public.manufacturing_orders where id = v_mo),
    300);

  -- What is on the shelf afterwards.
  perform pg_temp.check_eq('sixty boards left',
    (select quantity_on_hand from public.items where id = v_board), 60);
  perform pg_temp.check_eq('nine hundred and twenty screws left',
    (select quantity_on_hand from public.items where id = v_screw), 920);
  perform pg_temp.check_eq('ten chairs made',
    (select quantity_on_hand from public.items where id = v_chair), 10);
  perform pg_temp.check_eq('each carried at what it cost to make',
    (select average_cost from public.items where id = v_chair), 82);

  -- And what the ledger says about it. The finished value goes on to
  -- inventory, the components come off it, and the difference is the
  -- conversion — taken back out of the profit and loss so the wages
  -- already expensed when they were paid are not counted a second time.
  perform pg_temp.check_eq('the journal balances, debits',
    (select sum(debit) from public.gl_lines where entry_id = v_entry), 820);
  perform pg_temp.check_eq('and credits',
    (select sum(credit) from public.gl_lines where entry_id = v_entry), 820);
  perform pg_temp.check_eq('inventory is up by the conversion cost',
    (select sum(l.debit - l.credit) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '1310'), 300);
  perform pg_temp.check_eq('which is exactly what was absorbed',
    (select sum(l.credit) from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_entry and a.code = '5350'), 300);

  perform pg_temp.check_true('and the order knows its journal',
    (select gl_entry_id from public.manufacturing_orders where id = v_mo)
      = v_entry);
end $$;

-- ---------------------------------------------------------------------
-- A short run consumes proportionally less
--
-- The one that is easy to get wrong, and expensive: costing the whole
-- recipe against half an output carries the finished goods at twice what
-- they are worth, and nothing downstream will notice until the year end.
-- The unit cost is the assertion — it must not move when the run does.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Separuh Jalan Sdn Bhd');
  v_board uuid := pg_temp.stocked(v_org, 'BOARD', 100, 12);
  v_screw uuid := pg_temp.stocked(v_org, 'SCREW', 1000, 0.5);
  v_chair uuid := pg_temp.stocked(v_org, 'CHAIR', 0, 0);
  v_bom uuid := pg_temp.chair_bom(v_org, v_board, v_screw, v_chair);
  v_mo uuid := pg_temp.order_for(v_org, v_bom, v_chair, 10);
begin
  perform public.confirm_manufacturing_order(v_mo);
  -- Ten were ordered; six came off the line.
  perform public.post_manufacturing_order(v_mo, 6);

  perform pg_temp.check_eq('six chairs, not ten',
    (select quantity_done from public.manufacturing_orders where id = v_mo), 6);
  perform pg_temp.check_eq('six chairs'' worth of components',
    (select component_cost from public.manufacturing_orders where id = v_mo),
    312);
  perform pg_temp.check_eq('and six chairs'' worth of time',
    (select conversion_cost from public.manufacturing_orders where id = v_mo),
    180);
  perform pg_temp.check_eq('twenty-four boards used',
    (select quantity_on_hand from public.items where id = v_board), 76);
  perform pg_temp.check_eq('a chair still costs what a chair costs',
    (select average_cost from public.items where id = v_chair), 82);
end $$;

-- ---------------------------------------------------------------------
-- Booked time beats planned time
--
-- A shop that records its hours is costed on the hours it recorded. One
-- that does not still has to cost its output, so the plan stands in.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Lebih Masa Sdn Bhd');
  v_board uuid := pg_temp.stocked(v_org, 'BOARD', 100, 12);
  v_screw uuid := pg_temp.stocked(v_org, 'SCREW', 1000, 0.5);
  v_chair uuid := pg_temp.stocked(v_org, 'CHAIR', 0, 0);
  v_bom uuid := pg_temp.chair_bom(v_org, v_board, v_screw, v_chair);
  v_mo uuid := pg_temp.order_for(v_org, v_bom, v_chair, 10);
begin
  perform public.confirm_manufacturing_order(v_mo);

  -- It took eight hours, not five.
  update public.mo_operations set actual_minutes = 480 where mo_id = v_mo;
  perform public.post_manufacturing_order(v_mo);

  perform pg_temp.check_eq('costed on the hours actually worked',
    (select conversion_cost from public.manufacturing_orders where id = v_mo),
    480);
  perform pg_temp.check_eq('so the chairs cost more',
    (select average_cost from public.items where id = v_chair), 100);
end $$;

-- ---------------------------------------------------------------------
-- Scrap is added, not deducted
--
-- A process that wastes one board in twenty needs twenty-one. A plan
-- that issues twenty is a plan that stops halfway through the morning.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Buang Sisa Sdn Bhd');
  v_board uuid := pg_temp.stocked(v_org, 'BOARD', 100, 12);
  v_screw uuid := pg_temp.stocked(v_org, 'SCREW', 1000, 0.5);
  v_chair uuid := pg_temp.stocked(v_org, 'CHAIR', 0, 0);
  -- Five per cent of the boards are spoiled.
  v_bom uuid := pg_temp.chair_bom(v_org, v_board, v_screw, v_chair, 5);
  v_mo uuid := pg_temp.order_for(v_org, v_bom, v_chair, 10);
begin
  perform public.confirm_manufacturing_order(v_mo);

  -- 40 / 0.95 = 42.1053, more than forty and not less.
  perform pg_temp.check_eq('more boards are issued than the recipe names',
    (select quantity_required from public.mo_components
      where mo_id = v_mo and item_id = v_board), 42.1053);
  perform pg_temp.check_eq('the line without scrap is untouched',
    (select quantity_required from public.mo_components
      where mo_id = v_mo and item_id = v_screw), 80);
end $$;

-- ---------------------------------------------------------------------
-- What is missing, before the line starts
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Kurang Bahan Sdn Bhd');
  -- Ten boards on the shelf, forty needed.
  v_board uuid := pg_temp.stocked(v_org, 'BOARD', 10, 12);
  v_screw uuid := pg_temp.stocked(v_org, 'SCREW', 1000, 0.5);
  v_chair uuid := pg_temp.stocked(v_org, 'CHAIR', 0, 0);
  v_bom uuid := pg_temp.chair_bom(v_org, v_board, v_screw, v_chair);
  v_mo uuid := pg_temp.order_for(v_org, v_bom, v_chair, 10);
  v_short numeric;
begin
  perform public.confirm_manufacturing_order(v_mo);

  select quantity_short into v_short
    from public.mo_shortages(v_mo) where item_id = v_board;
  perform pg_temp.check_eq('thirty boards short', v_short, 30);

  select quantity_short into v_short
    from public.mo_shortages(v_mo) where item_id = v_screw;
  perform pg_temp.check_eq('and no screws short', v_short, 0);
end $$;

-- ---------------------------------------------------------------------
-- What a manufacturing order refuses
--
-- Each refusal is paired with the thing that should work, because an
-- assertion that only checks "was this refused?" passes for any reason a
-- statement can fail — including a typo in the test.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Tolak Sdn Bhd');
  v_board uuid := pg_temp.stocked(v_org, 'BOARD', 100, 12);
  v_screw uuid := pg_temp.stocked(v_org, 'SCREW', 1000, 0.5);
  v_chair uuid := pg_temp.stocked(v_org, 'CHAIR', 0, 0);
  v_bom uuid := pg_temp.chair_bom(v_org, v_board, v_screw, v_chair);
  v_mo uuid := pg_temp.order_for(v_org, v_bom, v_chair, 10);
  v_refused boolean;
begin
  -- A draft has no components snapshotted yet, so posting it would post
  -- nothing at all and call it a finished order.
  begin
    perform public.post_manufacturing_order(v_mo);
    v_refused := false;
  exception when sqlstate '22023' then v_refused := true;
  end;
  perform pg_temp.check_true('a draft order cannot be posted', v_refused);

  perform public.confirm_manufacturing_order(v_mo);

  begin
    perform public.confirm_manufacturing_order(v_mo);
    v_refused := false;
  exception when sqlstate '22023' then v_refused := true;
  end;
  perform pg_temp.check_true('and cannot be confirmed twice', v_refused);

  -- The positive control: confirmed, it posts.
  perform pg_temp.check_true('a confirmed order posts',
    public.post_manufacturing_order(v_mo) is not null);

  -- Twice would issue the components twice and credit the absorption
  -- account twice, against one lot of chairs.
  begin
    perform public.post_manufacturing_order(v_mo);
    v_refused := false;
  exception when sqlstate '22023' then v_refused := true;
  end;
  perform pg_temp.check_true('but not a second time', v_refused);
end $$;

-- ---------------------------------------------------------------------
-- Who may post one
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Siapa Boleh Sdn Bhd');
  v_board uuid := pg_temp.stocked(v_org, 'BOARD', 100, 12);
  v_screw uuid := pg_temp.stocked(v_org, 'SCREW', 1000, 0.5);
  v_chair uuid := pg_temp.stocked(v_org, 'CHAIR', 0, 0);
  v_bom uuid := pg_temp.chair_bom(v_org, v_board, v_screw, v_chair);
  v_mo uuid := pg_temp.order_for(v_org, v_bom, v_chair, 10);
  v_owner uuid := pg_temp.test_user();
  v_auditor uuid := pg_temp.another_user('auditor@perabot.test');
  v_refused boolean;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_auditor, 'auditor');

  perform pg_temp.sign_in_as(v_auditor);
  begin
    perform public.confirm_manufacturing_order(v_mo);
    v_refused := false;
  exception when sqlstate '42501' then v_refused := true;
  end;
  perform pg_temp.check_true('an auditor does not confirm production',
    v_refused);

  -- The control: the same call, by somebody who may.
  perform pg_temp.sign_in_as(v_owner);
  perform public.confirm_manufacturing_order(v_mo);
  perform pg_temp.check_eq('the owner does',
    (select count(*) from public.mo_components where mo_id = v_mo), 2);

  perform pg_temp.sign_in_as(v_auditor);
  begin
    perform public.post_manufacturing_order(v_mo);
    v_refused := false;
  exception when sqlstate '42501' then v_refused := true;
  end;
  perform pg_temp.check_true('nor posts one', v_refused);

  perform pg_temp.sign_in_as(v_owner);
end $$;

-- ---------------------------------------------------------------------
-- One company's recipe is not another's
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid := pg_temp.mfg_org('Kilang A Sdn Bhd');
  v_b uuid := pg_temp.mfg_org('Kilang B Sdn Bhd');
  v_chair uuid := pg_temp.stocked(v_a, 'CHAIR', 0, 0);
  v_board uuid := pg_temp.stocked(v_a, 'BOARD', 100, 12);
  v_screw uuid := pg_temp.stocked(v_a, 'SCREW', 1000, 0.5);
  v_bom uuid := pg_temp.chair_bom(v_a, v_board, v_screw, v_chair);
  v_outsider uuid := pg_temp.another_user('outsider@kilang.test');
  v_sees int;
  v_role text;
begin
  -- Somebody who belongs to B and not to A.
  insert into public.org_members (org_id, user_id, role)
  values (v_b, v_outsider, 'accountant');

  perform pg_temp.sign_in_as(v_outsider);
  begin
    set local role authenticated;
    v_role := current_user;
    select count(*) into v_sees
      from public.bills_of_materials where org_id = v_a;
  end;
  reset role;

  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_eq('another company''s bill of materials is not '
    'readable', v_sees, 0);

  -- The control: the owner of A can read it, so the zero above is the
  -- policy and not an empty table.
  perform pg_temp.sign_in_as(pg_temp.test_user());
  begin
    set local role authenticated;
    select count(*) into v_sees
      from public.bills_of_materials where org_id = v_a;
  end;
  reset role;
  perform pg_temp.check_eq('while its own is', v_sees, 1);

  perform pg_temp.check_true('and the bom exists', v_bom is not null);
end $$;

-- ---------------------------------------------------------------------
-- An order names its own company's branch
--
-- The column has a foreign key to `branches`, which refuses a branch
-- that does not exist and does not care whose it is — a foreign key
-- pointing at the right table looks exactly like a constraint that
-- works. This is what 0134 exists for, and the two controls are what
-- found it: without them "was it refused?" was answered yes by a
-- not-null violation on an unrelated column.
-- ---------------------------------------------------------------------
do $$
declare
  v_a uuid := pg_temp.mfg_org('Kilang Cawangan Sdn Bhd');
  v_b uuid := pg_temp.mfg_org('Kilang Lain Sdn Bhd');
  v_item_a uuid := pg_temp.stocked(v_a, 'WIDGET', 0, 0);
  v_item_b uuid := pg_temp.stocked(v_b, 'WIDGET', 0, 0);
  v_branch uuid;
begin
  insert into public.branches (org_id, code, name)
  values (v_a, 'KL', 'Kuala Lumpur') returning id into v_branch;

  -- Control one: no branch at all is the ordinary case and has to stay
  -- ordinary, or this guard broke every company that never opens a
  -- second place.
  -- A control asserts the insert SUCCEEDS, so no handler: one that
  -- turned any error into `v_ok := false` reported a failing insert as
  -- the branch guard working, including a column renamed out from under
  -- it. Unhandled, the real error stops the file and names itself.
  insert into public.manufacturing_orders
    (org_id, order_no, item_id, warehouse_id, quantity)
  values (v_b, 'MO-NONE', v_item_b, app.default_warehouse(v_b), 1);
  raise notice 'ok   an order with no branch is fine';

  -- Control two: its own company's branch is the point of the feature.
  insert into public.manufacturing_orders
    (org_id, order_no, item_id, warehouse_id, quantity, branch_id)
  values (v_a, 'MO-OWN', v_item_a, app.default_warehouse(v_a), 1, v_branch);
  raise notice 'ok   and its own company''s branch is fine';

  -- The one that matters.
  -- And the refusal on its words. 23514 is a check constraint and this
  -- insert could fail one for several reasons that are not the branch.
  perform pg_temp.check_refused(
    'but another company''s branch is refused',
    format($q$ insert into public.manufacturing_orders
                 (org_id, order_no, item_id, warehouse_id, quantity,
                  branch_id)
               values (%L, 'MO-BORROWED', %L, %L, 1, %L) $q$,
           v_b, v_item_b, app.default_warehouse(v_b), v_branch),
    '%branch belongs to another company%', '23514');
end $$;

-- ---------------------------------------------------------------------
-- The absorption account is made, not assumed
--
-- The seeded chart of accounts is a fixed list written long before this
-- module existed. A company created after it must still be able to post
-- its first order.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.mfg_org('Akaun Baru Sdn Bhd');
  v_id uuid;
begin
  delete from public.accounts where org_id = v_org and code = '5350';
  perform pg_temp.check_eq('a fresh company has none yet',
    (select count(*) from public.accounts
      where org_id = v_org and code = '5350'), 0);

  v_id := app.absorption_account(v_org);
  perform pg_temp.check_true('so it is created on first use',
    v_id is not null);
  perform pg_temp.check_true('under cost of sales',
    (select account_subtype = 'cost_of_sales' and not is_group
       from public.accounts where id = v_id));
  perform pg_temp.check_true('below the cost of sales heading',
    (select p.code from public.accounts a
       join public.accounts p on p.id = a.parent_id where a.id = v_id)
      = '5000');

  -- And asking twice does not make two.
  perform pg_temp.check_true('and asked again, reused rather than remade',
    app.absorption_account(v_org) = v_id);
end $$;

-- ---------------------------------------------------------------------
-- Reachability
-- ---------------------------------------------------------------------
do $$
begin
  perform pg_temp.check_true('posting is closed to anon',
    not has_function_privilege('anon',
      'public.post_manufacturing_order(uuid, numeric)', 'execute'));
  perform pg_temp.check_true('and confirming is',
    not has_function_privilege('anon',
      'public.confirm_manufacturing_order(uuid)', 'execute'));
  perform pg_temp.check_true('while a signed-in member may post',
    has_function_privilege('authenticated',
      'public.post_manufacturing_order(uuid, numeric)', 'execute'));
  perform pg_temp.check_true('the absorption account resolver is internal',
    not has_function_privilege('authenticated',
      'app.absorption_account(uuid)', 'execute'));
  perform pg_temp.check_true('and the tables are reachable through the api',
    has_table_privilege('authenticated', 'public.manufacturing_orders',
      'select'));
end $$;


-- ---------------------------------------------------------------------
-- The eight a mutation sweep found
-- ---------------------------------------------------------------------
-- Twenty-seven one-line mutants of `post_manufacturing_order` against
-- eleven test files. Nineteen died on the first run, and they are all
-- the COSTING: the ratio for a short run, components scaled and issued
-- with the right sign, actual minutes preferred over planned, planned
-- minutes scaled, the work centre's rate, minutes costed as minutes,
-- conversion added to what the goods cost, finished goods received at a
-- unit cost rather than a total, and every direction in the journal.
--
-- The eight that survived are the front door and the state machine --
-- the same split payroll showed an hour ago, where every rate held and
-- the eligibility flags and ceilings did not. THE ARITHMETIC GETS
-- ASSERTED; WHAT SURROUNDS IT DOES NOT.
--
-- Two of the eight are a pair worth naming, because each is only
-- invisible while the other works.
--
--   `if v_mo.posted_at is not null` and `if v_mo.status not in
--   ('confirmed', 'in_progress')` both refuse a second posting, and the
--   update at the end sets both. Break either one alone and the other
--   still refuses; break the state it reads and the other guard covers
--   for it. So the existing "but not a second time" assertion passes
--   against three of the four mutations in that square.
--
-- The answer is to assert the WHOLE message of the refusal, so that
-- which guard fired is part of what is asserted, and to assert the
-- state itself rather than only its consequence. Both are done below.
-- A second posting would double the finished goods on hand and credit
-- the components twice, so this is the square worth being careful in.
do $$
declare
  v_org   uuid;
  v_owner uuid := pg_temp.test_user();
  v_wh    uuid;
  v_flour uuid;
  v_bread uuid;
  v_bom   uuid;
  v_mo    uuid;
  v_group uuid;
  v_msg   text;
  v_qty   numeric;
begin
  perform pg_temp.sign_in_as(v_owner);
  v_org := pg_temp.test_org('Kilang Sapu Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', app.today())::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','manufacturing','accounting']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'KILANG', 'Factory', true) returning id into v_wh;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, cost_price)
  values (v_org, 'TEPUNG', 'Flour', 'stock', true, 'KGM', 2.00)
  returning id into v_flour;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'ROTI', 'Bread', 'stock', true, 'C62')
  returning id into v_bread;

  -- Stock to consume.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'OPEN-1', app.today(), 'opening_balance', v_flour, v_wh, 100, 2.00);

  insert into public.bills_of_materials
    (org_id, item_id, code, name, output_quantity, is_active)
  values (v_org, v_bread, 'BOM-1', 'Bread', 10, true) returning id into v_bom;
  insert into public.bom_lines (org_id, bom_id, line_no, item_id, quantity)
  values (v_org, v_bom, 1, v_flour, 20);

  -- ==================================================================
  -- 1. The front door
  -- ==================================================================
  begin
    perform public.post_manufacturing_order(gen_random_uuid());
    raise exception 'an order that does not exist was posted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('an order that is not there is refused',
      v_msg, 'No such manufacturing order');
  end;

  insert into public.manufacturing_orders
    (org_id, order_no, item_id, bom_id, warehouse_id, quantity, status)
  values (v_org, 'MO-SAPU-1', v_bread, v_bom, v_wh, 10, 'draft')
  returning id into v_mo;
  insert into public.mo_components
    (org_id, mo_id, item_id, quantity_required)
  values (v_org, v_mo, v_flour, 20);

  perform public.confirm_manufacturing_order(v_mo);

  begin
    perform public.post_manufacturing_order(v_mo, 0);
    raise exception 'an order producing nothing was posted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('an order that produced nothing is refused',
      v_msg, 'Nothing was produced');
  end;

  begin
    perform public.post_manufacturing_order(v_mo, -5);
    raise exception 'an order producing less than nothing was posted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('and so is one producing less than nothing',
      v_msg, 'Nothing was produced');
  end;

  -- ==================================================================
  -- 2. Posting, and the state it leaves behind
  --
  -- Asserted as state and not only as consequence, because the guard
  -- that reads this state and the guard beside it cover for each other.
  -- ==================================================================
  perform public.post_manufacturing_order(v_mo);

  perform pg_temp.check_eq('a posted order is done',
    (select status::text from public.manufacturing_orders where id = v_mo),
    'done');
  perform pg_temp.check_true('and carries the day it was posted',
    (select posted_at is not null from public.manufacturing_orders
      where id = v_mo));
  perform pg_temp.check_eq('and what each component actually gave up',
    (select quantity_issued from public.mo_components where mo_id = v_mo),
    20::numeric);

  -- The second posting is refused by the posted_at guard, and the WHOLE
  -- message is what says so. Refused by the status guard instead, the
  -- message is 'Only a confirmed order can be posted; this one is done'
  -- -- true, and a different sentence, and the difference is the whole
  -- assertion.
  begin
    perform public.post_manufacturing_order(v_mo);
    raise exception 'a manufacturing order was posted twice';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'a second posting is refused, by the guard that reads posted_at',
      v_msg, 'This order has already been posted');
  end;

  -- And nothing moved twice: the finished goods on hand are one run's
  -- worth, not two.
  select coalesce(sum(quantity), 0) into v_qty
    from public.stock_movements
   where org_id = v_org and item_id = v_bread;
  perform pg_temp.check_eq('so the finished goods are one run, not two',
    v_qty, 10::numeric);

  -- ==================================================================
  -- 3. The inventory account is a posting account, and there is one
  --
  -- The lookup is `code = '1310' and not is_group`, and the null check
  -- below it. Both were unasserted, and they are asserted together
  -- because one fixture reaches both: make 1310 a heading and the
  -- lookup finds nothing.
  --
  -- Without `not is_group` the heading is used, and the run's whole
  -- value is posted to an account that is a total of its children --
  -- where no report adds it up, and where the trial balance
  -- double-counts it against the detail beneath. Without the null check
  -- the failure arrives from inside create_gl_entry_internal, as a
  -- constraint on a column nobody mentioned.
  -- ==================================================================
  insert into public.manufacturing_orders
    (org_id, order_no, item_id, bom_id, warehouse_id, quantity, status)
  values (v_org, 'MO-SAPU-2', v_bread, v_bom, v_wh, 10, 'draft')
  returning id into v_mo;
  insert into public.mo_components
    (org_id, mo_id, item_id, quantity_required)
  values (v_org, v_mo, v_flour, 20);
  perform public.confirm_manufacturing_order(v_mo);

  perform pg_temp.check_true('1310 is a posting account, as seeded',
    (select not is_group from public.accounts
      where org_id = v_org and code = '1310'));
  update public.accounts set is_group = true
   where org_id = v_org and code = '1310';

  begin
    perform public.post_manufacturing_order(v_mo);
    raise exception
      'a manufacturing order posted its inventory to a heading';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq(
      'with no posting account for inventory, the order refuses in words',
      v_msg, 'The chart of accounts has no inventory account');
  end;

  update public.accounts set is_group = false
   where org_id = v_org and code = '1310';
  perform pg_temp.check_true('and posts once there is one again',
    public.post_manufacturing_order(v_mo) is not null);

  raise notice 'ok   manufacturing: the eight a sweep found';
end $$;

rollback;
