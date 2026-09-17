-- =====================================================================
-- 0520 :: the nineteen parents with three or four references each
--
-- The programme's shape has changed. The first nine migrations took
-- one large parent at a time -- `employees` had twenty-six columns,
-- `contacts` thirty-five, `items` thirty-three. What is left is a long
-- tail, and the per-batch overhead (a hosted violation check, an embed
-- check, a probe, four gates) now costs more than the constraints do.
-- So this is nineteen parents and sixty-three columns in one migration,
-- and the ones after it will be shaped the same way.
--
-- Seventeen of the nineteen need their own `unique (org_id, id)` first;
-- `matters` and `tickets` already had one.
--
-- Most of these are a parent and its own lines, where the composite key
-- says a line belongs to a document in the same company: a bill of
-- materials and its lines and operations, a landed cost run and its
-- charges and targets, a ticket and its comments and events, a sale
-- line and its modifiers.
--
-- Four are worth naming individually.
--
-- `receipts` -- `payment_allocations.receipt_id` is the money side.
-- 0167 stopped one customer's receipt settling another customer's
-- invoice; 0516 stopped one company's money settling another
-- company's; this holds the receipt end of the same allocation.
--
-- `matters` -- `client_account_transactions.matter_id` is a client
-- account movement under the Legal Profession (Accounts and Audit)
-- Rules. A movement recorded against another firm's matter is a
-- breach of the rules a solicitor is audited against, not merely a
-- wrong row.
--
-- `pos_tables.parent_table_id` is the T1-A/T1-B split from 0144, and
-- `item_categories.parent_id`, `tickets.parent_id`,
-- `purchase_document_lines.source_line_id` and
-- `sales_document_lines.source_line_id` are the other
-- self-references: a category tree, a child ticket, and a line copied
-- from the document before it in the cycle.
--
-- `ticket_share_links.ticket_id` is the third thing in this programme
-- that leaves the building, after `document_share_links` (0516) and
-- the customer portal: a token a person with no account follows to see
-- a ticket, read with that token rather than a session, so RLS does
-- not help.
--
-- Sixty-three columns, not sixty-four. `purchase_documents.
-- payment_term_id` is the second column in this programme where
-- crossing the boundary is deliberate, after
-- `source_sales_document_id` in 0516 -- and, like that one, the SQL
-- suite is what said so.
--
-- 0439 made `accept_intercompany_bill` copy the seller's due date onto
-- the buyer's bill, because `report_ap_aging` buckets on
-- `coalesce(due_date, doc_date)` and a null aged the bill from the day
-- it was raised, showing the group in arrears for a credit period it
-- had agreed. It copied the payment TERM alongside the date, and
-- asserted it: "and the terms it was raised on, not only the date they
-- produce". So the buyer's bill records the seller's terms on purpose.
--
-- I got this one wrong twice before getting it right. The constraint
-- was written like the other sixty-three; the test failed; I read that
-- as an implementation accident and changed the function to stop
-- copying the term; the test failed again, on the assertion that names
-- the intent in its own title. The function is unchanged and the column
-- is exempted by name in the coverage query, next to 0516's.
--
-- Checked on the hosted project before writing: none of the sixty-three
-- has a violating row. `scripts/check_embeds.py` is run against this
-- migration.
-- =====================================================================

alter table public.bills_of_materials
  add constraint bills_of_materials_org_id_id_key unique (org_id, id);
alter table public.contact_persons
  add constraint contact_persons_org_id_id_key unique (org_id, id);
alter table public.corp_resolutions
  add constraint corp_resolutions_org_id_id_key unique (org_id, id);
alter table public.item_categories
  add constraint item_categories_org_id_id_key unique (org_id, id);
alter table public.landed_cost_runs
  add constraint landed_cost_runs_org_id_id_key unique (org_id, id);
alter table public.opportunities
  add constraint opportunities_org_id_id_key unique (org_id, id);
alter table public.payment_terms
  add constraint payment_terms_org_id_id_key unique (org_id, id);
alter table public.pipeline_stages
  add constraint pipeline_stages_org_id_id_key unique (org_id, id);
alter table public.pos_kitchen_stations
  add constraint pos_kitchen_stations_org_id_id_key unique (org_id, id);
alter table public.pos_modifier_groups
  add constraint pos_modifier_groups_org_id_id_key unique (org_id, id);
