-- =====================================================================
-- 0521 :: the rest of them
--
-- This finishes the programme. Every remaining parent that carries its
-- own `org_id` and is named by a table that carries one too:
-- 76 parents, 98 columns, 71 of which need their own
-- `unique (org_id, id)` first.
--
-- After this, `tenant_foreign_keys.sql` stops listing parents by name.
-- The coverage query becomes unconditional -- EVERY single-column
-- foreign key between two tables that both carry `org_id` has to have a
-- composite sibling -- which is the assertion the whole programme was
-- for. A table added next year gets the same treatment on the day it is
-- written, and the two deliberate exceptions are the only names left in
-- the query.
--
-- Those two are unchanged and both on `purchase_documents`:
-- `source_sales_document_id` (0516) and `payment_term_id` (0520), both
-- inter-company billing, both found by the SQL suite rather than by
-- reading. They appear in this batch's candidate list and are excluded
-- here by name.
--
-- Nothing in this migration is individually remarkable, which is the
-- point of doing it in one go. It is the tail: a payslip and its lines,
-- a manufacturing order and its components and operations, a pipeline
-- and its stages, an appraisal and its goals, a delivery and the driver
-- and zone it names, a lot and the movements against it. The two
-- self-references are `ticket_categories.parent_id` and
-- `property_units.principal_unit_id` -- the second being a strata
-- accessory parcel hanging off its principal unit, which is the shape
-- the Strata Management Act cares about.
--
-- `payslip_access_log.payslip_id` and `.grant_id` are worth one line.
-- Those tables exist because a payslip is the most sensitive row in the
-- schema and 0136 made every read of one leave a trace. Holding them to
-- the organization means the trace names a payslip on the same books as
-- the person who read it.
--
-- Checked on the hosted project before writing, in two halves: none of
-- the 98 has a violating row. `scripts/check_embeds.py` is run
-- against this migration.
-- =====================================================================

alter table public.access_types
  add constraint access_types_org_id_id_key unique (org_id, id);
alter table public.ai_conversations
  add constraint ai_conversations_org_id_id_key unique (org_id, id);
alter table public.applicants
  add constraint applicants_org_id_id_key unique (org_id, id);
alter table public.appraisal_cycles
  add constraint appraisal_cycles_org_id_id_key unique (org_id, id);
alter table public.appraisals
  add constraint appraisals_org_id_id_key unique (org_id, id);
alter table public.attachments
  add constraint attachments_org_id_id_key unique (org_id, id);
alter table public.bank_reconciliations
  add constraint bank_reconciliations_org_id_id_key unique (org_id, id);
alter table public.budgets
  add constraint budgets_org_id_id_key unique (org_id, id);
alter table public.claim_types
  add constraint claim_types_org_id_id_key unique (org_id, id);
alter table public.contact_addresses
  add constraint contact_addresses_org_id_id_key unique (org_id, id);
alter table public.contra_notes
  add constraint contra_notes_org_id_id_key unique (org_id, id);
alter table public.corp_documents
  add constraint corp_documents_org_id_id_key unique (org_id, id);
alter table public.corp_filings
  add constraint corp_filings_org_id_id_key unique (org_id, id);
alter table public.corp_officers
  add constraint corp_officers_org_id_id_key unique (org_id, id);
alter table public.corp_share_classes
  add constraint corp_share_classes_org_id_id_key unique (org_id, id);
alter table public.corp_signature_requests
  add constraint corp_signature_requests_org_id_id_key unique (org_id, id);
alter table public.corp_signatures
  add constraint corp_signatures_org_id_id_key unique (org_id, id);
alter table public.deposit_notes
  add constraint deposit_notes_org_id_id_key unique (org_id, id);
alter table public.depreciation_runs
  add constraint depreciation_runs_org_id_id_key unique (org_id, id);
alter table public.einvoice_consolidations
  add constraint einvoice_consolidations_org_id_id_key unique (org_id, id);
alter table public.einvoice_submissions
  add constraint einvoice_submissions_org_id_id_key unique (org_id, id);
