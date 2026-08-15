-- =====================================================================
-- iAkauntan :: opening stock
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/opening_stock.sql
--
-- Two assertions carry this file, and they pull against each other,
-- which is the point.
--
--   * **Quantities and average costs arrive.** Without them the
--     inventory figure 0151 brought in has nothing behind it and every
--     sale afterwards takes cost from an average of nothing.
--   * **No journal is posted.** The inventory balance came in with the
--     trial balance. Posting it again here would double it, and a
--     doubled inventory looks like a healthy balance sheet — the same
--     silent failure the control accounts avoid in 0151, avoided the
--     same way.
--
-- The third thing worth asserting is the comparison between the two,
-- because it is what turns "no journal" from an omission into a check.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.stock_org(p_name text, p_inventory numeric)
returns uuid language plpgsql as $$
declare v_boss uuid := pg_temp.another_user(p_name || '@openstock.test');
        v_org uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', v_boss)
  returning id into v_org;
  perform app.seed_chart_of_accounts(v_org);
  perform pg_temp.sign_in_as(v_boss);
  perform public.create_fiscal_year(v_org, date '2026-01-01');

  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_org, 'WIDGET', 'Widget', 'stock', true, 'none', 20, 10),
         (v_org, 'BATCHY', 'Batched thing', 'stock', true, 'batch', 50, 25),
         (v_org, 'CONSULT', 'Consulting', 'service', false, 'none', 300, 0);

  -- The trial balance puts a figure in inventory, which is the thing
  -- this import has to reconcile to.
  if p_inventory <> 0 then
    perform public.import_opening_balances(v_org, jsonb_build_array(
      jsonb_build_object('account_code', '1310', 'debit', p_inventory::text),
      jsonb_build_object('account_code', '3100', 'credit', p_inventory::text)),
      date '2026-08-01', true);
  end if;
  return v_org;
end; $$;

-- ---------------------------------------------------------------------
-- Stock arrives, the ledger does not move, and the two agree
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_refused boolean; v_msg text; v_n numeric;
begin
  -- 100 widgets at 10 and 40 batched at 25 is 2,000.
  v_org := pg_temp.stock_org('Open Stock Sdn Bhd', 2000);

  perform public.import_opening_stock(v_org, jsonb_build_array(
    jsonb_build_object('item_code', 'WIDGET', 'quantity', '100',
                       'unit_cost', '10'),
    jsonb_build_object('item_code', 'BATCHY', 'quantity', '40',
                       'unit_cost', '25', 'lot_no', 'B-1',
                       'expiry_date', '2027-06-30')),
    date '2026-08-01', true);

  perform pg_temp.check_eq('the quantity arrives',
    (select quantity_on_hand from public.items
      where org_id = v_org and code = 'WIDGET'), 100);
  perform pg_temp.check_eq(
    'and so does the average cost, which is what cost of sales will use',
    (select average_cost from public.items
      where org_id = v_org and code = 'WIDGET'), 10);
  perform pg_temp.check_eq('the batched item too',
    (select quantity_on_hand from public.items
      where org_id = v_org and code = 'BATCHY'), 40);

  -- The batch is named, which is what the trigger would have refused the
  -- movement for if 0152 had not taught it to stand aside here.
  perform pg_temp.check_eq('the batch is recorded against the movement',
    (select count(*) from public.stock_movement_lots sml
       join public.stock_lots sl on sl.id = sml.lot_id
      where sl.org_id = v_org and sl.lot_ref = 'B-1'), 1);
  perform pg_temp.check_true('with the expiry it came in with',
    (select expiry_date = date '2027-06-30' from public.stock_lots
      where org_id = v_org and lot_ref = 'B-1'));

  -- The assertion that matters most.
  perform pg_temp.check_eq(
    'no journal was posted — the trial balance already brought the '
    'inventory figure in, and posting it again would double it',
    (select count(*) from public.gl_entries
      where org_id = v_org and source_table = 'opening_stock'), 0);
  perform pg_temp.check_eq('so the inventory account is where 0151 left it',
    (select round(coalesce(sum(l.debit - l.credit), 0), 2)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.org_id = v_org and a.code = '1310'), 2000);

  -- Once only.
  v_refused := false;
  begin
    perform public.import_opening_stock(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'WIDGET', 'quantity', '1',
                         'unit_cost', '10')), date '2026-08-01', true);
  exception when others then v_refused := true; end;
  perform pg_temp.sign_in_as(pg_temp.another_user('again@openstock.test'));
  perform pg_temp.check_true(
    'a second opening stock file is refused rather than added on',
    v_refused);
end $$;