alter table public.pos_sale_lines
  add constraint pos_sale_lines_org_id_id_key unique (org_id, id);
alter table public.pos_service_providers
  add constraint pos_service_providers_org_id_id_key unique (org_id, id);
alter table public.pos_stalls
  add constraint pos_stalls_org_id_id_key unique (org_id, id);
alter table public.pos_tables
  add constraint pos_tables_org_id_id_key unique (org_id, id);
alter table public.purchase_document_lines
  add constraint purchase_document_lines_org_id_id_key unique (org_id, id);
alter table public.receipts
  add constraint receipts_org_id_id_key unique (org_id, id);
alter table public.sales_document_lines
  add constraint sales_document_lines_org_id_id_key unique (org_id, id);
alter table public.bom_lines
  add constraint bom_lines_bom_same_org
  foreign key (org_id, bom_id)
  references public.bills_of_materials (org_id, id)
  on delete cascade;
alter table public.bom_operations
  add constraint bom_operations_bom_same_org
  foreign key (org_id, bom_id)
  references public.bills_of_materials (org_id, id)
  on delete cascade;
alter table public.manufacturing_orders
  add constraint manufacturing_orders_bom_same_org
  foreign key (org_id, bom_id)
  references public.bills_of_materials (org_id, id)
  on delete restrict;
alter table public.activities
  add constraint activities_contact_person_same_org
  foreign key (org_id, contact_person_id)
  references public.contact_persons (org_id, id)
  on delete set null (contact_person_id);
alter table public.opportunities
  add constraint opportunities_contact_person_same_org
  foreign key (org_id, contact_person_id)
  references public.contact_persons (org_id, id)
  on delete set null (contact_person_id);
alter table public.purchase_documents
  add constraint purchase_documents_contact_person_same_org
  foreign key (org_id, contact_person_id)
  references public.contact_persons (org_id, id)
  on delete set null (contact_person_id);
alter table public.sales_documents
  add constraint sales_documents_contact_person_same_org
  foreign key (org_id, contact_person_id)
  references public.contact_persons (org_id, id)
  on delete set null (contact_person_id);
alter table public.corp_documents
  add constraint corp_documents_resolution_same_org
  foreign key (org_id, resolution_id)
  references public.corp_resolutions (org_id, id)
  on delete set null (resolution_id);
alter table public.corp_filings
  add constraint corp_filings_resolution_same_org
  foreign key (org_id, resolution_id)
  references public.corp_resolutions (org_id, id)
  on delete set null (resolution_id);
alter table public.corp_share_events
  add constraint corp_share_events_resolution_same_org
  foreign key (org_id, resolution_id)
  references public.corp_resolutions (org_id, id)
  on delete set null (resolution_id);
alter table public.category_kitchen_stations
  add constraint category_kitchen_stations_category_same_org
  foreign key (org_id, category_id)
  references public.item_categories (org_id, id)
  on delete cascade;
alter table public.item_categories
  add constraint item_categories_parent_same_org
  foreign key (org_id, parent_id)
  references public.item_categories (org_id, id)
  on delete set null (parent_id);
alter table public.items
  add constraint items_category_same_org
  foreign key (org_id, category_id)
  references public.item_categories (org_id, id)
  on delete set null (category_id);
alter table public.landed_cost_allocations
  add constraint landed_cost_allocations_run_same_org
  foreign key (org_id, run_id)
  references public.landed_cost_runs (org_id, id)
  on delete cascade;
alter table public.landed_cost_charges
  add constraint landed_cost_charges_run_same_org
  foreign key (org_id, run_id)
  references public.landed_cost_runs (org_id, id)
  on delete cascade;
alter table public.landed_cost_targets
  add constraint landed_cost_targets_run_same_org
  foreign key (org_id, run_id)
  references public.landed_cost_runs (org_id, id)
  on delete cascade;
alter table public.client_account_transactions
  add constraint client_account_transactions_matter_same_org
  foreign key (org_id, matter_id)
  references public.matters (org_id, id)
  on delete restrict;
alter table public.disbursements
  add constraint disbursements_matter_same_org
  foreign key (org_id, matter_id)
  references public.matters (org_id, id)
  on delete cascade;
alter table public.sales_documents
  add constraint sales_documents_matter_same_org
  foreign key (org_id, matter_id)
  references public.matters (org_id, id)
  on delete set null (matter_id);
