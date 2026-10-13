-- =====================================================================
-- iAkauntan :: 0861 a recurring journal and a bank transfer are the
-- ledger's
--
-- Two more tables every member read (`app.is_org_member`), each the
-- ledger's by any reading of the word:
--
--   * `recurring_journals` -- each template's `template` is the journal
--     it posts, line by line, with accounts and amounts;
--   * `bank_transfers` -- money moved between the company's own banks,
--     with the amounts sent and received, the rates and the exchange
--     difference: the figures `0858` and `0859` withheld, from the
--     other side.
--
-- Measured on 13 October 2026, locally, as a `sales` member with the
-- role `authenticated`: a monthly "Directors' fees" journal of 25,000 a
-- side, and a transfer of 300,000 between two of the company's banks.
--
-- Every function on either asks `app.can_post` (`create_bank_transfer`,
-- `post_bank_transfer`, `void_bank_transfer`,
-- `run_recurring_journals_for`), as do the client writes on
-- `recurring_journals`. Answered "both need ledger access": both select
-- policies ask `app.can_read_ledger`.
-- =====================================================================

alter policy recurring_journals_select on public.recurring_journals
  using (app.can_read_ledger(org_id));

alter policy bank_transfers_select on public.bank_transfers
  using (app.can_read_ledger(org_id));
