-- =====================================================================
-- iAkauntan :: bringing a company's books across, and the rows refused
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/opening_import_shapes.sql
--
-- `opening_trial_balance.sql` and `opening_stock.sql` cover the good
-- path and most of what a file gets wrong. A sweep of 74 one-line
-- mutants over `import_opening_balances` and `import_opening_stock`
-- killed 57, and what lived was of two kinds.
--
-- WHICH ROW THE LOOKUP FINDS. Both functions match a code from the file
-- against the chart or the item list with `lower(x) = lower(y)`, and
-- every fixture types the code exactly as it is on file, so the
-- lowering was doing nothing observable. A migration file is exported
-- from somebody else's system, and it is the one place in the product
-- where the codes are NOT typed by the person who made them. Nor was
-- the lookup's tenancy tested: with `org_id` deleted, a file could name
-- an account or a warehouse belonging to another company on the
-- platform and be told it was fine.
--
-- AND WHAT COUNTS AS ALREADY DONE. An opening balance is brought in
-- ONCE, and the guard that says so is four conditions long — the right
-- source, the right source table, posted rather than drafted, and not
-- already reversed. Only the last was asserted, because `0525` was
-- written for it. A draft opening balance blocking the real one is a
-- migration nobody can finish.
--
-- Nothing is written; the file runs inside a transaction and rolls back.
-- =====================================================================

begin;

\i supabase/tests/_helpers.sql

create or replace function pg_temp.oi_org(p_name text, p_owner uuid)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.organizations
    (name, slug, entity_type, base_currency, created_by)
  values (p_name, lower(replace(p_name, ' ', '-')) || '-' || gen_random_uuid(),
          'sdn_bhd', 'MYR', p_owner)
  returning id into v;
  perform app.seed_chart_of_accounts(v);
  perform pg_temp.sign_in_as(p_owner);
  perform public.create_fiscal_year(v, date '2026-01-01');
  return v;
end; $$;

-- What the preview said about one row.
create or replace function pg_temp.oi_says(
  p_org uuid, p_rows jsonb, p_code text)
returns text language sql as $$
  select x.status || ': ' || x.message
    from public.import_opening_balances(p_org, p_rows, date '2026-08-01') x
   where x.code = p_code;
$$;

create or replace function pg_temp.os_says(
  p_org uuid, p_rows jsonb, p_code text)
returns text language sql as $$
  select x.status || ': ' || x.message
    from public.import_opening_stock(p_org, p_rows, date '2026-08-01') x
   where x.code = p_code;
$$;

-- =====================================================================
-- 1. The trial balance: which account a code finds
-- =====================================================================
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@oimport.test');
  v_org uuid; v_them uuid; v_rows jsonb;
