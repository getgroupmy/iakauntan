-- =====================================================================
-- iAkauntan :: 0842 a points card is enrolled
--
-- `0212` made points a ledger: `loyalty_entries` has a read policy and
-- no write policy, "a balance a client could type is not a balance", and
-- `adjust_loyalty_points` asks for an owner or admin -- "handing out
-- points is handing out money, and a cashier who can do it unwitnessed
-- is a control nobody has". The balance is the sum of an account's
-- entries. The account they hang on, `loyalty_accounts`, kept a policy
-- for all commands that asks only for write on the module.
--
-- Measured on 12 October 2026, locally, with the role `authenticated`,
-- signed in as a cashier (role `sales`) whom `adjust_loyalty_points`
-- refuses: Aminah's card repointed at another customer by an update was
-- accepted, and her 5,000 points -- RM50.00 at the till -- went with
-- it; her account deleted was accepted, and its ledger entries
-- cascaded away. The app writes no loyalty account itself: a member is
-- enrolled by `enrol_loyalty_member`, a definer, as the demonstration
-- books enrol theirs.
--
-- Answered "revoke client writes": insert, update and delete are
-- revoked from `authenticated` and `anon` and `loyalty_accounts_write`
-- dropped, as the ledger's own writes were. Reading is as before.
--
-- Production held one programme, one account and one entry on 12
-- October, in a demonstration company.
-- =====================================================================

revoke insert, update, delete on public.loyalty_accounts from authenticated, anon;
drop policy if exists loyalty_accounts_write on public.loyalty_accounts;
