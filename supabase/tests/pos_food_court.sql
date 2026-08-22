-- =====================================================================
-- Point of sale :: the food court, and what each stall is owed
--
-- Three arithmetics, and each of them is somebody's money.
--
--   1. The commission. A stall on 15% that sold RM 200 is owed RM 170,
--      and a court that rounds the wrong way over a thousand tickets a
--      week is quietly keeping money it did not earn.
--
--   2. The discount. A court that takes RM 10 off a basket and then
--      settles the stalls on the undiscounted figure has paid for its
--      own promotion twice. The share comes off in proportion.
--
--   3. The period. A day settled is a day closed. Paying for the same
--      Tuesday twice is the failure this is built to make impossible,
--      and it is impossible in the database rather than in a function
--      somebody might call twice at once.
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
  v_walkin uuid;
  v_outlet uuid;
  v_reg    uuid;
  v_shift  uuid;
  v_cash   uuid;

  v_ops1   uuid;   -- the nasi kandar operator
  v_ops2   uuid;   -- the cendol operator
  v_s1     uuid;
  v_s2     uuid;
  v_nasi   uuid;
  v_cendol uuid;
  v_court  uuid;   -- something the court sells itself

  v_sale   uuid;
  v_r      record;
  v_msg    text;
  v_bill   text;
  v_n      numeric;
  v_yday   date := (now() at time zone 'Asia/Kuala_Lumpur')::date - 1;
