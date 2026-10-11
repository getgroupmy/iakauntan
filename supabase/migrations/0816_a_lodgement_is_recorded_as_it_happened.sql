-- =====================================================================
-- iAkauntan :: 0816 a lodgement is recorded as it happened
--
-- `corp_filings` holds each SSM filing a practice has taken up for a
-- company -- an Annual Return, the financial statements, a change of
-- particulars -- and whether and when it was lodged. The deadline list,
-- `corp_upcoming_filings`, computes every deadline from the entity and
-- the Act and drops the ones whose row says `lodged`, `approved` or
-- `not_applicable`. The app writes the table through two definers:
-- `corp_open_filing`, which takes the due date from the filing type,
-- and `corp_mark_lodged`, which refuses a lodgement dated in the future
-- or before the event it notifies, and refuses recording one twice --
-- "recording it again would write over the reference SSM gave it". But
-- `authenticated` held insert, update and delete behind
-- `corp_filings_write`, an `ALL` policy asking `app.can_write`.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: an Annual Return due 11 April 2025, never lodged,
-- typed in as lodged on 1 January 2099 with the reference "MADE-UP" --
-- and it left the overdue list. A lodgement recorded properly, on 30
-- September 2026 as SSM-REAL-1, rewritten by hand to 1 January 2025,
-- before the anniversary it reports, under another reference; and then
-- deleted.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0815`: the
-- grants are revoked and the write policy dropped. Reading stays, by
-- `corp_filings_select`. Nothing in the app sets `approved`, `rejected`
-- or `not_applicable`, and now nothing a client does can; each would
-- want its own function, with a reason, when the app needs it.
--
-- Production held one filing on 11 October, lodged through
-- `corp_mark_lodged`.
-- =====================================================================

revoke insert, update, delete on public.corp_filings from authenticated, anon;
drop policy if exists corp_filings_write on public.corp_filings;

comment on table public.corp_filings is
  'Each SSM filing taken up for a company, its statutory due date and '
  'whether and when it was lodged; corp_upcoming_filings drops a '
  'deadline once its filing is lodged. WRITTEN ONLY BY FUNCTION -- 0816 '
  'revoked insert, update and delete from clients and dropped the write '
  'policy; corp_open_filing, which takes the due date from the filing '
  'type, and corp_mark_lodged, which refuses a lodgement in the future, '
  'before its event or recorded twice, write it.';
