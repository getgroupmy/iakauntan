-- =====================================================================
-- iAkauntan :: ten per cent for the table, and eight on top of that
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/pos_service_charge.sql
--
-- Every Malaysian restaurant bill ends the same way:
--
--     Subtotal              100.00
--     Service charge 10%     10.00
--     Service tax 8%          8.80
--     Total                 118.80
--
-- The 8.80 is the whole point. Service tax is charged on 110.00 and not
-- on 100.00, so a bill that taxes the food alone is 80 sen short on
-- every hundred ringgit — and until `0410` this schema had no service
-- charge at all, on the outlet, on the sale or on the document.
--
-- The compound falls out of the per-line tax rather than needing a
-- second pass: the lines already carry service tax on the food, so
-- taxing the charge at the same rate gives
-- rate x food + rate x charge = rate x (food + charge). That identity
-- is asserted below against the arithmetic rather than trusted.
--
-- Nothing is written; the file rolls back.
-- =====================================================================

\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

do $$
declare
  v_org    uuid;
  v_wh     uuid;
  v_walkin uuid;
  v_item   uuid;
  v_st8    uuid;
  v_outlet uuid;
  v_plain  uuid;   -- an outlet that charges nothing
  v_free   uuid;   -- a charge with no tax on it
  v_reg    uuid;
  v_reg2   uuid;
  v_reg3   uuid;
  v_cash   uuid;
  v_bank   uuid;
  v_sale   uuid;
  v_inv    uuid;
  v_gl     uuid;
  v_first  uuid;
  v_txt    text;
  v_other  uuid;
  v_other_tax uuid;
  v_msg    text;
  s        record;