alter table public.employee_documents
  add constraint employee_documents_org_id_id_key unique (org_id, id);
alter table public.expense_claims
  add constraint expense_claims_org_id_id_key unique (org_id, id);
alter table public.expenses
  add constraint expenses_org_id_id_key unique (org_id, id);
alter table public.fiscal_periods
  add constraint fiscal_periods_org_id_id_key unique (org_id, id);
alter table public.fiscal_years
  add constraint fiscal_years_org_id_id_key unique (org_id, id);
alter table public.forecast_lines
  add constraint forecast_lines_org_id_id_key unique (org_id, id);
alter table public.forecast_runs
  add constraint forecast_runs_org_id_id_key unique (org_id, id);
alter table public.item_conversions
  add constraint item_conversions_org_id_id_key unique (org_id, id);
alter table public.job_requisitions
  add constraint job_requisitions_org_id_id_key unique (org_id, id);
alter table public.leads
  add constraint leads_org_id_id_key unique (org_id, id);
alter table public.loyalty_accounts
  add constraint loyalty_accounts_org_id_id_key unique (org_id, id);
alter table public.loyalty_programs
  add constraint loyalty_programs_org_id_id_key unique (org_id, id);
alter table public.manufacturing_orders
  add constraint manufacturing_orders_org_id_id_key unique (org_id, id);
alter table public.onboarding_checklists
  add constraint onboarding_checklists_org_id_id_key unique (org_id, id);
alter table public.onboarding_templates
  add constraint onboarding_templates_org_id_id_key unique (org_id, id);
alter table public.org_mailboxes
  add constraint org_mailboxes_org_id_id_key unique (org_id, id);
alter table public.org_members
  add constraint org_members_org_id_id_key unique (org_id, id);
alter table public.payroll_runs
  add constraint payroll_runs_org_id_id_key unique (org_id, id);
alter table public.payslip_access_requests
  add constraint payslip_access_requests_org_id_id_key unique (org_id, id);
alter table public.payslips
  add constraint payslips_org_id_id_key unique (org_id, id);
alter table public.pipelines
  add constraint pipelines_org_id_id_key unique (org_id, id);
alter table public.platform_invoices
  add constraint platform_invoices_org_id_id_key unique (org_id, id);
alter table public.pos_delivery_zones
  add constraint pos_delivery_zones_org_id_id_key unique (org_id, id);
alter table public.pos_drivers
  add constraint pos_drivers_org_id_id_key unique (org_id, id);
alter table public.pos_floor_areas
  add constraint pos_floor_areas_org_id_id_key unique (org_id, id);
alter table public.pos_kitchen_tickets
  add constraint pos_kitchen_tickets_org_id_id_key unique (org_id, id);
alter table public.pos_membership_subscriptions
  add constraint pos_membership_subscriptions_org_id_id_key unique (org_id, id);
alter table public.pos_memberships
  add constraint pos_memberships_org_id_id_key unique (org_id, id);
alter table public.pos_menu_links
  add constraint pos_menu_links_org_id_id_key unique (org_id, id);
alter table public.pos_modifiers
  add constraint pos_modifiers_org_id_id_key unique (org_id, id);
alter table public.pos_promotions
  add constraint pos_promotions_org_id_id_key unique (org_id, id);
alter table public.pos_recipes
  add constraint pos_recipes_org_id_id_key unique (org_id, id);
alter table public.pos_shifts
  add constraint pos_shifts_org_id_id_key unique (org_id, id);
alter table public.pos_tender_types
  add constraint pos_tender_types_org_id_id_key unique (org_id, id);
alter table public.positions
  add constraint positions_org_id_id_key unique (org_id, id);
alter table public.post_dated_cheques
  add constraint post_dated_cheques_org_id_id_key unique (org_id, id);
alter table public.price_levels
  add constraint price_levels_org_id_id_key unique (org_id, id);
alter table public.purchase_payments
  add constraint purchase_payments_org_id_id_key unique (org_id, id);
alter table public.recurring_documents
  add constraint recurring_documents_org_id_id_key unique (org_id, id);
