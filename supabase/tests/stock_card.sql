-- =====================================================================
-- iAkauntan :: the stock card
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/stock_card.sql
--
-- The stock card computes its running balance with a window function
-- rather than reading `stock_movements.balance_quantity`, which the
-- trigger already maintains. That is a deliberate second implementation
-- of the same arithmetic, and the only thing that makes a second
-- implementation safe is holding it against the first.
--
-- So the assertion this file exists for is: **for one warehouse, at
-- every movement, the computed balance equals the stored one** — both
-- quantity and value. Two routes to the same number.
--
-- An assertion that only counts disagreements passes when there is
-- nothing to disagree about, so it is paired with a count of the rows it
-- actually compared. A silent zero is the failure mode.
--
-- The other half of the argument is the case the stored column cannot
-- answer: across two warehouses the stored balance is per location and
-- the card's is not, and they must differ. That is why the running
-- figure is computed rather than read, and it is asserted rather than
-- asserted-about-in-a-comment.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.check_text(
  p_label text, p_actual text, p_expected text)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL %: expected %, got %',
      p_label, coalesce(p_expected, '(null)'), coalesce(p_actual, '(null)');
  end if;
  raise notice 'ok   % = %', p_label, coalesce(p_actual, '(null)');
end;
$$;

-- ---------------------------------------------------------------------
-- One item, two warehouses, five movements
--
-- Inserted in date order and in movement_no order, which is how they
-- arrive in life: the trigger computes each stored balance from the one
-- before it, so an out-of-order fixture would be testing the fixture.
-- Back-dating is the case where the two orderings part company, and the
-- stored column has nothing to say about it — see 0155's header.
-- ---------------------------------------------------------------------
create or replace function pg_temp.card_org()
returns uuid language plpgsql as $$
declare
  v_org  uuid := pg_temp.test_org('Stock Card Sdn Bhd');
  v_item uuid;
  v_a    uuid;
  v_b    uuid;
  v_adj  uuid;
begin
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.items (org_id, code, name, item_type, track_inventory,
                            uom_code, unit_price, cost_price)
  values (v_org, 'CARD-1', 'Widget', 'stock', true, 'C62', 20, 10)
  returning id into v_item;

  v_a := app.default_warehouse(v_org);
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'WH-B', 'Second Warehouse')
  returning id into v_b;

  -- Something to point a movement's source at, so the card's reference
  -- column has a document to find rather than only a note to fall back
  -- on. Both paths are asserted below.
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason,
     adjustment_type, status)
  values (v_org, 'ADJ-CARD-1', date '2026-04-02', v_a, 'Damaged',
          'write_off', 'draft')
  returning id into v_adj;

  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost, notes, source_table, source_id)
  values
    (v_org, 'SM-0001', date '2026-03-01', 'opening_balance', v_item, v_a,
     100, 10, 'Brought over from the old books', null, null),
    (v_org, 'SM-0002', date '2026-03-05', 'purchase_receipt', v_item, v_a,
     50, 12, 'GRN 8891', null, null),
    -- Nil unit cost takes the moving average, which is how every issue
    -- out of stock is priced.
    (v_org, 'SM-0003', date '2026-03-20', 'sales_delivery', v_item, v_a,
     -30, 0, null, null, null),
    (v_org, 'SM-0004', date '2026-04-02', 'adjustment_out', v_item, v_a,
     -20, 0, 'Water damage', 'stock_adjustments', v_adj),
    (v_org, 'SM-0005', date '2026-04-10', 'purchase_receipt', v_item, v_b,
     40, 15, 'Delivered straight to the second shed', null, null);

  perform set_config('app.test_card_item', v_item::text, true);
  perform set_config('app.test_card_wh_a', v_a::text, true);
  perform set_config('app.test_card_wh_b', v_b::text, true);
  return v_org;
end;
$$;

-- ---------------------------------------------------------------------
-- The card reads in order, and the arithmetic is the trigger's
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org();
  v_item uuid := current_setting('app.test_card_item')::uuid;
  v_a    uuid := current_setting('app.test_card_wh_a')::uuid;
  v_rows integer;
  v_bad  integer;
  v_seen integer;
