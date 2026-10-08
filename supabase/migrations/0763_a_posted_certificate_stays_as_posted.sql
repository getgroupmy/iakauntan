-- =====================================================================
-- 0763 :: a posted withholding certificate stays as it was posted
--
-- Answered on 8 October: "close it".
--
-- `withholding_certificates` carried a single write policy for every
-- command (`withholding_certificates_write`, `for all`) asking only
-- `app.can_post`, and its one guard, `refuse_reposting` (0403), protects
-- only the link to the journal. So everything else about a POSTED
-- certificate could be changed or removed by a plain write.
-- Reproduced under row level security: an owner cut a posted
-- certificate's tax from RM10,000 to RM1, while its journal still
-- credited RM10,000 to 2145, and LHDN remittance and the withholding
-- reports read the certificate, not the journal. A direct DELETE also
-- went through, and `payment_allocations` references a certificate `on
-- delete cascade`: the bill's allocation went with it, so the bill owed
-- the withheld tax again while the ledger had already taken it off.
--
-- The app never wrote the table. It is written by three SECURITY DEFINER
-- functions -- `create_withholding`, `post_withholding`,
-- `remit_withholding` -- which keep working. Production had no
-- certificates when this was written.
--
-- 0761's and 0762's shape: the grant goes, and the write policy with
-- it. With row level security on and no policy for a command, Postgres
-- refuses it whatever a later grant says. SELECT, and its policy, stay.
-- =====================================================================

revoke insert, update, delete on public.withholding_certificates
  from authenticated;

drop policy if exists withholding_certificates_write
  on public.withholding_certificates;

comment on table public.withholding_certificates is
  'Withholding tax certificates (s107A, s109, s109B and the rest). WRITTEN '
  'ONLY BY FUNCTION -- `create_withholding`, `post_withholding`, '
  '`remit_withholding`. 0763 revoked insert, update and delete from '
  '`authenticated` and dropped the write policy: a posted certificate''s '
  'tax could be rewritten under its journal, or the certificate deleted '
  'and its allocation against the bill with it.';