alter table public.salary_components
  add constraint salary_components_org_id_id_key unique (org_id, id);
alter table public.salespeople
  add constraint salespeople_org_id_id_key unique (org_id, id);
alter table public.stock_adjustment_lines
  add constraint stock_adjustment_lines_org_id_id_key unique (org_id, id);
alter table public.stock_adjustments
  add constraint stock_adjustments_org_id_id_key unique (org_id, id);
alter table public.stock_lots
  add constraint stock_lots_org_id_id_key unique (org_id, id);
alter table public.stock_movements
  add constraint stock_movements_org_id_id_key unique (org_id, id);
alter table public.stock_transfers
  add constraint stock_transfers_org_id_id_key unique (org_id, id);
alter table public.strata_charge_rates
  add constraint strata_charge_rates_org_id_id_key unique (org_id, id);
alter table public.withholding_certificates
  add constraint withholding_certificates_org_id_id_key unique (org_id, id);
alter table public.work_centres
  add constraint work_centres_org_id_id_key unique (org_id, id);
alter table public.work_shifts
  add constraint work_shifts_org_id_id_key unique (org_id, id);
alter table public.org_members
  add constraint org_members_access_type_same_org
  foreign key (org_id, access_type_id)
  references public.access_types (org_id, id)
  on delete set null (access_type_id);
alter table public.ai_messages
  add constraint ai_messages_conversation_same_org
  foreign key (org_id, conversation_id)
  references public.ai_conversations (org_id, id)
  on delete cascade;
alter table public.applicant_stage_history
  add constraint applicant_stage_history_applicant_same_org
  foreign key (org_id, applicant_id)
  references public.applicants (org_id, id)
  on delete cascade;
alter table public.interviews
  add constraint interviews_applicant_same_org
  foreign key (org_id, applicant_id)
  references public.applicants (org_id, id)
  on delete cascade;
alter table public.appraisals
  add constraint appraisals_cycle_same_org
  foreign key (org_id, cycle_id)
  references public.appraisal_cycles (org_id, id)
  on delete cascade;
alter table public.appraisal_goals
  add constraint appraisal_goals_appraisal_same_org
  foreign key (org_id, appraisal_id)
  references public.appraisals (org_id, id)
  on delete cascade;
alter table public.ocr_scans
  add constraint ocr_scans_attachment_same_org
  foreign key (org_id, attachment_id)
  references public.attachments (org_id, id)
  on delete set null (attachment_id);
alter table public.bank_transactions
  add constraint bank_transactions_reconciliation_same_org
  foreign key (org_id, reconciliation_id)
  references public.bank_reconciliations (org_id, id)
  on delete set null (reconciliation_id);
alter table public.budget_lines
  add constraint budget_lines_budget_same_org
  foreign key (org_id, budget_id)
  references public.budgets (org_id, id)
  on delete cascade;
alter table public.expense_claim_lines
  add constraint expense_claim_lines_claim_type_same_org
  foreign key (org_id, claim_type_id)
  references public.claim_types (org_id, id)
  on delete set null (claim_type_id);
alter table public.sales_documents
  add constraint sales_documents_shipping_address_same_org
  foreign key (org_id, shipping_address_id)
  references public.contact_addresses (org_id, id)
  on delete set null (shipping_address_id);
alter table public.payment_allocations
  add constraint payment_allocations_contra_same_org
  foreign key (org_id, contra_id)
  references public.contra_notes (org_id, id)
  on delete cascade;
alter table public.corp_signature_requests
  add constraint corp_signature_requests_document_same_org
  foreign key (org_id, document_id)
  references public.corp_documents (org_id, id)
  on delete cascade;
alter table public.corp_documents
  add constraint corp_documents_filing_same_org
  foreign key (org_id, filing_id)
  references public.corp_filings (org_id, id)
  on delete set null (filing_id);
alter table public.corp_share_events
  add constraint corp_share_events_filing_same_org
  foreign key (org_id, filing_id)
  references public.corp_filings (org_id, id)
  on delete set null (filing_id);
