-- The standard chart of accounts cannot post a payroll.
--
-- `post_payroll_run()` builds its journal through `app.payroll_gl_line()`,
-- which takes the account configured in payroll settings and, where none
-- is configured, falls back to a code it expects to find in the chart.
-- Four of those codes are not in the chart that `create_organization()`
-- seeds:
--
--     2145  Net Salaries Payable
--     2185  Zakat Payable
--     2195  HRD Corp Levy Payable
--     6150  HRD Corp Levy
--
-- The first one is fatal on the first run any company ever posts. Net pay
-- is never zero, so the line is always built, and the fallback raises:
--
--     Payroll needs an account for "Net salaries payable" — configure it
--     in payroll settings or add account 2145 to the chart of accounts
--
-- Every organization created by this product, with the chart this product
-- seeds, is unable to post payroll until somebody reads that message and
-- adds an account by hand. That is not a demo problem; it is the payroll
-- module not working out of the box.
--
-- The other three are latent rather than fatal, because
-- `payroll_gl_line()` returns no line at all when both sides are zero:
-- they only raise for a company that pays the HRD Corp levy or deducts
-- zakat. That is a smaller set of companies, not a smaller bug — it just
-- waits for the first employer with a levy liability.
--
-- ## Why the backfill is a second call to the same function
--
-- `app.seed_chart_of_accounts()` has been re-entrant since `0071`: it
-- inserts `on conflict (org_id, code) do nothing` and re-derives the
-- parent hierarchy from the same table. Running it again over an existing
-- organization therefore adds exactly the rows that are missing and
-- leaves every other account alone — including any the company added
-- itself, which are not in `_coa` and are never touched.
--
-- So the backfill does not hand-write four inserts that would have to be
-- kept in step with the seed. It calls the seed. One code path, and it is
-- the one already under test.

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
$$;

-- ---------------------------------------------------------------------
-- Every organization that already exists gets the missing accounts
-- ---------------------------------------------------------------------
do $$
declare v_org uuid; v_n integer := 0;
begin
  for v_org in select id from public.organizations order by created_at loop
    perform app.seed_chart_of_accounts(v_org);
    v_n := v_n + 1;
  end loop;
  raise notice 'chart re-seeded for % organization(s)', v_n;
end $$;
