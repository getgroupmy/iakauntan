-- =====================================================================
-- iAkauntan :: the SST-02 return declares the tax the ledger holds
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sst_return_declares_what_was_charged.sql
--
-- `report_sst_summary` is the return a registered person files with
-- Customs. It summed `tax_amount` off the document **lines**, and the
-- service charge `0410` added is not a line -- it is a percentage of
-- all of them, so its tax sat on the header. On the worked example from
-- `pos_service_charge.sql` the document carried RM8.80 of output tax,
-- the ledger carried RM8.80 at 2130, and the return declared RM8.00.
--
-- So this file does not assert 8.80. It asserts the two identities that
-- make 8.80 the only possible answer, either of which the next tax
-- charged somewhere new will fail:
--
--   1. The return's output tax equals the output tax **in the ledger**
--      -- the credit to 2130 raised by posting those documents.
--   2. The return's output tax equals the sum of `tax_amount` on the
--      documents in the period.
--
-- A number in a test is a number somebody has to remember to change. An
-- identity against the ledger is the thing an auditor would check, and
-- it is the thing that was actually broken.
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
  v_plain  uuid;
  v_reg    uuid;
  v_reg2   uuid;
  v_cash   uuid;
  v_bank   uuid;
  v_sale   uuid;
  v_inv    uuid;
  s        record;
  v_ledger numeric;
  v_return numeric;
  v_docs   numeric;
  v_base   numeric;
