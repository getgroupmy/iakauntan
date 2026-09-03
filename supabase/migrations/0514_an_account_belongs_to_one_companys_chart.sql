-- =====================================================================
-- 0514 :: an account belongs to one company's chart
--
-- The fifth parent, after `employees` (0507-0509), `warehouses`
-- (0510), `contacts` (0512) and `items` (0513). `accounts` already has
-- its `unique (org_id, id)` -- 0160 added it for
-- `gl_lines_account_same_org` -- so this is thirty-five columns and no
-- parent key.
--
-- These are not the ledger. `gl_lines.account_id` has been held to the
-- organization since 0160, and that is the line that moves a balance.
-- What is here is every place an account is CONFIGURED: the account an
-- item sells to, the account a tax code collects into, the eleven
-- accounts payroll posts to, the receivable a customer is billed
-- against, the accounts a fixed asset depreciates through.
--
-- So the failure this closes is a different shape from the earlier
-- four. A wrong id here does not put money on another company's books
-- -- `gl_lines_account_same_org` stops that at the moment of posting.
-- It stops the posting instead: the invoice is typed, the post is
-- pressed, and the ledger refuses with a foreign key error naming a
-- constraint the person has no way to act on, because the item was
-- pointed at an account that is not in their chart. This turns that
-- into a refusal at the moment the item is configured, where the
-- person can see what they did.
--
-- `accounts.parent_id` is the self-reference: the chart is a tree, and
-- this is what stops a branch of one company's chart hanging off
-- another's.
--
-- Delete rules follow the plain key beside each column, with the
-- correction 0511 made necessary: `set null` on a composite key takes
-- the column list, or it nulls `org_id` too and the delete raises
-- 23502 instead of clearing the reference.
--
-- Checked on the hosted project before writing: none of the
-- thirty-five has a row whose account belongs to another company.
-- `scripts/check_embeds.py` is run against this migration.
-- =====================================================================

alter table public.accounts
  add constraint accounts_parent_same_org
  foreign key (org_id, parent_id)
  references public.accounts (org_id, id)
  on delete set null (parent_id);
alter table public.bank_accounts
  add constraint bank_accounts_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete restrict;
alter table public.budget_lines
  add constraint budget_lines_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete restrict;
alter table public.claim_types
  add constraint claim_types_expense_account_same_org
  foreign key (org_id, expense_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.contacts
  add constraint contacts_payable_account_same_org
  foreign key (org_id, payable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.contacts
  add constraint contacts_receivable_account_same_org
  foreign key (org_id, receivable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.expense_lines
  add constraint expense_lines_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.expenses
  add constraint expenses_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete restrict;
alter table public.fixed_assets
  add constraint fixed_assets_accumulated_account_same_org
  foreign key (org_id, accumulated_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.fixed_assets
  add constraint fixed_assets_asset_account_same_org
  foreign key (org_id, asset_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.fixed_assets
  add constraint fixed_assets_expense_account_same_org
  foreign key (org_id, expense_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.items
  add constraint items_cogs_account_same_org
  foreign key (org_id, cogs_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.items
  add constraint items_inventory_account_same_org
  foreign key (org_id, inventory_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.items
  add constraint items_purchase_account_same_org
  foreign key (org_id, purchase_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.items
  add constraint items_sales_account_same_org
  foreign key (org_id, sales_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.landed_cost_charges
  add constraint landed_cost_charges_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_eis_expense_account_same_org
  foreign key (org_id, eis_expense_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_eis_payable_account_same_org
  foreign key (org_id, eis_payable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_epf_expense_account_same_org
  foreign key (org_id, epf_expense_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_epf_payable_account_same_org
  foreign key (org_id, epf_payable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_hrdf_expense_account_same_org
  foreign key (org_id, hrdf_expense_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_pcb_payable_account_same_org
  foreign key (org_id, pcb_payable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_salary_expense_account_same_org
  foreign key (org_id, salary_expense_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_salary_payable_account_same_org
  foreign key (org_id, salary_payable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_socso_expense_account_same_org
  foreign key (org_id, socso_expense_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_socso_payable_account_same_org
  foreign key (org_id, socso_payable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payroll_settings
  add constraint payroll_settings_zakat_payable_account_same_org
  foreign key (org_id, zakat_payable_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.payslip_lines
  add constraint payslip_lines_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.purchase_document_lines
  add constraint purchase_document_lines_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete set null (account_id);
alter table public.revenue_schedule_periods
  add constraint revenue_schedule_periods_revenue_account_same_org
  foreign key (org_id, revenue_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.salary_components
  add constraint salary_components_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.sales_document_lines
  add constraint sales_document_lines_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete set null (account_id);
alter table public.stock_adjustments
  add constraint stock_adjustments_account_same_org
  foreign key (org_id, account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.tax_codes
  add constraint tax_codes_purchase_tax_account_same_org
  foreign key (org_id, purchase_tax_account_id)
  references public.accounts (org_id, id)
  on delete no action;
alter table public.tax_codes
  add constraint tax_codes_sales_tax_account_same_org
  foreign key (org_id, sales_tax_account_id)
  references public.accounts (org_id, id)
  on delete no action;