alter table public.corp_officers
  add constraint corp_officers_alternate_for_same_org
  foreign key (org_id, alternate_for)
  references public.corp_officers (org_id, id)
  on delete set null (alternate_for);
alter table public.corp_share_events
  add constraint corp_share_events_share_class_same_org
  foreign key (org_id, share_class_id)
  references public.corp_share_classes (org_id, id)
  on delete restrict;
alter table public.corp_signatures
  add constraint corp_signatures_request_same_org
  foreign key (org_id, request_id)
  references public.corp_signature_requests (org_id, id)
  on delete cascade;
alter table public.corp_signing_links
  add constraint corp_signing_links_signature_same_org
  foreign key (org_id, signature_id)
  references public.corp_signatures (org_id, id)
  on delete cascade;
alter table public.deposit_events
  add constraint deposit_events_deposit_same_org
  foreign key (org_id, deposit_id)
  references public.deposit_notes (org_id, id)
  on delete cascade;
alter table public.payment_allocations
  add constraint payment_allocations_deposit_same_org
  foreign key (org_id, deposit_id)
  references public.deposit_notes (org_id, id)
  on delete cascade;
alter table public.depreciation_entries
  add constraint depreciation_entries_run_same_org
  foreign key (org_id, run_id)
  references public.depreciation_runs (org_id, id)
  on delete cascade;
alter table public.einvoice_consolidation_items
  add constraint einvoice_consolidation_items_consolidation_same_org
  foreign key (org_id, consolidation_id)
  references public.einvoice_consolidations (org_id, id)
  on delete cascade;
alter table public.einvoice_documents
  add constraint einvoice_documents_submission_same_org
  foreign key (org_id, submission_id)
  references public.einvoice_submissions (org_id, id)
  on delete set null (submission_id);
alter table public.einvoice_logs
  add constraint einvoice_logs_submission_same_org
  foreign key (org_id, submission_id)
  references public.einvoice_submissions (org_id, id)
  on delete set null (submission_id);
alter table public.employee_documents
  add constraint employee_documents_supersedes_same_org
  foreign key (org_id, supersedes_id)
  references public.employee_documents (org_id, id)
  on delete set null (supersedes_id);
alter table public.claim_approvals
  add constraint claim_approvals_claim_same_org
  foreign key (org_id, claim_id)
  references public.expense_claims (org_id, id)
  on delete cascade;
alter table public.expense_claim_lines
  add constraint expense_claim_lines_claim_same_org
  foreign key (org_id, claim_id)
  references public.expense_claims (org_id, id)
  on delete cascade;
alter table public.expense_lines
  add constraint expense_lines_expense_same_org
  foreign key (org_id, expense_id)
  references public.expenses (org_id, id)
  on delete cascade;
alter table public.budget_lines
  add constraint budget_lines_period_same_org
  foreign key (org_id, period_id)
  references public.fiscal_periods (org_id, id)
  on delete cascade;
alter table public.gl_entries
  add constraint gl_entries_fiscal_period_same_org
  foreign key (org_id, fiscal_period_id)
  references public.fiscal_periods (org_id, id)
  on delete no action;
alter table public.budgets
  add constraint budgets_fiscal_year_same_org
  foreign key (org_id, fiscal_year_id)
  references public.fiscal_years (org_id, id)
  on delete cascade;
alter table public.fiscal_periods
  add constraint fiscal_periods_fiscal_year_same_org
  foreign key (org_id, fiscal_year_id)
  references public.fiscal_years (org_id, id)
  on delete cascade;
alter table public.depreciation_entries
  add constraint depreciation_entries_asset_same_org
  foreign key (org_id, asset_id)
  references public.fixed_assets (org_id, id)
  on delete cascade;
alter table public.purchase_document_lines
  add constraint purchase_document_lines_forecast_line_same_org
  foreign key (org_id, forecast_line_id)
  references public.forecast_lines (org_id, id)
  on delete set null (forecast_line_id);
