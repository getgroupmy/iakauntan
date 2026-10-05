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
  -- The upper-case spelling FIRST. This order does NOT tell the two
  -- halves of the check apart, and the comment here used to say it did:
  -- `v_seen` holds the LOWERED code, so with 'FX-1' seen first the
  -- second row 'fx-1' matches whether or not the comparison lowers it.
  -- A mutation sweep dropped the `lower()` from the comparison and this
  -- assertion passed. The other order is the one that distinguishes
  -- them, and it is added further down.
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

-- =====================================================================
-- The eleven a sweep found, and the elsif chain's own ORDER
-- =====================================================================
-- `import_opening_balances` was mutated forty ways across the five
-- files that reach it. 13 died on this one, 29 across all five. The
-- eleven that lived are mostly rows this file never put in a file --
-- and three of them are about the ORDER of the validation chain, which
-- is the one shape where moving a condition is the mutation worth
-- writing.
--
-- The function's own comment says the order is load-bearing: "Before
-- the existence check, not after: 3900 is created on demand, so in a
-- company that has imported nothing yet it does not exist, and the
-- wrong branch answers '3900 is not an account in this company's
-- chart' -- true, unhelpful, and not the reason it is being refused."
-- A fixture meeting two conditions at once cannot say which answered,
-- so each row below meets exactly one.
do $$
declare
  v_boss uuid := pg_temp.another_user('rantai@oimport.test');
  v_org  uuid;
  v_rows jsonb;
  v_said text;
  v_n    integer;