begin
  v_org := pg_temp.oi_org('Import Chart Sdn Bhd', v_boss);
  perform pg_temp.allow_many_companies();
  v_them := pg_temp.oi_org('Chart Next Door Sdn Bhd', v_boss);
  perform pg_temp.sign_in_as(v_boss);

  -- An account of our own whose code carries a letter, because a code
  -- of digits cannot tell a case-sensitive match from a lowered one.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, 'FX-1', 'Foreign account', 'asset', 'current_asset');
  -- One this company has retired.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype, is_active, deleted_at)
  values (v_org, 'OLD-1', 'Retired account', 'asset', 'current_asset',
          false, now());
  -- And one that belongs to the company next door and not to this one.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_them, 'THEIRS', 'Their account', 'asset', 'current_asset');

  -- A FILE IS EXPORTED FROM SOMEBODY ELSE'S SYSTEM. It is the one place
  -- in the product where the codes were not typed by the person who
  -- made them, so the case is whatever that system used.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', 'fx-1', 'debit', '500'),
    jsonb_build_object('account_code', '3100', 'credit', '500'));
  perform pg_temp.check_eq(
    'a code in the wrong case still finds its account',
    pg_temp.oi_says(v_org, v_rows, 'fx-1'), 'ok: ');

  -- The same code twice in one file, spelt two ways. Without lowering
  -- on BOTH sides the second one posts as well, and the account is
  -- doubled.
  -- The upper-case spelling FIRST, which is what tells the two halves
  -- of the check apart: the code is lowered on the way INTO the list of
  -- what has been seen as well as on the way out of it. Lowering only
  -- one end still catches 'fx-1' after 'FX-1' -- or the other way about,
  -- depending which end -- so the order here is the assertion.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', 'FX-1', 'debit', '500'),
    jsonb_build_object('account_code', 'fx-1', 'debit', '500'),
    jsonb_build_object('account_code', '3100', 'credit', '1000'));
  perform pg_temp.check_true(
    'and an account written twice in two cases is caught the second time',
    pg_temp.oi_says(v_org, v_rows, 'fx-1')
      like 'error:%is in this file more than once%');

  -- A retired account is not in the chart as far as an import is
  -- concerned: posting an opening balance to it puts money somewhere
  -- the chart says is gone.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', 'OLD-1', 'debit', '500'),
    jsonb_build_object('account_code', '3100', 'credit', '500'));
  perform pg_temp.check_true('a retired account is not an account here',
    pg_temp.oi_says(v_org, v_rows, 'OLD-1')
      like 'error:%is not an account in this company''s chart%');

  -- And the company next door's chart is not this company's.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', 'THEIRS', 'debit', '500'),
    jsonb_build_object('account_code', '3100', 'credit', '500'));
  perform pg_temp.check_true('nor is the company next door''s',
    pg_temp.oi_says(v_org, v_rows, 'THEIRS')
      like 'error:%is not an account in this company''s chart%');

  -- A negative on either side. `0150`'s rule is that a negative debit is
  -- a credit and belongs in the other column, and the assertion that
  -- existed only tried one of the two columns.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'credit', '-500'),
    jsonb_build_object('account_code', '3100', 'credit', '500'));
  perform pg_temp.check_true('a negative credit belongs in the other column',
    pg_temp.oi_says(v_org, v_rows, '1110')
      like 'error:%negative amount belongs in the other column%');
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'debit', '-500'),
    jsonb_build_object('account_code', '3100', 'credit', '500'));
  perform pg_temp.check_true('and so does a negative debit',
    pg_temp.oi_says(v_org, v_rows, '1110')
      like 'error:%negative amount belongs in the other column%');
end $$;

-- =====================================================================
-- 2. What the inventory line is told
-- =====================================================================
--
-- Two companies, one with something stock-tracked and one without, and
-- the message is the other way round for each. Neither had ever been
-- read: the warning was asserted as "there is a warning".
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@oiinv.test');
  v_with uuid; v_without uuid; v_rows jsonb;
begin
  v_with := pg_temp.oi_org('Ada Stok Sdn Bhd', v_boss);
  perform pg_temp.allow_many_companies();
  v_without := pg_temp.oi_org('Tiada Stok Sdn Bhd', v_boss);
  perform pg_temp.sign_in_as(v_boss);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_with, 'WIDGET', 'Widget', 'stock', true, 'none', 20, 10);
  -- A company whose only item is a service. It has an item list; what
  -- it does not have is anything with a quantity.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_without, 'CONSULT', 'Consulting', 'service', false, 'none',
          300, 0);

  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1310', 'debit', '2000'),
    jsonb_build_object('account_code', '3100', 'credit', '2000'));

  perform pg_temp.check_true(
    'a company that tracks stock is told the quantities are a separate '
    'import',
    pg_temp.oi_says(v_with, v_rows, '1310')
      like 'warning:%Opening stock quantities are a separate import%');
  perform pg_temp.check_true(
    'and one that tracks none is told there is nothing behind the figure '
    'at all -- which is a different problem with a different answer',
    pg_temp.oi_says(v_without, v_rows, '1310')
      like 'warning:%Nothing in this company is stock-tracked%');
