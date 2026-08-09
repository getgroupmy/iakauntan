-- =====================================================================
-- iAkauntan :: 0012 organization bootstrap
-- One RPC that stands up a complete, usable set of books: chart of
-- accounts, SST tax codes, payment terms, fiscal calendar, a default
-- warehouse and a sales pipeline.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Fiscal calendar
-- ---------------------------------------------------------------------
create or replace function public.create_fiscal_year(
  p_org_id     uuid,
  p_start_date date default null
)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org       public.organizations;
  v_start     date;
  v_end       date;
  v_fy_id     uuid;
  v_p_start   date;
  v_p_end     date;
  i           integer;
begin
  select * into v_org from public.organizations where id = p_org_id;
  if not found then
    raise exception 'Organization % not found', p_org_id;
  end if;
  if not app.can_post(p_org_id) then
    raise exception 'Insufficient privileges' using errcode = '42501';
  end if;

  if p_start_date is not null then
    v_start := p_start_date;
  else
    -- Derive the year end from the org's configured month/day, rolling
    -- forward if this year's date has already passed.
    v_end := (date_trunc('month',
                make_date(extract(year from current_date)::int, v_org.fiscal_year_end_month, 1))
              + interval '1 month' - interval '1 day')::date;
    if v_org.fiscal_year_end_day < 28 then
      v_end := make_date(extract(year from v_end)::int, v_org.fiscal_year_end_month,
                         v_org.fiscal_year_end_day);
    end if;
    if v_end < current_date then
      v_end := (v_end + interval '1 year')::date;
    end if;
    v_start := (v_end - interval '1 year' + interval '1 day')::date;
  end if;

  v_end := (v_start + interval '1 year' - interval '1 day')::date;

  insert into public.fiscal_years (org_id, name, start_date, end_date)
  values (p_org_id,
          case when extract(year from v_start) = extract(year from v_end)
               then extract(year from v_start)::text
               else extract(year from v_start)::text || '/' || extract(year from v_end)::text
          end,
          v_start, v_end)
  on conflict (org_id, name) do nothing
  returning id into v_fy_id;

  if v_fy_id is null then
    return null;   -- already exists
  end if;

  -- Twelve calendar months.
  for i in 0 .. 11 loop
    v_p_start := (v_start + (i || ' months')::interval)::date;
    v_p_end   := (v_p_start + interval '1 month' - interval '1 day')::date;
    insert into public.fiscal_periods (
      org_id, fiscal_year_id, period_no, name, start_date, end_date
    ) values (
      p_org_id, v_fy_id, i + 1, to_char(v_p_start, 'Mon YYYY'), v_p_start, v_p_end
    );
  end loop;

  return v_fy_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Default chart of accounts for a Malaysian SME (MPERS aligned)