alter table public.forecast_lines
  add constraint forecast_lines_run_same_org
  foreign key (org_id, run_id)
  references public.forecast_runs (org_id, id)
  on delete cascade;
alter table public.item_conversion_outputs
  add constraint item_conversion_outputs_conversion_same_org
  foreign key (org_id, conversion_id)
  references public.item_conversions (org_id, id)
  on delete cascade;
alter table public.applicants
  add constraint applicants_requisition_same_org
  foreign key (org_id, requisition_id)
  references public.job_requisitions (org_id, id)
  on delete set null (requisition_id);
alter table public.activities
  add constraint activities_lead_same_org
  foreign key (org_id, lead_id)
  references public.leads (org_id, id)
  on delete cascade;
alter table public.opportunities
  add constraint opportunities_lead_same_org
  foreign key (org_id, lead_id)
  references public.leads (org_id, id)
  on delete set null (lead_id);
alter table public.loyalty_entries
  add constraint loyalty_entries_account_same_org
  foreign key (org_id, account_id)
  references public.loyalty_accounts (org_id, id)
  on delete cascade;
alter table public.pos_sales
  add constraint pos_sales_loyalty_account_same_org
  foreign key (org_id, loyalty_account_id)
  references public.loyalty_accounts (org_id, id)
  on delete set null (loyalty_account_id);
alter table public.loyalty_accounts
  add constraint loyalty_accounts_program_same_org
  foreign key (org_id, program_id)
  references public.loyalty_programs (org_id, id)
  on delete cascade;
alter table public.loyalty_tiers
  add constraint loyalty_tiers_program_same_org
  foreign key (org_id, program_id)
  references public.loyalty_programs (org_id, id)
  on delete cascade;
alter table public.mo_components
  add constraint mo_components_mo_same_org
  foreign key (org_id, mo_id)
  references public.manufacturing_orders (org_id, id)
  on delete cascade;
alter table public.mo_operations
  add constraint mo_operations_mo_same_org
  foreign key (org_id, mo_id)
  references public.manufacturing_orders (org_id, id)
  on delete cascade;
alter table public.onboarding_tasks
  add constraint onboarding_tasks_checklist_same_org
  foreign key (org_id, checklist_id)
  references public.onboarding_checklists (org_id, id)
  on delete cascade;
alter table public.onboarding_checklists
  add constraint onboarding_checklists_template_same_org
  foreign key (org_id, template_id)
  references public.onboarding_templates (org_id, id)
  on delete set null (template_id);
alter table public.onboarding_template_items
  add constraint onboarding_template_items_template_same_org
  foreign key (org_id, template_id)
  references public.onboarding_templates (org_id, id)
  on delete cascade;
alter table public.inbound_emails
  add constraint inbound_emails_mailbox_same_org
  foreign key (org_id, mailbox_id)
  references public.org_mailboxes (org_id, id)
  on delete cascade;
alter table public.salespeople
  add constraint salespeople_member_same_org
  foreign key (org_id, member_id)
  references public.org_members (org_id, id)
  on delete set null (member_id);
alter table public.payslip_access_requests
  add constraint payslip_access_requests_run_same_org
  foreign key (org_id, run_id)
  references public.payroll_runs (org_id, id)
  on delete cascade;
alter table public.payslips
  add constraint payslips_run_same_org
  foreign key (org_id, run_id)
  references public.payroll_runs (org_id, id)
  on delete cascade;
alter table public.payslip_access_log
  add constraint payslip_access_log_grant_same_org
  foreign key (org_id, grant_id)
  references public.payslip_access_requests (org_id, id)
  on delete set null (grant_id);
alter table public.payslip_access_log
  add constraint payslip_access_log_payslip_same_org
  foreign key (org_id, payslip_id)
  references public.payslips (org_id, id)
  on delete set null (payslip_id);
alter table public.payslip_lines
  add constraint payslip_lines_payslip_same_org
  foreign key (org_id, payslip_id)
  references public.payslips (org_id, id)
  on delete cascade;
alter table public.opportunities
  add constraint opportunities_pipeline_same_org
  foreign key (org_id, pipeline_id)
  references public.pipelines (org_id, id)
  on delete restrict;
