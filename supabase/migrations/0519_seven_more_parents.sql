-- =====================================================================
-- 0519 :: a bank account, a branch, an entity, a person, a department,
--         an e-Invoice and a register
--
-- Seven parents, forty-two columns. Six of them need their own
-- `unique (org_id, id)` first; `bank_accounts` already had one from
-- 0160. `corp_persons` had no unique constraint at all beyond its
-- primary key, which is worth noticing on its way past.
--
-- The corporate secretarial pair is the one to read carefully, because
-- the module's whole purpose is a practice handling OTHER people's
-- companies, and that sounds like it should cross the boundary the way
-- inter-company billing does. It does not. A `corp_entities` row is the
-- PRACTICE's record of a company it acts for -- it carries the
-- practice's `org_id` -- and every officer, charge, resolution and
-- share event hangs off that record inside the same practice. Nothing
-- here points at another org's row, and the hosted check confirms it:
-- none of the forty-two has a violating row.
--
-- `corp_persons` is the register of directors, secretaries and
-- shareholders. `corp_share_events` names two of them -- `from_person`
-- and `to_person` -- which is the pairing that goes wrong quietly, the
-- same shape as `stock_transfers` in 0510: both ends read as valid
-- people and the shares simply move between the wrong ones.
--
-- `branches` is the cost centre a document is booked to; a wrong one
-- puts this company's revenue in another company's branch on every
-- report that groups by it. `einvoice_documents` is what LHDN was
-- actually sent, and `sales_documents.einvoice_id` is the link a
-- taxpayer follows to prove what they submitted.
--
-- Delete rules follow the plain key beside each column, with 0511's
-- column list on the `set null` ones.
--
-- Checked on the hosted project before writing.
-- `scripts/check_embeds.py` is run against this migration.
-- =====================================================================

alter table public.branches
  add constraint branches_org_id_id_key unique (org_id, id);
alter table public.corp_entities
  add constraint corp_entities_org_id_id_key unique (org_id, id);
alter table public.corp_persons
  add constraint corp_persons_org_id_id_key unique (org_id, id);
alter table public.departments
  add constraint departments_org_id_id_key unique (org_id, id);
alter table public.einvoice_documents
  add constraint einvoice_documents_org_id_id_key unique (org_id, id);
alter table public.pos_registers
  add constraint pos_registers_org_id_id_key unique (org_id, id);
alter table public.deposit_events
  add constraint deposit_events_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id)
  on delete no action;
alter table public.deposit_notes
  add constraint deposit_notes_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id)
  on delete no action;
alter table public.org_payment_gateways
  add constraint org_payment_gateways_settlement_bank_account_same_org
  foreign key (org_id, settlement_bank_account_id)
  references public.bank_accounts (org_id, id)
  on delete no action;
alter table public.pos_tender_types
  add constraint pos_tender_types_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id)
  on delete restrict;
alter table public.post_dated_cheques
  add constraint post_dated_cheques_bank_account_same_org
  foreign key (org_id, bank_account_id)
  references public.bank_accounts (org_id, id)
  on delete no action;
alter table public.employees
  add constraint employees_branch_same_org
  foreign key (org_id, branch_id)
  references public.branches (org_id, id)
  on delete no action;
alter table public.expenses
  add constraint expenses_branch_same_org
  foreign key (org_id, branch_id)
  references public.branches (org_id, id)
  on delete no action;
alter table public.manufacturing_orders
  add constraint manufacturing_orders_branch_same_org
  foreign key (org_id, branch_id)
  references public.branches (org_id, id)
  on delete no action;
alter table public.pos_outlets
  add constraint pos_outlets_branch_same_org
  foreign key (org_id, branch_id)
  references public.branches (org_id, id)
  on delete set null (branch_id);
alter table public.purchase_documents
  add constraint purchase_documents_branch_same_org
  foreign key (org_id, branch_id)
  references public.branches (org_id, id)
  on delete no action;
alter table public.sales_documents
  add constraint sales_documents_branch_same_org
  foreign key (org_id, branch_id)
  references public.branches (org_id, id)
  on delete no action;
alter table public.warehouses
  add constraint warehouses_branch_same_org
  foreign key (org_id, branch_id)
  references public.branches (org_id, id)
  on delete no action;