end $$;

-- =====================================================================
-- 3. What counts as already brought in
-- =====================================================================
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@oiagain.test');
  v_org uuid; v_them uuid; v_idle uuid; v_rows jsonb; v_e uuid;
  v_bank uuid; v_idle_bank uuid; v_idle_ac uuid;
begin
  v_org := pg_temp.oi_org('Sekali Sahaja Sdn Bhd', v_boss);
  perform pg_temp.allow_many_companies();
  v_them := pg_temp.oi_org('Jiran Sekali Sdn Bhd', v_boss);
  -- A third company that imports nothing. The neighbour above brings
  -- its own books across, so ITS bank balance is meant to move; this
  -- one's is the figure that must not.
  v_idle := pg_temp.oi_org('Belum Mula Sdn Bhd', v_boss);
  perform pg_temp.sign_in_as(v_boss);

  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'debit', '5000'),
    jsonb_build_object('account_code', '3100', 'credit', '5000'));

  -- A DRAFT opening balance. Somebody started a journal and left it;
  -- it has posted nothing, so it cannot be double-counting anything,
  -- and a guard that treats it as done leaves a migration that can
  -- never be finished.
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, source_table, description,
     total_debit, total_credit, status)
  values (v_org, 'DRAFT-OB', date '2026-08-01', 'opening_balance',
          'opening_trial_balance', 'Half-typed', 0, 0, 'draft');

  -- And a POSTED journal on the same table from another source. The
  -- source is what says this journal is an opening trial balance
  -- rather than something else filed against the same record.
  insert into public.gl_entries
    (org_id, entry_no, entry_date, source, source_table, description,
     total_debit, total_credit, status, posted_at)
  values (v_org, 'MANUAL-1', date '2026-08-01', 'manual',
          'opening_trial_balance', 'Not an opening balance', 0, 0,
          'posted', now());

  -- TWO BANK ACCOUNTS, standing up BEFORE the import that resyncs them.
  -- 1110 is the account the file posts to, and a bank account carries
  -- its own running balance for the reconciliation screen, derived
  -- rather than posted, so the import has to tell it. The idle
  -- company's is set to a figure nothing could arrive at, so a resync
  -- that reached across companies would be unmistakable.
  select a.id into v_idle_ac from public.accounts a
   where a.org_id = v_idle and a.code = '1110';
  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, account_type, currency,
     account_id, current_balance)
  values (v_idle, 'Untouched current', 'CIMB', '9999', 'current', 'MYR',
          v_idle_ac, 999999)
  returning id into v_idle_bank;

  select a.id into v_e from public.accounts a
   where a.org_id = v_org and a.code = '1110';
  insert into public.bank_accounts
    (org_id, name, bank_name, account_number, account_type, currency,
     account_id, current_balance)
  values (v_org, 'Our current', 'Maybank', '1111', 'current', 'MYR',
          v_e, 0)
  returning id into v_bank;

  -- The company next door has brought its own books across.
  perform public.import_opening_balances(v_them, v_rows,
                                         date '2026-08-01', true);

  perform pg_temp.check_eq(
    'none of those stop this company bringing its books across',
    (select count(*) from public.import_opening_balances(
       v_org, v_rows, date '2026-08-01', true) x
      where x.status = 'imported'), 2);

  -- And now that it has, a second run is refused. Without this the
  -- assertion above is also satisfied by a guard that never fires.
  perform pg_temp.check_refused(
    'but its own posted one does',
    format('select count(*) from public.import_opening_balances(%L, %L, %L, true)',
           v_org, v_rows, date '2026-08-01'),
    '%already been brought into this company%');

  -- WHOSE BANK BALANCES THE IMPORT RESYNCS. Ours moved, because the
  -- file put five thousand into 1110. Theirs did not, because it is not
  -- ours to touch -- and the two assertions are one finding: without
  -- the first, a resync that reached nothing at all would also leave
  -- the neighbour's figure alone.
  perform pg_temp.check_eq('our own bank balance is brought up to date',
    (select b.current_balance from public.bank_accounts b
      where b.id = v_bank), 5000);
  perform pg_temp.check_eq(
    'and a company that has imported nothing is left alone',
    (select b.current_balance from public.bank_accounts b
      where b.id = v_idle_bank), 999999);
