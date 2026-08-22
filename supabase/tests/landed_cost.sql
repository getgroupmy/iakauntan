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

rollback;
