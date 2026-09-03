-- =====================================================================
-- 0512 :: a customer, a supplier and a client belong to one company
--
-- The third parent in the boundary programme, after `employees`
-- (0507-0509) and `warehouses` (0510). `contacts` already had its
-- `unique (org_id, id)` -- 0176 added it for group linking -- so this
-- is the thirty-five columns and nothing else.
--
-- This is the widest of the three and the one where a wrong id is
-- money rather than a listing. `sales_documents.contact_id` decides
-- whose receivable an invoice is; `receipts.contact_id` and
-- `purchase_payments.contact_id` decide whose money settles it;
-- `gl_lines.contact_id` is what the aged receivable and payable
-- reports are grouped by; `matters.client_id` is who a legal file
-- belongs to and whose disbursements are recharged. A row pointing at
-- another company's contact does not read as wrong anywhere -- the
-- name resolves, the report just attributes the money to somebody who
-- is not on the same books.
--
-- Each key keeps the delete rule of the plain key beside it, with one
-- correction that 0511 made necessary: `set null` on a composite key
-- needs the column list, or it nulls `org_id` too and the delete fails
-- with 23502 instead of clearing the reference.
--
-- Checked on the hosted project before writing: none of the
-- thirty-five has a row whose contact belongs to another company.
-- `scripts/check_embeds.py` is run against this migration -- adding a
-- foreign key is an API change, and 0508 made three embeds in
-- repository.dart ambiguous exactly this way.
-- =====================================================================

alter table public.activities
  add constraint activities_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete cascade;
alter table public.contact_addresses
  add constraint contact_addresses_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete cascade;
alter table public.contact_persons
  add constraint contact_persons_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete cascade;
alter table public.contra_notes
  add constraint contra_notes_customer_contact_same_org
  foreign key (org_id, customer_contact_id)
  references public.contacts (org_id, id)
  on delete no action;
alter table public.contra_notes
  add constraint contra_notes_supplier_contact_same_org
  foreign key (org_id, supplier_contact_id)
  references public.contacts (org_id, id)
  on delete no action;
alter table public.corp_entities
  add constraint corp_entities_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete set null (contact_id);
alter table public.customer_portal_links
  add constraint customer_portal_links_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete cascade;
alter table public.deposit_notes
  add constraint deposit_notes_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete no action;
alter table public.disbursements
  add constraint disbursements_supplier_same_org
  foreign key (org_id, supplier_id)
  references public.contacts (org_id, id)
  on delete set null (supplier_id);
alter table public.expense_claim_lines
  add constraint expense_claim_lines_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete no action;
alter table public.expenses
  add constraint expenses_billed_to_same_org
  foreign key (org_id, billed_to_id)
  references public.contacts (org_id, id)
  on delete set null (billed_to_id);
alter table public.expenses
  add constraint expenses_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete set null (contact_id);
alter table public.fixed_assets
  add constraint fixed_assets_supplier_same_org
  foreign key (org_id, supplier_id)
  references public.contacts (org_id, id)
  on delete set null (supplier_id);
alter table public.forecast_lines
  add constraint forecast_lines_supplier_same_org
  foreign key (org_id, supplier_id)
  references public.contacts (org_id, id)
  on delete set null (supplier_id);
alter table public.gl_lines
  add constraint gl_lines_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete set null (contact_id);
alter table public.item_forecast_params
  add constraint item_forecast_params_supplier_same_org
  foreign key (org_id, supplier_id)
  references public.contacts (org_id, id)
  on delete set null (supplier_id);
alter table public.items
  add constraint items_preferred_supplier_same_org
  foreign key (org_id, preferred_supplier_id)
  references public.contacts (org_id, id)
  on delete set null (preferred_supplier_id);
alter table public.leads
  add constraint leads_converted_contact_same_org
  foreign key (org_id, converted_contact_id)
  references public.contacts (org_id, id)
  on delete set null (converted_contact_id);
alter table public.loyalty_accounts
  add constraint loyalty_accounts_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete cascade;
alter table public.matters
  add constraint matters_client_same_org
  foreign key (org_id, client_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.opportunities
  add constraint opportunities_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete set null (contact_id);
alter table public.pos_bookings
  add constraint pos_bookings_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete set null (contact_id);
alter table public.pos_membership_subscriptions
  add constraint pos_membership_subscriptions_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete cascade;
alter table public.pos_outlets
  add constraint pos_outlets_walk_in_contact_same_org
  foreign key (org_id, walk_in_contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.pos_sales
  add constraint pos_sales_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.pos_stalls
  add constraint pos_stalls_operator_contact_same_org
  foreign key (org_id, operator_contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.post_dated_cheques
  add constraint post_dated_cheques_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete no action;
alter table public.projects
  add constraint projects_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete set null (contact_id);
alter table public.purchase_documents
  add constraint purchase_documents_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.purchase_payments
  add constraint purchase_payments_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.receipts
  add constraint receipts_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.recurring_documents
  add constraint recurring_documents_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.sales_documents
  add constraint sales_documents_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
alter table public.stock_lots
  add constraint stock_lots_supplier_same_org
  foreign key (org_id, supplier_id)
  references public.contacts (org_id, id)
  on delete set null (supplier_id);
alter table public.withholding_certificates
  add constraint withholding_certificates_contact_same_org
  foreign key (org_id, contact_id)
  references public.contacts (org_id, id)
  on delete restrict;