begin
  v_org := pg_temp.test_org('Medan Selera Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory','purchases']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  perform pg_temp.sign_in_as(v_owner);

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'MAIN', 'The court', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Counter sales', 'customer') returning id into v_walkin;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'GERAI1', 'Nasi Kandar Pak Din', 'supplier')
  returning id into v_ops1;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'GERAI2', 'Cendol Kak Yah', 'supplier')
  returning id into v_ops2;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'MEDAN', 'Medan Selera', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_outlet;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'C1', 'The counter') returning id into v_reg;
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, false);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true)
  returning id into v_cash;
  v_shift := public.open_pos_shift(v_reg, 100.00);

  -- ------------------------------------------------------------------
  -- 1. Two stalls, two operators, two commissions
  -- ------------------------------------------------------------------
  v_s1 := public.upsert_pos_stall(null, v_outlet, 'A1', 'Nasi Kandar Pak Din',
                                  v_ops1, 15);
  v_s2 := public.upsert_pos_stall(null, v_outlet, 'B2', 'Cendol Kak Yah',
                                  v_ops2, 10);

  perform pg_temp.check_eq('a court has stalls in it',
    (select count(*)::integer from public.pos_stalls_list(v_outlet)), 2);
  perform pg_temp.check_eq('each with its own cut',
    (select l.commission_percent from public.pos_stalls_list(v_outlet) l
      where l.id = v_s1), 15::numeric);
  perform pg_temp.check_eq('and its own operator to settle with',
    (select l.operator from public.pos_stalls_list(v_outlet) l
      where l.id = v_s2), 'Cendol Kak Yah');

  -- A commission is a share of the takings.
  begin
    perform public.upsert_pos_stall(null, v_outlet, 'C3', 'Silly', v_ops1, 120);
    perform pg_temp.check_true('a commission cannot be more than all of it',
      false);
  exception when others then
    perform pg_temp.check_true('a commission cannot be more than all of it',
      true);
  end;

  -- A stall is somebody's business.
  begin
    perform public.upsert_pos_stall(null, v_outlet, 'C3', 'Nobody''s',
                                    gen_random_uuid(), 10);
    perform pg_temp.check_true('a stall needs somebody to settle with', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a stall needs somebody to settle with',
      v_msg like '%somebody''s business%');
  end;

  -- ------------------------------------------------------------------
  -- 2. Whose food it is, stamped on the line
  -- ------------------------------------------------------------------
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'NASI', 'Nasi kandar', 'service', false, 'C62', 12.00)
  returning id into v_nasi;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'CENDOL', 'Cendol', 'service', false, 'C62', 4.00)
  returning id into v_cendol;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'AIR', 'Air suam', 'service', false, 'C62', 1.00)
  returning id into v_court;

  perform public.set_item_stall(v_nasi, v_s1);
  perform public.set_item_stall(v_cendol, v_s2);
  -- The water is the court's own, and stays unstalled.

  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_nasi, 1, 12.00);
  perform public.add_pos_sale_line(v_sale, v_cendol, 1, 4.00);
  perform public.add_pos_sale_line(v_sale, v_court, 1, 1.00);

  perform pg_temp.check_eq('a line knows whose food it is',
    (select l.stall_id from public.pos_sale_lines l
      where l.sale_id = v_sale and l.item_id = v_nasi), v_s1);
  perform pg_temp.check_true('and the court''s own line belongs to nobody',
    (select l.stall_id from public.pos_sale_lines l
      where l.sale_id = v_sale and l.item_id = v_court) is null);

  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 17.00)));

  -- The stall changing hands must not rewrite what has been sold.
  perform public.set_item_stall(v_nasi, v_s2);
  perform pg_temp.check_eq('a line already rung up does not follow the item',
    (select l.stall_id from public.pos_sale_lines l
      where l.sale_id = v_sale and l.item_id = v_nasi), v_s1);
  perform public.set_item_stall(v_nasi, v_s1);

  -- ------------------------------------------------------------------
  -- 3. The commission
  -- ------------------------------------------------------------------
  -- Move it to yesterday so it can be settled: a period that has not
  -- finished cannot be.
  update public.pos_sales s
     set completed_at = (v_yday + time '12:00') at time zone 'Asia/Kuala_Lumpur'
   where s.id = v_sale;

  select * into v_r from public.pos_stall_takings(v_outlet, v_yday, v_yday) t
   where t.stall_id = v_s1;
  perform pg_temp.check_eq('the nasi stall sold twelve ringgit',
    v_r.gross, 12.00::numeric);
  perform pg_temp.check_eq('the court keeps fifteen per cent of it',
    v_r.commission, 1.80::numeric);
  perform pg_temp.check_eq('and the stall is owed the rest',
    v_r.net, 10.20::numeric);

  select * into v_r from public.pos_stall_takings(v_outlet, v_yday, v_yday) t
   where t.stall_id = v_s2;
  perform pg_temp.check_eq('the cendol stall sold four',
    v_r.gross, 4.00::numeric);
  perform pg_temp.check_eq('at its own ten per cent',
    v_r.commission, 0.40::numeric);
  perform pg_temp.check_eq('leaving three sixty',
    v_r.net, 3.60::numeric);

  perform pg_temp.check_eq(
    'and the ringgit of water is the court''s alone, on no stall''s figure',
    (select round(sum(t.gross), 2) from public.pos_stall_takings(v_outlet, v_yday, v_yday) t),
    16.00::numeric);

  -- ------------------------------------------------------------------
  -- 4. A discount the court gave away
  -- ------------------------------------------------------------------
  -- A second bill: 12 of nasi and 4 of cendol, with 4 off the whole
  -- basket. The customer paid 12, which is three quarters of the list,
  -- so each stall's share is three quarters of what it listed.
  v_sale := public.open_pos_sale(v_reg);
  perform public.add_pos_sale_line(v_sale, v_nasi, 1, 12.00);
  perform public.add_pos_sale_line(v_sale, v_cendol, 1, 4.00);
  perform public.discount_pos_sale(v_sale, null, 4.00, 'Opening week');
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', 12.00)));
  update public.pos_sales s
     set completed_at = (v_yday + time '13:00') at time zone 'Asia/Kuala_Lumpur'
   where s.id = v_sale;

  select * into v_r from public.pos_stall_takings(v_outlet, v_yday, v_yday) t
   where t.stall_id = v_s1;
  -- 12 from the first bill, and three quarters of 12 from the second.
  perform pg_temp.check_eq(
    'a basket discount comes off the stall''s share in proportion',
    v_r.gross, 21.00::numeric);
  select * into v_r from public.pos_stall_takings(v_outlet, v_yday, v_yday) t
   where t.stall_id = v_s2;
  perform pg_temp.check_eq('and off the other stall''s too',
    v_r.gross, 7.00::numeric);

  -- ------------------------------------------------------------------
  -- 5. Settling
  -- ------------------------------------------------------------------
  begin
    perform public.settle_pos_stalls(v_outlet, v_yday,
      (now() at time zone 'Asia/Kuala_Lumpur')::date);
    perform pg_temp.check_true('a day still trading cannot be settled', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('a day still trading cannot be settled',
      v_msg like '%not over yet%');
  end;

  select t.bill_no into v_bill from public.settle_pos_stalls(v_outlet, v_yday, v_yday) t
   where t.stall_id = v_s1;

  perform pg_temp.check_true('settling raises a bill against the operator',
    v_bill is not null);
  perform pg_temp.check_eq('for the takings less the commission',
    (select d.total_amount from public.purchase_documents d
      where d.doc_no = v_bill), 17.85::numeric);
  perform pg_temp.check_eq('owed to the person who runs the stall',
    (select c.name from public.purchase_documents d
      join public.contacts c on c.id = d.contact_id where d.doc_no = v_bill),
    'Nasi Kandar Pak Din');
  perform pg_temp.check_eq('and posted, not left in a drawer',
    (select d.status::text from public.purchase_documents d
      where d.doc_no = v_bill), 'posted');

  -- The ledger. The court's cost of buying from its stalls is its own
  -- account, so the two margins can be told apart.
  perform pg_temp.check_eq('the cost lands in stall purchases',
    (select round(sum(gl.debit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
       join public.purchase_documents d on d.id = e.source_id
      where d.doc_no = v_bill and a.code = '5150'), 17.85::numeric);
  perform pg_temp.check_eq('and the payable is what the stall is owed',
    (select round(sum(gl.credit), 2)
       from public.gl_lines gl
       join public.gl_entries e on e.id = gl.entry_id
       join public.accounts a on a.id = gl.account_id
       join public.purchase_documents d on d.id = e.source_id
      where d.doc_no = v_bill and a.code = '2110'), 17.85::numeric);

  perform pg_temp.check_eq('both stalls were settled',
    (select count(*)::integer from public.pos_stall_settlements_list(v_outlet)), 2);
  perform pg_temp.check_eq('and the court kept its commission',
    (select round(sum(l.commission), 2)
       from public.pos_stall_settlements_list(v_outlet) l), 3.85::numeric);

  -- ------------------------------------------------------------------
  -- 6. The same Tuesday, twice
  -- ------------------------------------------------------------------
  perform pg_temp.check_true('the takings now say they are settled',
    (select t.settled from public.pos_stall_takings(v_outlet, v_yday, v_yday) t
      where t.stall_id = v_s1));

  begin
    perform public.settle_pos_stalls(v_outlet, v_yday, v_yday);
    perform pg_temp.check_true('a settled period cannot be settled again',
      false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'a settled period cannot be settled again, and it says why',
      v_msg like '%same Tuesday twice%');
  end;

  -- Nor a period that merely overlaps one.
  begin
    perform public.settle_pos_stalls(v_outlet, v_yday - 3, v_yday);
    perform pg_temp.check_true('nor one that overlaps it', false);
  exception when others then
    perform pg_temp.check_true('nor one that overlaps it', true);
  end;

  -- And the database itself refuses, not only the function.
  begin
    insert into public.pos_stall_settlements
      (org_id, stall_id, period_from, period_to, gross, commission, net)
    values (v_org, v_s1, v_yday, v_yday, 1, 0, 1);
    perform pg_temp.check_true(
      'the overlap is refused by the table, not just by the function', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      'the overlap is refused by the table, not just by the function',
      v_msg like '%pos_stall_settlements_no_overlap%'
        or v_msg like '%conflicting key%');
  end;

  -- A day nobody traded is not an error worth a bill.
  begin
    perform public.settle_pos_stalls(v_outlet, v_yday - 30, v_yday - 20);
    perform pg_temp.check_true('an empty week settles nothing', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true('an empty week settles nothing',
      v_msg like '%did not sell%' or v_msg like '%No stall sold%');
  end;

  raise notice 'ok   pos_food_court';
end $$;

rollback;
