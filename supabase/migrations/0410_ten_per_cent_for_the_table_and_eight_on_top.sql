-- ---------------------------------------------------------------------
-- 0410  Ten per cent for the table, and eight on top of that
-- ---------------------------------------------------------------------
--
-- Every Malaysian restaurant bill ends the same way:
--
--     Subtotal              100.00
--     Service charge 10%     10.00
--     Service tax 8%          8.80
--     Total                 118.80
--
-- The service tax is charged on 110.00, not on 100.00. That is the
-- compound `docs/gaps-against-akaunting.md` has listed as open since it
-- was written -- "compound tax is still absent, `is_compound` appears
-- nowhere in the migrations, the client or the edge functions" -- and
-- this is the form it actually takes in this country.
--
-- Until now the schema had no service charge at all. Not on
-- `pos_outlets`, not on `pos_sales`, not on `sales_documents`; grepped
-- across every migration for `service_charge` and `is_compound` and
-- found in neither. A restaurant using this point of sale could not
-- produce a correct bill, and every part of the food and beverage
-- module -- the floor plan, the modifiers, the split bills, the kitchen
-- display, the counters -- was built on top of a total that was wrong
-- by ten per cent plus the tax on it.
--
-- ## Where the compound comes from without charging tax twice
--
-- Tax in this schema is computed per line and summed:
-- `pos_sale_lines.tax_amount` already carries service tax on the food.
-- So the charge only needs to be taxed at the same rate:
--
--     rate x food + rate x charge = rate x (food + charge)
--
-- which is the figure the Act asks for, reached without a second tax
-- pass and without any line being taxed twice. `pos_service_charge.sql`
-- asserts the identity against the worked example above rather than
-- trusting the algebra.
--
-- ## What the shop chooses
--
-- `pos_outlets.service_charge_percent` -- ten is usual, some outlets
-- charge nothing, and a takeaway counter in the same company may differ
-- from the dining room, which is why it is on the outlet and not on the
-- organization.
--
-- `pos_outlets.service_charge_tax_code_id` -- which tax rides the
-- charge. Named rather than assumed, because a shop's food may be at
-- one rate and its service charge at another, and because an outlet
-- that is not SST-registered charges a service charge with no tax on it
-- at all. Null means exactly that: a charge, and nothing on top.
--
-- ## Where it lands in the ledger
--
-- `4250 Service Charge`, new in this migration, beside `4200 Service
-- Income`. Not `4100 Sales`: the charge is revenue for the table rather
-- than for the food, a restaurant needs to see the two apart -- it is
-- what the service staff are paid out of -- and `0013` already sets the
-- precedent by giving the courier charge `4900` instead of folding it
-- into sales.
--
-- The chart is re-seeded for every organization that already exists, by
-- calling `app.seed_chart_of_accounts` again rather than hand-writing
-- the insert. `0071` made that function re-entrant and `0189` used it
-- for exactly this; it adds the rows that are missing and touches
-- nothing a company added itself.
--
-- ## And the column that must be frozen
--
-- `0402` froze the money on a posted document against a named
-- deny-list, and `posted_document_is_frozen.sql` walks every column of
-- both document tables and requires each to be either frozen or
-- explicitly named as writable. A new money column that is neither
-- fails that test -- which is the guard working. `service_charge_amount`
-- joins the frozen list here.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- The columns
-- ---------------------------------------------------------------------
alter table public.pos_outlets
  add column if not exists service_charge_percent numeric(5, 2) not null default 0,
  add column if not exists service_charge_tax_code_id uuid references public.tax_codes(id);

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'pos_outlets_service_charge_percent_check') then
    alter table public.pos_outlets
      add constraint pos_outlets_service_charge_percent_check
      check (service_charge_percent >= 0 and service_charge_percent <= 100);
  end if;
end
$do$;

alter table public.pos_sales
  add column if not exists service_charge numeric(18, 2) not null default 0,
  add column if not exists service_charge_tax numeric(18, 2) not null default 0;

alter table public.sales_documents
  add column if not exists service_charge_amount numeric(18, 2) not null default 0;

comment on column public.pos_outlets.service_charge_percent is
  'The service charge this outlet adds to a bill — ten per cent is the '
  'Malaysian norm. On the outlet rather than the organization because a '
  'takeaway counter and a dining room in the same company charge '
  'differently.';
comment on column public.pos_outlets.service_charge_tax_code_id is
  'Which tax rides the service charge. Null means a charge with nothing '
  'on top, which is what an outlet that is not SST-registered has.';
comment on column public.sales_documents.service_charge_amount is
  'The service charge, on its own header field so it posts to 4250 '
  'rather than into food sales. The tax on it is in tax_amount with the '
  'rest of the output tax, because Malaysian service tax is charged on '
  'the bill after the service charge.';

