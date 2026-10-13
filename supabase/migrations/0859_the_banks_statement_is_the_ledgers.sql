-- =====================================================================
-- iAkauntan :: 0859 the bank's statement is the ledger's
--
-- `0858` withheld the bank's balance from a role that does not read the
-- ledger. Two tables still gave it away, both read by every member
-- (`app.is_org_member`):
--
--   * `bank_transactions` -- the statement, line by line: what was paid,
--     to whom, and the bank's running balance after it;
--   * `bank_reconciliations` -- each reconciliation's statement balance
--     and book balance.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated` (`can_read_ledger` false, `bank_balances` empty):
-- the salesman read "GAJI PENGARAH OKT" at -45,000.00 with a running
-- balance of 98,765.43, and a reconciliation's statement and book
-- balance of 110,765.43.
--
-- Every function that touches either table already asks for the ledger
-- or for posting (`import_bank_transactions`, `match_bank_transaction`,
-- `post_bank_transaction`, `complete_bank_reconciliation`,
-- `report_bank_reconciliations`, `suggest_bank_matches` ...). No view
-- and no invoker function reads them. The plain select was the one door
-- left, and the one reader in the app is the reconciliation screen.
--
-- Answered "statement lines need ledger access": both select policies
-- ask `app.can_read_ledger`. Writes are unchanged -- `0808` made
-- `bank_transactions` read-only to a client, and reconciliations are
-- written by their functions.
-- =====================================================================

alter policy bank_transactions_select on public.bank_transactions
  using (app.can_read_ledger(org_id));

alter policy bank_reconciliations_select on public.bank_reconciliations
  using (app.can_read_ledger(org_id));