begin
  v_org := pg_temp.test_org('Restoran Lapan Puluh Sen Sdn Bhd');
  perform public.create_fiscal_year(v_org, date_trunc('year', current_date)::date);

  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos','inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name)
  values (v_org, 'MAIN', 'Kitchen') returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type)
  values (v_org, 'WALK-IN', 'Diners', 'customer') returning id into v_walkin;

  insert into public.tax_codes
    (org_id, code, name, tax_type_code, rate, applies_to,
     sales_tax_account_id, purchase_tax_account_id)
  values (v_org, 'ST8', 'Service Tax 8%', '02', 8, 'both',
          (select id from public.accounts where org_id = v_org and code = '2130'),
          (select id from public.accounts where org_id = v_org and code = '1410'))
  returning id into v_st8;

  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code,
     unit_price, cost_price, sales_tax_code_id)
  values (v_org, 'SET', 'Set dinner', 'service', false, 'C62', 100.00, 0, v_st8)
  returning id into v_item;

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax, service_charge_percent, service_charge_tax_code_id)
  values (v_org, 'DINE', 'The dining room', 'food_beverage', v_wh, v_walkin,
          false, 10.00, v_st8)
  returning id into v_outlet;

  -- The takeaway counter charges nothing for service. Its sales are in
  -- the same return and must not acquire a service charge row.
  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'TAPAU', 'The takeaway counter', 'food_beverage', v_wh,
          v_walkin, false)
  returning id into v_plain;

  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_outlet, 'T1', 'Dining till') returning id into v_reg;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_plain, 'T2', 'Takeaway till') returning id into v_reg2;

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
  -- A day's trade: two tables and one takeaway
  -- ------------------------------------------------------------------
  perform public.open_pos_shift(v_reg, 0.00);
  for i in 1..2 loop
    v_sale := public.open_pos_sale(v_reg, null);
    perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);
    select * into s from public.pos_sales where id = v_sale;
    perform public.complete_pos_sale(
      v_sale,
      jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', s.total_amount)),
      null);
  end loop;

  perform public.open_pos_shift(v_reg2, 0.00);
  v_sale := public.open_pos_sale(v_reg2, null);
  perform public.add_pos_sale_line(v_sale, v_item, 1, 100.00);
  select * into s from public.pos_sales where id = v_sale;
  perform public.complete_pos_sale(
    v_sale,
    jsonb_build_array(jsonb_build_object('type', v_cash, 'amount', s.total_amount)),
    null);

  -- ------------------------------------------------------------------
  -- The two identities
  -- ------------------------------------------------------------------
  select coalesce(sum(tax_amount), 0) into v_return
    from public.report_sst_summary(v_org, current_date - 1, current_date + 1)
   where direction = 'output';

  -- What posting actually put in output tax. 2130 is credited by
  -- `app.post_sales_document_internal` and by nothing else here, so
  -- this is the figure a Customs officer would tie the return to.
  select coalesce(sum(l.credit - l.debit), 0) into v_ledger
    from public.gl_lines l
    join public.accounts a on a.id = l.account_id
   where a.org_id = v_org and a.code = '2130';

  select coalesce(sum(d.tax_amount), 0) into v_docs
    from public.sales_documents d
   where d.org_id = v_org
     and d.doc_type in ('invoice', 'credit_note', 'debit_note', 'refund_note')
     and d.status not in ('draft', 'void');

  perform pg_temp.check_true('there is tax to declare in the first place',
    v_ledger > 0);
  perform pg_temp.check_eq(
    'the return declares the output tax the ledger holds',
    v_return, v_ledger);
  perform pg_temp.check_eq(
    'and the output tax the documents carry',
    v_return, v_docs);

  -- ------------------------------------------------------------------
  -- And the taxable value it is charged on
  -- ------------------------------------------------------------------
  -- The identity above is satisfied by declaring the right tax against
  -- the wrong value. Service tax is charged on the food *and* the
  -- charge, so a return that declares 8.80 on a taxable value of 300 is
  -- a return that says the rate is not eight per cent.
  select coalesce(sum(taxable_amount), 0) into v_base
    from public.report_sst_summary(v_org, current_date - 1, current_date + 1)
   where direction = 'output';

  -- Three set dinners at 100, plus ten per cent on the two eaten in.
  perform pg_temp.check_eq('the taxable value is the food and the charge',
    v_base, 320.00);
  perform pg_temp.check_eq('so the tax is eight per cent of it',
    v_return, round(v_base * 8 / 100.0, 2));

  -- ------------------------------------------------------------------
  -- Under its own tax type, not somebody else's
  -- ------------------------------------------------------------------
  -- The return is filed by type. A service charge landing under a code
  -- it was not charged under balances and still misstates the return.
  perform pg_temp.check_eq('and it is all under service tax, type 02',
    (select coalesce(sum(tax_amount), 0)
       from public.report_sst_summary(v_org, current_date - 1, current_date + 1)
      where direction = 'output' and tax_type_code = '02'),
    v_return);

  perform pg_temp.check_eq('the takeaway counter contributes no charge',
    (select coalesce(sum(service_charge_amount), 0)
       from public.sales_documents d
       join public.pos_sales p on p.invoice_id = d.id
      where p.outlet_id = v_plain),
    0.00);

  -- ------------------------------------------------------------------
  -- What the document remembers about it
  -- ------------------------------------------------------------------
  select d.* into s from public.sales_documents d
    join public.pos_sales p on p.invoice_id = d.id
   where p.outlet_id = v_outlet limit 1;
  perform pg_temp.check_eq('the tax on the charge is kept on the document',
    s.service_charge_tax, 0.80);
  perform pg_temp.check_true('with the code it was charged under',
    s.service_charge_tax_code_id = v_st8);
  perform pg_temp.check_eq(
    'and it is inside the header total, not on top of it',
    s.tax_amount, 8.80);

  -- Posted, so it cannot be edited afterwards. A figure a return
  -- declares that can be changed later is a return that stops agreeing
  -- with the ledger. `0238`'s guard does the refusing.
  begin
    update public.sales_documents set service_charge_tax = 99.00 where id = s.id;
    raise exception 'the tax on a posted charge could be edited';
  exception when others then
    if sqlstate = 'P0001' and sqlerrm = 'the tax on a posted charge could be edited'
      then raise;
    end if;
    perform pg_temp.check_true(
      'and a posted document refuses to have it changed', true);
  end;
end $$;

rollback;
