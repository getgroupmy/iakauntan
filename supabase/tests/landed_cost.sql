-- =====================================================================
-- The freight is part of what it cost
--
-- One assertion matters more than the rest: after a landed cost run,
-- the item's weighted average is the goods plus its share of the
-- charges. If that number is wrong every subsequent sale of the item is
-- costed wrong, and nothing else in the system will say so.
--
-- The rest: the spread itself, by value and by quantity; a charge
-- landing to the sen with nothing left over; goods already sold keeping
-- their share on the expense account rather than being capitalised onto
-- stock that is not there; and a posted run refusing to be edited.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_wh     uuid;
  v_sup    uuid;
  v_cust   uuid;
  v_tile   uuid;   -- cheap, heavy, a hundred of them
  v_tap    uuid;   -- dear, and the same hundred

  v_bill   uuid;
  v_inv    uuid;
  v_run    uuid;
  v_org2   uuid;
  v_run2   uuid;
  v_entry  uuid;
  v_freight uuid;
  v_duty   uuid;
  v_msg    text;
  v_n      numeric;
begin
  v_org := pg_temp.test_org('Pengimport Bahan Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','purchases','sales']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'The yard', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'A supplier in Foshan', 'supplier') returning id into v_sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'A contractor', 'customer') returning id into v_cust;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'TILE', 'Floor tile', 'stock', true, 'C62', 20.00)
  returning id into v_tile;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'TAP', 'Basin tap', 'stock', true, 'C62', 60.00)
  returning id into v_tap;

  -- A hundred tiles at ten, a hundred taps at thirty. Same count, three
  -- times the money, which is what makes the two bases give different
  -- answers.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-1', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill, 1, 'item', v_tile, 'Tiles', 100, 'C62', 10.00, v_wh),
         (v_org, v_bill, 2, 'item', v_tap,  'Taps',  100, 'C62', 30.00, v_wh);
  perform public.post_purchase_document(v_bill);

  perform pg_temp.check_eq('the goods cost what they cost, to begin with',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tile),
    10::numeric);

  select id into v_freight from public.accounts
   where org_id = v_org and code = '5400';
  perform pg_temp.check_true(
    'and 5400 was in the chart all along, waiting for this',
    v_freight is not null);
  select id into v_duty from public.accounts
   where org_id = v_org and code = '5100';

  -- ------------------------------------------------------------------
  -- 1. A charge spread by value
  -- ------------------------------------------------------------------
  --
  -- RM 400 of ocean freight over RM 1000 of tiles and RM 3000 of taps:
  -- a quarter to the tiles, three quarters to the taps.
  v_run := public.upsert_landed_cost_run(
    null, v_org, current_date,
    jsonb_build_array(jsonb_build_object('bill', v_bill)),
    jsonb_build_array(jsonb_build_object(
      'description', 'Ocean freight', 'amount', 400, 'basis', 'value')),
    'Container FSCU1234567');

  perform pg_temp.check_eq('the tiles take a quarter of the freight',
    (select p.amount from public.landed_cost_preview(v_run) p
      where p.item_code = 'TILE'), 100::numeric);
  perform pg_temp.check_eq('and the taps take the other three quarters',
    (select p.amount from public.landed_cost_preview(v_run) p
      where p.item_code = 'TAP'), 300::numeric);
  perform pg_temp.check_eq('nothing is left over',
    (select sum(p.amount) from public.landed_cost_preview(v_run) p),
    400::numeric);

  -- ------------------------------------------------------------------
  -- The register of runs
  --
  -- `landed_cost_runs_list` is the screen somebody opens to find last
  -- month's container, and it was called by no test. Four of its columns
  -- are counts and sums computed per run rather than stored, and the
  -- pair that matters is `total` against `capitalised`: what the freight
  -- cost against how much of it has actually reached the stock. They are
  -- equal after posting and they are not before, which is the difference
  -- between a run somebody prepared and a run somebody finished.
  -- ------------------------------------------------------------------
  perform pg_temp.check_eq('a run appears while it is still a draft',
    (select l.status from public.landed_cost_runs_list(v_org) l
      where l.id = v_run), 'draft');
  perform pg_temp.check_eq('with the bill it is spreading over',
    (select l.bills from public.landed_cost_runs_list(v_org) l
      where l.id = v_run), 1);
  perform pg_temp.check_eq('and the charge it is spreading',
    (select l.charges from public.landed_cost_runs_list(v_org) l
      where l.id = v_run), 1);
  perform pg_temp.check_eq('which comes to the freight',
    (select l.total from public.landed_cost_runs_list(v_org) l
      where l.id = v_run), 400::numeric);
  perform pg_temp.check_eq('none of which is on the stock yet',
    (select l.capitalised from public.landed_cost_runs_list(v_org) l
      where l.id = v_run), 0::numeric);

  v_entry := public.post_landed_cost_run(v_run);

  perform pg_temp.check_eq('once posted the whole charge is capitalised',
    (select l.capitalised from public.landed_cost_runs_list(v_org) l
      where l.id = v_run), 400::numeric);
  perform pg_temp.check_eq('and the run says so',
    (select l.status from public.landed_cost_runs_list(v_org) l
      where l.id = v_run), 'posted');
  perform pg_temp.check_eq('a status nothing is in comes back empty',
    (select count(*) from public.landed_cost_runs_list(v_org, 'draft')), 0);
  perform pg_temp.check_eq('and the one it is in does not',
    (select count(*) from public.landed_cost_runs_list(v_org, 'posted')), 1);

  -- A second importer, so that two things this list promises can be told
  -- apart at all. Its run carries a charge and no bill, which is the one
  -- shape where `bills` and `charges` are different numbers — everything
  -- else in this file is one of each, and a list that counted the wrong
  -- one would read correctly throughout.
  --
  -- It belongs to the same fixture user on purpose. If the caller were
  -- not a member of it, dropping the org filter from the query would
  -- change nothing here and the leak it would open could not be seen.
  v_org2 := pg_temp.test_org('Pengimport Lain Sdn Bhd');
  perform pg_temp.sign_in_as(v_owner);
  insert into public.landed_cost_runs (org_id, run_no, run_date, status)
  values (v_org2, 'LC-OTHER', current_date, 'draft') returning id into v_run2;
  insert into public.landed_cost_charges
    (org_id, run_id, line_no, description, amount, basis, account_id)
  values (v_org2, v_run2, 1, 'Ocean freight', 90, 'value',
          (select id from public.accounts where org_id = v_org2 and code = '5400'));

  perform pg_temp.check_eq('a charge with no bill behind it still counts',
    (select l.charges from public.landed_cost_runs_list(v_org2) l
      where l.id = v_run2), 1);
  perform pg_temp.check_eq('and the bills it is spread over are none',
    (select l.bills from public.landed_cost_runs_list(v_org2) l
      where l.id = v_run2), 0);
  perform pg_temp.check_eq('one company''s runs are not the other''s',
    (select count(*) from public.landed_cost_runs_list(v_org)
      where id = v_run2), 0);

  -- What a container cost to bring in is what this company pays for its
  -- goods, which is its margin written down.
  perform pg_temp.sign_in_as(pg_temp.another_user('nosy@freight.test'));
  begin
    perform * from public.landed_cost_runs_list(v_org);
    perform pg_temp.check_true('another importer''s runs are refused', false);
  exception when sqlstate '42501' then
    perform pg_temp.check_true('another importer''s runs are refused', true);
  end;
  perform pg_temp.sign_in_as(v_owner);

  perform pg_temp.check_eq(
    'a tile now costs eleven ringgit, which is what it cost',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tile),
    11::numeric);
  perform pg_temp.check_eq('and a tap thirty-three',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tap),
    33::numeric);
  perform pg_temp.check_eq('with not one more tile in the yard',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tile),
    100::numeric);
  perform pg_temp.check_eq('the stock is worth the goods plus the freight',
    (select round(sum(sl.value), 2) from public.stock_levels sl
      where sl.warehouse_id = v_wh), 4400::numeric);

  -- The ledger says the same thing from the other side.
  perform pg_temp.check_eq('inventory rises by the freight',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1310'), 400::numeric);
  perform pg_temp.check_eq('and the freight account is relieved of it',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '5400'), 400::numeric);

  -- ------------------------------------------------------------------
  -- 2. A charge spread by quantity
  -- ------------------------------------------------------------------
  --
  -- Customs duty is on the count, not the value: the same hundred of
  -- each takes the same hundred ringgit each.
  v_run := public.upsert_landed_cost_run(
    null, v_org, current_date,
    jsonb_build_array(jsonb_build_object('bill', v_bill)),
    jsonb_build_array(jsonb_build_object(
      'description', 'Import duty', 'amount', 200, 'basis', 'quantity',
      'account', v_freight)),
    null);

  perform pg_temp.check_eq('duty falls on the count, so half each',
    (select p.amount from public.landed_cost_preview(v_run) p
      where p.item_code = 'TILE'), 100::numeric);
  perform public.post_landed_cost_run(v_run);

  perform pg_temp.check_eq('a tile is twelve now',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tile),
    12::numeric);
  perform pg_temp.check_eq('and a tap thirty-four, not thirty-six',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tap),
    34::numeric);

  -- ------------------------------------------------------------------
  -- 3. What has already been sold cannot be capitalised
  -- ------------------------------------------------------------------
  --
  -- Half the tiles go out, and then a freight invoice turns up for the
  -- shipment they came in on. The half still in the yard takes its
  -- share; the half that was sold keeps its share on the expense
  -- account, because the sale that carried it is posted and its cost is
  -- history.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_cust,
          'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_tile, 'Tiles', 50, 'C62', 20.00, v_wh);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('fifty tiles left',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_tile),
    50::numeric);

  v_run := public.upsert_landed_cost_run(
    null, v_org, current_date,
    jsonb_build_array(jsonb_build_object('bill', v_bill)),
    jsonb_build_array(jsonb_build_object(
      'description', 'A late haulage invoice', 'amount', 400,
      'basis', 'quantity')),
    null);

  perform pg_temp.check_eq('the tiles'' share of it is still two hundred',
    (select p.amount from public.landed_cost_preview(v_run) p
      where p.item_code = 'TILE'), 200::numeric);
  perform pg_temp.check_eq('but only half of that can go onto stock',
    (select p.capitalised from public.landed_cost_preview(v_run) p
      where p.item_code = 'TILE'), 100::numeric);
  perform pg_temp.check_eq('the taps are all still there, so all of theirs can',
    (select p.capitalised from public.landed_cost_preview(v_run) p
      where p.item_code = 'TAP'), 200::numeric);

  v_entry := public.post_landed_cost_run(v_run);

  perform pg_temp.check_eq(
    'the fifty tiles left carry two ringgit of haulage each',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tile),
    14::numeric);
  perform pg_temp.check_eq(
    'and the ledger only capitalises what there was stock for',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      join public.accounts a on a.id = gl.account_id
     where gl.entry_id = v_entry and a.code = '1310'), 300::numeric);
  perform pg_temp.check_eq(
    'the hundred that could not be is still on the expense account',
    (select round(sum(a2.amount - a2.capitalised), 2)
       from public.landed_cost_allocations a2 where a2.run_id = v_run),
    100::numeric);

  -- ------------------------------------------------------------------
  -- 4. A charge that does not divide, still lands to the sen
  -- ------------------------------------------------------------------
  v_run := public.upsert_landed_cost_run(
    null, v_org, current_date,
    jsonb_build_array(jsonb_build_object('bill', v_bill)),
    jsonb_build_array(jsonb_build_object(
      'description', 'Port charges', 'amount', 100.01, 'basis', 'quantity')),
    null);
  perform pg_temp.check_eq('a hundred ringgit and one sen, all of it spread',
    (select sum(p.amount) from public.landed_cost_preview(v_run) p),
    100.01::numeric);
  perform public.cancel_landed_cost_run(v_run);
  perform pg_temp.check_eq('and a cancelled run does nothing to anything',
    (select round(i.average_cost, 4) from public.items i where i.id = v_tile),
    14::numeric);

  -- ------------------------------------------------------------------
  -- 5. What it refuses
  -- ------------------------------------------------------------------
  v_run := public.upsert_landed_cost_run(
    null, v_org, current_date,
    jsonb_build_array(jsonb_build_object('bill', v_bill)),
    jsonb_build_array(jsonb_build_object(
      'description', 'Insurance', 'amount', 50, 'basis', 'value')),
    null);
  perform public.post_landed_cost_run(v_run);

  begin
    perform public.post_landed_cost_run(v_run);
    perform pg_temp.check_true('a run posted twice would double the stock value', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a run cannot be posted twice',
      v_msg like '%already posted%');
  end;

  begin
    perform public.upsert_landed_cost_run(
      v_run, v_org, current_date,
      jsonb_build_array(jsonb_build_object('bill', v_bill)),
      jsonb_build_array(jsonb_build_object(
        'description', 'Insurance', 'amount', 5000, 'basis', 'value')),
      null);
    perform pg_temp.check_true('a posted run would be rewritten', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'and what a posted run did to the stock cannot be edited afterwards',
      v_msg like '%cannot be rewritten%');
  end;

  -- A bill nobody has posted has put nothing in the yard.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'bill', 'BILL-2', current_date, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill;
  begin
    perform public.upsert_landed_cost_run(
      null, v_org, current_date,
      jsonb_build_array(jsonb_build_object('bill', v_bill)),
      jsonb_build_array(jsonb_build_object(
        'description', 'Freight', 'amount', 10, 'basis', 'value')),
      null);
    perform pg_temp.check_true('a draft bill has stock to cost', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'freight cannot land on a bill that has not been posted',
      v_msg like '%on a shelf yet%');
  end;

  -- ------------------------------------------------------------------
  -- 6. A tracked item takes landed cost without naming a batch
  -- ------------------------------------------------------------------
  --
  -- The lot invariant refuses a movement of a tracked item that names
  -- no units. A landed cost movement moves no units at all, so there is
  -- nothing to name -- and before 0271 put the condition on the trigger
  -- this raised and the whole run failed.
  update public.items set tracking = 'batch' where id = v_tap;
  select count(*) into v_n from public.stock_movements
   where item_id = v_tap and movement_type = 'landed_cost';

  v_run := public.upsert_landed_cost_run(
    null, v_org, current_date,
    jsonb_build_array(jsonb_build_object(
      'bill', (select t.bill_id from public.landed_cost_targets t
                join public.landed_cost_runs r on r.id = t.run_id
               where r.status = 'posted' limit 1))),
    jsonb_build_array(jsonb_build_object(
      'description', 'Demurrage', 'amount', 60, 'basis', 'quantity')),
    null);
  perform public.post_landed_cost_run(v_run);
  perform pg_temp.check_eq(
    'a batch-tracked item is revalued without naming a batch',
    (select count(*) from public.stock_movements
      where item_id = v_tap and movement_type = 'landed_cost'), v_n + 1);

  raise notice 'ok   landed_cost';