alter table public.pipeline_stages
  add constraint pipeline_stages_pipeline_same_org
  foreign key (org_id, pipeline_id)
  references public.pipelines (org_id, id)
  on delete cascade;
alter table public.platform_payments
  add constraint platform_payments_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.platform_invoices (org_id, id)
  on delete restrict;
alter table public.pos_deliveries
  add constraint pos_deliveries_zone_same_org
  foreign key (org_id, zone_id)
  references public.pos_delivery_zones (org_id, id)
  on delete set null (zone_id);
alter table public.pos_deliveries
  add constraint pos_deliveries_driver_same_org
  foreign key (org_id, driver_id)
  references public.pos_drivers (org_id, id)
  on delete set null (driver_id);
alter table public.pos_tables
  add constraint pos_tables_area_same_org
  foreign key (org_id, area_id)
  references public.pos_floor_areas (org_id, id)
  on delete set null (area_id);
alter table public.pos_kitchen_ticket_lines
  add constraint pos_kitchen_ticket_lines_ticket_same_org
  foreign key (org_id, ticket_id)
  references public.pos_kitchen_tickets (org_id, id)
  on delete cascade;
alter table public.pos_membership_sessions
  add constraint pos_membership_sessions_subscription_same_org
  foreign key (org_id, subscription_id)
  references public.pos_membership_subscriptions (org_id, id)
  on delete cascade;
alter table public.membership_items
  add constraint membership_items_membership_same_org
  foreign key (org_id, membership_id)
  references public.pos_memberships (org_id, id)
  on delete cascade;
alter table public.pos_membership_subscriptions
  add constraint pos_membership_subscriptions_membership_same_org
  foreign key (org_id, membership_id)
  references public.pos_memberships (org_id, id)
  on delete restrict;
alter table public.pos_sales
  add constraint pos_sales_menu_link_same_org
  foreign key (org_id, menu_link_id)
  references public.pos_menu_links (org_id, id)
  on delete set null (menu_link_id);
alter table public.pos_sale_line_modifiers
  add constraint pos_sale_line_modifiers_modifier_same_org
  foreign key (org_id, modifier_id)
  references public.pos_modifiers (org_id, id)
  on delete set null (modifier_id);
alter table public.pos_sale_promotions
  add constraint pos_sale_promotions_promotion_same_org
  foreign key (org_id, promotion_id)
  references public.pos_promotions (org_id, id)
  on delete restrict;
alter table public.pos_recipe_lines
  add constraint pos_recipe_lines_recipe_same_org
  foreign key (org_id, recipe_id)
  references public.pos_recipes (org_id, id)
  on delete cascade;
alter table public.pos_sales
  add constraint pos_sales_shift_same_org
  foreign key (org_id, shift_id)
  references public.pos_shifts (org_id, id)
  on delete restrict;
alter table public.pos_tenders
  add constraint pos_tenders_tender_type_same_org
  foreign key (org_id, tender_type_id)
  references public.pos_tender_types (org_id, id)
  on delete restrict;
alter table public.employees
  add constraint employees_position_same_org
  foreign key (org_id, position_id)
  references public.positions (org_id, id)
  on delete set null (position_id);
alter table public.job_requisitions
  add constraint job_requisitions_position_same_org
  foreign key (org_id, position_id)
  references public.positions (org_id, id)
  on delete set null (position_id);
alter table public.payment_allocations
  add constraint payment_allocations_pdc_same_org
  foreign key (org_id, pdc_id)
  references public.post_dated_cheques (org_id, id)
  on delete cascade;
alter table public.contacts
  add constraint contacts_price_level_same_org
  foreign key (org_id, price_level_id)
  references public.price_levels (org_id, id)
  on delete set null (price_level_id);
alter table public.item_prices
  add constraint item_prices_price_level_same_org
  foreign key (org_id, price_level_id)
  references public.price_levels (org_id, id)
  on delete cascade;
