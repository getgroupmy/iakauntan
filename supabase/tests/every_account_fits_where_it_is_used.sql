-- =====================================================================
-- iAkauntan :: every account fits where it is used (0926)
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/every_account_fits_where_it_is_used.sql
--
-- `0912` asked what kind of account a contact, an item and a document
-- line name. Before `0926` ten other columns asked nothing: an expense
-- and its split, a claim type, a payment method's charge, a fixed
-- asset's three accounts, a stock adjustment, a landed cost charge. An
-- expense coded to receivables posted a receivable with no customer;
-- a landed cost charge on 1310 itself moved the stock with nothing in
-- the ledger. As the owner with the role `authenticated`, and as the
-- database's owner: the rule is for every writer.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

create temporary table t_ef (
  org uuid, other uuid, wh uuid, sup uuid, tile uuid, bill uuid, ct uuid,
  cash uuid, bank uuid, ar uuid, ap uuid, head uuid, inv uuid, git uuid,
  freight uuid, adj uuid, rent uuid, ppe uuid, accum uuid, dep uuid,
  closed uuid, their_inv uuid, old_exp uuid);
grant select on t_ef to authenticated;

do $$
declare r t_ef;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  r.org := pg_temp.test_org('Setiap Akaun Sdn Bhd');
  r.other := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  perform public.create_fiscal_year(r.org, date_trunc('year', pg_temp.today())::date);
  perform pg_temp.open_years(r.org, pg_temp.today() - 30, pg_temp.today() + 30);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select r.org, m, true
    from unnest(array['accounting', 'sales', 'purchases', 'inventory', 'fixed_assets', 'hr']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  select id into r.cash    from public.accounts where org_id = r.org and code = '1110';
  select id into r.bank    from public.accounts where org_id = r.org and code = '1120';
  select id into r.ar      from public.accounts where org_id = r.org and code = '1210';
  select id into r.ap      from public.accounts where org_id = r.org and code = '2110';
  select id into r.head    from public.accounts where org_id = r.org and code = '2100';
  select id into r.inv     from public.accounts where org_id = r.org and code = '1310';
  select id into r.git     from public.accounts where org_id = r.org and code = '1320';
  select id into r.freight from public.accounts where org_id = r.org and code = '5400';
  select id into r.adj     from public.accounts where org_id = r.org and code = '5900';
  select id into r.rent    from public.accounts where org_id = r.org and code = '6200';
  select id into r.ppe     from public.accounts where org_id = r.org and code = '1510';
  select id into r.accum   from public.accounts where org_id = r.org and code = '1590';
  select id into r.dep     from public.accounts where org_id = r.org and code = '6400';
  select id into r.their_inv from public.accounts where org_id = r.other and code = '1310';

  -- Freight once coded to an account of its own, now closed.
  insert into public.accounts (org_id, code, name, account_type, account_subtype, parent_id)
  select r.org, '5490', 'Fret Tutup', 'expense', 'cost_of_sales', a.parent_id
    from public.accounts a where a.org_id = r.org and a.code = '5400'
  returning id into r.closed;
  perform public.retire_account(r.closed);

  insert into public.warehouses (org_id, code, name, is_default)
  values (r.org, 'MAIN', 'Stor', true) returning id into r.wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (r.org, 'SUP', 'Pembekal', 'supplier') returning id into r.sup;
  insert into public.items (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (r.org, 'TILE', 'Jubin', 'stock', true, 'C62', 20) returning id into r.tile;
  insert into public.claim_types (org_id, code, name, expense_account_id)
  values (r.org, 'ADA', 'Tuntutan Ada', r.rent) returning id into r.ct;

  -- A hundred tiles at ten, on the shelf for the freight to land on.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency, exchange_rate, status)
  values (r.org, 'bill', 'BIL-1', pg_temp.today(), pg_temp.today(), r.sup, 'MYR', 1, 'draft')
  returning id into r.bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description, quantity, uom_code, unit_price, warehouse_id)
  values (r.org, r.bill, 1, 'item', r.tile, 'Jubin', 100, 'C62', 10, r.wh);
  perform public.post_purchase_document(r.bill);

  insert into t_ef select r.*;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.test_user(), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  d t_ef; v_bank uuid; v_bank_acct uuid; v_exp uuid; v_adj uuid; v_fa uuid;
  v_run uuid; v_entry uuid; v_col text;
