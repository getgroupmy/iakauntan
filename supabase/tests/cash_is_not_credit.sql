-- =====================================================================
-- iAkauntan :: cash is not credit
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/cash_is_not_credit.sql
--
-- Measured before 0467, on a customer on credit hold paying cash at the
-- counter:
--
--   "Encik Zaid is on credit hold, so INV-2026-00001 cannot be posted.
--    Take the hold off, or raise this as a cash sale."
--
-- The till printing that at a customer who is handing over money, and
-- telling the cashier to do what they have just done.
--
-- The half that has to keep working is the other tender: a counter sale
-- put on somebody's tab **is** credit, and a hold has to stop that. So
-- the assertions come in pairs.
--
-- Nothing is written; the file rolls back.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

\i supabase/tests/_helpers.sql

-- A shop, a counter, and one customer the office has stopped lending to.
create or replace function pg_temp.till_shop(p_name text)
returns uuid language plpgsql as $$
declare
  v_org uuid := pg_temp.test_org(p_name);
  v_wh  uuid;
  v_c   uuid;
  v_o   uuid;
begin
  perform public.create_fiscal_year(
    v_org, date_trunc('year', current_date)::date);
  insert into public.org_modules (org_id, module_code, is_enabled)
  select v_org, m, true from unnest(array['pos', 'accounting', 'inventory']) m
  on conflict (org_id, module_code) do update set is_enabled = true;

  insert into public.warehouses (org_id, code, name, is_default)
  values (v_org, 'W', 'Store', true) returning id into v_wh;
  insert into public.contacts (org_id, code, name, contact_type,
                               credit_limit, credit_hold)
  values (v_org, 'REG', 'Encik Zaid', 'customer', 500, false)
  returning id into v_c;
  insert into public.items
    (org_id, code, name, item_type, track_inventory, uom_code, unit_price)
  values (v_org, 'KOPI', 'Kopi', 'service', false, 'C62', 5.00);

  insert into public.pos_outlets
    (org_id, code, name, business_type, warehouse_id, walk_in_contact_id,
     prices_include_tax)
  values (v_org, 'K', 'Kedai', 'retail', v_wh, v_c, false)
  returning id into v_o;
  insert into public.pos_registers (org_id, outlet_id, code, name)
  values (v_org, v_o, 'C1', 'Counter');
  insert into public.pos_settings (org_id, round_cash_to_5sen)
  values (v_org, false);
  insert into public.pos_tender_types
    (org_id, code, name, kind, payment_mode_code, counts_in_drawer,
     gives_change, opens_drawer)
  values (v_org, 'TUNAI', 'Tunai', 'cash', '01', true, true, true),
         (v_org, 'AKAUN', 'Akaun', 'on_account', null, false, false, false);
  perform public.open_pos_shift(
    (select id from public.pos_registers where org_id = v_org), 100.00);
  return v_org;
end $$;

create or replace function pg_temp.till_sell(
  p_org uuid, p_tender text, p_amount numeric)
returns text language plpgsql as $$
declare
  v_sale uuid;
  v_msg  text;
begin
  -- The customer is named on the sale. A sale on account has to be —
  -- `complete_pos_sale` refuses one that is not, which is right and is
  -- not what this file is about.
  v_sale := public.open_pos_sale(
    (select id from public.pos_registers where org_id = p_org),
    (select id from public.contacts where org_id = p_org and code = 'REG'));
  perform public.add_pos_sale_line(v_sale,
    (select id from public.items where org_id = p_org and code = 'KOPI'),
    1, p_amount);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object(
      'type', (select id from public.pos_tender_types
                where org_id = p_org and code = p_tender),
      'amount', p_amount)));
  return 'ok';
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;


-- Two tenders on one basket: most of it in the drawer, a little on the
-- tab. This is the shape that tells the two readings of the rule apart
-- — the basket and the amount actually being lent are different
-- numbers, and only one of them is credit.
create or replace function pg_temp.till_split(
  p_org uuid, p_cash numeric, p_onacct numeric)
returns text language plpgsql as $$
declare
  v_sale uuid;
  v_msg  text;
begin
  v_sale := public.open_pos_sale(
    (select id from public.pos_registers where org_id = p_org),
    (select id from public.contacts where org_id = p_org and code = 'REG'));
  perform public.add_pos_sale_line(v_sale,
    (select id from public.items where org_id = p_org and code = 'KOPI'),
    1, p_cash + p_onacct);
  perform public.complete_pos_sale(v_sale, jsonb_build_array(
    jsonb_build_object(
      'type', (select id from public.pos_tender_types
                where org_id = p_org and code = 'TUNAI'),
      'amount', p_cash),
    jsonb_build_object(
      'type', (select id from public.pos_tender_types
                where org_id = p_org and code = 'AKAUN'),
      'amount', p_onacct)));
  return 'ok';
exception when others then
  get stacked diagnostics v_msg = message_text;
  return v_msg;
end $$;

-- ---------------------------------------------------------------------
-- The customer on hold, with cash in their hand
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_out text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.till_shop('Kedai Tunai Sdn Bhd');
  update public.contacts set credit_hold = true where org_id = v_org;

  v_out := pg_temp.till_sell(v_org, 'TUNAI', 5.00);
  perform pg_temp.check_eq(
    'a customer on hold can still buy a coffee with cash', v_out, 'ok');

  perform pg_temp.check_eq('and the sale is in the books',
    (select count(*)::integer from public.pos_sales
      where org_id = v_org and status = 'completed'), 1);
  perform pg_temp.check_eq('with nothing left owing on it',
    (select d.balance_amount from public.sales_documents d
       join public.pos_sales s on s.invoice_id = d.id
      where d.org_id = v_org), 0::numeric);

  -- The other tender. This one is a promise, and a hold is exactly the
  -- instruction not to take promises from this customer.
  v_out := pg_temp.till_sell(v_org, 'AKAUN', 5.00);
  perform pg_temp.check_true(
    'but the shop still cannot put it on their tab',
    v_out like '%on credit hold%');
