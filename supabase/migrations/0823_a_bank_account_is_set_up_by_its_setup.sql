-- =====================================================================
-- iAkauntan :: 0823 a bank account is set up by its setup
--
-- The app reads `bank_accounts` and writes it only through functions:
-- `upsert_bank_account` adds and edits one -- refusing a ledger account
-- that is not a bank or cash account of the same company -- and the
-- posting functions keep `current_balance`, which `resync_bank_balance`
-- rebuilds from the ledger. Sixteen functions write the table, every
-- one a definer. But `0010`'s policies left insert, update and delete
-- to anybody who may post.
--
-- Measured on 11 October 2026, locally, as the owner with the role
-- `authenticated`: `upsert_bank_account` refused to point a bank
-- account at 6400 Depreciation -- "That is not a bank or cash account
-- in this company" -- and a direct update did it. A RM500 receipt into
-- that bank then posted Dr 6400 Depreciation, Cr Receivables: money
-- received, booked as an expense. And a balance typed in as RM1,000,000
-- went straight onto the dashboard's bank balance, which the cash
-- forecast starts from too.
--
-- Answered "read-only to clients", as `0804` and `0806` to `0819`: the
-- grants are revoked and the three write policies dropped. Reading
-- stays, by `bank_accounts_select`.
--
-- Production held twenty-nine bank accounts across sixteen companies,
-- every one on a bank or cash account, on 11 October.
-- =====================================================================

revoke insert, update, delete on public.bank_accounts from authenticated, anon;
drop policy if exists bank_accounts_insert on public.bank_accounts;
drop policy if exists bank_accounts_update on public.bank_accounts;
drop policy if exists bank_accounts_delete on public.bank_accounts;

comment on table public.bank_accounts is
  'Each bank and cash account a company keeps, the ledger account it '
  'posts to, and a cached balance. WRITTEN ONLY BY FUNCTION -- 0823 '
  'revoked insert, update and delete from clients and dropped the write '
  'policies; upsert_bank_account sets one up, refusing a ledger account '
  'that is not a bank or cash account of the company, the posting '
  'functions keep the balance and resync_bank_balance rebuilds it.';