begin
  select * into d from t_ef;
  v_bank := public.upsert_bank_account('Bank Utama', 'Maybank', null, '5123000077', p_org_id => d.org);
  select account_id into v_bank_acct from public.bank_accounts where id = v_bank;

  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, bank_account_id, amount, total_amount, status, description)
  values (d.org, 'EXP-1', pg_temp.today(), d.rent, v_bank, 100, 100, 'draft', 'Sewa')
  returning id into v_exp;
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id)
  values (d.org, 'ADJ-1', pg_temp.today(), d.wh, 'Kiraan', 'stock_take', 'draft', d.adj)
  returning id into v_adj;

  -- -------------------------------------------------------------------
  -- An expense, and its split
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('an expense is not coded to receivables',
    format('insert into public.expenses (org_id, expense_no, expense_date, account_id, bank_account_id, amount, total_amount, status, description) '
           'values (%L, %L, %L, %L, %L, 100, 100, %L, %L)', d.org, 'EXP-2', pg_temp.today(), d.ar, v_bank, 'draft', 'Ke penghutang'),
    'An expense''s account may not be 1210 Accounts Receivable, an accounts receivable account: a receivable or a payable is posted by the document it belongs to, against its customer or supplier, so the aged listing still agrees with the account.',
    '23514');
  perform pg_temp.check_refused('nor to the bank it was paid from',
    format('insert into public.expenses (org_id, expense_no, expense_date, account_id, bank_account_id, amount, total_amount, status, description) '
           'values (%L, %L, %L, %L, %L, 100, 100, %L, %L)', d.org, 'EXP-3', pg_temp.today(), v_bank_acct, v_bank, 'draft', 'Ke bank'),
    'An expense''s account may not be 1121 %, a bank account: money reaches a bank or a till through a receipt or a payment, where the reconciliation can see it.',
    '23514');
  perform pg_temp.check_refused('nor is one already there moved onto the till',
    format('update public.expenses set account_id = %L where id = %L', d.cash, v_exp),
    'An expense''s account may not be 1110 Cash in Hand, a cash account:%', '23514');
  perform pg_temp.check_refused('nor split onto payables',
    format('select public.set_expense_split(%L, %L::jsonb)', v_exp,
           jsonb_build_array(jsonb_build_object('account_id', d.rent, 'amount', 70),
                             jsonb_build_object('account_id', d.ap, 'amount', 30))::text),
    'A line of an expense''s split may not be 2110 Accounts Payable, an accounts payable account:%', '23514');

  -- -------------------------------------------------------------------
  -- A claim type and a payment method
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a new claim type is not charged to receivables',
    format('insert into public.claim_types (org_id, code, name, expense_account_id) values (%L, %L, %L, %L)',
           d.org, 'BARU', 'Tuntutan Baru', d.ar),
    'A claim type''s expense account may not be 1210 Accounts Receivable, an accounts receivable account:%', '23514');
  perform pg_temp.check_refused('nor is one already there moved onto the bank',
    format('update public.claim_types set expense_account_id = %L where id = %L', d.bank, d.ct),
    'A claim type''s expense account may not be 1120 Bank Accounts, a bank account:%', '23514');
  perform pg_temp.check_refused('a payment method does not take its charges out of the bank',
    format('select public.save_payment_method(%L, %L, p_charge_account_id => %L, p_charge_percent => 2)',
           d.org, 'Kad Kredit', d.bank),
    'A payment method''s charge account may not be 1120 Bank Accounts, a bank account:%', '23514');

  -- -------------------------------------------------------------------
  -- A fixed asset, each of its three
  -- -------------------------------------------------------------------
  foreach v_col in array array['asset', 'accumulated', 'expense'] loop
    perform pg_temp.check_refused('a fixed asset''s ' || v_col || ' account is not a bank, a receivable or a heading',
      format('insert into public.fixed_assets (org_id, asset_no, name, asset_account_id, accumulated_account_id, '
             'expense_account_id, acquisition_date, cost, method, useful_life_months) '
             'values (%L, %L, %L, %L, %L, %L, %L, 1200, %L, 60)',
             d.org, 'FA-' || v_col, 'Mesin',
             case v_col when 'asset' then d.ar else d.ppe end,
             case v_col when 'accumulated' then d.head else d.accum end,
             case v_col when 'expense' then d.bank else d.dep end,
             pg_temp.today() - 70, 'straight_line'),
      case v_col
        when 'asset' then 'A fixed asset''s asset account may not be 1210 Accounts Receivable, an accounts receivable account:%'
        when 'accumulated' then 'A fixed asset''s accumulated depreciation account may not be 2100 Current Liabilities, which is a heading: nothing posts to a heading, only to the accounts under it.'
        else 'A fixed asset''s depreciation expense account may not be 1120 Bank Accounts, a bank account:%' end,
      '23514');
  end loop;

  -- -------------------------------------------------------------------
  -- A stock adjustment
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a stock adjustment is not set against receivables',
    format('insert into public.stock_adjustments (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id) '
           'values (%L, %L, %L, %L, %L, %L, %L, %L)',
           d.org, 'ADJ-2', pg_temp.today(), d.wh, 'Kiraan', 'stock_take', 'draft', d.ar),
    'A stock adjustment''s account may not be 1210 Accounts Receivable, an accounts receivable account:%', '23514');
  perform pg_temp.check_refused('nor against the stock itself',
    format('insert into public.stock_adjustments (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id) '
           'values (%L, %L, %L, %L, %L, %L, %L, %L)',
           d.org, 'ADJ-3', pg_temp.today(), d.wh, 'Kiraan', 'stock_take', 'draft', d.inv),
    'A stock adjustment''s account may not be 1310 Inventory, the account the stock is kept in: the stock is posted there and this account takes the other side, so the two would cancel and the stock would move with nothing in the ledger to show it. Choose the account the difference belongs to.',
    '23514');
  perform pg_temp.check_refused('nor is one already there moved onto the stock',
    format('update public.stock_adjustments set account_id = %L where id = %L', d.inv, v_adj),
    'A stock adjustment''s account may not be 1310 Inventory, the account the stock is kept in:%', '23514');

  -- -------------------------------------------------------------------
  -- A landed cost charge
  -- -------------------------------------------------------------------
  perform pg_temp.check_refused('a landed cost charge does not come off the bank',
    format('select public.upsert_landed_cost_run(null, %L, %L, %L::jsonb, %L::jsonb, null)',
           d.org, pg_temp.today(), jsonb_build_array(jsonb_build_object('bill', d.bill))::text,
           jsonb_build_array(jsonb_build_object('description', 'Fret', 'amount', 50, 'account', d.bank))::text),
    'A landed cost charge''s account may not be 1120 Bank Accounts, a bank account:%', '23514');
  perform pg_temp.check_refused('nor off receivables',
    format('select public.upsert_landed_cost_run(null, %L, %L, %L::jsonb, %L::jsonb, null)',
           d.org, pg_temp.today(), jsonb_build_array(jsonb_build_object('bill', d.bill))::text,
           jsonb_build_array(jsonb_build_object('description', 'Fret', 'amount', 50, 'account', d.ar))::text),
    'A landed cost charge''s account may not be 1210 Accounts Receivable, an accounts receivable account:%', '23514');
  perform pg_temp.check_refused('nor off payables',
    format('select public.upsert_landed_cost_run(null, %L, %L, %L::jsonb, %L::jsonb, null)',
           d.org, pg_temp.today(), jsonb_build_array(jsonb_build_object('bill', d.bill))::text,
           jsonb_build_array(jsonb_build_object('description', 'Fret', 'amount', 50, 'account', d.ap))::text),
    'A landed cost charge''s account may not be 2110 Accounts Payable, an accounts payable account:%', '23514');
  perform pg_temp.check_refused('nor off an account that has closed',
    format('select public.upsert_landed_cost_run(null, %L, %L, %L::jsonb, %L::jsonb, null)',
           d.org, pg_temp.today(), jsonb_build_array(jsonb_build_object('bill', d.bill))::text,
           jsonb_build_array(jsonb_build_object('description', 'Fret', 'amount', 50, 'account', d.closed))::text),
    'A landed cost charge''s account may not be 5490 Fret Tutup, which is closed: what is posted through it would land in an account that is out of use. Choose one that is open.',
    '23514');
  perform pg_temp.check_refused('nor off the stock it lands on',
    format('select public.upsert_landed_cost_run(null, %L, %L, %L::jsonb, %L::jsonb, null)',
           d.org, pg_temp.today(), jsonb_build_array(jsonb_build_object('bill', d.bill))::text,
           jsonb_build_array(jsonb_build_object('description', 'Fret', 'amount', 50, 'account', d.inv))::text),
    'A landed cost charge''s account may not be 1310 Inventory, the account the stock is kept in:%', '23514');
  -- Another company's 1310 is the function's own refusal, and names nothing.
  perform pg_temp.check_refused('another company''s stock account is not described',
    format('select public.upsert_landed_cost_run(null, %L, %L, %L::jsonb, %L::jsonb, null)',
           d.org, pg_temp.today(), jsonb_build_array(jsonb_build_object('bill', d.bill))::text,
           jsonb_build_array(jsonb_build_object('description', 'Fret', 'amount', 50, 'account', d.their_inv))::text),
    'No such account.', 'P0002');

  perform pg_temp.check_eq('after all of that nothing was written',
    (select count(*) from public.expenses where org_id = d.org and expense_no <> 'EXP-1')
    + (select count(*) from public.expenses where id = v_exp and account_id <> d.rent)
    + (select count(*) from public.expense_lines where expense_id = v_exp)
    + (select count(*) from public.claim_types where org_id = d.org and (code <> 'ADA' or expense_account_id <> d.rent))
    + (select count(*) from public.payment_methods where org_id = d.org and charge_account_id is not null)
    + (select count(*) from public.fixed_assets where org_id = d.org)
    + (select count(*) from public.stock_adjustments where org_id = d.org and (adjustment_no <> 'ADJ-1' or account_id <> d.adj))
    + (select count(*) from public.landed_cost_runs where org_id = d.org),
    0::bigint);

  -- -------------------------------------------------------------------
  -- What fits is taken, and posts where it should
  -- -------------------------------------------------------------------
  perform public.set_expense_split(v_exp, jsonb_build_array(
    jsonb_build_object('account_id', d.rent, 'amount', 70),
    jsonb_build_object('account_id', d.freight, 'amount', 30)));
  update public.claim_types set expense_account_id = d.freight where id = d.ct;
  perform public.save_payment_method(d.org, 'Kad Kredit', p_charge_account_id => d.rent, p_charge_percent => 2);
  insert into public.fixed_assets
    (org_id, asset_no, name, asset_account_id, accumulated_account_id, expense_account_id,
     acquisition_date, cost, method, useful_life_months)
  values (d.org, 'FA-1', 'Mesin', d.ppe, d.accum, d.dep, pg_temp.today() - 70, 1200, 'straight_line', 60)
  returning id into v_fa;
  update public.stock_adjustments set account_id = null where id = v_adj;
  update public.stock_adjustments set account_id = d.adj where id = v_adj;

  perform pg_temp.check_eq('an account of the right kind is taken by each of them, as before',
    (select count(*) from public.expense_lines where expense_id = v_exp)
    + (select count(*) from public.claim_types where id = d.ct and expense_account_id = d.freight)
    + (select count(*) from public.payment_methods where org_id = d.org and charge_account_id = d.rent)
    + (select count(*) from public.fixed_assets where id = v_fa)
    + (select count(*) from public.stock_adjustments where id = v_adj and account_id = d.adj),
    6::bigint);

  -- Freight held in Goods in Transit and brought onto the stock: what a
  -- landed cost run is for, and still taken.
  v_run := public.upsert_landed_cost_run(null, d.org, pg_temp.today(),
    jsonb_build_array(jsonb_build_object('bill', d.bill)),
    jsonb_build_array(jsonb_build_object('description', 'Fret dalam transit', 'amount', 50, 'account', d.git)),
    null);
  v_entry := public.post_landed_cost_run(v_run);
  perform pg_temp.check_eq('a charge held in Goods in Transit comes off it',
    (select sum(l.debit - l.credit) from public.gl_lines l where l.entry_id = v_entry and l.account_id = d.git),
    -50::numeric);
  perform pg_temp.check_eq('and onto the stock',
    (select sum(l.debit - l.credit) from public.gl_lines l where l.entry_id = v_entry and l.account_id = d.inv),
    50::numeric);
  perform pg_temp.check_eq('so the ledger''s stock is the stock''s own figure',
    (select sum(l.debit - l.credit) from public.gl_lines l where l.account_id = d.inv),
    (select sum(m.total_cost) from public.stock_movements m where m.org_id = d.org));
  perform pg_temp.check_eq('which is the hundred tiles and their freight',
    (select sum(m.total_cost) from public.stock_movements m where m.org_id = d.org),
    1050::numeric);