end $$;

-- =====================================================================
-- 4. Opening stock: which item, which warehouse, and what has moved
-- =====================================================================
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@oistock.test');
  v_org uuid; v_them uuid; v_rows jsonb;
  v_widget uuid; v_moved uuid; v_batch uuid; v_wh uuid; v_lot uuid;
begin
  v_org := pg_temp.oi_org('Stok Import Sdn Bhd', v_boss);
  perform pg_temp.allow_many_companies();
  v_them := pg_temp.oi_org('Jiran Stok Sdn Bhd', v_boss);
  perform pg_temp.sign_in_as(v_boss);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_org, 'WIDGET', 'Widget', 'stock', true, 'none', 20, 10)
  returning id into v_widget;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_org, 'MOVED', 'Already moved', 'stock', true, 'none', 20, 10)
  returning id into v_moved;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_org, 'BATCHY', 'Batched thing', 'stock', true, 'batch', 50, 25)
  returning id into v_batch;
  -- One this company has deleted, and one belonging to the shop next
  -- door.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price, deleted_at)
  values (v_org, 'GONE', 'Deleted item', 'stock', true, 'none', 20, 10,
          now());
  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_them, 'THEIRS', 'Their item', 'stock', true, 'none', 20, 10);

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Our floor') returning id into v_wh;
  insert into public.warehouses (org_id, code, name)
  values (v_them, 'THEIRWH', 'Their floor');

  -- A CODE IN THE WRONG CASE, from somebody else's export.
  perform pg_temp.check_eq('an item code in the wrong case finds its item',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'widget', 'quantity', '10',
                         'unit_cost', '10')), 'widget'), 'ok: ');
  perform pg_temp.check_eq('and a warehouse code in the wrong case too',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'WIDGET', 'warehouse_code', 'main',
                         'quantity', '10', 'unit_cost', '10')),
      'WIDGET'), 'ok: ');

  perform pg_temp.check_true('a deleted item is not an item here',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'GONE', 'quantity', '10',
                         'unit_cost', '10')), 'GONE')
      like 'error:%is not an item here%');
  perform pg_temp.check_true('nor is the shop next door''s',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'THEIRS', 'quantity', '10',
                         'unit_cost', '10')), 'THEIRS')
      like 'error:%is not an item here%');
  perform pg_temp.check_true('and their warehouse is not a warehouse here',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'WIDGET', 'warehouse_code', 'THEIRWH',
                         'quantity', '10', 'unit_cost', '10')), 'WIDGET')
      like 'error:%is not a warehouse here%');

  -- STOCK THAT COST NOTHING. Samples, promotional units, a line the
  -- previous system valued at nought: a cost of zero is a cost. Only a
  -- NEGATIVE one is refused.
  perform pg_temp.check_eq(
    'stock brought in at no cost at all is allowed -- samples are stock',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'WIDGET', 'quantity', '10',
                         'unit_cost', '0')), 'WIDGET'), 'ok: ');

  -- AN ITEM THAT HAS ALREADY MOVED, beside one that has not. The guard
  -- is per item, and a company that has begun trading in one line can
  -- still bring the rest of its stock across.
  insert into public.stock_movements
    (org_id, movement_no, movement_date, movement_type, item_id,
     warehouse_id, quantity, unit_cost, source_table)
  values (v_org, 'SM-1', date '2026-07-01', 'purchase_receipt', v_moved,
          v_wh, 5, 10, 'test');

  perform pg_temp.check_true('an item that has already moved is refused',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'MOVED', 'quantity', '10',
                         'unit_cost', '10')), 'MOVED')
      like 'error:%has already moved in this system%');
  perform pg_temp.check_eq(
    'while the item beside it that has not is brought in',
    pg_temp.os_says(v_org, jsonb_build_array(
      jsonb_build_object('item_code', 'WIDGET', 'quantity', '10',
                         'unit_cost', '10')), 'WIDGET'), 'ok: ');

  -- AND THE COMMIT ITSELF, which has its own guard: "opening stock has
  -- already been brought in" must mean opening stock, not any movement
  -- at all. This company has a purchase receipt on the books.
  perform pg_temp.check_eq(
    'a company that has begun trading can still open the rest of its '
    'stock',
    (select count(*) from public.import_opening_stock(v_org,
       jsonb_build_array(
         jsonb_build_object('item_code', 'WIDGET', 'quantity', '10',
                            'unit_cost', '10')),
       date '2026-08-01', true) x
      where x.status = 'imported'), 1);

  -- And now it cannot do it twice. The control for the assertion above.
  perform pg_temp.check_refused('but not twice',
    format('select count(*) from public.import_opening_stock(%L, %L, %L, true)',
           v_org, jsonb_build_array(
             jsonb_build_object('item_code', 'BATCHY', 'quantity', '10',
                                'unit_cost', '25', 'lot_no', 'B-9')),
           date '2026-08-01'),
    '%Opening stock has already been brought into this company%');