-- ---------------------------------------------------------------------
-- The comparison
--
-- The reason "no journal" is a design rather than an omission. Asserted
-- both ways round, because a function that always said they agreed would
-- pass the first half on its own.
-- ---------------------------------------------------------------------
do $$
declare v_org uuid;
begin
  v_org := pg_temp.stock_org('Agreeing Stock Sdn Bhd', 1000);
  perform pg_temp.check_true(
    'stock worth what the ledger says is reported as agreeing',
    (select status = 'ok' and message like '%which is what the inventory '
                                        || 'accounts already say%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '100',
                            'unit_cost', '10')), date '2026-08-01', false)
      where code = ''));

  v_org := pg_temp.stock_org('Differing Stock Sdn Bhd', 1500);
  perform pg_temp.check_true('and stock worth less is not',
    (select status = 'warning'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '100',
                            'unit_cost', '10')), date '2026-08-01', false)
      where code = ''));
  perform pg_temp.check_true(
    'naming both figures and the difference, which is what somebody goes '
    'looking for',
    (select message like '%1000.00%' and message like '%1500.00%'
        and message like '%-500.00%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '100',
                            'unit_cost', '10')), date '2026-08-01', false)
      where code = ''));

  -- A warning does not stop it: the difference is a thing to investigate,
  -- and neither side is adjusted to the other, because writing off stock
  -- nobody has looked at is not something this should do on its own.
  perform public.import_opening_stock(v_org, jsonb_build_array(
    jsonb_build_object('item_code', 'WIDGET', 'quantity', '100',
                       'unit_cost', '10')), date '2026-08-01', true);
  perform pg_temp.check_eq('and the stock still comes in',
    (select quantity_on_hand from public.items
      where org_id = v_org and code = 'WIDGET'), 100);
  perform pg_temp.check_eq('with the ledger untouched',
    (select round(coalesce(sum(l.debit - l.credit), 0), 2)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.org_id = v_org and a.code = '1310'), 1500);
end $$;

-- ---------------------------------------------------------------------
-- Rows that are wrong
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_clerk uuid := pg_temp.another_user('clerk@openstock.test');
  v_refused boolean; v_role text;
begin
  v_org := pg_temp.stock_org('Bad Stock Sdn Bhd', 0);

  perform pg_temp.check_true('a service has no quantity to bring in',
    (select message like '%not stock-tracked%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'CONSULT', 'quantity', '1',
                            'unit_cost', '1')), date '2026-08-01', false)
      where code = 'CONSULT'));

  perform pg_temp.check_true('an item nobody imported is named',
    (select message like '%Import the item list first%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'NOPE', 'quantity', '1',
                            'unit_cost', '1')), date '2026-08-01', false)
      where code = 'NOPE'));

  perform pg_temp.check_true('a batched item has to say which batch',
    (select message like '%tracked by batch%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'BATCHY', 'quantity', '1',
                            'unit_cost', '1')), date '2026-08-01', false)
      where code = 'BATCHY'));

  perform pg_temp.check_true('and an untracked one may not',
    (select message like '%recorded and never looked at%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '1',
                            'unit_cost', '1', 'lot_no', 'X')),
         date '2026-08-01', false)
      where code = 'WIDGET'));

  perform pg_temp.check_true('nothing is not an opening quantity',
    (select message like '%more than nothing%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '0',
                            'unit_cost', '1')), date '2026-08-01', false)
      where code = 'WIDGET'));

  perform pg_temp.check_true('and a cost is not optional, because cost of '
    'sales is charged at it',
    (select message like '%No unit cost%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '5')),
         date '2026-08-01', false)
      where code = 'WIDGET'));

  -- The control for all of the above.
  perform pg_temp.check_true('a good row is not an error',
    (select status = 'ok'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '5',
                            'unit_cost', '10')), date '2026-08-01', false)
      where code = 'WIDGET'));

  -- Posting, not preparing — the same rule the rest of the migration
  -- keeps, even though this one writes no journal: it sets the cost
  -- every future sale is charged at.
  insert into public.org_members (org_id, user_id, role)
  values (v_org, v_clerk, 'accounts_clerk');
  perform pg_temp.sign_in_as(v_clerk);
  v_refused := false;
  begin
    set local role authenticated;
    v_role := current_user;
    perform public.import_opening_stock(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'WIDGET', 'quantity', '5',
                         'unit_cost', '10')), date '2026-08-01', true);
  exception when others then v_refused := true;
  end;
  reset role;
  perform pg_temp.sign_in_as(v_clerk);
  perform pg_temp.check_true('the test ran under row level security',
    v_role = 'authenticated');
  perform pg_temp.check_true('an accounts clerk cannot open the stock',
    v_refused);
end $$;

rollback;
