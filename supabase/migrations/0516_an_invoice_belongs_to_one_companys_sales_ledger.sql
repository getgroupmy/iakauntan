-- =====================================================================
-- 0516 :: an invoice belongs to one company's sales ledger
--
-- The seventh parent, after `employees` (0507-0509), `warehouses`
-- (0510), `contacts` (0512), `items` (0513), `accounts` (0514) and
-- `gl_entries` (0515). `sales_documents` already has its
-- `unique (org_id, id)` -- 0166 added it for
-- `collection_attempts_document_same_org` -- so this is columns only,
-- no parent key.
--
-- Two of the twenty are money directly. `payment_allocations.
-- invoice_id` and `.credit_note_id` are what settles a debt: 0167
-- stopped one customer's money settling another customer's invoice,
-- and this stops one COMPANY's money doing it. `time_entries.
-- invoice_id` and `disbursements.invoice_id` are the legal side of the
-- same thing -- what has been billed and what is still work in
-- progress.
--
-- The rest are the paper trail, and two of them leave the building.
-- `document_share_links.document_id` is the token a customer with no
-- account follows to see an invoice, and `document_downloads` records
-- that they did; a link pointing at another company's document is that
-- company's invoice shown to somebody who was never meant to see it.
-- RLS does not help, because the share link is read with a token
-- rather than a session.
--
-- `sales_documents.parent_id` and `.original_invoice_id` are the two
-- self-references: a document made from the one before it in the cycle
-- (quotation to order to delivery order to invoice), and a credit note
-- naming the invoice it cancels. A credit note cancelling another
-- company's invoice is the one that would move money.
--
-- Nineteen columns, not twenty. `purchase_documents.
-- source_sales_document_id` is deliberately left alone, and this is
-- the first column in the whole programme where crossing the boundary
-- is the FEATURE. Inter-company billing is one company in a group
-- invoicing another: the seller raises a sales document, the buyer
-- gets a purchase document, and that column is the link between them
-- -- so it points at another company's row by design.
--
-- I did not spot that from reading. The constraint was written, and
-- `supabase/tests/intercompany_billing.sql` failed on it. That file is
-- the reason it was caught, and the reason it is excluded here rather
-- than the boundary being weakened somewhere else to accommodate it.
-- The coverage query in `tenant_foreign_keys.sql` names it as an
-- explicit exemption, with the same reason, so it does not read as a
-- gap somebody should close later.
--
-- Delete rules follow the plain key beside each column, with 0511's
-- column list on the `set null` ones.
--
-- Checked on the hosted project before writing: none of the
-- nineteen has
-- a row whose document belongs to another company.
-- `scripts/check_embeds.py` is run against this migration.
-- =====================================================================

alter table public.client_account_transactions
  add constraint client_account_transactions_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.sales_documents (org_id, id)
  on delete set null (invoice_id);
alter table public.disbursements
  add constraint disbursements_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.sales_documents (org_id, id)
  on delete set null (invoice_id);
alter table public.document_downloads
  add constraint document_downloads_document_same_org
  foreign key (org_id, document_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.document_share_links
  add constraint document_share_links_document_same_org
  foreign key (org_id, document_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.einvoice_consolidation_items
  add constraint einvoice_consolidation_items_sales_document_same_org
  foreign key (org_id, sales_document_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.email_outbox
  add constraint email_outbox_document_same_org
  foreign key (org_id, document_id)
  references public.sales_documents (org_id, id)
  on delete set null (document_id);
alter table public.opportunities
  add constraint opportunities_quotation_same_org
  foreign key (org_id, quotation_id)
  references public.sales_documents (org_id, id)
  on delete set null (quotation_id);
alter table public.payment_allocations
  add constraint payment_allocations_credit_note_same_org
  foreign key (org_id, credit_note_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.payment_allocations
  add constraint payment_allocations_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.pos_sales
  add constraint pos_sales_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.sales_documents (org_id, id)
  on delete restrict;
alter table public.rent_run_lines
  add constraint rent_run_lines_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.sales_documents (org_id, id)
  on delete set null (invoice_id);
alter table public.revenue_schedule_periods
  add constraint revenue_schedule_periods_cancelled_by_same_org
  foreign key (org_id, cancelled_by_id)
  references public.sales_documents (org_id, id)
  on delete no action;
alter table public.revenue_schedule_periods
  add constraint revenue_schedule_periods_document_same_org
  foreign key (org_id, document_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.sales_document_lines
  add constraint sales_document_lines_document_same_org
  foreign key (org_id, document_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.sales_documents
  add constraint sales_documents_original_invoice_same_org
  foreign key (org_id, original_invoice_id)
  references public.sales_documents (org_id, id)
  on delete set null (original_invoice_id);
alter table public.sales_documents
  add constraint sales_documents_parent_same_org
  foreign key (org_id, parent_id)
  references public.sales_documents (org_id, id)
  on delete set null (parent_id);
alter table public.sales_gateway_payments
  add constraint sales_gateway_payments_document_same_org
  foreign key (org_id, document_id)
  references public.sales_documents (org_id, id)
  on delete cascade;
alter table public.strata_charge_lines
  add constraint strata_charge_lines_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.sales_documents (org_id, id)
  on delete set null (invoice_id);
alter table public.time_entries
  add constraint time_entries_invoice_same_org
  foreign key (org_id, invoice_id)
  references public.sales_documents (org_id, id)
  on delete set null (invoice_id);
