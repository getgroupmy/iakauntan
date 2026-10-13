-- =====================================================================
-- iAkauntan :: 0864 a filed statement's figures are the ledger's
--
-- `0855` made `fs_prepare` and `fs_export` refuse a member who does not
-- read the ledger, `fs_export` in its own words because it answers a
-- frozen filing from `fs_figures` without calling `fs_prepare`. The
-- table it answers from was still read by every member
-- (`app.is_org_member`) with the MBRS add-on: the refusal was on the
-- function and the figures were one select away.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated`: `fs_export` refused, and `select * from
-- fs_figures` gave the frozen year line by line -- cost of sales
-- 4,321.09, share capital 4,321.09, retained earnings -4,321.09.
-- Production has four frozen filings and no figure rows yet.
--
-- No screen reads the table; only the four functions do, each a
-- definer (`fs_freeze`, `fs_unfreeze`, `fs_prepare`, `fs_export`).
-- Answered "figures need ledger access": the select policy asks
-- `app.can_read_ledger`. The restrictive MBRS module gate stays as it
-- was. `fs_filings` -- status, dates, the auditor -- and the narrative
-- in `fs_disclosures` hold no figure and stay open to every member, as
-- the filings list needs them.
-- =====================================================================

alter policy fs_figures_select on public.fs_figures
  using (app.can_read_ledger(org_id));