alter table public.corp_beneficial_owners
  add constraint corp_beneficial_owners_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.corp_charges
  add constraint corp_charges_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.corp_documents
  add constraint corp_documents_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.corp_filings
  add constraint corp_filings_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.corp_officers
  add constraint corp_officers_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.corp_resolutions
  add constraint corp_resolutions_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.corp_share_classes
  add constraint corp_share_classes_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.corp_share_events
  add constraint corp_share_events_entity_same_org
  foreign key (org_id, entity_id)
  references public.corp_entities (org_id, id)
  on delete cascade;
alter table public.fs_filings
  add constraint fs_filings_corp_entity_same_org
  foreign key (org_id, corp_entity_id)
  references public.corp_entities (org_id, id)
  on delete set null (corp_entity_id);
alter table public.corp_beneficial_owners
  add constraint corp_beneficial_owners_person_same_org
  foreign key (org_id, person_id)
  references public.corp_persons (org_id, id)
  on delete restrict;
alter table public.corp_officers
  add constraint corp_officers_person_same_org
  foreign key (org_id, person_id)
  references public.corp_persons (org_id, id)
  on delete restrict;
alter table public.corp_resolutions
  add constraint corp_resolutions_chairman_person_same_org
  foreign key (org_id, chairman_person_id)
  references public.corp_persons (org_id, id)
  on delete set null (chairman_person_id);
alter table public.corp_share_events
  add constraint corp_share_events_from_person_same_org
  foreign key (org_id, from_person_id)
  references public.corp_persons (org_id, id)
  on delete restrict;
alter table public.corp_share_events
  add constraint corp_share_events_to_person_same_org
  foreign key (org_id, to_person_id)
  references public.corp_persons (org_id, id)
  on delete restrict;
alter table public.corp_signatures
  add constraint corp_signatures_person_same_org
  foreign key (org_id, person_id)
  references public.corp_persons (org_id, id)
  on delete restrict;
alter table public.departments
  add constraint departments_parent_same_org
  foreign key (org_id, parent_id)
  references public.departments (org_id, id)
  on delete set null (parent_id);
alter table public.employees
  add constraint employees_department_same_org
  foreign key (org_id, department_id)
  references public.departments (org_id, id)
  on delete set null (department_id);
alter table public.job_requisitions
  add constraint job_requisitions_department_same_org
  foreign key (org_id, department_id)
  references public.departments (org_id, id)
  on delete set null (department_id);
alter table public.onboarding_templates
  add constraint onboarding_templates_department_same_org
  foreign key (org_id, department_id)
  references public.departments (org_id, id)
  on delete set null (department_id);
alter table public.positions
  add constraint positions_department_same_org
  foreign key (org_id, department_id)
  references public.departments (org_id, id)
  on delete set null (department_id);
alter table public.einvoice_consolidations
  add constraint einvoice_consolidations_einvoice_same_org
  foreign key (org_id, einvoice_id)
  references public.einvoice_documents (org_id, id)
  on delete set null (einvoice_id);
alter table public.einvoice_lines
  add constraint einvoice_lines_einvoice_same_org
  foreign key (org_id, einvoice_id)
  references public.einvoice_documents (org_id, id)
  on delete cascade;
alter table public.einvoice_logs
  add constraint einvoice_logs_einvoice_same_org
  foreign key (org_id, einvoice_id)
  references public.einvoice_documents (org_id, id)
  on delete set null (einvoice_id);
alter table public.purchase_documents
  add constraint purchase_documents_einvoice_same_org
  foreign key (org_id, einvoice_id)
  references public.einvoice_documents (org_id, id)
  on delete set null (einvoice_id);
alter table public.sales_documents
  add constraint sales_documents_einvoice_same_org
  foreign key (org_id, einvoice_id)
  references public.einvoice_documents (org_id, id)
  on delete set null (einvoice_id);
alter table public.pos_menu_links
  add constraint pos_menu_links_register_same_org
  foreign key (org_id, register_id)
  references public.pos_registers (org_id, id)
  on delete set null (register_id);
alter table public.pos_offline_rejects
  add constraint pos_offline_rejects_register_same_org
  foreign key (org_id, register_id)
  references public.pos_registers (org_id, id)
  on delete set null (register_id);
alter table public.pos_sales
  add constraint pos_sales_opened_on_register_same_org
  foreign key (org_id, opened_on_register_id)
  references public.pos_registers (org_id, id)
  on delete set null (opened_on_register_id);
alter table public.pos_sales
  add constraint pos_sales_register_same_org
  foreign key (org_id, register_id)
  references public.pos_registers (org_id, id)
  on delete restrict;
alter table public.pos_shifts
  add constraint pos_shifts_register_same_org
  foreign key (org_id, register_id)
  references public.pos_registers (org_id, id)
  on delete restrict;
