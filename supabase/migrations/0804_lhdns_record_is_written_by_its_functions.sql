-- =====================================================================
-- iAkauntan :: 0804 LHDN's record is written by its functions
--
-- `einvoice_documents` is what this company filed with LHDN and what
-- LHDN said: the figures and parties as submitted, the status, the
-- MyInvois UUID, when it was validated and why it was cancelled.
-- `einvoice_lines` are its lines, `einvoice_submissions` the batches it
-- went in, and `einvoice_consolidations` with their items the monthly
-- consolidated e-Invoice of a shop's receipts. Every write the product
-- makes to any of them goes through a SECURITY DEFINER function --
-- `prepare_einvoice`, `prepare_self_billed_einvoice`,
-- `set_requires_self_billed`, `void_sales_document`,
-- `consolidate_pos_einvoices` and the consolidation functions under
-- them -- or through the MyInvois edge function as the service role.
-- The app only reads `einvoice_documents`. But `authenticated` held
-- INSERT, UPDATE and DELETE on all five, and their policies asked only
-- `app.can_write` and the e-Invoice module.
--
-- Measured on 10 October 2026, locally, with `0803` applied, as the
-- owner with the role `authenticated`: an e-Invoice LHDN had accepted
-- was marked 'cancelled' by hand -- `sync_einvoice_status` copied that
-- onto the invoice -- and `void_sales_document` then voided the
-- invoice: void in the books, valid at LHDN, which is `0803`'s own case
-- by the other table. Its figures were rewritten to RM1.00. A voided
-- invoice's withdrawn e-Invoice was put back in the queue, which the
-- bulk MyInvois sweep files without looking at the invoice. And the
-- accepted record was deleted.
--
-- Answered "read-only to clients", as `0740` made the client account
-- ledger: the grants are revoked AND the write policies dropped. With
-- row level security on and no policy for a command, Postgres denies
-- it whatever a grant says, so the two are two defences rather than one
-- and an ornament (`table_grants.sql` refuses a policy nobody can
-- reach). Reading stays as it was. The functions run as their owner and
-- the service role bypasses row level security, so neither notices.
--
-- Production held no row in any of the five tables on 10 October.
-- =====================================================================

revoke insert, update, delete on public.einvoice_documents from authenticated, anon;
drop policy if exists einvoice_documents_insert on public.einvoice_documents;
drop policy if exists einvoice_documents_update on public.einvoice_documents;
drop policy if exists einvoice_documents_delete on public.einvoice_documents;

revoke insert, update, delete on public.einvoice_lines from authenticated, anon;
drop policy if exists einvoice_lines_insert on public.einvoice_lines;
drop policy if exists einvoice_lines_update on public.einvoice_lines;
drop policy if exists einvoice_lines_delete on public.einvoice_lines;

revoke insert, update, delete on public.einvoice_submissions from authenticated, anon;
drop policy if exists einvoice_submissions_insert on public.einvoice_submissions;
drop policy if exists einvoice_submissions_update on public.einvoice_submissions;
drop policy if exists einvoice_submissions_delete on public.einvoice_submissions;

revoke insert, update, delete on public.einvoice_consolidations from authenticated, anon;
drop policy if exists einvoice_consolidations_insert on public.einvoice_consolidations;
drop policy if exists einvoice_consolidations_update on public.einvoice_consolidations;
drop policy if exists einvoice_consolidations_delete on public.einvoice_consolidations;

revoke insert, update, delete on public.einvoice_consolidation_items from authenticated, anon;
drop policy if exists einvoice_consolidation_items_insert on public.einvoice_consolidation_items;
drop policy if exists einvoice_consolidation_items_update on public.einvoice_consolidation_items;
drop policy if exists einvoice_consolidation_items_delete on public.einvoice_consolidation_items;

comment on table public.einvoice_documents is
  'An e-Invoice: what this company filed with LHDN (or will) and what LHDN said of it. WRITTEN ONLY BY FUNCTION -- 0804 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; the e-Invoice functions and the MyInvois function, as the '
  'service role, write it. Members of the company read it.';

comment on table public.einvoice_lines is
  'The lines of an e-Invoice, as filed. WRITTEN ONLY BY FUNCTION -- 0804 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; the e-Invoice functions and the MyInvois function, as the '
  'service role, write it. Members of the company read it.';

comment on table public.einvoice_submissions is
  'A batch of e-Invoices sent to MyInvois together, and LHDN''s reply to it. WRITTEN ONLY BY FUNCTION -- 0804 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; the e-Invoice functions and the MyInvois function, as the '
  'service role, write it. Members of the company read it.';

comment on table public.einvoice_consolidations is
  'A month''s consolidated e-Invoice of receipts no buyer asked one for. WRITTEN ONLY BY FUNCTION -- 0804 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; the e-Invoice functions and the MyInvois function, as the '
  'service role, write it. Members of the company read it.';

comment on table public.einvoice_consolidation_items is
  'The receipts a consolidated e-Invoice carries. WRITTEN ONLY BY FUNCTION -- 0804 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; the e-Invoice functions and the MyInvois function, as the '
  'service role, write it. Members of the company read it.';