end $$;

-- ---------------------------------------------------------------------
-- Kos Mendarat Sdn Bhd: the spread between the charge accounts, and
-- everything the run refuses
--
-- Sweeping `post_landed_cost_run` killed six of seventeen mutants. What
-- the charges do to the average cost is nailed down above; almost
-- nothing else was.
--
-- Two of the survivors are the same fixture problem. Every run in this
-- file carries ONE charge line, and with one charge line the
-- proportioning is unobservable: the ratio is applied, then immediately
-- overwritten by `v_credit := v_left` because the first line is also
-- the last. `v_ratio := 1` and the rounding override could both be
-- deleted and the single line still came out at exactly what was
-- capitalised. Three charge lines on three accounts, with a third of
-- the goods still on the shelf, separates them: 100 each becomes 33.33,
-- 33.33 and 33.34, and the odd sen is the whole point of the override.
--
-- The dates are the other kind. Every run here is dated `current_date`,
-- so a function that used today's date instead of the run's would agree
-- with the fixture on every single assertion. This run is dated thirty
-- days back.
-- ---------------------------------------------------------------------
do $$
declare
  v_org    uuid;
  v_owner  uuid := pg_temp.test_user();
  v_wh     uuid; v_sup uuid; v_cust uuid;
  v_batu   uuid; v_pasir uuid;
  v_bill_a uuid; v_bill_b uuid; v_inv uuid;
  v_a1 uuid; v_a2 uuid; v_a3 uuid; v_inv_acct uuid;
  v_run    uuid; v_entry uuid; v_bare uuid; v_entry_run uuid;
  v_when   date := current_date - 30;
  v_msg    text;
