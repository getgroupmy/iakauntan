-- =====================================================================
-- iAkauntan :: 0810 a filing is recorded as it was
--
-- `tax_filings` records each LHDN filing -- Form C and the rest -- with
-- the date it was due and the date it was filed; `tax_filing_history`
-- reports `was_late` from the two, "the thing a penalty is assessed
-- on", as its own comment says. `record_tax_filing` takes the due date,
-- the period and the year of assessment from the obligation itself
-- (`tax_upcoming_filings`), not from the caller. `tax_estimate_payments`
-- records CP204 instalments, and `record_tax_instalment` asks that the
-- instalment is one the estimate's schedule has and that something was
-- paid. The app writes both through those functions and their `clear_`
-- twins. But `authenticated` held insert, update and delete on both,
-- behind policies asking `app.can_post` (`app.can_admin` to delete a
-- filing).
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: a Form C for the year to 30 June 2026, due 31
-- January 2027, recorded as filed on 2 March 2027 -- late. Its
-- `due_date` set to the filing date by hand, and the history read it
-- on time. An instalment's `paid_on` could be moved back the same way,
-- or one recorded that the schedule does not have.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0809`: the
-- grants are revoked and the write policies dropped on both. Reading
-- stays. The four functions are definers.
--
-- Production held no filing and no instalment on 11 October.
-- =====================================================================

revoke insert, update, delete on public.tax_filings from authenticated, anon;
drop policy if exists tax_filings_insert on public.tax_filings;
drop policy if exists tax_filings_update on public.tax_filings;
drop policy if exists tax_filings_delete on public.tax_filings;

revoke insert, update, delete on public.tax_estimate_payments from authenticated, anon;
drop policy if exists tax_estimate_payments_insert on public.tax_estimate_payments;
drop policy if exists tax_estimate_payments_update on public.tax_estimate_payments;
drop policy if exists tax_estimate_payments_delete on public.tax_estimate_payments;

comment on table public.tax_filings is
  'Each LHDN filing, its statutory due date and when it was filed; '
  'tax_filing_history reports lateness from them. WRITTEN ONLY BY '
  'FUNCTION -- 0810 revoked insert, update and delete from clients and '
  'dropped the write policies; record_tax_filing, which takes the due '
  'date from the obligation, and clear_tax_filing write it.';

comment on table public.tax_estimate_payments is
  'CP204 instalments paid against a tax estimate. WRITTEN ONLY BY '
  'FUNCTION -- 0810 revoked insert, update and delete from clients and '
  'dropped the write policies; record_tax_instalment and '
  'clear_tax_instalment write it.';