end $$;

-- =====================================================================
-- 5. A batch already on file keeps what is known about it
-- =====================================================================
do $$
declare
  v_boss uuid := pg_temp.another_user('boss@oilot.test');
  v_org uuid; v_batch uuid; v_lot uuid;
begin
  v_org := pg_temp.oi_org('Lot Import Sdn Bhd', v_boss);

  insert into public.items
    (org_id, code, name, item_type, track_inventory, tracking,
     unit_price, cost_price)
  values (v_org, 'BATCHY', 'Batched thing', 'stock', true, 'batch', 50, 25)
  returning id into v_batch;

  -- The batch is already on file with an expiry date -- keyed in by
  -- hand, or arrived with the item list. The stock file names the same
  -- batch and says nothing about when it expires.
  insert into public.stock_lots (org_id, item_id, lot_ref, kind, expiry_date)
  values (v_org, v_batch, 'B-1', 'batch', date '2027-06-30')
  returning id into v_lot;

  perform public.import_opening_stock(v_org, jsonb_build_array(
    jsonb_build_object('item_code', 'BATCHY', 'quantity', '40',
                       'unit_cost', '25', 'lot_no', 'B-1')),
    date '2026-08-01', true);

  perform pg_temp.check_eq(
    'a file that says nothing about the expiry does not erase the one '
    'on file -- a batch with no expiry is a batch nobody will recall',
    (select l.expiry_date::text from public.stock_lots l where l.id = v_lot),
    '2027-06-30');
  perform pg_temp.check_eq('and the quantity is against that same batch',
    (select coalesce(sum(ml.quantity), 0)
       from public.stock_movement_lots ml where ml.lot_id = v_lot), 40);
end $$;

-- =====================================================================
-- 6. A rule the already-moved guard leans on
-- =====================================================================
do $$
begin
  -- `import_opening_stock` asks whether an item has moved with
  --
  --     where m.org_id = p_org_id and m.item_id = v_item_id
  --
  -- and dropping the first condition changes no answer, because a
  -- movement's item is always in the movement's own company. That is a
  -- constraint rather than an argument, so it is the constraint that is
  -- asserted.
  perform pg_temp.check_true(
    'a stock movement''s item belongs to the movement''s own company',
    exists (select 1 from pg_constraint
             where conname = 'stock_movements_item_same_org'
               and conrelid = 'public.stock_movements'::regclass
               and contype = 'f'));
end $$;

rollback;