begin
  v_org := pg_temp.oi_org('Rantai Semak Sdn Bhd', v_boss);

  -- ------------------------------------------------------------------
  -- 1. The first link: NO CODE AT ALL
  -- ------------------------------------------------------------------
  -- A spreadsheet with a stray blank row in it, which is how every
  -- changeover file arrives.
  v_rows := jsonb_build_array(
    jsonb_build_object('debit', '100'),
    jsonb_build_object('account_code', '1110', 'debit', '100'),
    jsonb_build_object('account_code', '3100', 'credit', '200'));
  select x.status || ': ' || x.message into v_said
    from public.import_opening_balances(v_org, v_rows, date '2026-08-01') x
   where x.row_no = 1;
  -- `check_true` and not `check_eq`, deliberately. `check_eq` prints the
  -- EXPECTED VALUE in its success notice, and `run_locally.sh` decides a
  -- file failed by grepping its output for `^psql.*[Ee]rror:` -- so an
  -- assertion whose expected value is the string "error: ..." reports
  -- the whole file as FAILED while passing. The runner's own comment
  -- names this as the safe direction to be wrong in, and it is: the fix
  -- belongs here. Every other refusal in this file already uses
  -- `check_true` with a `like`, which echoes nothing.
  perform pg_temp.check_true('a row with no account code says so',
    v_said = 'error: No account code.');

  -- ------------------------------------------------------------------
  -- 2. A DUPLICATE in the other order
  -- ------------------------------------------------------------------
  -- The file above catches 'FX-1' then 'fx-1'. That order cannot tell
  -- `lower(v_code) = any (v_seen)` from `v_code = any (v_seen)`,
  -- because `v_seen` holds the LOWERED code and the second row is
  -- already lower case -- so the comparison matches either way. The
  -- other order is the discriminator: lower first, upper second, where
  -- only a comparison that lowers BOTH ends catches it.
  insert into public.accounts
    (org_id, code, name, account_type, account_subtype)
  values (v_org, 'FX-9', 'Another foreign account', 'asset', 'current_asset');
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', 'fx-9', 'debit', '500'),
    jsonb_build_object('account_code', 'FX-9', 'debit', '500'),
    jsonb_build_object('account_code', '3100', 'credit', '1000'));
  select x.status || ': ' || x.message into v_said
    from public.import_opening_balances(v_org, v_rows, date '2026-08-01') x
   where x.row_no = 2;
  perform pg_temp.check_true(
    'a code written LOWER then UPPER is still caught the second time',
    v_said like 'error: FX-9 is in this file more than once.%');

  -- ------------------------------------------------------------------
  -- 3. 3900 -- and the branch ORDER that answers for it
  -- ------------------------------------------------------------------
  -- In a company that has imported nothing, 3900 does not exist yet, so
  -- the existence check below would answer "3900 is not an account in
  -- this company's chart" -- true and useless. The assertion is on the
  -- WORDS, because that is the whole of what the ordering buys.
  perform pg_temp.check_true(
    'this company has no 3900 yet, so the order of the chain matters',
    not exists (select 1 from public.accounts
                 where org_id = v_org and code = '3900'));
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '3900', 'credit', '400'),
    jsonb_build_object('account_code', '1110', 'debit', '400'));
  perform pg_temp.check_true(
    'a file naming 3900 is told it is what the import balances TO',
    pg_temp.oi_says(v_org, v_rows, '3900')
      like 'error: Opening Balance Equity is what this import balances %');

  -- ------------------------------------------------------------------
  -- 4. A HEADING
  -- ------------------------------------------------------------------
  -- 1100 is "Current Assets" in the seeded chart: its total is the
  -- accounts under it, and posting to it doubles them.
  perform pg_temp.check_true('1100 really is a heading',
    (select is_group from public.accounts
      where org_id = v_org and code = '1100'));
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1100', 'debit', '700'),
    jsonb_build_object('account_code', '3100', 'credit', '700'));
  perform pg_temp.check_true('a heading cannot take an opening balance',
    pg_temp.oi_says(v_org, v_rows, '1100')
      like 'error: 1100 is a heading, not an account.%');

  -- ------------------------------------------------------------------
  -- 5. SOMETHING THAT IS NOT AN AMOUNT
  -- ------------------------------------------------------------------
  -- `app.import_number(..., 0)` returns null on a value it cannot read,
  -- and the chain says which column it was. A file with "n/a" or a
  -- footnote in a money column is ordinary; read as nought it imports a
  -- balance of nothing and says the file balanced.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'debit', 'n/a'),
    jsonb_build_object('account_code', '3100', 'credit', '100'));
  perform pg_temp.check_true('a debit that is not a number says so',
    pg_temp.oi_says(v_org, v_rows, '1110') like 'error: "n/a" is not an amount.%');
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'debit', '100'),
    jsonb_build_object('account_code', '3100', 'credit', 'see note 4'));
  perform pg_temp.check_true('and so does a credit',
    pg_temp.oi_says(v_org, v_rows, '3100')
      like 'error: "see note 4" is not an amount.%');

  -- ------------------------------------------------------------------
  -- 6. BOTH COLUMNS ON ONE LINE
  -- ------------------------------------------------------------------
  -- A trial balance line is on one side or the other. Both filled is
  -- two spellings of a net figure, and whichever way the import read it
  -- would be a guess.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'debit', '900', 'credit', '400'),
    jsonb_build_object('account_code', '3100', 'credit', '500'));
  perform pg_temp.check_true('a line in both columns is refused',
    pg_temp.oi_says(v_org, v_rows, '1110')
      like 'error: A trial balance line is on one side or the other%');

  -- ------------------------------------------------------------------
  -- 7. A ROW WITH NO DESCRIPTION, and a WARNING that is not "imported"
  -- ------------------------------------------------------------------
  -- Every row in the suite until now carried a description, so the
  -- fallback to 'Opening balance' was unreachable. And the relabel at
  -- the end sets 'ok' rows to 'imported' and leaves a WARNING alone --
  -- an inventory figure with nothing behind it is still a warning after
  -- the commit, which is the only place anybody will see it again.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1110', 'debit', '1000'),
    jsonb_build_object('account_code', '1310', 'debit', '600'),
    jsonb_build_object('account_code', '3100', 'credit', '1600'));
  select count(*) into v_n
    from public.import_opening_balances(v_org, v_rows, date '2026-08-01', true) x
   where x.status = 'warning';
  perform pg_temp.check_eq(
    'a warning survives the commit rather than reading as imported',
    v_n, 1);
  perform pg_temp.check_eq('while the plain rows read as imported',
    (select count(*) from public.import_opening_balances(
       v_org, v_rows, date '2026-08-01', false) x
      where x.status = 'ok'), 2);
  perform pg_temp.check_eq(
    'and a row that said nothing about itself is named for what it is',
    (select l.description from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where a.org_id = v_org and a.code = '1110'
        and l.debit = 1000),
    'Opening balance');

  raise notice 'ok   the chain, in order, one condition at a time';
end $$;

-- =====================================================================
-- The control-account comparison, in BOTH directions
-- =====================================================================
-- A receivable or payable row is never posted: the open invoices and
-- bills brought across already did that, so the row is COMPARED with
-- what they came to. The verdict has two halves and this file had
-- neither -- and the sign of the comparison depends on the account
-- TYPE, so an asset and a liability read the two columns the opposite
-- way round. Three mutants lived in those two sentences.
do $$
declare
  v_boss uuid := pg_temp.another_user('kawalan@oimport.test');
  v_org  uuid; v_cust uuid; v_sup uuid; v_rows jsonb;