end $$;

-- ---------------------------------------------------------------------
-- And the limit, which is arithmetic rather than a flag
-- ---------------------------------------------------------------------
do $$
declare
  v_org uuid;
  v_c   uuid;
  v_out text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.till_shop('Kedai Had Sdn Bhd');
  update public.organizations set credit_control = 'block' where id = v_org;
  select id into v_c from public.contacts where org_id = v_org;

  -- Already at the limit: five hundred owed, five hundred allowed.
  perform public.import_open_invoices(
    v_org,
    jsonb_build_array(jsonb_build_object(
      'contact_code', 'REG', 'doc_no', 'OLD-1',
      'doc_date', to_char(current_date - 100, 'YYYY-MM-DD'),
      'due_date', to_char(current_date - 70, 'YYYY-MM-DD'),
      'outstanding_amount', '500')),
    current_date, true);

  v_out := pg_temp.till_sell(v_org, 'TUNAI', 5.00);
  perform pg_temp.check_eq(
    'a customer at their limit can still pay cash', v_out, 'ok');

  v_out := pg_temp.till_sell(v_org, 'AKAUN', 5.00);
  perform pg_temp.check_true(
    'and still cannot go over it on account',
    v_out like '%against a credit limit of%');
  -- The figure in the refusal is what would be lent, not the basket:
  -- 500 already owed plus the 5 on account.
  perform pg_temp.check_true('by the amount actually being lent',
    v_out like '%505.00%');
end $$;


-- ---------------------------------------------------------------------
-- Part in the drawer, part on the tab
-- ---------------------------------------------------------------------
--
-- The assertion that tells the two readings of the rule apart. A
-- RM100 basket, RM80 of it cash and RM20 put on the account, against
-- RM500 already owed and a RM550 limit. The credit being extended is
-- RM20, so this is inside the limit; read against the basket it is
-- RM100 and would be refused. Both readings pass every other
-- assertion in this file, because everywhere else the basket and the
-- tab are the same number.
do $$
declare
  v_org uuid;
  v_out text;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.till_shop('Kedai Campur Sdn Bhd');
  update public.organizations set credit_control = 'block' where id = v_org;
  update public.contacts set credit_limit = 550 where org_id = v_org;

  perform public.import_open_invoices(
    v_org,
    jsonb_build_array(jsonb_build_object(
      'contact_code', 'REG', 'doc_no', 'OLD-1',
      'doc_date', to_char(current_date - 100, 'YYYY-MM-DD'),
      'due_date', to_char(current_date - 70, 'YYYY-MM-DD'),
      'outstanding_amount', '500')),
    current_date, true);

  v_out := pg_temp.till_split(v_org, 80, 20);
  perform pg_temp.check_eq(
    'the limit counts what goes on the tab, not what is in the basket',
    v_out, 'ok');
  perform pg_temp.check_eq('and only the tab is left owing',
    (select round(d.balance_amount, 2) from public.sales_documents d
       join public.pos_sales p on p.invoice_id = d.id
      where d.org_id = v_org), 20::numeric);

  -- And the tab is still held to it: another RM40 on account takes the
  -- customer to 560 against 550.
  v_out := pg_temp.till_split(v_org, 60, 40);
  perform pg_temp.check_true('while the tab is still held to the limit',
    v_out like '%against a credit limit of%' and v_out like '%560.00%');
end $$;

-- ---------------------------------------------------------------------
-- An ordinary invoice is unchanged
-- ---------------------------------------------------------------------
--
-- The whole document is the credit when there is no till behind it.
-- A rule expressed as "what is on account" could quietly exempt every
-- invoice, since none of them has a `pos_sales` row.
do $$
declare
  v_org  uuid;
  v_c    uuid;
  v_doc  uuid;
  v_msg  text;
  v_took boolean;
begin
  perform pg_temp.sign_in_as(pg_temp.test_user());
  v_org := pg_temp.till_shop('Kedai Invois Sdn Bhd');
  update public.organizations set credit_control = 'block' where id = v_org;
  select id into v_c from public.contacts where org_id = v_org;

  insert into public.sales_documents
    (org_id, doc_type, doc_no, doc_date, due_date, contact_id, status,
     currency, exchange_rate)
  values (v_org, 'invoice', 'INV-1', current_date, current_date, v_c,
          'draft', 'MYR', 1)
  returning id into v_doc;
  insert into public.sales_document_lines
    (org_id, document_id, line_no, line_type, item_id, description,
     quantity, unit_price)
  values (v_org, v_doc, 1, 'item',
          (select id from public.items where org_id = v_org and code = 'KOPI'),
          'Catering', 1, 900);

  begin
    perform public.post_sales_document(v_doc);
    v_took := true;
  exception when sqlstate '23514' then
    get stacked diagnostics v_msg = message_text;
    v_took := false;
  end;
  perform pg_temp.check_true(
    'an invoice with no till behind it is credit in full', not v_took);
  perform pg_temp.check_true('and the limit refuses it on the whole amount',
    v_msg like '%900.00%');
end $$;

rollback;
