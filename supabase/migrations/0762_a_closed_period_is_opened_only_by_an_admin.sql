-- =====================================================================
-- 0762 :: a closed period, and a closed year, are opened only by
--         somebody allowed to
--
-- Answered on 8 October: "close it", for periods and years both.
--
-- `set_fiscal_period_status` lets only an owner or an admin open or
-- close a period, and refuses to unlock a locked one -- "Locked is
-- deliberately terminal: it is what year-end sign-off means".
-- `close_fiscal_year` and `reopen_fiscal_year` ask the same, and do the
-- work that goes with it: closing posts the year's closing entry, and
-- reopening reverses it.
--
-- None of it bound anybody, because `fiscal_periods` and `fiscal_years`
-- both carried insert, update and delete for `authenticated`, behind
-- policies asking only `app.can_post`. Reproduced under row level
-- security: an owner locked January; an accountant -- can_post, not
-- can_admin -- was refused by the function, then set January back to
-- `open` with a plain UPDATE. A year could be set `open` with its closing
-- entry still in the ledger, or `closed` with none; periods and years
-- could be inserted or deleted outright.
--
-- The app only reads both tables. They are written by five SECURITY
-- DEFINER functions -- `create_fiscal_year`, `create_previous_fiscal_
-- year`, `set_fiscal_period_status`, `close_fiscal_year`, `reopen_
-- fiscal_year` -- which keep working. Production had 408 periods, none
-- closed or locked, when this was written.
--
-- 0740's and 0761's shape: the grant goes and the write policies with
-- it. With row level security on and no policy for a command, Postgres
-- refuses it whatever a later grant says. SELECT is untouched.
-- =====================================================================

revoke insert, update, delete on public.fiscal_periods from authenticated;
drop policy if exists fiscal_periods_insert on public.fiscal_periods;
drop policy if exists fiscal_periods_update on public.fiscal_periods;
drop policy if exists fiscal_periods_delete on public.fiscal_periods;

revoke insert, update, delete on public.fiscal_years from authenticated;
drop policy if exists fiscal_years_insert on public.fiscal_years;
drop policy if exists fiscal_years_update on public.fiscal_years;
drop policy if exists fiscal_years_delete on public.fiscal_years;

comment on table public.fiscal_periods is
  'The months of a fiscal year, each open, closed or locked. WRITTEN ONLY '
  'BY FUNCTION -- `create_fiscal_year`, `create_previous_fiscal_year`, '
  '`set_fiscal_period_status`. 0762 revoked insert, update and delete '
  'from `authenticated` and dropped the write policies: a direct update '
  'let a member who may not open a period unlock a locked one.';

comment on table public.fiscal_years is
  'A company''s fiscal years. WRITTEN ONLY BY FUNCTION -- '
  '`create_fiscal_year`, `create_previous_fiscal_year`, '
  '`close_fiscal_year`, `reopen_fiscal_year`. 0762 revoked insert, update '
  'and delete from `authenticated` and dropped the write policies: a '
  'direct update could reopen a year without reversing its closing '
  'entry, or close one without posting it.';