begin
  v_org := pg_temp.test_org('Warung Sepuluh Peratus Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Kitchen') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Diners', 'customer') returning id into v_walkin;

  -- `pg_temp.test_org` seeds the chart and not the tax codes, so the
  -- eight per cent is created here. The same row `create_organization`
  -- seeds for a real company: tax type 02, eight per cent, output to
  -- 2130.
  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8, 'both',
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_st8;

  -- One dish at a hundred ringgit, so every figure below is the worked
  -- example and can be checked by hand.
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, sales_tax_code_id)
  values (v_org, 'SET', 'Set dinner', 'service', false, 'C62',
          100.00, 0, v_st8)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax, service_charge_percent, service_charge_tax_code_id)
  values (v_org, 'DINE', 'The dining room', 'food_beverage', v_wh, v_walkin, false,
          10.00, v_st8)
  returning id into v_outlet;

  -- The takeaway counter in the same company. No service charge: nobody
  -- waited on anybody. This is why the percentage is on the outlet.
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'TAPAU', 'The takeaway counter', 'food_beverage', v_wh, v_walkin, false)
  returning id into v_plain;

  -- And a stall that adds a service charge and is not registered for
  -- service tax, so there is nothing to put on top of it.
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax, service_charge_percent)
  values (v_org, 'GERAI', 'The stall', 'food_beverage', v_wh, v_walkin, false, 10.00)
  returning id into v_free;

  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Dining till') returning id into v_reg;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_plain, 'T2', 'Takeaway till') returning id into v_reg2;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_free, 'T3', 'Stall till') returning id into v_reg3;

  insert into public.bank_accounts
    (org_id, account_id, name, account_type, currency)
  values (v_org,
          (select id from public.accounts where org_id = v_org and code = '1110'),
          'Cash in hand', 'cash', 'MYR')
  returning id into v_bank;
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, bank_account_id,
     counts_in_drawer, gives_change)
  values (v_org, 'CASH', 'Cash', 'cash', '01', v_bank, true, true)
  returning id into v_cash;

  -- ------------------------------------------------------------------
  -- The worked example
  -- ------------------------------------------------------------------
  perform public.open_pos_shift(v_reg, 0.00);
  v_sale := public.open_pos_sale(v_reg, null);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);

  select * into s from public.pos_sales where id = v_sale;

  perform pg_temp.check_eq('the food is a hundred', s.subtotal, 100.00);
  perform pg_temp.check_eq('the service charge is ten per cent of it',
    s.service_charge, 10.00);
  perform pg_temp.check_eq('the tax on the food is eight', s.tax_amount, 8.00);
  perform pg_temp.check_eq('and eighty sen rides the service charge',
    s.service_charge_tax, 0.80);
  perform pg_temp.check_eq('so the bill is a hundred and eighteen eighty',
    s.total_amount, 118.80);

  -- The identity the whole file exists for. Written as the arithmetic
  -- the Act asks for rather than as the number above, so a change to
  -- either rate keeps this assertion honest.
  perform pg_temp.check_eq(
    'and the tax charged is eight per cent of the food plus the charge, '
    'not of the food alone',
    s.tax_amount + s.service_charge_tax,
    round((s.subtotal + s.service_charge) * 8 / 100.0, 2));
  perform pg_temp.check_true('which is more than eight per cent of the food',
    s.tax_amount + s.service_charge_tax > round(s.subtotal * 8 / 100.0, 2));

  -- ------------------------------------------------------------------
  -- What the ledger is told
  -- ------------------------------------------------------------------
  perform public.complete_pos_sale(
    v_sale, jsonb_build_array(
      jsonb_build_object('type', v_cash, 'amount', 118.80)), null);

  v_first := v_sale;
  select invoice_id into v_inv from public.pos_sales where id = v_sale;
  perform pg_temp.check_true('the sale raised an invoice', v_inv is not null);

  perform pg_temp.check_eq('the invoice carries the service charge',
    (select service_charge_amount from public.sales_documents where id = v_inv),
    10.00);
  perform pg_temp.check_eq('and the tax on the whole bill',
    (select tax_amount from public.sales_documents where id = v_inv), 8.80);
  perform pg_temp.check_eq('and adds up to what was charged',
    (select total_amount from public.sales_documents where id = v_inv), 118.80);

  select gl_entry_id into v_gl from public.sales_documents where id = v_inv;
  perform pg_temp.check_true('and it posted', v_gl is not null);

  -- 4250, not 4100. A restaurant needs to see what it took at the table
  -- apart from what it took for the table: the charge is what the
  -- service staff are paid out of.
  perform pg_temp.check_eq('the service charge is credited to 4250',
    (select coalesce(sum(l.credit - l.debit), 0)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_gl and a.code = '4250'), 10.00);
  perform pg_temp.check_eq('the food to 4100',
    (select coalesce(sum(l.credit - l.debit), 0)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_gl and a.code = '4100'), 100.00);
  perform pg_temp.check_eq('and the whole of the tax to output tax',
    (select coalesce(sum(l.credit - l.debit), 0)
       from public.gl_lines l
       join public.accounts a on a.id = l.account_id
      where l.entry_id = v_gl and a.code = '2130'), 8.80);
  perform pg_temp.check_eq('and the journal balances',
    (select coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
       from public.gl_lines l where l.entry_id = v_gl), 0);

  -- ------------------------------------------------------------------
  -- The counter that charges nothing
  -- ------------------------------------------------------------------
  -- The positive control. A service charge added to every bill in the
  -- company would satisfy every assertion above and be wrong for half
  -- the outlets in it.
  perform public.open_pos_shift(v_reg2, 0.00);
  v_sale := public.open_pos_sale(v_reg2, null);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);
  select * into s from public.pos_sales where id = v_sale;

  perform pg_temp.check_eq('a takeaway carries no service charge',
    s.service_charge, 0);
  perform pg_temp.check_eq('and nothing rides it', s.service_charge_tax, 0);
  perform pg_temp.check_eq('so the bill is the food and its own tax',
    s.total_amount, 108.00);

  -- ------------------------------------------------------------------
  -- A charge with nothing on top
  -- ------------------------------------------------------------------
  -- An outlet that is not registered for service tax still adds a
  -- service charge, and there is no tax to put on it. A null tax code
  -- means exactly that, and asserting it is what stops the null being
  -- read as "use whatever the food used".
  perform public.open_pos_shift(v_reg3, 0.00);
  v_sale := public.open_pos_sale(v_reg3, null);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);
  select * into s from public.pos_sales where id = v_sale;

  perform pg_temp.check_eq('the stall charges its ten per cent',
    s.service_charge, 10.00);
  perform pg_temp.check_eq('and puts nothing on top of it',
    s.service_charge_tax, 0);
  perform pg_temp.check_eq('so the bill is the food, its tax, and the charge',
    s.total_amount, 118.00);

  -- ------------------------------------------------------------------
  -- What the paper says
  -- ------------------------------------------------------------------
  -- Ten per cent added to a bill that does not mention it is not a
  -- service charge, it is a discrepancy. The percentage goes on the
  -- line because that is what a customer checks the arithmetic against.
  v_txt := public.pos_receipt_text(v_first);
  perform pg_temp.check_true('the receipt names the service charge',
    v_txt like '%Service charge%');
  perform pg_temp.check_true('with the percentage on it',
    v_txt like '%Service charge 10%%');
  perform pg_temp.check_true('and the amount beside it',
    v_txt like '%10.00%');
  perform pg_temp.check_true('above the tax it is taxed with, where a '
    'Malaysian bill puts it',
    position('Service charge' in v_txt) < position('Tax' in v_txt));

  -- ------------------------------------------------------------------
  -- Setting it
  -- ------------------------------------------------------------------
  perform public.set_pos_service_charge(v_plain, 5.00, v_st8);
  perform pg_temp.check_eq('the takeaway counter can be given a charge',
    (select service_charge_percent from public.pos_outlets where id = v_plain),
    5.00);
  perform pg_temp.check_true('and the tax that rides it',
    (select service_charge_tax_code_id from public.pos_outlets
      where id = v_plain) = v_st8);

  perform public.set_pos_service_charge(v_plain, 0, null);
  perform pg_temp.check_eq('and taken off again',
    (select service_charge_percent from public.pos_outlets where id = v_plain), 0);

  -- The column carries a check constraint as well, so "is it refused"
  -- is answered by two things and a test that asks only that cannot
  -- tell them apart -- the first version of this file could not, and
  -- the guard in the function survived being deleted. What the function
  -- adds is a sentence a person can act on, so that is what is
  -- asserted; the constraint's own message names the constraint.
  begin
    perform public.set_pos_service_charge(v_outlet, 150, v_st8);
    raise exception 'FAIL: a service charge of 150 per cent was accepted';
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    perform pg_temp.check_true(
      format('a service charge is a percentage of the bill, and says so: %s',
             v_msg),
      v_msg like '%percentage of the bill%');
  end;

  -- The reach a parameter can have that a policy cannot see. Another
  -- company's tax code is a uuid like any other, and without this check
  -- the charge would be taxed at a rate nobody here chose.
  v_other := pg_temp.test_org('Syarikat Lain Sdn Bhd');
  perform pg_temp.sign_in_as(pg_temp.test_user());
  insert into public.tax_codes (org_id, code, name, tax_type_code, rate)
  values (v_other, 'ST6', 'Service Tax 6%', '02', 6)
  returning id into v_other_tax;

  begin
    perform public.set_pos_service_charge(v_outlet, 10, v_other_tax);
    raise exception
      'FAIL: another company''s tax code was accepted on this outlet';
  exception when sqlstate '23503' then
    raise notice 'ok   and the tax code has to be this company''s';
  end;

  perform pg_temp.check_true('so the outlet still has its own',
    (select service_charge_tax_code_id from public.pos_outlets
      where id = v_outlet) = v_st8);

  perform pg_temp.sign_out();
end $$;

rollback;