alter table public.property_units
  add constraint property_units_principal_unit_same_org
  foreign key (org_id, principal_unit_id)
  references public.property_units (org_id, id)
  on delete set null (principal_unit_id);
alter table public.payment_allocations
  add constraint payment_allocations_payment_same_org
  foreign key (org_id, payment_id)
  references public.purchase_payments (org_id, id)
  on delete cascade;
alter table public.pos_membership_subscriptions
  add constraint pos_membership_subscriptions_recurring_document_same_org
  foreign key (org_id, recurring_document_id)
  references public.recurring_documents (org_id, id)
  on delete set null (recurring_document_id);
alter table public.employee_salary_components
  add constraint employee_salary_components_component_same_org
  foreign key (org_id, component_id)
  references public.salary_components (org_id, id)
  on delete cascade;
alter table public.payslip_lines
  add constraint payslip_lines_component_same_org
  foreign key (org_id, component_id)
  references public.salary_components (org_id, id)
  on delete no action;
alter table public.sales_documents
  add constraint sales_documents_salesperson_same_org
  foreign key (org_id, salesperson_id)
  references public.salespeople (org_id, id)
  on delete set null (salesperson_id);
alter table public.sla_targets
  add constraint sla_targets_policy_same_org
  foreign key (org_id, policy_id)
  references public.sla_policies (org_id, id)
  on delete cascade;
alter table public.document_line_lots
  add constraint document_line_lots_adjustment_line_same_org
  foreign key (org_id, adjustment_line_id)
  references public.stock_adjustment_lines (org_id, id)
  on delete cascade;
alter table public.stock_adjustment_lines
  add constraint stock_adjustment_lines_adjustment_same_org
  foreign key (org_id, adjustment_id)
  references public.stock_adjustments (org_id, id)
  on delete cascade;
alter table public.stock_movement_lots
  add constraint stock_movement_lots_lot_same_org
  foreign key (org_id, lot_id)
  references public.stock_lots (org_id, id)
  on delete restrict;
alter table public.landed_cost_allocations
  add constraint landed_cost_allocations_movement_same_org
  foreign key (org_id, movement_id)
  references public.stock_movements (org_id, id)
  on delete no action;
alter table public.stock_movement_lots
  add constraint stock_movement_lots_movement_same_org
  foreign key (org_id, movement_id)
  references public.stock_movements (org_id, id)
  on delete cascade;
alter table public.stock_transfer_lines
  add constraint stock_transfer_lines_transfer_same_org
  foreign key (org_id, transfer_id)
  references public.stock_transfers (org_id, id)
  on delete cascade;
alter table public.strata_charge_runs
  add constraint strata_charge_runs_rate_same_org
  foreign key (org_id, rate_id)
  references public.strata_charge_rates (org_id, id)
  on delete no action;
alter table public.ticket_categories
  add constraint ticket_categories_parent_same_org
  foreign key (org_id, parent_id)
  references public.ticket_categories (org_id, id)
  on delete set null (parent_id);
alter table public.ticket_team_members
  add constraint ticket_team_members_team_same_org
  foreign key (org_id, team_id)
  references public.ticket_teams (org_id, id)
  on delete cascade;
alter table public.payment_allocations
  add constraint payment_allocations_withholding_same_org
  foreign key (org_id, withholding_id)
  references public.withholding_certificates (org_id, id)
  on delete cascade;
alter table public.bom_operations
  add constraint bom_operations_work_centre_same_org
  foreign key (org_id, work_centre_id)
  references public.work_centres (org_id, id)
  on delete restrict;
alter table public.mo_operations
  add constraint mo_operations_work_centre_same_org
  foreign key (org_id, work_centre_id)
  references public.work_centres (org_id, id)
  on delete restrict;
alter table public.attendance_records
  add constraint attendance_records_shift_same_org
  foreign key (org_id, shift_id)
  references public.work_shifts (org_id, id)
  on delete set null (shift_id);
alter table public.employee_shifts
  add constraint employee_shifts_shift_same_org
  foreign key (org_id, shift_id)
  references public.work_shifts (org_id, id)
  on delete cascade;