alter table public.activities
  add constraint activities_opportunity_same_org
  foreign key (org_id, opportunity_id)
  references public.opportunities (org_id, id)
  on delete cascade;
alter table public.leads
  add constraint leads_converted_opportunity_same_org
  foreign key (org_id, converted_opportunity_id)
  references public.opportunities (org_id, id)
  on delete set null (converted_opportunity_id);
alter table public.opportunity_stage_history
  add constraint opportunity_stage_history_opportunity_same_org
  foreign key (org_id, opportunity_id)
  references public.opportunities (org_id, id)
  on delete cascade;
alter table public.sales_documents
  add constraint sales_documents_opportunity_same_org
  foreign key (org_id, opportunity_id)
  references public.opportunities (org_id, id)
  on delete set null (opportunity_id);
alter table public.contacts
  add constraint contacts_payment_term_same_org
  foreign key (org_id, payment_term_id)
  references public.payment_terms (org_id, id)
  on delete no action;
alter table public.sales_documents
  add constraint sales_documents_payment_term_same_org
  foreign key (org_id, payment_term_id)
  references public.payment_terms (org_id, id)
  on delete no action;
alter table public.opportunities
  add constraint opportunities_stage_same_org
  foreign key (org_id, stage_id)
  references public.pipeline_stages (org_id, id)
  on delete restrict;
alter table public.opportunity_stage_history
  add constraint opportunity_stage_history_from_stage_same_org
  foreign key (org_id, from_stage_id)
  references public.pipeline_stages (org_id, id)
  on delete set null (from_stage_id);
alter table public.opportunity_stage_history
  add constraint opportunity_stage_history_to_stage_same_org
  foreign key (org_id, to_stage_id)
  references public.pipeline_stages (org_id, id)
  on delete cascade;
alter table public.category_kitchen_stations
  add constraint category_kitchen_stations_station_same_org
  foreign key (org_id, station_id)
  references public.pos_kitchen_stations (org_id, id)
  on delete cascade;
alter table public.item_kitchen_stations
  add constraint item_kitchen_stations_station_same_org
  foreign key (org_id, station_id)
  references public.pos_kitchen_stations (org_id, id)
  on delete cascade;
alter table public.pos_kitchen_tickets
  add constraint pos_kitchen_tickets_station_same_org
  foreign key (org_id, station_id)
  references public.pos_kitchen_stations (org_id, id)
  on delete cascade;
alter table public.item_modifier_groups
  add constraint item_modifier_groups_group_same_org
  foreign key (org_id, group_id)
  references public.pos_modifier_groups (org_id, id)
  on delete cascade;
alter table public.pos_modifiers
  add constraint pos_modifiers_group_same_org
  foreign key (org_id, group_id)
  references public.pos_modifier_groups (org_id, id)
  on delete cascade;
alter table public.pos_sale_line_modifiers
  add constraint pos_sale_line_modifiers_group_same_org
  foreign key (org_id, group_id)
  references public.pos_modifier_groups (org_id, id)
  on delete set null (group_id);
alter table public.pos_kitchen_ticket_lines
  add constraint pos_kitchen_ticket_lines_sale_line_same_org
  foreign key (org_id, sale_line_id)
  references public.pos_sale_lines (org_id, id)
  on delete set null (sale_line_id);
alter table public.pos_membership_sessions
  add constraint pos_membership_sessions_line_same_org
  foreign key (org_id, line_id)
  references public.pos_sale_lines (org_id, id)
  on delete cascade;
alter table public.pos_sale_line_modifiers
  add constraint pos_sale_line_modifiers_line_same_org
  foreign key (org_id, line_id)
  references public.pos_sale_lines (org_id, id)
  on delete cascade;
alter table public.pos_sale_promotions
  add constraint pos_sale_promotions_line_same_org
  foreign key (org_id, line_id)
  references public.pos_sale_lines (org_id, id)
  on delete cascade;
alter table public.pos_bookings
  add constraint pos_bookings_provider_same_org
  foreign key (org_id, provider_id)
  references public.pos_service_providers (org_id, id)
  on delete restrict;
alter table public.pos_provider_hours
  add constraint pos_provider_hours_provider_same_org
  foreign key (org_id, provider_id)
  references public.pos_service_providers (org_id, id)
  on delete cascade;
alter table public.pos_provider_time_off
  add constraint pos_provider_time_off_provider_same_org
  foreign key (org_id, provider_id)
  references public.pos_service_providers (org_id, id)
  on delete cascade;
