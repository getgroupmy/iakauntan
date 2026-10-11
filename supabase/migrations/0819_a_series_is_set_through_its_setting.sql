-- =====================================================================
-- iAkauntan :: 0819 a series is set through its setting
--
-- Every document this system issues is numbered from
-- `number_sequences`, drawn by `app.next_document_number_internal`.
-- `0480` gave the series a setting -- `set_document_numbering`, admin
-- only, which the settings screen calls -- and one rule above the rest:
-- the next number cannot be set below the last one issued while the
-- series keeps its shape, because "`sales_documents (org_id, doc_no)`
-- would refuse the draw later, with the index's message, on somebody
-- else's screen". But the row stayed behind `0010`'s admin insert,
-- update and delete policies, so an admin could set it from anywhere
-- else without the rule.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: INV-2026-00001 to 00003 issued.
-- `set_document_numbering` refused a next number of 1 -- "The last of
-- invoices issued was INV-2026-00003; the next cannot be lower than 4".
-- The same row updated directly to 1 was accepted, and the next invoice
-- failed with `duplicate key value violates unique constraint` -- and
-- the failed draw rolls back with it, so every invoice after it fails
-- the same way until somebody mends the row. Deleting the row does the
-- same: the next draw makes it again, from 1.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0817`: the
-- grants are revoked and the three write policies dropped. Reading
-- stays, by `number_sequences_select`; the settings screen reads the
-- series through `document_numbering` and sets it through
-- `set_document_numbering`, both definers, as does the draw.
--
-- Production held 111 series across fifteen companies on 11 October.
-- =====================================================================

revoke insert, update, delete on public.number_sequences from authenticated, anon;
drop policy if exists number_sequences_insert on public.number_sequences;
drop policy if exists number_sequences_update on public.number_sequences;
drop policy if exists number_sequences_delete on public.number_sequences;

comment on table public.number_sequences is
  'Each company''s document number series: prefix, suffix, padding, '
  'reset policy and the next number. WRITTEN ONLY BY FUNCTION -- 0819 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; set_document_numbering sets a series, refusing a next '
  'number below the last one issued, and the draw moves it on.';
