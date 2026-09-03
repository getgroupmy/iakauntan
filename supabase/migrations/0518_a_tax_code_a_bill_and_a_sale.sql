-- =====================================================================
-- 0518 :: a tax code, a bill and a sale, and the shape of what is left
--
-- The ninth, tenth and eleventh parents, in one migration because none
-- of them is large enough to be worth its own. All three need their own
-- `unique (org_id, id)` first -- `tax_codes` had only `(org_id, code)`,
-- `purchase_documents` only `(org_id, doc_type, doc_no)`, `pos_sales`
-- only `(org_id, sale_no)`.
--
-- `tax_codes` (thirteen columns) is the SST rate a line is charged at.
-- Its own `sales_tax_account_id` and `purchase_tax_account_id` were
-- held to the organization by 0514, so the account a tax collects into
-- is already right -- but the CODE named on the line was not, and a
-- line pointing at another company's tax code takes their rate and
-- their registration into this company's SST return.
--
-- `purchase_documents` (eleven) is the buy side of 0516, with the same
-- two self-references: `parent_id` for a purchase order becoming a
-- bill, and `original_bill_id` for a debit note naming the bill it
-- cancels. `payment_allocations.bill_id` is the money -- it is what
-- settles a supplier debt, and it now says which company's.
--
-- Note what is NOT here. 0516 left `purchase_documents.
-- source_sales_document_id` alone because inter-company billing points
-- it at another company's sales document on purpose. That column is a
-- reference FROM purchase_documents, not TO it, so nothing in this
-- migration touches it; the exemption in `tenant_foreign_keys.sql`
-- still stands and is still one column wide.
--
-- `pos_sales` (ten) is the till receipt and everything hanging off it:
-- its lines, its tenders, its kitchen tickets, the loyalty points it
-- earned, the membership it started. `pos_sale_lines.sale_id` and
-- `pos_tenders.sale_id` are the two that decide what a shift
-- reconciles to.
--
-- Checked on the hosted project before writing: none of the
-- thirty-four has a violating row. `scripts/check_embeds.py` is run
-- against this migration.
-- =====================================================================

alter table public.tax_codes
  add constraint tax_codes_org_id_id_key unique (org_id, id);

alter table public.purchase_documents
  add constraint purchase_documents_org_id_id_key unique (org_id, id);

alter table public.pos_sales
  add constraint pos_sales_org_id_id_key unique (org_id, id);

alter table public.accounts
  add constraint accounts_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete set null (tax_code_id);
alter table public.contacts
  add constraint contacts_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.expense_claim_lines
  add constraint expense_claim_lines_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.expense_lines
  add constraint expense_lines_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.expenses
  add constraint expenses_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.gl_lines
  add constraint gl_lines_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete set null (tax_code_id);
alter table public.items
  add constraint items_purchase_tax_code_same_org
  foreign key (org_id, purchase_tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.items
  add constraint items_sales_tax_code_same_org
  foreign key (org_id, sales_tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.pos_outlets
  add constraint pos_outlets_service_charge_tax_code_same_org
  foreign key (org_id, service_charge_tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.pos_sale_lines
  add constraint pos_sale_lines_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.purchase_document_lines
  add constraint purchase_document_lines_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.sales_document_lines
  add constraint sales_document_lines_tax_code_same_org
  foreign key (org_id, tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.sales_documents
  add constraint sales_documents_service_charge_tax_code_same_org
  foreign key (org_id, service_charge_tax_code_id)
  references public.tax_codes (org_id, id)
  on delete no action;
alter table public.fixed_assets
  add constraint fixed_assets_purchase_document_same_org
  foreign key (org_id, purchase_document_id)
  references public.purchase_documents (org_id, id)
  on delete set null (purchase_document_id);
alter table public.landed_cost_allocations
  add constraint landed_cost_allocations_bill_same_org
  foreign key (org_id, bill_id)
  references public.purchase_documents (org_id, id)
  on delete no action;
alter table public.landed_cost_charges
  add constraint landed_cost_charges_source_bill_same_org
  foreign key (org_id, source_bill_id)
  references public.purchase_documents (org_id, id)
  on delete no action;
alter table public.landed_cost_targets
  add constraint landed_cost_targets_bill_same_org
  foreign key (org_id, bill_id)
  references public.purchase_documents (org_id, id)
  on delete restrict;
alter table public.payment_allocations
  add constraint payment_allocations_bill_same_org
  foreign key (org_id, bill_id)
  references public.purchase_documents (org_id, id)
  on delete cascade;
alter table public.pos_stall_settlements
  add constraint pos_stall_settlements_bill_same_org
  foreign key (org_id, bill_id)
  references public.purchase_documents (org_id, id)
  on delete set null (bill_id);
alter table public.property_statutory_charges
  add constraint property_statutory_charges_bill_document_same_org
  foreign key (org_id, bill_document_id)
  references public.purchase_documents (org_id, id)
  on delete set null (bill_document_id);
alter table public.purchase_document_lines
  add constraint purchase_document_lines_document_same_org
  foreign key (org_id, document_id)
  references public.purchase_documents (org_id, id)
  on delete cascade;
alter table public.purchase_documents
  add constraint purchase_documents_original_bill_same_org
  foreign key (org_id, original_bill_id)
  references public.purchase_documents (org_id, id)
  on delete set null (original_bill_id);
alter table public.purchase_documents
  add constraint purchase_documents_parent_same_org
  foreign key (org_id, parent_id)
  references public.purchase_documents (org_id, id)
  on delete set null (parent_id);
alter table public.withholding_certificates
  add constraint withholding_certificates_bill_same_org
  foreign key (org_id, bill_id)
  references public.purchase_documents (org_id, id)
  on delete restrict;
alter table public.loyalty_entries
  add constraint loyalty_entries_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete set null (sale_id);
alter table public.pos_bookings
  add constraint pos_bookings_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete set null (sale_id);
alter table public.pos_deliveries
  add constraint pos_deliveries_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete cascade;
alter table public.pos_kitchen_tickets
  add constraint pos_kitchen_tickets_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete set null (sale_id);
alter table public.pos_membership_sessions
  add constraint pos_membership_sessions_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete set null (sale_id);
alter table public.pos_membership_subscriptions
  add constraint pos_membership_subscriptions_origin_sale_same_org
  foreign key (org_id, origin_sale_id)
  references public.pos_sales (org_id, id)
  on delete set null (origin_sale_id);
alter table public.pos_sale_line_voids
  add constraint pos_sale_line_voids_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete cascade;
alter table public.pos_sale_lines
  add constraint pos_sale_lines_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete cascade;
alter table public.pos_sale_promotions
  add constraint pos_sale_promotions_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete cascade;
alter table public.pos_tenders
  add constraint pos_tenders_sale_same_org
  foreign key (org_id, sale_id)
  references public.pos_sales (org_id, id)
  on delete cascade;