alter table public.items
  add constraint items_stall_same_org
  foreign key (org_id, stall_id)
  references public.pos_stalls (org_id, id)
  on delete set null (stall_id);
alter table public.pos_sale_lines
  add constraint pos_sale_lines_stall_same_org
  foreign key (org_id, stall_id)
  references public.pos_stalls (org_id, id)
  on delete set null (stall_id);
alter table public.pos_stall_settlements
  add constraint pos_stall_settlements_stall_same_org
  foreign key (org_id, stall_id)
  references public.pos_stalls (org_id, id)
  on delete cascade;
alter table public.pos_menu_links
  add constraint pos_menu_links_table_same_org
  foreign key (org_id, table_id)
  references public.pos_tables (org_id, id)
  on delete cascade;
alter table public.pos_queue_entries
  add constraint pos_queue_entries_table_same_org
  foreign key (org_id, table_id)
  references public.pos_tables (org_id, id)
  on delete set null (table_id);
alter table public.pos_sales
  add constraint pos_sales_table_same_org
  foreign key (org_id, table_id)
  references public.pos_tables (org_id, id)
  on delete set null (table_id);
alter table public.pos_tables
  add constraint pos_tables_parent_table_same_org
  foreign key (org_id, parent_table_id)
  references public.pos_tables (org_id, id)
  on delete cascade;
alter table public.document_line_lots
  add constraint document_line_lots_purchase_line_same_org
  foreign key (org_id, purchase_line_id)
  references public.purchase_document_lines (org_id, id)
  on delete cascade;
alter table public.fixed_assets
  add constraint fixed_assets_purchase_line_same_org
  foreign key (org_id, purchase_line_id)
  references public.purchase_document_lines (org_id, id)
  on delete set null (purchase_line_id);
alter table public.landed_cost_allocations
  add constraint landed_cost_allocations_bill_line_same_org
  foreign key (org_id, bill_line_id)
  references public.purchase_document_lines (org_id, id)
  on delete cascade;
alter table public.purchase_document_lines
  add constraint purchase_document_lines_source_line_same_org
  foreign key (org_id, source_line_id)
  references public.purchase_document_lines (org_id, id)
  on delete set null (source_line_id);
alter table public.email_outbox
  add constraint email_outbox_receipt_same_org
  foreign key (org_id, receipt_id)
  references public.receipts (org_id, id)
  on delete set null (receipt_id);
alter table public.payment_allocations
  add constraint payment_allocations_receipt_same_org
  foreign key (org_id, receipt_id)
  references public.receipts (org_id, id)
  on delete cascade;
alter table public.pos_sales
  add constraint pos_sales_receipt_same_org
  foreign key (org_id, receipt_id)
  references public.receipts (org_id, id)
  on delete restrict;
alter table public.sales_gateway_payments
  add constraint sales_gateway_payments_receipt_same_org
  foreign key (org_id, receipt_id)
  references public.receipts (org_id, id)
  on delete no action;
alter table public.document_line_lots
  add constraint document_line_lots_sales_line_same_org
  foreign key (org_id, sales_line_id)
  references public.sales_document_lines (org_id, id)
  on delete cascade;
alter table public.revenue_schedule_periods
  add constraint revenue_schedule_periods_line_same_org
  foreign key (org_id, line_id)
  references public.sales_document_lines (org_id, id)
  on delete cascade;
alter table public.sales_document_lines
  add constraint sales_document_lines_source_line_same_org
  foreign key (org_id, source_line_id)
  references public.sales_document_lines (org_id, id)
  on delete set null (source_line_id);
alter table public.ticket_comments
  add constraint ticket_comments_ticket_same_org
  foreign key (org_id, ticket_id)
  references public.tickets (org_id, id)
  on delete cascade;
alter table public.ticket_events
  add constraint ticket_events_ticket_same_org
  foreign key (org_id, ticket_id)
  references public.tickets (org_id, id)
  on delete cascade;
alter table public.ticket_share_links
  add constraint ticket_share_links_ticket_same_org
  foreign key (org_id, ticket_id)
  references public.tickets (org_id, id)
  on delete cascade;
alter table public.tickets
  add constraint tickets_parent_same_org
  foreign key (org_id, parent_id)
  references public.tickets (org_id, id)
  on delete set null (parent_id);