begin
  v_org := pg_temp.oi_org('Akaun Kawalan Sdn Bhd', v_boss);
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'C-1', 'Pelanggan', 'customer') returning id into v_cust;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'S-1', 'Pembekal', 'supplier') returning id into v_sup;

  -- Open items brought across first: a 1,000 invoice and a 400 bill.
  perform public.import_open_invoices(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','INV-OLD-1','contact_code','C-1',
      'doc_date','2026-07-01','outstanding_amount','1000')),
    date '2026-08-01', true);
  perform public.import_open_bills(v_org, jsonb_build_array(
    jsonb_build_object('doc_no','BILL-OLD-1','contact_code','S-1',
      'doc_date','2026-07-01','outstanding_amount','400')),
    date '2026-08-01', true);

  -- AGREEING: the file says exactly what the open items came to. The
  -- receivable is an ASSET, so it is a debit of 1,000; the payable is a
  -- LIABILITY, so it is a credit of 400. Reading either the other way
  -- round is what the type-dependent sign exists for.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1210', 'debit', '1000'),
    jsonb_build_object('account_code', '2110', 'credit', '400'));
  perform pg_temp.check_true(
    'a receivable that agrees with the open invoices says so, and is not posted',
    pg_temp.oi_says(v_org, v_rows, '1210')
      like 'ok: Not posted — the open invoices already did, and they agree at 1000.00%');
  perform pg_temp.check_true('and a payable that agrees with the bills likewise',
    pg_temp.oi_says(v_org, v_rows, '2110')
      like 'ok: Not posted — the open bills already did, and they agree at 400.00%');

  -- OUT: the file says something else. A warning rather than an error,
  -- because the file is not wrong -- one of the two sides is, and the
  -- operator is told by how much so they can find out which.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1210', 'debit', '1500'),
    jsonb_build_object('account_code', '2110', 'credit', '400'),
    jsonb_build_object('account_code', '3100', 'credit', '1100'));
  perform pg_temp.check_true(
    'a receivable that does NOT agree is a warning naming both figures',
    pg_temp.oi_says(v_org, v_rows, '1210')
      like 'warning: Not posted. This file says 1500.00 and the open invoices brought across come to 1000.00.%');

  -- And the sign by TYPE, which is the half a same-signed fixture
  -- cannot see: the payable's 400 is a CREDIT, and reading it as
  -- `debit - credit` makes it -400 against a ledger of 400.
  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '2110', 'credit', '400'),
    jsonb_build_object('account_code', '1110', 'debit', '400'));
  perform pg_temp.check_true(
    'a payable is compared as a liability and not as an asset',
    pg_temp.oi_says(v_org, v_rows, '2110')
      like 'ok: Not posted — the open bills already did, and they agree at 400.00%');

  raise notice 'ok   the control accounts, agreeing and not, on both signs';
end $$;

-- =====================================================================
-- A company whose only stocked item has been RETIRED
-- =====================================================================
-- `select exists (... where it.track_inventory and it.deleted_at is
-- null)` decides which of the two inventory warnings a 1310 balance
-- gets, and the two say different things: one says there are no
-- quantities behind the figure at all, the other says the quantities
-- are a separate import. A company that USED to track stock and has
-- retired the item is in the first state, not the second, and
-- `deleted_at is null` is the only thing that knows it.
do $$
declare
  v_boss uuid := pg_temp.another_user('simpan@oimport.test');
  v_org  uuid; v_item uuid; v_rows jsonb;
begin
  v_org := pg_temp.oi_org('Stok Bersara Sdn Bhd', v_boss);
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code)
  values (v_org, 'LAMA', 'Barang lama', 'stock', true, 'C62')
  returning id into v_item;

  v_rows := jsonb_build_array(
    jsonb_build_object('account_code', '1310', 'debit', '900'),
    jsonb_build_object('account_code', '3100', 'credit', '900'));
  perform pg_temp.check_true(
    'while the item is live, a 1310 balance is told the quantities are a '
    'separate import',
    pg_temp.oi_says(v_org, v_rows, '1310')
      like 'warning: Brought in as a figure. Opening stock quantities are a separate import%');

  update public.items set deleted_at = now() where id = v_item;
  perform pg_temp.check_true(
    'and once it is retired, that nothing in the company is stock-tracked '
    'at all',
    pg_temp.oi_says(v_org, v_rows, '1310')
      like 'warning: Brought in as a figure. Nothing in this company is stock-tracked%');

  raise notice 'ok   a retired item is not a company that tracks stock';
end $$;


rollback;