begin
  select count(*) into v_rows
    from public.report_stock_card(v_org, v_item);
  perform pg_temp.check_eq('every movement is on the card', v_rows, 5);

  -- Order. Anything that reads down a page has to be in the right one.
  perform pg_temp.check_text('the card reads in order',
    (select string_agg(c.movement_no, ',')
       from public.report_stock_card(v_org, v_item) c),
    'SM-0001,SM-0002,SM-0003,SM-0004,SM-0005');

  -- 100 @ 10 = 1,000; + 50 @ 12 = 1,600 over 150, an average of
  -- 10.666667; − 30 at that average is 320.00, leaving 120 and 1,280.00.
  perform pg_temp.check_eq('quantity after the delivery',
    (select c.balance_quantity from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0003'), 120);
  perform pg_temp.check_eq('value after the delivery',
    (select c.balance_value from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0003'), 1280.00);

  -- ------------------------------------------------------------------
  -- The assertion this file exists for.
  -- ------------------------------------------------------------------
  select count(*) filter (where m.balance_quantity <> c.balance_quantity
                             or m.balance_value <> c.balance_value),
         count(*)
    into v_bad, v_seen
    from public.report_stock_card(v_org, v_item, null, current_date, v_a) c
    join public.stock_movements m
      on m.org_id = v_org and m.movement_no = c.movement_no;

  perform pg_temp.check_eq('computed and stored agree at every movement',
    v_bad, 0);
  -- Without this the line above passes on an empty join.
  perform pg_temp.check_eq('and there were movements to compare',
    v_seen, 4);
end;
$$;

-- ---------------------------------------------------------------------
-- Across warehouses the two must differ, which is the whole reason
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org();
  v_item uuid := current_setting('app.test_card_item')::uuid;
  v_b    uuid := current_setting('app.test_card_wh_b')::uuid;
begin
  -- The last movement is the first one in the second shed, so its stored
  -- balance is that shed's 40. The card is being read for the company,
  -- and the company holds 140.
  perform pg_temp.check_eq('the stored balance is the warehouse''s',
    (select m.balance_quantity from public.stock_movements m
      where m.org_id = v_org and m.movement_no = 'SM-0005'), 40);
  perform pg_temp.check_eq('the card''s balance is the company''s',
    (select c.balance_quantity from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0005'), 140);
  perform pg_temp.check_eq('and so is the value',
    (select c.balance_value from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0005'), 1666.67);

  -- Narrowed to that shed, the card agrees with the stored figure again.
  perform pg_temp.check_eq('narrowed to the shed, it agrees',
    (select c.balance_quantity
       from public.report_stock_card(v_org, v_item, null, current_date, v_b) c
      where c.movement_no = 'SM-0005'), 40);
  perform pg_temp.check_eq('and the shed holds nothing else',
    (select count(*)
       from public.report_stock_card(v_org, v_item, null, current_date, v_b)),
    1);
end;
$$;

-- ---------------------------------------------------------------------
-- Brought forward
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org();
  v_item uuid := current_setting('app.test_card_item')::uuid;
begin
  -- Opening at 1 April: the three March movements, 120 at 1,280.00.
  perform pg_temp.check_eq('brought forward carries the quantity',
    (select c.balance_quantity
       from public.report_stock_card(v_org, v_item, date '2026-04-01') c
      where c.reference = 'Brought forward'), 120);
  perform pg_temp.check_eq('brought forward carries the value',
    (select c.balance_value
       from public.report_stock_card(v_org, v_item, date '2026-04-01') c
      where c.reference = 'Brought forward'), 1280.00);
  perform pg_temp.check_eq('it is one line and it is the first',
    (select count(*)
       from public.report_stock_card(v_org, v_item, date '2026-04-01') c
      where c.reference = 'Brought forward'), 1);
  perform pg_temp.check_text('the first line is the brought forward',
    (select c.reference
       from public.report_stock_card(v_org, v_item, date '2026-04-01') c
      limit 1), 'Brought forward');
  -- It carries no movement, because it is not one.
  perform pg_temp.check_true('brought forward is not a movement',
    (select c.movement_type is null and c.quantity is null
       from public.report_stock_card(v_org, v_item, date '2026-04-01') c
      limit 1));

  -- The range continues from it rather than restarting at nil.
  perform pg_temp.check_eq('the range carries on from it',
    (select c.balance_quantity
       from public.report_stock_card(v_org, v_item, date '2026-04-01') c
      where c.movement_no = 'SM-0004'), 100);
  perform pg_temp.check_eq('and ends where the full card ends',
    (select c.balance_quantity
       from public.report_stock_card(v_org, v_item, date '2026-04-01') c
      where c.movement_no = 'SM-0005'), 140);

  -- Nothing came before the beginning, so there is nothing to say.
  perform pg_temp.check_eq('no brought forward from before the start',
    (select count(*)
       from public.report_stock_card(v_org, v_item, date '2026-01-01') c
      where c.reference = 'Brought forward'), 0);
  perform pg_temp.check_eq('and the card is still whole',
    (select count(*)
       from public.report_stock_card(v_org, v_item, date '2026-01-01')), 5);

  -- The closing date closes the card.
  perform pg_temp.check_eq('the card stops at the closing date',
    (select count(*)
       from public.report_stock_card(v_org, v_item, null, date '2026-03-31')),
    3);
  perform pg_temp.check_eq('and closes on the March balance',
    (select c.balance_quantity
       from public.report_stock_card(v_org, v_item, null, date '2026-03-31') c
      where c.movement_no = 'SM-0003'), 120);
end;
$$;

-- ---------------------------------------------------------------------
-- The reference answers "why", not only "when"
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org();
  v_item uuid := current_setting('app.test_card_item')::uuid;
begin
  perform pg_temp.check_text('a sourced movement names its document',
    (select c.reference from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0004'), 'ADJ-CARD-1');
  perform pg_temp.check_text('an unsourced one falls back to the note',
    (select c.reference from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0002'), 'GRN 8891');
  perform pg_temp.check_true('a movement with neither says nothing',
    (select c.reference is null from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0003'));
  perform pg_temp.check_text('and the location is named',
    (select c.warehouse from public.report_stock_card(v_org, v_item) c
      where c.movement_no = 'SM-0005'), 'Second Warehouse');
end;
$$;

-- ---------------------------------------------------------------------
-- Who may read it
--
-- Membership, not the ledger bar. A purchaser cannot read the general
-- ledger and still has to be able to answer for a shelf, so the pair
-- below is the point: the same person is refused the ledger and allowed
-- the card. A test that only checked the refusal would pass if the card
-- refused everybody.
-- ---------------------------------------------------------------------
do $$
declare
  v_org     uuid := pg_temp.card_org();
  v_item    uuid := current_setting('app.test_card_item')::uuid;
  v_owner   uuid := (select user_id from public.org_members
                      where org_id = v_org and role = 'owner' limit 1);
  v_store   uuid := pg_temp.another_user('storekeeper@stockcard.test');
  v_outside uuid := pg_temp.another_user('outsider@stockcard.test');
  v_msg     text;
begin
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_store, 'purchaser');

  perform pg_temp.sign_in_as(v_store);
  perform pg_temp.check_true('a purchaser cannot read the ledger',
    not app.can_read_ledger(v_org));
  perform pg_temp.check_eq('and can still read the stock card',
    (select count(*) from public.report_stock_card(v_org, v_item)), 5);

  perform pg_temp.sign_in_as(v_outside);
  begin
    perform * from public.report_stock_card(v_org, v_item);
    v_msg := null;
  exception when others then
    v_msg := sqlerrm;
  end;
  -- A caught exception unwinds to the savepoint, and the sign-in with
  -- it, so it has to be done again before anything else is asked.
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_text('an outsider is refused',
    v_msg, 'You are not a member of this company');
  perform pg_temp.check_eq('and the owner still gets the card',
    (select count(*) from public.report_stock_card(v_org, v_item)), 5);
end;
$$;

-- ---------------------------------------------------------------------
-- The grant, checked as the role that carries it
--
-- CI connects as the superuser, which may execute anything. So the
-- role is switched, and asserted switched, or this proves nothing.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid := pg_temp.card_org();
  v_item uuid := current_setting('app.test_card_item')::uuid;
begin
  perform pg_temp.check_true('anon may not execute it',
    not has_function_privilege('anon',
      'public.report_stock_card(uuid, uuid, date, date, uuid)', 'execute'));
  perform pg_temp.check_true('authenticated may',
    has_function_privilege('authenticated',
      'public.report_stock_card(uuid, uuid, date, date, uuid)', 'execute'));
end;
$$;

do $$
declare
  v_org  uuid;
  v_item uuid;
  v_n    integer;
begin
  v_org  := pg_temp.card_org();
  v_item := current_setting('app.test_card_item')::uuid;
  set local role authenticated;
  perform pg_temp.check_text('running as authenticated', current_user,
    'authenticated');
  select count(*) into v_n from public.report_stock_card(v_org, v_item);
  perform pg_temp.check_eq('and the card comes back', v_n, 5);
end;
$$;

-- `set local` lasts to the end of the transaction, not the end of the
-- block, and everything after this builds fixtures that need the
-- superuser back.
reset role;

-- ---------------------------------------------------------------------
-- An item nothing has ever happened to
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid := pg_temp.card_org();
begin
  perform pg_temp.check_eq('an untouched item has an empty card',
    (select count(*) from public.report_stock_card(v_org, gen_random_uuid())),
    0);
end;
$$;

-- ---------------------------------------------------------------------
-- What the shelf remembers
-- ---------------------------------------------------------------------
-- Three properties of `app.apply_stock_movement` that the fixture above
-- cannot reach, because every average in it changes on every movement
-- and nothing ever empties.
--
--   * `average_cost_after` is the average AFTER the movement. On a
--     receipt at a new price the two differ, and the stock card is the
--     only record of what a thing was worth at the moment it moved. A
--     card that stamps the previous average reads plausibly and is
--     wrong on every line that matters.
--   * a shelf that empties keeps the average it was carrying. Value
--     goes to zero because there is nothing there, but the cost is not
--     forgotten -- zero is a price, and the next issue priced at it
--     would take goods out at nothing.
--   * and the item-level rollup keeps it too, for the same reason: a
--     count of zero across every warehouse means there is nothing to
--     average, not that the thing is free.
--
-- One mutant here is equivalent and is left alone: `round(quantity *
-- unit_cost, 2)` on an inbound movement. `v_cost` is declared
-- numeric(18,2), so the assignment rounds whether or not `round` is
-- written. Checked rather than reasoned about -- the round was removed
-- and a receipt of 3 at 1.005 still stored 3.02, with the same average
-- to six places.
-- ---------------------------------------------------------------------
do $$
declare
  v_org  uuid;
  v_item uuid;
  v_wh   uuid;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kos Purata Sdn Bhd');
  perform pg_temp.allow_many_companies();
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.items (org_id, code, name, item_type, track_inventory,
                            uom_code, unit_price, cost_price)
  values (v_org, 'AVG-1', 'Bearing', 'stock', true, 'C62', 30, 10)
  returning id into v_item;
  v_wh := app.default_warehouse(v_org);

  -- Ten at ten, then ten at twenty: twenty on the shelf worth 300, an
  -- average of fifteen. The second movement is the one where the
  -- average before and the average after are different numbers.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'KP-0001', date '2026-05-01', 'purchase_receipt',
          v_item, v_wh, 10, 10),
         (v_org, 'KP-0002', date '2026-05-02', 'purchase_receipt',
          v_item, v_wh, 10, 20);

  perform pg_temp.check_eq('ten at ten leaves the average at ten',
    (select average_cost_after from public.stock_movements
      where org_id = v_org and movement_no = 'KP-0001'), 10.000000);
  perform pg_temp.check_eq(
    'and ten at twenty on top of it leaves fifteen, not ten',
    (select average_cost_after from public.stock_movements
      where org_id = v_org and movement_no = 'KP-0002'), 15.000000);
  perform pg_temp.check_eq('on twenty pieces worth three hundred',
    (select balance_value from public.stock_movements
      where org_id = v_org and movement_no = 'KP-0002'), 300.00);

  -- Everything goes out at the average, and the shelf is empty.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'KP-0003', date '2026-05-10', 'sales_delivery',
          v_item, v_wh, -20, 0);

  perform pg_temp.check_eq('twenty out at fifteen is three hundred',
    (select total_cost from public.stock_movements
      where org_id = v_org and movement_no = 'KP-0003'), -300.00);
  perform pg_temp.check_eq('an empty shelf is worth nothing',
    (select balance_value from public.stock_movements
      where org_id = v_org and movement_no = 'KP-0003'), 0.00);

  -- Worth nothing is not the same as costing nothing.
  perform pg_temp.check_eq('but it still remembers what it cost',
    (select average_cost from public.stock_levels
      where item_id = v_item and warehouse_id = v_wh), 15.000000);
  perform pg_temp.check_eq('and so does the item',
    (select average_cost from public.items where id = v_item), 15.000000);
  perform pg_temp.check_eq('which holds nothing',
    (select quantity_on_hand from public.items where id = v_item), 0);

  -- And the remembered average does not follow the next delivery in.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost)
  values (v_org, 'KP-0004', date '2026-05-20', 'purchase_receipt',
          v_item, v_wh, 5, 12);
  perform pg_temp.check_eq('five at twelve onto an empty shelf is twelve',
    (select average_cost_after from public.stock_movements
      where org_id = v_org and movement_no = 'KP-0004'), 12.000000);
end;
$$;

rollback;
