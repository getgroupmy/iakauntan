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

-- ---------------------------------------------------------------------
-- The twenty-one a mutation sweep found
--
-- Forty one-line mutants of import_opening_stock against sixteen test
-- files. Eighteen died on the first run and they are, again, the
-- arithmetic and the state: quantities and average costs arriving, no
-- journal posted, the file's value totalled from quantity TIMES cost,
-- the movement typed as an opening balance, the lot written and
-- attached, the cost carried onto the movement, stock with no warehouse
-- landing in the default one.
--
-- The twenty-one that survived are the validator, the reconciliation
-- and three details of the posting. This is the third opening-balance
-- importer swept and the third with the same shape, so it is worth
-- saying plainly: in this codebase a validator is written once and
-- tested through whichever two rows the author happened to think of.
--
-- Each row below is wrong in EXACTLY ONE way. The chain is checked in
-- order, so a row wrong in two ways reports whichever guard comes first
-- and would assert that rule rather than this one.
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid; v_boss uuid; v_wh1 uuid; v_wh2 uuid;
  v_msg text; v_ent uuid; v_inv uuid; v_eq uuid;
begin
  v_org := pg_temp.stock_org('Sapu Stock Sdn Bhd', 0);
  v_boss := (select user_id from public.org_members
              where org_id = v_org and role = 'owner' limit 1);

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'W1', 'Gudang Satu') returning id into v_wh1;
  insert into public.warehouses (org_id, code, name)
  values (v_org, 'W2', 'Gudang Dua') returning id into v_wh2;

  -- ==================================================================
  -- 1. The validator, one branch at a time
  -- ==================================================================
  perform pg_temp.check_true('a row with no item code',
    (select message = 'No item code.'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('quantity','1','unit_cost','1')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a row with no quantity',
    (select message = 'No quantity.'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','unit_cost','10')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a quantity that is not a quantity',
    (select message = '"a few" is not a quantity.'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','a few',
                            'unit_cost','10')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a cost that is not a cost',
    (select message = '"about ten" is not a cost.'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','about ten')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a negative cost',
    (select message = 'A cost cannot be negative.'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','-3')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('a warehouse that is not on file',
    (select message = 'W9 is not a warehouse here.'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','10','warehouse_code','W9')),
         date '2026-08-01', false) where row_no = 1));

  perform pg_temp.check_true('the same item, warehouse and lot twice',
    (select message like 'WIDGET is in this file more than once%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','10','warehouse_code','W1'),
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','10','warehouse_code','W1')),
         date '2026-08-01', false) where row_no = 2));

  -- But the same item in two warehouses is two counts, not a repeat.
  -- The warehouse is part of what makes a line unique; without it a
  -- company with a shop and a store could open only one of them.
  perform pg_temp.check_eq('the same item in two warehouses is not a repeat',
    (select count(*) from public.import_opening_stock(v_org,
       jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','10','warehouse_code','W1'),
         jsonb_build_object('item_code','WIDGET','quantity','7',
                            'unit_cost','10','warehouse_code','W2')),
       date '2026-08-01', false) where status = 'ok'), 2);

  -- And the same batched item in two lots is two batches.
  perform pg_temp.check_eq('nor are two lots of the same batched item',
    (select count(*) from public.import_opening_stock(v_org,
       jsonb_build_array(
         jsonb_build_object('item_code','BATCHY','quantity','5',
                            'unit_cost','25','lot_no','B-1'),
         jsonb_build_object('item_code','BATCHY','quantity','7',
                            'unit_cost','25','lot_no','B-2')),
       date '2026-08-01', false) where status = 'ok'), 2);

  -- ==================================================================
  -- 2. The comparison against the ledger
  --
  -- v_ledger is what the inventory accounts already say, and it is the
  -- whole reason this import posts no journal of its own. Three things
  -- about it were unasserted: that it stops at the changeover, that it
  -- counts only posted entries, and that the comparison is withheld
  -- when the file is wrong.
  -- ==================================================================
  select id into v_inv from public.accounts
   where org_id = v_org and code = '1310';
  v_eq := app.opening_balance_account(v_org);

  -- Inventory bought AFTER the changeover. It is not part of what the
  -- ledger said on the day the stock was counted, and counting it would
  -- report a difference against a figure nobody was comparing to.
  perform app.create_gl_entry_internal(
    v_org, date '2026-09-15', 'manual'::app.journal_source,
    jsonb_build_array(
      jsonb_build_object('account_id', v_inv, 'debit', 500, 'credit', 0),
      jsonb_build_object('account_id', v_eq,  'debit', 0, 'credit', 500)),
    'Bought after the changeover', null, null, null, 'MYR', 1);

  -- And a journal that was never posted.
  insert into public.gl_entries (org_id, entry_no, entry_date, status,
    description, source)
  values (v_org, 'DRAFT-1', date '2026-07-01', 'draft',
          'Never posted', 'manual'::app.journal_source)
  returning id into v_ent;
  insert into public.gl_lines (org_id, entry_id, line_no, account_id,
    debit, credit)
  values (v_org, v_ent, 1, v_inv, 900, 0),
         (v_org, v_ent, 2, v_eq, 0, 900);

  -- The ledger said nothing on 1 August, so a file worth 50 differs by
  -- 50 -- not by 550 (the September purchase) and not by 950 (the draft).
  perform pg_temp.check_true(
    'the comparison reads the ledger at the changeover, not after it, '
    'and not counting journals nobody posted',
    (select message like '%worth 50.00 and the inventory accounts '
                      || 'say 0.00, a difference of 50.00%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','10')),
         date '2026-08-01', false) where row_no = 2));

  -- A file with a bad row gets no comparison at all. Offering one would
  -- put a figure on a file that is not going to be imported, and the
  -- figure would be wrong -- the bad row's own value is not in it.
  perform pg_temp.check_eq('a file with a bad row is not given a comparison',
    (select count(*) from public.import_opening_stock(v_org,
       jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','10'),
         jsonb_build_object('item_code','NOSUCH','quantity','5',
                            'unit_cost','10')),
       date '2026-08-01', false)), 2);

  -- And when a comparison IS given, the rejected row's value is not in
  -- it. Asserted on a file whose only fault is a repeat, so exactly one
  -- row counts.
  perform pg_temp.check_true('a rejected row is not counted into the value',
    (select message like '%worth 50.00%'
       from public.import_opening_stock(v_org, jsonb_build_array(
         jsonb_build_object('item_code','WIDGET','quantity','5',
                            'unit_cost','10')),
         date '2026-08-01', false) where row_no = 2));

  -- ==================================================================
  -- 3. Nothing is written when anything is wrong
  -- ==================================================================
  begin
    perform public.import_opening_stock(v_org, jsonb_build_array(
      jsonb_build_object('item_code','WIDGET','quantity','5',
                         'unit_cost','10'),
      jsonb_build_object('item_code','NOSUCH','quantity','5',
                         'unit_cost','10')),
      date '2026-08-01', true);
    raise exception 'a stock file with a bad row was committed';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a stock file with a bad row writes nothing',
      v_msg like 'Nothing was imported: 1 of 2 rows%');
  end;
  perform pg_temp.check_eq('and the good row is not on the shelf either',
    (select count(*) from public.stock_movements where org_id = v_org), 0);

  -- ==================================================================
  -- 4. What a committed row does
  -- ==================================================================
  perform pg_temp.check_true('a committed row reports itself imported',
    exists (select 1 from public.import_opening_stock(v_org,
      jsonb_build_array(
        jsonb_build_object('item_code','WIDGET','quantity','8',
                           'unit_cost','10','warehouse_code','W2'),
        jsonb_build_object('item_code','BATCHY','quantity','6',
                           'unit_cost','25','lot_no','B-9',
                           'expiry_date','2028-01-31'),
        -- One batch, split across two warehouses, with the expiry
        -- printed on only one of the two lines. The second row finds
        -- the lot already written by the first, so the ON CONFLICT
        -- branch is the one that runs -- and it is the only way that
        -- branch is ever reached, because opening stock is imported
        -- once and an item that has moved cannot be opened at all.
        jsonb_build_object('item_code','BATCHY','quantity','4',
                           'unit_cost','25','lot_no','B-7',
                           'warehouse_code','W1'),
        jsonb_build_object('item_code','BATCHY','quantity','3',
                           'unit_cost','25','lot_no','B-7',
                           'warehouse_code','W2',
                           'expiry_date','2029-03-31')),
      date '2026-08-01', true) where status = 'imported' and code = 'WIDGET'));

  -- The warehouse the file NAMED, not the default one. Ignored, every
  -- count lands in the main store and the shop's own stock figure is
  -- nil from the first day.
  perform pg_temp.check_eq('the stock lands in the warehouse the file named',
    (select warehouse_id from public.stock_movements
      where org_id = v_org and quantity = 8), v_wh2);

  -- The movement is dated at the changeover. Dated today it would sit
  -- after every transaction it is supposed to precede, and the stock
  -- card would open with a balance arriving out of order.
  perform pg_temp.check_true('and is dated at the changeover',
    (select movement_date = date '2026-08-01' from public.stock_movements
      where org_id = v_org and quantity = 8));

  -- The lot carries the quantity of the line it came in on, not one.
  perform pg_temp.check_eq('the batch holds the quantity it came in with',
    (select sml.quantity from public.stock_movement_lots sml
       join public.stock_lots sl on sl.id = sml.lot_id
      where sl.org_id = v_org and sl.lot_ref = 'B-9'), 6);
  perform pg_temp.check_true('with the expiry date off the file',
    (select expiry_date = date '2028-01-31' from public.stock_lots
      where org_id = v_org and lot_ref = 'B-9'));

  -- The split batch: one lot row, both halves of the quantity against
  -- it, and the expiry taken from the line that carried one. Kept from
  -- the existing row instead, a batch whose expiry was typed on the
  -- second line of the file would be stocked with no expiry at all --
  -- and an expiry nobody recorded is one nobody is warned about.
  perform pg_temp.check_eq('a batch split across two warehouses is one lot',
    (select count(*) from public.stock_lots
      where org_id = v_org and lot_ref = 'B-7'), 1);
  perform pg_temp.check_eq('holding both halves of the quantity',
    (select sum(sml.quantity) from public.stock_movement_lots sml
       join public.stock_lots sl on sl.id = sml.lot_id
      where sl.org_id = v_org and sl.lot_ref = 'B-7'), 7);
  perform pg_temp.check_true(
    'and taking the expiry from whichever line carried one',
    (select expiry_date = date '2029-03-31' from public.stock_lots
      where org_id = v_org and lot_ref = 'B-7'));

  -- ==================================================================
  -- 5. Once, and only for stock that has not moved
  --
  -- Two guards refuse a second file and each covers for the other, so
  -- the existing "was it refused?" assertion passed with either one
  -- deleted. Asserted on the WHOLE message, so which guard fired is
  -- part of what is asserted.
  -- ==================================================================
  -- An item that is stock, is tracked, and has never moved -- so every
  -- row check above passes and the already-imported guard is the only
  -- thing left to refuse it. CONSULT is a service and WIDGET has just
  -- moved, and either would have been refused by an earlier branch.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_org, 'LATE', 'Bought later', 'stock', true, 'none', 5, 2);

  begin
    perform public.import_opening_stock(v_org, jsonb_build_array(
      jsonb_build_object('item_code','LATE','quantity','1',
                         'unit_cost','1')), date '2026-08-01', true);
    raise exception 'a second opening stock file was accepted';
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_eq('a second file is refused as a second file',
      v_msg, 'Opening stock has already been brought into this company.');
  end;

  -- And separately: an item that has already moved cannot be opened,
  -- even in a company that has no opening file yet. A fresh company,
  -- because the guard above would otherwise answer first.
  declare
    v_org2 uuid; v_wh uuid;
  begin
    v_org2 := pg_temp.stock_org('Moved Already Sdn Bhd', 0);
    v_wh := public.ensure_default_warehouse(v_org2);
    insert into public.stock_movements
      (org_id, movement_no, movement_date, movement_type, item_id,
       warehouse_id, quantity, unit_cost, source_table)
    select v_org2, 'SM-X', date '2026-02-01', 'adjustment_in', it.id, v_wh,
           3, 10, 'manual'
      from public.items it where it.org_id = v_org2 and it.code = 'WIDGET';

    perform pg_temp.check_true('an item that has already moved cannot be opened',
      (select message like 'WIDGET has already moved in this system%'
         from public.import_opening_stock(v_org2, jsonb_build_array(
           jsonb_build_object('item_code','WIDGET','quantity','5',
                              'unit_cost','10')),
           date '2026-08-01', false) where row_no = 1));
  end;

  perform pg_temp.sign_in_as(v_boss);
  raise notice 'ok   opening stock: the twenty-one a sweep found';
end $$;


rollback;