begin
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.allow_many_companies();
  v_org := pg_temp.test_org('Kos Mendarat Sdn Bhd');
  perform pg_temp.allow_many_companies();
  -- The run is dated thirty days back, which can be last year in
  -- January, so both years get a fiscal period.
  perform public.create_fiscal_year(v_org,
    (date_trunc('year', current_date) - interval '1 year')::date);
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['inventory','purchases','sales']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'The yard', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'SUP', 'A quarry', 'supplier') returning id into v_sup;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'CUST', 'A builder', 'customer') returning id into v_cust;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'BATU', 'Stone', 'stock', true, 'C62', 20.00)
  returning id into v_batu;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'PASIR', 'Sand', 'stock', true, 'C62', 20.00)
  returning id into v_pasir;

  select id into v_a1 from public.accounts where org_id = v_org and code = '5400';
  select id into v_a2 from public.accounts where org_id = v_org and code = '5100';
  select id into v_a3 from public.accounts where org_id = v_org and code = '5900';
  select id into v_inv_acct from public.accounts
   where org_id = v_org and code = '1310' and not is_group;

  -- Two bills, so a run can be aimed at one item or at both.
  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (v_org, 'bill', 'BILL-A', current_date - 40, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill_a;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill_a, 1, 'item', v_batu, 'Stone', 300, 'C62', 10.00, v_wh);
  perform public.post_purchase_document(v_bill_a);

  insert into public.purchase_documents
    (org_id, doc_type, doc_no, doc_date, contact_id, currency, exchange_rate, status)
  values (v_org, 'bill', 'BILL-B', current_date - 40, v_sup, 'MYR', 1, 'draft')
  returning id into v_bill_b;
  insert into public.purchase_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_bill_b, 1, 'item', v_pasir, 'Sand', 100, 'C62', 10.00, v_wh);
  perform public.post_purchase_document(v_bill_b);

  -- Two hundred of the three hundred stone go out, so a third is left
  -- and the ratio is a third. All the sand goes.
  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
     exchange_rate, status)
  values (v_org, 'invoice', 'INV-A', current_date - 35, current_date - 35,
          v_cust, 'MYR', 1, 'draft')
  returning id into v_inv;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, uom_code, unit_price, warehouse_id)
  values (v_org, v_inv, 1, 'item', v_batu, 'Stone', 200, 'C62', 20.00, v_wh),
         (v_org, v_inv, 2, 'item', v_pasir, 'Sand', 100, 'C62', 20.00, v_wh);
  perform public.post_sales_document(v_inv);

  perform pg_temp.check_eq('a third of the stone is left',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_batu),
    100::numeric);
  perform pg_temp.check_eq('and none of the sand',
    (select round(i.quantity_on_hand, 4) from public.items i where i.id = v_pasir),
    0::numeric);

  -- ------------------------------------------------------------------
  -- Three charges, three accounts, a third of it capitalised
  -- ------------------------------------------------------------------
  v_run := public.upsert_landed_cost_run(
    null, v_org, v_when,
    jsonb_build_array(jsonb_build_object('bill', v_bill_a)),
    jsonb_build_array(
      jsonb_build_object('description', 'Ocean freight', 'amount', 100,
                         'basis', 'value', 'account', v_a1),
      jsonb_build_object('description', 'Import duty', 'amount', 100,
                         'basis', 'value', 'account', v_a2),
      jsonb_build_object('description', 'Demurrage', 'amount', 100,
                         'basis', 'value', 'account', v_a3)),
    'Three charges');

  perform pg_temp.check_eq('three hundred of charges falls on the stone',
    (select p.amount from public.landed_cost_preview(v_run) p
      where p.item_code = 'BATU'), 300::numeric);
  perform pg_temp.check_eq('and only the third still on the shelf takes it',
    (select p.capitalised from public.landed_cost_preview(v_run) p
      where p.item_code = 'BATU'), 100::numeric);

  v_entry := public.post_landed_cost_run(v_run);
  v_entry_run := v_run;

  -- A third of three hundred is a hundred, and a third of each hundred
  -- is 33.33 with a sen over. The sen goes to the last line, which is
  -- the only reason the entry balances at all.
  perform pg_temp.check_eq('the freight account gives up a third of its share',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_a1), 33.33::numeric);
  perform pg_temp.check_eq('so does the duty account',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_a2), 33.33::numeric);
  perform pg_temp.check_eq('and the last one takes the odd sen',
    (select round(sum(gl.credit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_a3), 33.34::numeric);
  perform pg_temp.check_eq('which is what reaches the stock',
    (select round(sum(gl.debit), 2) from public.gl_lines gl
      where gl.entry_id = v_entry and gl.account_id = v_inv_acct), 100::numeric);

  -- ------------------------------------------------------------------
  -- On the day of the run, and tied to the journal
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the movement is dated the day of the run',
    (select bool_and(m.movement_date = v_when) from public.stock_movements m
      where m.source_table = 'landed_cost_runs' and m.source_id = v_run));
  perform pg_temp.check_true('and so is the journal',
    (select e.entry_date = v_when from public.gl_entries e where e.id = v_entry));
  perform pg_temp.check_true('the movement names the journal it went with',
    (select bool_and(m.gl_entry_id = v_entry) from public.stock_movements m
      where m.source_table = 'landed_cost_runs' and m.source_id = v_run));
  perform pg_temp.check_true('and the run names it too, and says it is posted',
    (select r.gl_entry_id = v_entry and r.status = 'posted'
       from public.landed_cost_runs r where r.id = v_run));

  -- ------------------------------------------------------------------
  -- A line with nothing left to sit on gets no movement at all
  -- ------------------------------------------------------------------
  v_run := public.upsert_landed_cost_run(
    null, v_org, v_when,
    jsonb_build_array(jsonb_build_object('bill', v_bill_a),
                      jsonb_build_object('bill', v_bill_b)),
    jsonb_build_array(jsonb_build_object(
      'description', 'A late haulage invoice', 'amount', 80,
      'basis', 'quantity', 'account', v_a1)),
    null);
  perform public.post_landed_cost_run(v_run);
  perform pg_temp.check_eq('the sand, all sold, gets no revaluation movement',
    (select count(*)::integer from public.stock_movements m
      where m.source_table = 'landed_cost_runs' and m.source_id = v_run
        and m.item_id = v_pasir), 0);
  perform pg_temp.check_eq('while the stone still on the shelf gets one',
    (select count(*)::integer from public.stock_movements m
      where m.source_table = 'landed_cost_runs' and m.source_id = v_run
        and m.item_id = v_batu), 1);

  -- ------------------------------------------------------------------
  -- And a run where everything has been sold is refused outright
  -- ------------------------------------------------------------------
  v_run := public.upsert_landed_cost_run(
    null, v_org, v_when,
    jsonb_build_array(jsonb_build_object('bill', v_bill_b)),
    jsonb_build_array(jsonb_build_object(
      'description', 'Sand haulage', 'amount', 50,
      'basis', 'value', 'account', v_a1)),
    null);
  begin
    perform public.post_landed_cost_run(v_run);
    raise exception 'FAIL capitalised charges onto stock that is not there';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('charges cannot sit on goods that are gone',
      v_msg like '%already been sold%');
  end;

  -- ------------------------------------------------------------------
  -- A run with nothing to spread
  -- ------------------------------------------------------------------
  insert into public.landed_cost_runs (org_id, run_no, run_date, status)
  values (v_org, 'LC-KOSONG', v_when, 'draft') returning id into v_bare;
  insert into public.landed_cost_targets (org_id, run_id, bill_id)
  values (v_org, v_bare, v_bill_a);
  begin
    perform public.post_landed_cost_run(v_bare);
    raise exception 'FAIL posted a run with no charges on it';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a run with no charges has nothing to spread',
      v_msg like '%nothing to spread%');
  end;

  -- ------------------------------------------------------------------
  -- Who may post one
  -- ------------------------------------------------------------------
  v_run := public.upsert_landed_cost_run(
    null, v_org, v_when,
    jsonb_build_array(jsonb_build_object('bill', v_bill_a)),
    jsonb_build_array(jsonb_build_object(
      'description', 'Insurance', 'amount', 30,
      'basis', 'value', 'account', v_a1)),
    null);
  perform pg_temp.sign_in_as(pg_temp.another_user('luar-kos@example.test'));
  begin
    perform public.post_landed_cost_run(v_run);
    raise exception 'FAIL a stranger posted another company''s landed cost';
  exception when sqlstate '42501' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('somebody outside the company cannot post one',
      v_msg like '%not permitted to write%');
  end;
  perform pg_temp.sign_in_as(v_owner);
  perform pg_temp.check_true('and the run is still a draft',
    (select r.status = 'draft' and r.gl_entry_id is null
       from public.landed_cost_runs r where r.id = v_run));

  -- ------------------------------------------------------------------
  -- A company with nowhere to put the stock
  --
  -- The whole point of landed cost is that it lands on inventory. A
  -- chart with no 1310 has nowhere for it to land, and posting anyway
  -- would silently drop the debit side.
  -- ------------------------------------------------------------------
  update public.accounts set code = '1312'
   where org_id = v_org and code = '1310' and not is_group;
  begin
    perform public.post_landed_cost_run(v_run);
    raise exception 'FAIL posted with no inventory account in the chart';
  exception when sqlstate 'P0002' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('with no inventory account it will not post',
      v_msg like '%no inventory account%');
  end;
  update public.accounts set code = '1310'
   where org_id = v_org and code = '1312' and not is_group;

  -- ------------------------------------------------------------------
  -- Cancelling one
  --
  -- `cancel_landed_cost_run` had no assertion of its own that could
  -- fail: the file cancels a draft run and then checks the average cost
  -- has not moved, which is equally true of a function that does
  -- nothing at all. All four of its decisions were open.
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('an id that names no run cannot be cancelled',
    (select not exists (select 1 from public.landed_cost_runs
                         where id = '00000000-0000-0000-0000-000000000001')));
  begin
    perform public.cancel_landed_cost_run(
      '00000000-0000-0000-0000-000000000001'::uuid);
    raise exception 'FAIL cancelled a run that does not exist';
  exception when sqlstate 'P0002' then
    raise notice 'ok   and it says so rather than reporting success';
  end;

  perform pg_temp.sign_in_as(pg_temp.another_user('luar-batal-kos@example.test'));
  begin
    perform public.cancel_landed_cost_run(v_run);
    raise exception 'FAIL a stranger cancelled another company''s run';
  exception when sqlstate '42501' then
    raise notice 'ok   somebody outside the company cannot cancel one';
  end;
  perform pg_temp.sign_in_as(v_owner);

  -- The posted run from the top of this block. Stock it has already
  -- revalued cannot be un-revalued by changing a status.
  begin
    perform public.cancel_landed_cost_run(v_entry_run);
    raise exception 'FAIL cancelled a run that had already revalued stock';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a posted run is undone with an adjustment',
      v_msg like '%stock adjustment%');
  end;

  perform pg_temp.check_true('a draft run is cancelled',
    public.cancel_landed_cost_run(v_run) = true);
  perform pg_temp.check_true('and the run says cancelled, not draft',
    (select r.status = 'cancelled' from public.landed_cost_runs r
      where r.id = v_run));

  perform pg_temp.sign_out();
end $$;

rollback;