-- ---------------------------------------------------------------------
create or replace function app.seed_chart_of_accounts(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_row record;
begin
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
    ('2150','EPF Payable','liability','current_liability',false,'2100',2150),
    ('2160','SOCSO Payable','liability','current_liability',false,'2100',2160),
    ('2170','EIS Payable','liability','current_liability',false,'2100',2170),
    ('2180','PCB / MTD Payable','liability','current_liability',false,'2100',2180),
    ('2190','Amount Due to Directors','liability','current_liability',false,'2100',2190),
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
$$;

-- ---------------------------------------------------------------------
-- The bootstrap RPC
-- ---------------------------------------------------------------------
create or replace function public.create_organization(
  p_name                  text,
  p_slug                  text default null,
  p_entity_type           app.entity_type default 'sdn_bhd',
  p_registration_no       text default null,
  p_tin                   text default null,
  p_msic_code             text default null,
  p_business_activity     text default null,
  p_state_code            text default null,
  p_city                  text default null,
  p_postcode              text default null,
  p_address_line1         text default null,
  p_phone                 text default null,
  p_email                 text default null,
  p_is_sst_registered     boolean default false,
  p_sst_registration_no   text default null,
  p_fiscal_year_end_month smallint default 12
)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_org_id      uuid;
  v_slug        text;
  v_ar_id       uuid;
  v_ap_id       uuid;
  v_out_tax_id  uuid;
  v_in_tax_id   uuid;
  v_sales_tax   uuid;
  v_svc_tax     uuid;
  v_na_tax      uuid;
  v_pipeline_id uuid;
  v_suffix      integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- Derive a unique slug from the name.
  v_slug := regexp_replace(lower(coalesce(p_slug, p_name)), '[^a-z0-9]+', '-', 'g');
  v_slug := trim(both '-' from v_slug);
  if v_slug = '' then
    v_slug := 'org';
  end if;
  while exists (select 1 from public.organizations o where o.slug = v_slug) loop
    v_suffix := v_suffix + 1;
    v_slug := regexp_replace(lower(coalesce(p_slug, p_name)), '[^a-z0-9]+', '-', 'g')
              || '-' || v_suffix;
    v_slug := trim(both '-' from v_slug);
  end loop;

  insert into public.organizations (
    name, legal_name, slug, entity_type, registration_no, tin, msic_code,
    business_activity, state_code, city, postcode, address_line1,
    phone, email, is_sst_registered, sst_registration_no,
    fiscal_year_end_month, einvoice_tin, einvoice_id_value, einvoice_id_type,
    books_start_date, created_by
  ) values (
    p_name, p_name, v_slug, p_entity_type, p_registration_no, p_tin, p_msic_code,
    p_business_activity, p_state_code, p_city, p_postcode, p_address_line1,
    p_phone, p_email, p_is_sst_registered, p_sst_registration_no,
    p_fiscal_year_end_month, p_tin, p_registration_no, 'BRN',
    current_date, auth.uid()
  ) returning id into v_org_id;

  -- The add_creator_as_owner trigger has now made the caller an owner.
  perform app.seed_chart_of_accounts(v_org_id);

  select id into v_ar_id      from public.accounts where org_id = v_org_id and code = '1210';
  select id into v_ap_id      from public.accounts where org_id = v_org_id and code = '2110';
  select id into v_out_tax_id from public.accounts where org_id = v_org_id and code = '2130';
  select id into v_in_tax_id  from public.accounts where org_id = v_org_id and code = '1410';

  -- SST tax codes. Service tax moved to 8% for most taxable services in
  -- 2024, with 6% retained for F&B, telco, parking and logistics.
  insert into public.tax_codes (
    org_id, code, name, tax_type_code, rate, applies_to,
    sales_tax_account_id, purchase_tax_account_id, is_exempt, is_default
  ) values
    (v_org_id, 'NA',   'Not Applicable',        '06', 0,  'both',     v_out_tax_id, v_in_tax_id, false, true),
    (v_org_id, 'ST8',  'Service Tax 8%',        '02', 8,  'both',     v_out_tax_id, v_in_tax_id, false, false),
    (v_org_id, 'ST6',  'Service Tax 6%',        '02', 6,  'both',     v_out_tax_id, v_in_tax_id, false, false),
    (v_org_id, 'SL10', 'Sales Tax 10%',         '01', 10, 'both',     v_out_tax_id, v_in_tax_id, false, false),
    (v_org_id, 'SL5',  'Sales Tax 5%',          '01', 5,  'both',     v_out_tax_id, v_in_tax_id, false, false),
    (v_org_id, 'TTX',  'Tourism Tax',           '03', 0,  'sales',    v_out_tax_id, null,        false, false),
    (v_org_id, 'EXM',  'Exempt',                'E',  0,  'both',     v_out_tax_id, v_in_tax_id, true,  false),
    (v_org_id, 'ZR',   'Zero Rated / Export',   '06', 0,  'sales',    v_out_tax_id, null,        false, false)
  on conflict (org_id, code) do nothing;

  select id into v_na_tax    from public.tax_codes where org_id = v_org_id and code = 'NA';
  select id into v_svc_tax   from public.tax_codes where org_id = v_org_id and code = 'ST8';
  select id into v_sales_tax from public.tax_codes where org_id = v_org_id and code = 'SL10';

  update public.organizations
     set default_sales_tax_code_id    = case when p_is_sst_registered then v_svc_tax else v_na_tax end,
         default_purchase_tax_code_id = case when p_is_sst_registered then v_svc_tax else v_na_tax end
   where id = v_org_id;

  -- Payment terms
  insert into public.payment_terms (org_id, code, name, days, term_type, is_default) values
    (v_org_id, 'COD',    'Cash on Delivery',  0,  'cod',  false),
    (v_org_id, 'PREPAID','Prepaid',           0,  'prepaid', false),
    (v_org_id, 'NET7',   '7 Days',            7,  'net',  false),
    (v_org_id, 'NET14',  '14 Days',           14, 'net',  false),
    (v_org_id, 'NET30',  '30 Days',           30, 'net',  true),
    (v_org_id, 'NET60',  '60 Days',           60, 'net',  false),
    (v_org_id, 'NET90',  '90 Days',           90, 'net',  false),
    (v_org_id, 'EOM30',  'End of Month + 30', 30, 'eom',  false)
  on conflict (org_id, code) do nothing;

  -- Default warehouse and price level
  insert into public.warehouses (org_id, code, name, is_default, state_code, city)
  values (v_org_id, 'MAIN', 'Main Warehouse', true, p_state_code, p_city)
  on conflict (org_id, code) do nothing;

  insert into public.price_levels (org_id, code, name, is_default)
  values (v_org_id, 'STD', 'Standard Price', true),
         (v_org_id, 'WHL', 'Wholesale', false),
         (v_org_id, 'RTL', 'Retail', false)
  on conflict (org_id, code) do nothing;

  -- Point the AR/AP control accounts at the right defaults
  update public.accounts set is_system = true
   where org_id = v_org_id and code in ('1210', '2110', '2130', '1410', '3300', '4990');

  -- CRM pipeline
  insert into public.pipelines (org_id, name, description, is_default)
  values (v_org_id, 'Sales Pipeline', 'Default sales process', true)
  returning id into v_pipeline_id;

  insert into public.pipeline_stages (org_id, pipeline_id, name, probability, stage_type, color, sort_order) values
    (v_org_id, v_pipeline_id, 'Qualification',  10,  'open', '#94A3B8', 1),
    (v_org_id, v_pipeline_id, 'Needs Analysis', 25,  'open', '#60A5FA', 2),
    (v_org_id, v_pipeline_id, 'Proposal Sent',  50,  'open', '#818CF8', 3),
    (v_org_id, v_pipeline_id, 'Negotiation',    75,  'open', '#FBBF24', 4),
    (v_org_id, v_pipeline_id, 'Closed Won',     100, 'won',  '#34D399', 5),
    (v_org_id, v_pipeline_id, 'Closed Lost',    0,   'lost', '#F87171', 6);

  -- Fiscal calendar
  perform public.create_fiscal_year(v_org_id, null);

  update public.profiles set last_org_id = v_org_id where id = auth.uid();

  return v_org_id;
end;
$$;

comment on function public.create_organization is
  'Creates a tenant with a ready-to-use Malaysian SME chart of accounts, SST tax codes, fiscal calendar and CRM pipeline.';