end $$;

reset role;

-- ---------------------------------------------------------------------
-- For every writer, and a row that already names one is saved whole
-- ---------------------------------------------------------------------
do $$
declare d t_ef; v_run uuid; v_old uuid;
begin
  select * into d from t_ef;
  select id into v_run from public.landed_cost_runs where org_id = d.org;

  perform pg_temp.check_refused('the database''s owner does not put a charge on the bank either',
    format('insert into public.landed_cost_charges (org_id, run_id, line_no, description, amount, account_id) '
           'values (%L, %L, 9, %L, 10, %L)', d.org, v_run, 'Fret', d.bank),
    'A landed cost charge''s account may not be 1120 Bank Accounts, a bank account:%', '23514');
  perform pg_temp.check_refused('nor on a heading',
    format('insert into public.landed_cost_charges (org_id, run_id, line_no, description, amount, account_id) '
           'values (%L, %L, 9, %L, 10, %L)', d.org, v_run, 'Fret', d.head),
    'A landed cost charge''s account may not be 2100 Current Liabilities, which is a heading:%', '23514');
  perform pg_temp.check_refused('nor an expense on receivables',
    format('update public.expenses set account_id = %L where org_id = %L', d.ar, d.org),
    'An expense''s account may not be 1210 Accounts Receivable, an accounts receivable account:%', '23514');
  perform pg_temp.check_refused('nor a charge on the stock it lands on',
    format('insert into public.landed_cost_charges (org_id, run_id, line_no, description, amount, account_id) '
           'values (%L, %L, 9, %L, 10, %L)', d.org, v_run, 'Fret', d.inv),
    'A landed cost charge''s account may not be 1310 Inventory, the account the stock is kept in:%', '23514');
  -- Another company's 1310 is the tenant key's, and is described to nobody.
  perform pg_temp.check_refused('another company''s stock account is left to the tenant key',
    format('insert into public.landed_cost_charges (org_id, run_id, line_no, description, amount, account_id) '
           'values (%L, %L, 9, %L, 10, %L)', d.org, v_run, 'Fret', d.their_inv),
    'insert or update on table "landed_cost_charges" violates foreign key constraint "landed_cost_charges_account_same_org"%',
    '23503');

  -- An expense coded to receivables, and a stock adjustment set against
  -- the stock, before there was a rule.
  alter table public.expenses disable trigger an_account_fits_where_it_is_used;
  insert into public.expenses
    (org_id, expense_no, expense_date, account_id, amount, total_amount, status, description)
  values (d.org, 'EXP-LAMA', pg_temp.today(), d.ar, 40, 40, 'draft', 'Lama')
  returning id into v_old;
  alter table public.expenses enable trigger an_account_fits_where_it_is_used;
  -- Saved whole, as the app saves a row: the account sent back unchanged.
  update public.expenses set description = 'Lama, dibetulkan', account_id = account_id where id = v_old;
  perform pg_temp.check_eq('a row that already names one is still saved whole',
    (select description from public.expenses where id = v_old), 'Lama, dibetulkan');

  alter table public.stock_adjustments disable trigger the_stock_is_not_its_own_other_side;
  insert into public.stock_adjustments
    (org_id, adjustment_no, adjustment_date, warehouse_id, reason, adjustment_type, status, account_id)
  values (d.org, 'ADJ-LAMA', pg_temp.today(), d.wh, 'Kiraan', 'stock_take', 'draft', d.inv)
  returning id into v_old;
  alter table public.stock_adjustments enable trigger the_stock_is_not_its_own_other_side;
  update public.stock_adjustments set reason = 'Kiraan semula', account_id = account_id where id = v_old;
  perform pg_temp.check_eq('and so is one already set against the stock',
    (select reason from public.stock_adjustments where id = v_old), 'Kiraan semula');
end $$;

rollback;
