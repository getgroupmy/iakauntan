-- =====================================================================
-- 0761 :: a reconciliation is closed only by closing it
--
-- Answered on 8 October: "close it".
--
-- `public.bank_reconciliations` has been writable by `authenticated`
-- since `0006`, behind insert, update and delete policies that ask only
-- for `app.can_post`. Everything `complete_bank_reconciliation` enforces
-- was therefore optional to anybody who called the table instead of the
-- function: that the difference is nil, that a reconciliation closes
-- only forward of the last one, and that the lines it closed are
-- stamped with it.
--
-- Reproduced under row level security: an owner inserted a "completed"
-- reconciliation dated 31 December and out by RM99,999. It read as an
-- agreement in the history, and the real October close was then refused
-- -- "This account is reconciled to 2026-12-31". An UPDATE could rewrite
-- a closed one's figures, and a DELETE reopened one silently: the
-- foreign key from `bank_transactions.reconciliation_id` is `on delete
-- set null`, so the lines came free without `reopen_bank_reconciliation`
-- asking whether a later reconciliation had been closed over them.
--
-- The app never wrote the table: it closes and reopens through the two
-- functions and reads through `report_bank_reconciliations`. Both
-- functions are SECURITY DEFINER and keep working. Production had no
-- reconciliations when this was written.
--
-- 0740's shape: the grant goes, and the three write policies go with
-- it. With row level security on and no policy for a command, Postgres
-- refuses it whatever a later grant says -- two defences, not one and a
-- decoration. SELECT, and its policy, are untouched.
-- =====================================================================

revoke insert, update, delete on public.bank_reconciliations
  from authenticated;

drop policy if exists bank_reconciliations_insert
  on public.bank_reconciliations;
drop policy if exists bank_reconciliations_update
  on public.bank_reconciliations;
drop policy if exists bank_reconciliations_delete
  on public.bank_reconciliations;

comment on table public.bank_reconciliations is
  'A bank statement agreed with the books, to a date. WRITTEN ONLY BY '
  'FUNCTION -- `complete_bank_reconciliation` and '
  '`reopen_bank_reconciliation`. 0761 revoked insert, update and delete '
  'from `authenticated` and dropped the three write policies: a direct '
  'insert could record a reconciliation out by any amount as completed, '
  'and block every real close before its date.';
