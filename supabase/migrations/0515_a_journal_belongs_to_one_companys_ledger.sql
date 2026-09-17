-- =====================================================================
-- 0515 :: a journal belongs to one company's ledger
--
-- The sixth parent, after `employees` (0507-0509), `warehouses`
-- (0510), `contacts` (0512), `items` (0513) and `accounts` (0514).
-- `gl_entries` has only `unique (org_id, entry_no)`, so it gets its own
-- `(org_id, id)` first.
--
-- Thirty-two columns, and nearly all of them are the same thing: the
-- backlink from a document to the journal it posted. `sales_documents.
-- gl_entry_id`, `receipts.gl_entry_id`, `payroll_runs.gl_entry_id`,
-- and so on down the list. That link is what "what happened to this
-- invoice" is built from, and what `app.refuse_posted_document_change`
-- reads to decide a document is posted and may not be edited. A row
-- pointing at another company's journal is a document that reads as
-- posted, cannot be edited, and whose drill-down shows a journal that
-- is not on these books.
--
-- `gl_lines.entry_id` is the exception and the important one: it is
-- what makes a line part of a journal, and it is NOT NULL, so the key
-- is enforced on every row rather than only the ones that name
-- somebody. 0160 held `gl_lines.account_id` to the organization; this
-- holds the other end.
--
-- `gl_entries.reversed_entry_id` is the self-reference -- a reversing
-- journal names the one it reverses -- which is what stops a reversal
-- in one company cancelling an entry in another.
--
-- Delete rules follow the plain key beside each column, with the
-- correction 0511 made necessary: `set null` on a composite key takes
-- the column list, or it nulls `org_id` too and the delete raises
-- 23502 instead of clearing the reference. Sixteen of the
-- thirty-two are `set null`, so this migration is where that
-- correction earns its keep.
--
-- Checked on the hosted project before writing: none of the
-- thirty-two has a row whose journal belongs to another company.
-- `scripts/check_embeds.py` is run against this migration.
-- =====================================================================

alter table public.gl_entries
  add constraint gl_entries_org_id_id_key unique (org_id, id);

alter table public.bank_transactions
  add constraint bank_transactions_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.bank_transfers
  add constraint bank_transfers_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.client_account_transactions
  add constraint client_account_transactions_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.contra_notes
  add constraint contra_notes_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.contra_notes
  add constraint contra_notes_void_entry_same_org
  foreign key (org_id, void_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.deposit_events
  add constraint deposit_events_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.deposit_notes
  add constraint deposit_notes_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.deposit_notes
  add constraint deposit_notes_void_entry_same_org
  foreign key (org_id, void_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.depreciation_runs
  add constraint depreciation_runs_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.expense_claims
  add constraint expense_claims_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.expenses
  add constraint expenses_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.fixed_assets
  add constraint fixed_assets_disposal_entry_same_org
  foreign key (org_id, disposal_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.gl_entries
  add constraint gl_entries_reversed_entry_same_org
  foreign key (org_id, reversed_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (reversed_entry_id);
alter table public.gl_lines
  add constraint gl_lines_entry_same_org
  foreign key (org_id, entry_id)
  references public.gl_entries (org_id, id)
  on delete cascade;
alter table public.landed_cost_runs
  add constraint landed_cost_runs_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.manufacturing_orders
  add constraint manufacturing_orders_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.payment_allocations
  add constraint payment_allocations_discount_entry_same_org
  foreign key (org_id, discount_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.payroll_runs
  add constraint payroll_runs_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.post_dated_cheques
  add constraint post_dated_cheques_bounce_entry_same_org
  foreign key (org_id, bounce_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.post_dated_cheques
  add constraint post_dated_cheques_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.post_dated_cheques
  add constraint post_dated_cheques_settle_entry_same_org
  foreign key (org_id, settle_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.purchase_documents
  add constraint purchase_documents_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.purchase_payments
  add constraint purchase_payments_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.receipts
  add constraint receipts_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.revenue_schedule_periods
  add constraint revenue_schedule_periods_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete no action;
alter table public.sales_documents
  add constraint sales_documents_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.stock_adjustments
  add constraint stock_adjustments_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.stock_movements
  add constraint stock_movements_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.stock_transfers
  add constraint stock_transfers_receipt_entry_same_org
  foreign key (org_id, receipt_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (receipt_entry_id);
alter table public.stock_transfers
  add constraint stock_transfers_send_entry_same_org
  foreign key (org_id, send_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (send_entry_id);
alter table public.withholding_certificates
  add constraint withholding_certificates_gl_entry_same_org
  foreign key (org_id, gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (gl_entry_id);
alter table public.withholding_certificates
  add constraint withholding_certificates_remittance_gl_entry_same_org
  foreign key (org_id, remittance_gl_entry_id)
  references public.gl_entries (org_id, id)
  on delete set null (remittance_gl_entry_id);