create or replace function app.seed_chart_of_accounts(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row record;
begin
  -- Dropped first because `on commit drop` only fires at COMMIT: two
  -- organizations seeded inside one transaction — which is what the
  -- test suite does — would otherwise collide on the second call.
  drop table if exists _coa;
  create temp table _coa (
    code text, name text, atype text, asubtype text,
    is_group boolean, parent_code text, sort_order int
  ) on commit drop;

  insert into _coa values
    -- Assets
    ('1000','ASSETS','asset','current_asset',true,null,1000),
    ('1100','Current Assets','asset','current_asset',true,'1000',1100),
    ('1110','Cash in Hand','asset','cash',false,'1100',1110),
    ('1120','Bank Accounts','asset','bank',false,'1100',1120),
    ('1130','Petty Cash','asset','cash',false,'1100',1130),
    ('1200','Trade and Other Receivables','asset','current_asset',true,'1100',1200),
    ('1210','Accounts Receivable','asset','accounts_receivable',false,'1200',1210),
    ('1220','Other Receivables','asset','current_asset',false,'1200',1220),
    ('1230','Deposits and Prepayments','asset','current_asset',false,'1200',1230),
    ('1240','Amount Due from Directors','asset','current_asset',false,'1200',1240),
    ('1300','Inventories','asset','inventory',true,'1100',1300),
    ('1310','Inventory','asset','inventory',false,'1300',1310),
    ('1320','Goods in Transit','asset','inventory',false,'1300',1320),
    ('1400','Tax Assets','asset','current_asset',true,'1100',1400),
    ('1410','SST Input Tax','asset','current_asset',false,'1400',1410),
    ('1500','Non-Current Assets','asset','fixed_asset',true,'1000',1500),
    ('1510','Property, Plant and Equipment','asset','fixed_asset',false,'1500',1510),
    ('1520','Motor Vehicles','asset','fixed_asset',false,'1500',1520),
    ('1530','Office Equipment','asset','fixed_asset',false,'1500',1530),
    ('1540','Furniture and Fittings','asset','fixed_asset',false,'1500',1540),
    ('1550','Computer Equipment','asset','fixed_asset',false,'1500',1550),
    ('1590','Accumulated Depreciation','asset','accumulated_depreciation',false,'1500',1590),
    -- Liabilities
    ('2000','LIABILITIES','liability','current_liability',true,null,2000),
    ('2100','Current Liabilities','liability','current_liability',true,'2000',2100),
    ('2110','Accounts Payable','liability','accounts_payable',false,'2100',2110),
    ('2120','Other Payables and Accruals','liability','current_liability',false,'2100',2120),
    ('2130','SST Output Tax','liability','tax_payable',false,'2100',2130),
    ('2140','Income Tax Payable','liability','tax_payable',false,'2100',2140),
    ('2145','Net Salaries Payable','liability','current_liability',false,'2100',2145),
    ('2150','EPF Payable','liability','current_liability',false,'2100',2150),
    ('2160','SOCSO Payable','liability','current_liability',false,'2100',2160),
    ('2170','EIS Payable','liability','current_liability',false,'2100',2170),
    ('2180','PCB / MTD Payable','liability','current_liability',false,'2100',2180),
    ('2185','Zakat Payable','liability','current_liability',false,'2100',2185),
    ('2190','Amount Due to Directors','liability','current_liability',false,'2100',2190),
    ('2195','HRD Corp Levy Payable','liability','current_liability',false,'2100',2195),
    ('2200','Non-Current Liabilities','liability','long_term_liability',true,'2000',2200),
    ('2210','Term Loans','liability','long_term_liability',false,'2200',2210),
    ('2220','Hire Purchase Payable','liability','long_term_liability',false,'2200',2220),
    -- Equity
    ('3000','EQUITY','equity','share_capital',true,null,3000),
    ('3100','Share Capital','equity','share_capital',false,'3000',3100),
    ('3200','Retained Earnings','equity','retained_earnings',false,'3000',3200),
    ('3300','Current Year Earnings','equity','retained_earnings',false,'3000',3300),
    ('3400','Drawings','equity','drawings',false,'3000',3400),
    -- Revenue
    ('4000','REVENUE','revenue','sales',true,null,4000),
    ('4100','Sales','revenue','sales',false,'4000',4100),
    ('4200','Service Income','revenue','sales',false,'4000',4200),
    ('4250','Service Charge','revenue','sales',false,'4000',4250),
    ('4300','Sales Returns and Discounts','revenue','sales',false,'4000',4300),
    ('4900','Other Income','revenue','other_income',false,'4000',4900),
    ('4910','Interest Income','revenue','other_income',false,'4000',4910),
    ('4920','Foreign Exchange Gain','revenue','other_income',false,'4000',4920),
    ('4990','Rounding Adjustment','revenue','other_income',false,'4000',4990),
    -- Cost of sales
    ('5000','COST OF SALES','expense','cost_of_sales',true,null,5000),
    ('5100','Purchases','expense','cost_of_sales',false,'5000',5100),
    ('5200','Cost of Goods Sold','expense','cost_of_sales',false,'5000',5200),
    ('5300','Direct Labour','expense','cost_of_sales',false,'5000',5300),
    ('5400','Freight and Import Duty','expense','cost_of_sales',false,'5000',5400),
    ('5900','Inventory Adjustment','expense','cost_of_sales',false,'5000',5900),
    -- Expenses
    ('6000','EXPENSES','expense','operating_expense',true,null,6000),
    ('6100','Salaries and Wages','expense','payroll_expense',false,'6000',6100),
    ('6110','EPF Contribution','expense','payroll_expense',false,'6000',6110),
    ('6120','SOCSO Contribution','expense','payroll_expense',false,'6000',6120),
    ('6130','EIS Contribution','expense','payroll_expense',false,'6000',6130),
    ('6140','Staff Welfare','expense','payroll_expense',false,'6000',6140),
    ('6150','HRD Corp Levy','expense','payroll_expense',false,'6000',6150),
    ('6200','Rental','expense','operating_expense',false,'6000',6200),
    ('6210','Utilities','expense','operating_expense',false,'6000',6210),
    ('6220','Telephone and Internet','expense','operating_expense',false,'6000',6220),
    ('6230','Printing and Stationery','expense','operating_expense',false,'6000',6230),
    ('6240','Repair and Maintenance','expense','operating_expense',false,'6000',6240),
    ('6250','Transport and Travelling','expense','operating_expense',false,'6000',6250),
    ('6260','Entertainment','expense','operating_expense',false,'6000',6260),
    ('6270','Advertising and Marketing','expense','operating_expense',false,'6000',6270),
    ('6280','Professional Fees','expense','operating_expense',false,'6000',6280),
    ('6290','Insurance','expense','operating_expense',false,'6000',6290),
    ('6295','Licence and Permit','expense','operating_expense',false,'6000',6295),
    ('6300','Bank Charges','expense','finance_cost',false,'6000',6300),
    ('6310','Interest Expense','expense','finance_cost',false,'6000',6310),
    ('6400','Depreciation','expense','depreciation_expense',false,'6000',6400),
    ('6500','Foreign Exchange Loss','expense','other_expense',false,'6000',6500),
    ('6600','Bad Debts Written Off','expense','other_expense',false,'6000',6600),
    ('6900','Other Expenses','expense','other_expense',false,'6000',6900),
    ('6990','Income Tax Expense','expense','tax_expense',false,'6000',6990);

  for v_row in select * from _coa order by sort_order loop
    insert into public.accounts (
      org_id, code, name, account_type, account_subtype,
      is_group, is_system, sort_order
    ) values (
      p_org_id, v_row.code, v_row.name,
      v_row.atype::app.account_type, v_row.asubtype::app.account_subtype,
      v_row.is_group, true, v_row.sort_order
    ) on conflict (org_id, code) do nothing;
  end loop;

  -- Second pass: wire up the parent hierarchy now that every row exists.
  update public.accounts a
     set parent_id = p.id
    from _coa c
    join public.accounts p on p.org_id = p_org_id and p.code = c.parent_code
   where a.org_id = p_org_id
     and a.code = c.code
     and c.parent_code is not null;
end;
$$;CREATE OR REPLACE FUNCTION app.recalc_sales_totals()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_doc_id    uuid := coalesce(new.document_id, old.document_id);
  v_subtotal  numeric(18, 2);
  v_tax       numeric(18, 2);
  v_doc       public.sales_documents;
  v_method    text;
  v_discount  numeric(18, 2);
  v_raw_total numeric(18, 2);
  v_rounded   numeric(18, 2);
begin
  select * into v_doc from public.sales_documents where id = v_doc_id;
  if not found then
    return coalesce(new, old);
  end if;

  select coalesce(sum(line_subtotal), 0), coalesce(sum(tax_amount), 0)
    into v_subtotal, v_tax
    from public.sales_document_lines
   where document_id = v_doc_id;

  select rounding_method into v_method
    from public.organizations where id = v_doc.org_id;

  if coalesce(v_doc.discount_percent, 0) > 0 then
    v_discount := round(v_subtotal * v_doc.discount_percent / 100.0, 2);
  else
    v_discount := coalesce(v_doc.discount_amount, 0);
  end if;

  -- The service charge rides beside the shipping: both are amounts the
  -- customer is charged that no line carries. The tax that belongs to
  -- the charge is already in `tax_amount` -- `complete_pos_sale` puts it
  -- there, because Malaysian service tax is charged on the bill after
  -- the service charge and not on the food alone.
  v_raw_total := v_subtotal - v_discount + v_tax
               + coalesce(v_doc.shipping_amount, 0)
               + coalesce(v_doc.service_charge_amount, 0);
  v_rounded   := app.round_amount(v_raw_total, coalesce(v_method, 'none'));

  update public.sales_documents
     set subtotal          = v_subtotal,
         discount_amount   = v_discount,
         tax_amount        = v_tax,
         rounding_amount   = v_rounded - v_raw_total,
         total_amount      = v_rounded,
         base_total_amount = round(v_rounded * coalesce(v_doc.exchange_rate, 1), 2),
         balance_amount    = v_rounded - coalesce(v_doc.paid_amount, 0)
                                       - coalesce(v_doc.applied_amount, 0)
   where id = v_doc_id;

  return coalesce(new, old);
end;
$function$;
CREATE OR REPLACE FUNCTION app.post_sales_document_internal(p_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_doc         public.sales_documents;
  v_line        record;
  v_entries     jsonb := '[]'::jsonb;
  v_sign        integer;
  v_ar_account  uuid;
  v_tax_account uuid;
  v_round_acct  uuid;
  v_cogs_acct   uuid;
  v_inv_acct    uuid;
  v_rev_acct    uuid;
  v_entry_id    uuid;
  v_amount      numeric(18, 2);
  v_cogs_total  numeric(18, 2) := 0;
  v_from_do     boolean := false;
  v_rate        numeric(18, 8);
  v_deferred    boolean := false;
begin
  select * into v_doc from public.sales_documents where id = p_id;
  if not found then
    raise exception 'Sales document % not found', p_id;
  end if;
  if v_doc.doc_type not in ('invoice', 'credit_note', 'debit_note', 'refund_note') then
    raise exception 'Document type % does not post to the ledger', v_doc.doc_type;
  end if;
  if v_doc.gl_entry_id is not null then
    raise exception 'Document % is already posted', v_doc.doc_no;
  end if;

  -- Credit and refund notes move the ledger the other way.
  v_sign := case when v_doc.doc_type in ('credit_note', 'refund_note') then -1 else 1 end;
  v_rate := coalesce(v_doc.exchange_rate, 1);

  select coalesce(c.receivable_account_id,
                  (select id from public.accounts
                    where org_id = v_doc.org_id and code = '1210'))
    into v_ar_account
    from public.contacts c where c.id = v_doc.contact_id;

  select id into v_tax_account from public.accounts
   where org_id = v_doc.org_id and code = '2130';
  select id into v_round_acct from public.accounts
   where org_id = v_doc.org_id and code = '4990';

  -- Receivable: debit for an invoice, credit for a credit note.
  v_amount := round(v_sign * v_doc.total_amount * v_rate, 2);
  v_entries := v_entries || jsonb_build_object(
    'account_id',  v_ar_account,
    'description', v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'debit',       greatest(v_amount, 0),
    'credit',      greatest(-v_amount, 0),
    'contact_id',  v_doc.contact_id
  );

  -- Revenue, one line per document line.
  for v_line in
    select l.*, i.sales_account_id, i.track_inventory, i.cogs_account_id,
           i.inventory_account_id, i.average_cost
      from public.sales_document_lines l
      left join public.items i on i.id = l.item_id
     where l.document_id = p_id and l.line_type = 'item'
     order by l.line_no
  loop
    -- 0309. A line with a service period has not been earned yet, so
    -- the credit goes to the liability rather than to revenue. The
    -- schedule built below is what releases it, month by month. A line
    -- without one is untouched and still credits revenue on the day,
    -- which is every line this system has ever posted.
    -- 0310. Only a document that *creates* the obligation defers. A
    -- credit note is a reversal: it takes revenue back, and what it
    -- does about the liability is cancel the schedule below, not open
    -- a second one.
    if v_line.service_start is not null and v_sign = 1 then
      v_rev_acct := app.deferred_revenue_account(v_doc.org_id);
      v_deferred := true;
    else
      v_rev_acct := app.resolve_account(
        v_doc.org_id, v_line.account_id, v_line.item_id, 'sales_account_id', '4100');
    end if;

    v_amount := round(-v_sign * v_line.line_subtotal * v_rate, 2);
    if v_amount <> 0 then
      v_entries := v_entries || jsonb_build_object(
        'account_id',  v_rev_acct,
        'description', left(coalesce(v_line.description, ''), 200),
        'debit',       greatest(v_amount, 0),
        'credit',      greatest(-v_amount, 0),
        'contact_id',  v_doc.contact_id,
        'item_id',     v_line.item_id,
        'tax_code_id', v_line.tax_code_id,
        'project_code', v_line.project_code,
        'department_code', v_line.department_code
      );
    end if;

    -- Cost of sales for stock items.
    if v_line.track_inventory and v_line.item_id is not null then
      -- `average_cost` is per the item's own unit, so the cost of a
      -- line sold in cartons is the pieces it came to, not the number
      -- of cartons. 0270.
      v_cogs_total := v_cogs_total
        + round(coalesce(v_line.base_quantity, v_line.quantity)
                * coalesce(v_line.average_cost, 0) * v_rate, 2);
    end if;
  end loop;

  -- Header discount, if it was not already pushed down to the lines.
  if coalesce(v_doc.discount_amount, 0) > 0 then
    v_amount := round(v_sign * v_doc.discount_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4300'),
      'description', 'Discount',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- SST output tax.
  if coalesce(v_doc.tax_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.tax_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_tax_account,
      'description', 'SST output tax',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0),
      'tax_amount',  abs(v_amount)
    );
  end if;

  -- Cash rounding difference.
  if coalesce(v_doc.rounding_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.rounding_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  v_round_acct,
      'description', 'Rounding adjustment',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- The service charge, in its own revenue account.
  --
  -- 4250, not 4100: a Malaysian bill reads "subject to 10% service
  -- charge and 8% service tax", the charge is revenue from service
  -- rather than from food, and a restaurant that cannot see the two
  -- apart cannot tell what it took at the table from what it took for
  -- the table. The service tax that sits on top of it is already in
  -- `tax_amount` and posts with the rest of the output tax.
  if coalesce(v_doc.service_charge_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.service_charge_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts
                       where org_id = v_doc.org_id and code = '4250'),
      'description', 'Service charge',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- Shipping charged to the customer.
  if coalesce(v_doc.shipping_amount, 0) <> 0 then
    v_amount := round(-v_sign * v_doc.shipping_amount * v_rate, 2);
    v_entries := v_entries || jsonb_build_object(
      'account_id',  (select id from public.accounts where org_id = v_doc.org_id and code = '4900'),
      'description', 'Shipping',
      'debit',       greatest(v_amount, 0),
      'credit',      greatest(-v_amount, 0)
    );
  end if;

  -- Cost of sales pair.
  if v_cogs_total <> 0 then
    select id into v_cogs_acct from public.accounts where org_id = v_doc.org_id and code = '5200';
    select id into v_inv_acct  from public.accounts where org_id = v_doc.org_id and code = '1310';
    v_amount := round(v_sign * v_cogs_total, 2);
    v_entries := v_entries
      || jsonb_build_object('account_id', v_cogs_acct, 'description', 'Cost of goods sold',
                            'debit', greatest(v_amount, 0), 'credit', greatest(-v_amount, 0))
      || jsonb_build_object('account_id', v_inv_acct, 'description', 'Inventory movement',
                            'debit', greatest(-v_amount, 0), 'credit', greatest(v_amount, 0));
  end if;

  v_entry_id := app.create_gl_entry_internal(
    v_doc.org_id, v_doc.doc_date,
    case v_doc.doc_type
      when 'credit_note' then 'credit_note'::app.journal_source
      when 'debit_note'  then 'debit_note'::app.journal_source
      else 'sales_invoice'::app.journal_source
    end,
    v_entries,
    v_doc.doc_type::text || ' ' || v_doc.doc_no,
    'sales_documents', v_doc.id, v_doc.reference,
    v_doc.currency, v_rate
  );

  -- Move stock, unless a delivery order already did.
  select exists (
    select 1 from public.sales_documents d
     where d.id = v_doc.parent_id and d.doc_type = 'delivery_order'
  ) into v_from_do;

  if not v_from_do then
    insert into public.stock_movements (
      org_id, movement_no, movement_date, movement_type, item_id, warehouse_id,
      quantity, unit_cost, source_table, source_id, source_line_id, gl_entry_id, created_by
    )
    select v_doc.org_id,
           app.next_document_number_internal(v_doc.org_id, 'stock_movement'),
           v_doc.doc_date,
           case when v_sign = 1 then 'sales_delivery' else 'sales_return' end::app.stock_movement_type,
           l.item_id,
           coalesce(l.warehouse_id, (select id from public.warehouses
                                      where org_id = v_doc.org_id and is_default limit 1)),
           -- In the item's own unit. Two cartons of twenty-four is
           -- forty-eight pieces off the shelf. 0270.
           -v_sign * coalesce(l.base_quantity, l.quantity),
           coalesce(i.average_cost, 0),
           'sales_documents', v_doc.id, l.id, v_entry_id, auth.uid()
      from public.sales_document_lines l
      join public.items i on i.id = l.item_id
     where l.document_id = p_id
       and l.line_type = 'item'
       and i.track_inventory
       and l.quantity > 0;
  end if;

  update public.sales_documents
     set gl_entry_id = v_entry_id,
         status      = 'posted',
         posted_at   = now(),
         posted_by   = auth.uid()
   where id = p_id;

  -- Only when something was actually deferred, so a document of
  -- ordinary lines does no extra work and writes no empty schedule.
  if v_deferred then
    perform app.build_revenue_schedule(p_id, v_rate);
  end if;

  -- 0310. A credit note against a deferred invoice stops the rest of
  -- that invoice's schedule and returns what is left of the liability
  -- to revenue. Without this the invoice went on earning after it had
  -- been cancelled.
  if v_sign = -1 then
    perform app.cancel_revenue_schedule(p_id);
  end if;

  return v_entry_id;
end;
$function$;
CREATE OR REPLACE FUNCTION app.recalc_pos_sale(p_sale uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sub numeric; v_tax numeric; v_disc numeric;
  v_loy numeric; v_pct numeric; v_bill numeric;
  v_promo numeric; v_gross numeric; v_fee numeric;
  v_svc_pct numeric; v_svc numeric; v_svc_tax numeric; v_svc_rate numeric;
begin
  select coalesce(sum(l.line_subtotal), 0),
         coalesce(sum(l.tax_amount), 0),
         coalesce(sum(l.discount_amount), 0)
    into v_sub, v_tax, v_disc
    from public.pos_sale_lines l where l.sale_id = p_sale;

  select coalesce(s.loyalty_discount, 0),
         coalesce(s.bill_discount_percent, 0),
         coalesce(s.bill_discount, 0)
    into v_loy, v_pct, v_bill
    from public.pos_sales s where s.id = p_sale;

  -- Derived, never stored twice: the rows are the promotions.
  select coalesce(sum(sp.amount), 0) into v_promo
    from public.pos_sale_promotions sp where sp.sale_id = p_sale;

  -- ------------------------------------------------------------------
  -- The service charge, and the tax that sits on top of it
  -- ------------------------------------------------------------------
  -- A Malaysian bill reads "subject to 10% service charge and 8%
  -- service tax", and the service tax is charged on the amount that
  -- already includes the charge. Charged on the food net of the
  -- discounts that belong to the lines, which is what `line_subtotal`
  -- already is.
  --
  -- The compound falls out of the per-line tax without any tax being
  -- charged twice: the lines already carry service tax on the food, so
  -- taxing the charge at the same rate gives
  -- rate x food + rate x charge = rate x (food + charge), which is the
  -- figure the Act asks for.
  select coalesce(o.service_charge_percent, 0), t.rate
    into v_svc_pct, v_svc_rate
    from public.pos_sales s
    join public.pos_outlets o on o.id = s.outlet_id
    left join public.tax_codes t on t.id = o.service_charge_tax_code_id
   where s.id = p_sale;

  v_svc := round(coalesce(v_sub, 0) * coalesce(v_svc_pct, 0) / 100.0, 2);
  v_svc_tax := round(v_svc * coalesce(v_svc_rate, 0) / 100.0, 2);

  v_gross := round(v_sub + v_tax + v_svc + v_svc_tax, 2);

  -- The ride, rebuilt from the zone against the food. Measured on the
  -- goods before any discount, because "spend RM 50 and delivery is
  -- free" is a promise about what was ordered, not about what was
  -- charged after the manager knocked something off.
  update public.pos_deliveries d
     set fee = app.pos_delivery_fee(d.zone_id, v_gross),
         updated_at = now()
   where d.sale_id = p_sale
     and not d.fee_is_manual
     and d.fee <> app.pos_delivery_fee(d.zone_id, v_gross);

  select coalesce(d.fee, 0) into v_fee
    from public.pos_deliveries d where d.sale_id = p_sale;
  v_fee := coalesce(v_fee, 0);

  if v_pct > 0 then
    v_bill := round(v_gross * v_pct / 100.0, 2);
  end if;
  v_bill := least(greatest(v_bill, 0), v_gross);
  -- Whatever is left after the manual discount, so the two together can
  -- never hand money back across the counter.
  v_promo := least(greatest(v_promo, 0), v_gross - v_bill);

  update public.pos_sales s
     set subtotal = v_sub,
         service_charge = v_svc,
         service_charge_tax = v_svc_tax,
         tax_amount = v_tax,
         discount_amount = v_disc,
         bill_discount = v_bill,
         promo_discount = v_promo,
         delivery_fee = v_fee,
         -- The food, floored at nothing, and then the ride on top.
         total_amount = round(
           greatest(round(v_gross - v_bill - v_promo - v_loy, 2), 0) + v_fee, 2)
   where s.id = p_sale;
end;
$function$;
CREATE OR REPLACE FUNCTION public.complete_pos_sale(p_sale uuid, p_tenders jsonb, p_contact uuid DEFAULT NULL::uuid)
 RETURNS TABLE(sale_id uuid, invoice_no text, total numeric, cash_due numeric, change_due numeric, rounding numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sale     public.pos_sales;
  v_outlet   public.pos_outlets;
  v_round    boolean;
  v_noncash  numeric := 0;
  v_cashin   numeric := 0;
  v_cashdue  numeric;
  v_adj      numeric;
  v_change   numeric;
  v_contact  uuid;
  v_inv      uuid;
  v_rcp      uuid;
  v_no       text;
  v_line     record;
  v_t        record;
  v_n        integer := 0;
  v_kind     app.pos_tender_kind;
  v_bank     uuid;
  v_mode     text;
  -- What of this basket is going on somebody's account rather than
  -- into the drawer. Counted separately from `v_noncash` because the
  -- two answer different questions: `v_noncash` is what the rounding
  -- rule works from -- an on-account amount is not cash and rounds the
  -- same way a card does -- and this is what no receipt may be written
  -- for.
  v_onacct   numeric := 0;
  v_recv     numeric;
  v_block    text;
begin
  select * into v_sale from public.pos_sales where id = p_sale;
  if v_sale.id is null then
    raise exception 'No such sale.' using errcode = 'P0002';
  end if;
  if not app.can_write_module(v_sale.org_id, 'pos') then
    raise exception 'not permitted to sell for this organization'
      using errcode = '42501';
  end if;
  if v_sale.status <> 'parked' then
    raise exception 'That sale is already %.', v_sale.status
      using errcode = '23514';
  end if;
  -- Aliased, because `sale_id` is also an OUT parameter of this
  -- function and plpgsql cannot tell which one an unqualified reference
  -- means. It refuses rather than guessing, which is the right choice
  -- and only says so at run time.
  if not exists (select 1 from public.pos_sale_lines l where l.sale_id = p_sale) then
    raise exception 'There is nothing on this sale to pay for.'
      using errcode = '23514';
  end if;

  -- Worked out again here, not trusted from the screen. A bill parked
  -- at ten to eleven and settled at five past is settled outside the
  -- happy hour, and the customer is charged what the shop's own rule
  -- says at the moment the money changes hands. Re-read afterwards,
  -- because this is what moves the total.
  perform app.refresh_pos_promotions(p_sale);
  perform app.recalc_pos_sale(p_sale);
  select * into v_sale from public.pos_sales where id = p_sale;

  -- The zone minimum, checked at the one moment the basket is final.
  -- Refusing at the door would refuse the wrong thing: every shop with
  -- a minimum takes the address first and the order second.
  v_block := app.pos_delivery_blocked(p_sale);
  if v_block is not null then
    raise exception '%', v_block using errcode = '23514';
  end if;

  select * into v_outlet from public.pos_outlets where id = v_sale.outlet_id;
  select coalesce(ps.round_cash_to_5sen, true) into v_round
    from public.pos_settings ps where ps.org_id = v_sale.org_id;
  v_round := coalesce(v_round, true);

  -- --------------------------------------------------------------
  -- What is being paid with what
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid   as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference'     as reference
      from jsonb_array_elements(coalesce(p_tenders, '[]'::jsonb)) e
  loop
    if v_t.amount is null or v_t.amount <= 0 then
      raise exception 'A tender needs an amount.' using errcode = '23514';
    end if;
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id and tt.org_id = v_sale.org_id and tt.is_active;
    if v_kind is null then
      raise exception 'That is not a tender this company accepts.'
        using errcode = 'P0002';
    end if;
    if v_kind = 'cash' then
      v_cashin := v_cashin + v_t.amount;
    else
      v_noncash := v_noncash + v_t.amount;
      if v_kind = 'on_account' then
        v_onacct := v_onacct + v_t.amount;
      end if;
    end if;
    v_n := v_n + 1;
  end loop;

  -- A basket covered entirely by points has nothing left to tender,
  -- and that is a completed sale rather than an unpaid one. Without
  -- this, a customer with enough points to clear the till could put
  -- them all against the basket and then find the sale could not be
  -- rung up at all -- a dead end reachable from the screen that offers
  -- the redemption.
  if v_n = 0 and v_sale.total_amount > 0 then
    raise exception 'A sale has to be paid for.' using errcode = '23514';
  end if;

  -- 0208's rule: round what is left after everything that is not cash.
  v_cashdue := app.pos_cash_due(v_sale.total_amount, v_noncash, v_round);
  v_adj     := app.pos_rounding_adjustment(v_sale.total_amount, v_noncash, v_round);
  v_change  := round(v_cashin - v_cashdue, 2);

  if v_change < 0 then
    raise exception
      'Short by %. The customer still owes that much.', -v_change
      using errcode = '23514';
  end if;
  -- Non-cash cannot over-pay: a card charged more than the basket is a
  -- refund waiting to happen, not a sale.
  if v_noncash > v_sale.total_amount + 0.005 and v_cashin = 0 then
    raise exception
      'That is more than the basket comes to. Charge the card the right '
      'amount, or take the difference as a refund.'
      using errcode = '23514';
  end if;

  v_contact := coalesce(p_contact, v_sale.contact_id, v_outlet.walk_in_contact_id);
  if v_contact is null then
    raise exception
      'This outlet has no walk-in customer set, so an anonymous sale has '
      'nobody to bill. Set one on the outlet.'
      using errcode = '23502';
  end if;

  -- The walk-in contact is not an account. It is one row every
  -- anonymous sale in the outlet is billed to, so putting a basket on
  -- it would build a receivable balance belonging to nobody, that
  -- nobody would ever be chased for. An on-account sale has to name a
  -- customer, which is why this checks what was passed rather than
  -- `v_contact` -- the fallback above is exactly what must not count.
  if v_onacct > 0 and coalesce(p_contact, v_sale.contact_id) is null then
    raise exception
      'A sale on account has to name the customer whose account it goes '
      'on.'
      using errcode = '23502';
  end if;

  -- --------------------------------------------------------------
  -- The invoice
  -- --------------------------------------------------------------
  v_no := app.next_document_number_internal(v_sale.org_id, 'invoice');

  -- No salesperson. `sales_documents.salesperson_id` points at
  -- `public.salespeople` — a commission record — and not at the user
  -- who rang the sale up. A cashier is not automatically one of those,
  -- and 0105 has a trigger that says so. Who served the customer is on
  -- `pos_sales.sold_by`, which is the right place for it; a shop that
  -- pays counter commission can map the two later.
  insert into public.sales_documents (
    org_id, doc_type, doc_no, doc_date, due_date, contact_id, currency,
    exchange_rate, status, notes, created_by)
  values (
    v_sale.org_id, 'invoice', v_no, current_date, current_date, v_contact,
    'MYR', 1, 'draft',
    'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
  returning id into v_inv;

  for v_line in
    select * from public.pos_sale_lines l where l.sale_id = p_sale order by l.line_no
  loop
    insert into public.sales_document_lines (
      org_id, document_id, line_no, line_type, item_id, description,
      quantity, uom_code, unit_price, discount_amount, tax_code_id,
      tax_rate, is_tax_inclusive, warehouse_id)
    values (
      v_sale.org_id, v_inv, v_line.line_no, 'item', v_line.item_id,
      v_line.description, v_line.quantity, v_line.uom_code,
      v_line.unit_price, v_line.discount_amount, v_line.tax_code_id,
      v_line.tax_rate, v_line.is_tax_inclusive, v_line.warehouse_id);
  end loop;

  -- After the lines, because the totals trigger fires on line changes
  -- and would otherwise impose the organization's rounding on a card
  -- sale. See the header: this is POS taking a number the trigger
  -- normally owns, and the test asserts the result.
  update public.sales_documents d
     set rounding_amount = v_adj,
         -- The redemption AND the bill discount, on the header rather
         -- than spread across the lines. `sales_documents.discount_amount`
         -- is exactly the field for a discount that belongs to the
         -- document, and `prepare_einvoice` already maps it to the
         -- MyInvois total discount, so what LHDN is told matches what
         -- was charged. Both are added because both came off the same
         -- header: reporting only one of them would understate the
         -- discount on every bill a manager touched.
         discount_amount = coalesce(v_sale.loyalty_discount, 0)
                         + coalesce(v_sale.bill_discount, 0)
                         + coalesce(v_sale.promo_discount, 0),
         -- The ride, on the field the ledger already knows what to do
         -- with. 0013 posts shipping_amount to 4900 on its own, so the
         -- courier charge lands in its own revenue account instead of
         -- in food sales, and the journal still balances because the
         -- receivable was always the header total.
         shipping_amount = coalesce(v_sale.delivery_fee, 0),
         -- The service charge, on its own header field so it posts to
         -- 4250 rather than disappearing into food sales, and its tax
         -- added to what the lines already carry. The lines' trigger
         -- owns `tax_amount` and recomputes it from the lines; this
         -- runs after the last line and the document is frozen the
         -- moment it posts, so the addition stands. Same bargain as
         -- `rounding_amount` two fields up, and for the same reason.
         service_charge_amount = coalesce(v_sale.service_charge, 0),
         tax_amount = round(coalesce(d.tax_amount, 0)
                          + coalesce(v_sale.service_charge_tax, 0), 2),
         total_amount    = round(v_sale.total_amount + v_adj, 2),
         base_total_amount = round(v_sale.total_amount + v_adj, 2),
         balance_amount  = round(v_sale.total_amount + v_adj, 2)
   where d.id = v_inv;

  perform app.post_sales_document_internal(v_inv);

  -- --------------------------------------------------------------
  -- The receipt, and the debt closing behind it
  -- --------------------------------------------------------------
  -- What actually arrived. An on-account tender is a promise, so the
  -- receipt is for the rest of the basket and the remainder stays on
  -- the invoice for the customer to settle later.
  v_recv := round(v_sale.total_amount + v_adj - v_onacct, 2);

  -- Banked against the first tender's account, skipping any that went
  -- on account -- those have no bank account and never will, and a null
  -- one falls back to the current account, which is the whole failure
  -- being fixed here. A shop splitting one sale across two accounts is
  -- real and is not this migration's problem; what matters is that the
  -- money lands somewhere named rather than in the current account by
  -- default.
  select tt.bank_account_id, tt.payment_mode_code
    into v_bank, v_mode
    from jsonb_array_elements(p_tenders) with ordinality as e(t, ord)
    join public.pos_tender_types tt on tt.id = (t ->> 'type')::uuid
   where tt.kind <> 'on_account'
   order by e.ord
   limit 1;

  -- A receipt unless the whole basket went on account. Not `v_recv > 0`
  -- on its own: a basket cleared entirely by loyalty points also comes
  -- to nothing, and `0212` deliberately gives that one a receipt for
  -- zero so the sale is a completed sale rather than a stuck one. The
  -- two zeroes mean different things and only one of them means no
  -- money was taken.
  if v_onacct = 0 or v_recv > 0 then
    v_no := app.next_document_number_internal(v_sale.org_id, 'receipt');

    insert into public.receipts (
      org_id, receipt_no, receipt_date, contact_id, payment_mode_code,
      bank_account_id, currency, exchange_rate, amount, base_amount,
      status, notes, created_by)
    values (
      v_sale.org_id, v_no, current_date, v_contact, v_mode, v_bank,
      'MYR', 1, v_recv, v_recv,
      'draft', 'Counter sale ' || v_sale.sale_no, v_sale.sold_by)
    returning id into v_rcp;
  end if;

  -- Only when there is something to allocate. `payment_allocations`
  -- checks that its amount is positive, and it is right to: an
  -- allocation of nothing is not an allocation. A basket cleared by
  -- points leaves an invoice for zero, which already owes nothing, so
  -- there is nothing for a receipt to settle against it.
  if v_recv > 0 then
    insert into public.payment_allocations
      (org_id, receipt_id, invoice_id, amount, allocated_by)
    values
      (v_sale.org_id, v_rcp, v_inv, v_recv, v_sale.sold_by);
  end if;

  if v_rcp is not null then
    perform app.post_receipt_internal(v_rcp);
  end if;

  -- --------------------------------------------------------------
  -- And the tenders, now that they are known to be good
  -- --------------------------------------------------------------
  for v_t in
    select (e ->> 'type')::uuid as type_id,
           (e ->> 'amount')::numeric as amount,
            e ->> 'reference' as reference,
           row_number() over () as rn,
           count(*) over () as total_rows
      from jsonb_array_elements(p_tenders) e
  loop
    select tt.kind into v_kind from public.pos_tender_types tt
     where tt.id = v_t.type_id;
    insert into public.pos_tenders
      (org_id, sale_id, tender_type_id, kind, amount, change_given, reference)
    values
      (v_sale.org_id, p_sale, v_t.type_id, v_kind, v_t.amount,
       -- Change comes out of the last tender offered, which is the one
       -- the customer is standing there waiting for.
       case when v_t.rn = v_t.total_rows then v_change else 0 end,
       v_t.reference);
  end loop;

  update public.pos_sales s
     set status = 'completed',
         completed_at = now(),
         contact_id = v_contact,
         rounding_amount = v_adj,
         total_amount = round(v_sale.total_amount + v_adj, 2),
         invoice_id = v_inv,
         receipt_id = v_rcp,
         on_account_amount = v_onacct
   where s.id = p_sale;

  -- --------------------------------------------------------------
  -- And the points, last
  -- --------------------------------------------------------------
  -- Nothing above this line touches the loyalty ledger. A parked sale
  -- holds no points: it can be abandoned, and a customer whose balance
  -- fell when a cashier changed their mind has been robbed by a
  -- transaction that never happened.
  -- On the food, not on the ride. A shop that pays points on a courier
  -- charge is paying points on money it hands straight to a rider.
  perform app.pos_settle_loyalty(
    p_sale,
    greatest(round(v_sale.total_amount + v_adj
                   - coalesce(v_sale.delivery_fee, 0), 2), 0));

  sale_id := p_sale;
  select d.doc_no into invoice_no from public.sales_documents d where d.id = v_inv;
  -- Scaled to the sen on the way out. `numeric` with no declared scale
  -- is exact and prints as 10.8500000000000000, which reaches the till
  -- as a string and is the one number a customer reads back off a
  -- receipt. Correct is not the same as legible.
  total := round(v_sale.total_amount + v_adj, 2);
  cash_due := round(v_cashdue, 2);
  change_due := round(v_change, 2);
  rounding := round(v_adj, 2);
  return next;
end;
$function$;
CREATE OR REPLACE FUNCTION app.refuse_posted_document_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'app', 'pg_temp'
AS $function$
declare
  -- The figures and identifiers the journal was built from. Same list
  -- for both tables; a column absent from one is skipped rather than
  -- assumed.
  c_frozen constant text[] := array[
    'id', 'org_id', 'doc_type', 'doc_no', 'doc_date',
    'currency', 'exchange_rate', 'subtotal', 'discount_amount',
    'discount_percent', 'tax_amount', 'shipping_amount',
    'rounding_amount', 'total_amount', 'base_total_amount',
    'branch_id', 'matter_id', 'posted_at', 'posted_by', 'gl_entry_id',
    'service_charge_amount'];
  -- The same question asked of the line: which of its columns did the
  -- journal read? Everything else on a line goes on moving, and some of
  -- it has to -- `app.refresh_sales_progress` and
  -- `app.refresh_purchase_progress` write the four progress counters on
  -- the lines of a posted document every time something is transferred
  -- from or received against it, and `source_line_id` is the link they
  -- follow.
  c_line_frozen constant text[] := array[
    'id', 'org_id', 'document_id', 'line_no', 'line_type', 'item_id',
    'description', 'quantity', 'base_quantity', 'uom_code', 'unit_price',
    'discount_amount', 'discount_percent', 'tax_code_id', 'tax_rate',
    'is_tax_inclusive', 'line_subtotal', 'tax_amount', 'line_total',
    'account_id', 'warehouse_id', 'cost_amount',
    'service_start', 'service_end', 'project_code', 'department_code'];
  v_is_line boolean := tg_table_name like '%_lines';
  v_entry   uuid;
  v_no      text;
  v_org     uuid;
  v_old     jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  v_new     jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  v_col     text;
begin
  if v_is_line then
    select d.gl_entry_id, d.doc_no, d.org_id into v_entry, v_no, v_org
      from public.sales_documents d
     where tg_table_name = 'sales_document_lines'
       and d.id = coalesce((v_new ->> 'document_id')::uuid,
                           (v_old ->> 'document_id')::uuid);
    if v_no is null then
      select d.gl_entry_id, d.doc_no, d.org_id into v_entry, v_no, v_org
        from public.purchase_documents d
       where tg_table_name = 'purchase_document_lines'
         and d.id = coalesce((v_new ->> 'document_id')::uuid,
                             (v_old ->> 'document_id')::uuid);
    end if;
  else
    v_entry := (coalesce(v_old, v_new) ->> 'gl_entry_id')::uuid;
    v_no    := coalesce(v_old, v_new) ->> 'doc_no';
    v_org   := nullif(coalesce(v_old, v_new) ->> 'org_id', '')::uuid;
  end if;

  -- Not posted: this is an ordinary document and none of this applies.
  -- A line whose document has already gone is in the same position.
  if v_entry is null then
    return coalesce(new, old);
  end if;

  -- The company is already gone and these rows are cascading away
  -- behind it. `app.write_audit_log` makes the same check for the same
  -- reason, and only on a delete: an insert or an update cannot name an
  -- organization that does not exist, because the row's own foreign key
  -- has already said so.
  if tg_op = 'DELETE'
     and v_org is not null
     and not exists (select 1 from public.organizations o where o.id = v_org)
  then
    return old;
  end if;

  if tg_op = 'DELETE' then
    raise exception
      '% is posted: its journal is in the ledger, which `0238` made '
      'append-only, and deleting it would leave that journal with '
      'nothing to explain it. Void the document instead, which reverses '
      'the journal, or raise a credit note against it.', v_no
      using errcode = '42501';
  end if;

  if tg_op = 'INSERT' then
    raise exception
      'A line cannot be added to %, which is posted. Its journal was '
      'built from the lines it had. Raise a credit note or a further '
      'document instead.', v_no
      using errcode = '42501';
  end if;

  if v_is_line then
    foreach v_col in array c_line_frozen loop
      if (v_new ? v_col)
         and (v_new -> v_col) is distinct from (v_old -> v_col) then
        raise exception
          'Line % of % cannot be changed: % is posted and its journal '
          'was built from this line''s % (% -> %). Void the document or '
          'raise a credit note.',
          coalesce(v_new ->> 'line_no', '?'), v_no, v_no, v_col,
          coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
          using errcode = '42501';
      end if;
    end loop;
    return new;
  end if;

  foreach v_col in array c_frozen loop
    if (v_new ? v_col)
       and (v_new -> v_col) is distinct from (v_old -> v_col) then
      -- `gl_entry_id` is worth its own sentence: clearing it is not a
      -- disagreement with the ledger, it is a second posting waiting to
      -- happen. `post_sales_document_internal` refuses to post twice by
      -- reading this column and nothing else.
      if v_col = 'gl_entry_id' then
        raise exception
          '% is already posted as journal %. Clearing the link would '
          'let it be posted a second time, and the company would carry '
          'the sale twice. Void the document, which reverses the '
          'journal through `reverse_gl_entry`.',
          v_no, (v_old ->> 'gl_entry_id')
          using errcode = '42501';
      end if;
      raise exception
        '% is posted and % is one of the figures its journal was built '
        'from (% -> %). The ledger is append-only, so this would leave '
        'the document and the accounts disagreeing with no way to '
        'reconcile them. Void the document or raise a credit note.',
        v_no, v_col,
        coalesce(v_old ->> v_col, 'null'), coalesce(v_new ->> v_col, 'null')
        using errcode = '42501';
    end if;
  end loop;

  return new;
end $function$;

-- ---------------------------------------------------------------------
-- Every organization that already exists gets 4250
-- ---------------------------------------------------------------------
do $do$
declare v_org uuid; v_n integer := 0;
begin
  for v_org in select id from public.organizations order by created_at loop
    perform app.seed_chart_of_accounts(v_org);
    v_n := v_n + 1;
  end loop;
  raise notice '0410: chart re-seeded for % organization(s)', v_n;
end
$do$;

-- ---------------------------------------------------------------------
-- What this migration did, asserted
-- ---------------------------------------------------------------------
do $do$
declare v_missing int; v_src text;
begin
  select count(*) into v_missing
    from public.organizations o
   where not exists (select 1 from public.accounts a
                      where a.org_id = o.id and a.code = '4250');
  if v_missing > 0 then
    raise exception
      'FAIL 0410: % organization(s) have no 4250 to post a service '
      'charge to, so the first bill that carries one would refuse',
      v_missing;
  end if;

  -- The charge reaches the total. A column that nothing adds up is the
  -- shape this migration exists to close, so it is asserted on the
  -- source of the function that owns the total rather than assumed.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'recalc_sales_totals';
  if v_src !~ 'service_charge_amount' then
    raise exception
      'FAIL 0410: the document total does not include the service charge';
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'post_sales_document_internal';
  if v_src !~ '4250' then
    raise exception
      'FAIL 0410: the service charge does not reach the ledger';
  end if;

  -- `0402`'s deny-list. The test walks the columns and would catch a
  -- new money column left writable, but the migration that adds the
  -- column is the right place to say it.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'refuse_posted_document_change';
  if v_src !~ 'service_charge_amount' then
    raise exception
      'FAIL 0410: service_charge_amount is not frozen on a posted document';
  end if;

  -- `0407` took `seed_chart_of_accounts` off the client roles, and this
  -- migration replaces the function. `create or replace` keeps the ACL,
  -- which is worth proving rather than believing.
  if has_function_privilege('authenticated',
       'app.seed_chart_of_accounts(uuid)', 'EXECUTE')
     or has_function_privilege('anon',
       'app.seed_chart_of_accounts(uuid)', 'EXECUTE') then
    raise exception
      'FAIL 0410: replacing seed_chart_of_accounts handed it back to a '
      'client role -- 0407 revoked it';
  end if;

  raise notice
    '0410: the service charge is charged, taxed, totalled, posted and frozen';
end
$do$;
