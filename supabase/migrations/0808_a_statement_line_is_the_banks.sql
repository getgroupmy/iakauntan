-- =====================================================================
-- iAkauntan :: 0808 a statement line is the bank's
--
-- `bank_transactions` is the bank's statement, line by line, as
-- imported: what came in and went out, which document explains each
-- line, and which reconciliation agreed it. Six SECURITY DEFINER
-- functions write it -- `import_bank_transactions`,
-- `match_bank_transaction`, `unmatch_bank_transaction`,
-- `post_bank_transaction`, `complete_bank_reconciliation` and
-- `reopen_bank_reconciliation` -- and the app only reads it. But
-- `authenticated` held insert, update and delete, behind policies that
-- asked only `app.can_post`.
--
-- `0761` closed `bank_reconciliations` for the same reason: a deleted
-- reconciliation "reopened one silently", the lines coming free without
-- `reopen_bank_reconciliation` asking whether a later one had been
-- closed over them. The lines were the other half of that door.
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: a line matched to a RM1,000 receipt and reconciled
-- for March. `unmatch_bank_transaction` refused it -- "That line belongs
-- to a reconciliation that has been completed" -- until its
-- `reconciliation_id` was cleared by hand; then the unmatch went
-- through, and March read RM1,000 out against a reconciliation still
-- 'completed'. A reconciled line's amount or date could be rewritten
-- the same way.
--
-- Answered "read-only to clients", as `0740`, `0761`, `0804`, `0806`
-- and `0807`: the grants are revoked and the three write policies
-- dropped. Reading stays. The bank feed and statement scans import
-- through `import_bank_transactions`.
--
-- Production held thirty-two lines, three matched, none reconciled, on
-- 11 October.
-- =====================================================================

revoke insert, update, delete on public.bank_transactions from authenticated, anon;
drop policy if exists bank_transactions_insert on public.bank_transactions;
drop policy if exists bank_transactions_update on public.bank_transactions;
drop policy if exists bank_transactions_delete on public.bank_transactions;

comment on table public.bank_transactions is
  'The bank''s statement, line by line, as imported, with the document '
  'that explains each line and the reconciliation that agreed it. '
  'WRITTEN ONLY BY FUNCTION -- 0808 revoked insert, update and delete '
  'from clients and dropped the write policies: import, match, unmatch, '
  'post, and complete or reopen a reconciliation write it. Members who '
  'may read the bank read it.';
