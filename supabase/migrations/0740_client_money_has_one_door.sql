-- ---------------------------------------------------------------------
-- 0740  Client money has one door
--
-- `client_account_transactions` is a solicitor's CLIENT ACCOUNT ledger —
-- money the firm holds that is not its own. `authenticated` held INSERT,
-- UPDATE and DELETE on it, and the insert policy asked only for
-- `app.can_write(org_id)` and the legal module.
--
-- The shipped client used that door. `Repo.recordClientTransaction`
-- inserted the row itself — choosing the matter, the type and the signed
-- amount, minting `transaction_no` client-side, looking the client bank
-- account up client-side — and then called `post_client_transaction`. It
-- was a hand-rolled copy of `receive_client_money` and
-- `pay_from_client_account` with their guards left out.
--
-- ## What that actually cost, and what it did not
--
-- **It did NOT risk overdrawing a client.** That was the first thing
-- written in this comment and it was wrong, and the way it was found is
-- the reason the rule about measuring exists: the assertions below were
-- mutated by re-granting the door, and the direct insert of -999,999 was
-- refused — not by the new assertion but by
-- `app.assert_client_funds`, a DEFERRABLE INITIALLY DEFERRED CONSTRAINT
-- TRIGGER on the table, with the sentence *"Client money held for one
-- matter cannot fund another."* **The cardinal rule of the Legal
-- Profession (Accounts) Rules is enforced on the TABLE, at commit,
-- whichever door the write came through.** Somebody built that properly
-- and it held.
--
-- What the direct door did cost:
--
-- | guard | where it lives | what the direct insert did |
-- | --- | --- | --- |
-- | `app.can_post`, *"Insufficient privileges to move client money"* | both functions | the insert policy asked only `app.can_write`. A member who may write but not post could record a client-money movement — and `post_client_transaction` would then refuse it, **leaving an unposted trust row on the client ledger**: money shown against a client and absent from the accounts |
-- | the amount must be positive, and the type decides the sign | both functions | a SIGNED amount went straight through, so a `receipt` could carry a negative amount or a `payment` a positive one. `assert_client_funds` checks the matter's TOTAL, not whether a row's sign agrees with its type |
-- | `transaction_no` from `next_document_number` in the same statement | both functions | minted client-side in one round trip and inserted in another, which is a gap on a retry and a duplicate on a race |
--
-- So: a privilege gap and a sign gap, not a hole in the trust arithmetic.
-- Narrower than it first looked, and still worth closing — a member
-- without posting rights should not be able to write on a client's
-- ledger at all, and an unposted trust row is exactly the kind of thing
-- that is found at an audit rather than at a desk.
--
-- `0549` has been here one door down: it took the transfer option off
-- that same dropdown because it wrote ONE leg, so the client ledger fell
-- and the office account was never debited.
--
-- ## What changes
--
-- The grant goes. `authenticated` keeps SELECT — the matter screen and
-- the client-account ledger both read this table and must go on doing so
-- — and loses INSERT, UPDATE and DELETE. The five functions that write it
-- are SECURITY DEFINER and run as the owner, so they are unaffected:
-- `receive_client_money`, `pay_from_client_account`,
-- `settle_from_client_account`, `transfer_between_matters` and
-- `post_client_transaction`. After this they are the ONLY door, so their
-- guards are no longer optional.
--
-- The three write POLICIES go as well, and that is the stronger half.
-- `table_grants.sql` refused a first draft that kept and tightened them,
-- because a policy `authenticated` cannot reach is decoration -- and with
-- RLS on and no policy for a command, Postgres denies it whatever the
-- grants say. So the revoke and the drop are two defences rather than one
-- defence and an ornament. The SELECT policy stays untouched.
--
-- Nothing is dropped and no data moves. A firm's existing ledger is
-- untouched.
-- ---------------------------------------------------------------------

-- The door itself.
revoke insert, update, delete on public.client_account_transactions
  from authenticated;

-- And the policies go with it, which is STRONGER than restating them.
--
-- The first draft of this migration kept all three and tightened them to
-- `app.can_post`, reasoning that if a later migration ever restored a
-- grant the rule under it should already be the right one.
-- `table_grants.sql` refused that outright:
--
--     FAIL a policy without the privilege to reach it:
--       client_account_transactions (DELETE), (INSERT), (UPDATE)
--
-- which is `0661` and `0662`'s lesson -- a policy nobody can reach is
-- decoration -- and the assertion was written for the opposite mistake.
-- It is right here too, and the reasoning behind the draft was simply
-- wrong: **row level security with no policy at all is how this schema
-- says no access**, as `table_grants.sql` says three lines further down.
-- With RLS enabled and no permissive policy for a command, Postgres
-- denies it for every role that is not the owner -- grant or no grant.
--
-- So dropping them is not the weaker option, it is the one that holds
-- even if somebody restores the grant. Two defences, not one and a
-- decoration.
drop policy if exists client_account_transactions_insert
  on public.client_account_transactions;
drop policy if exists client_account_transactions_update
  on public.client_account_transactions;
drop policy if exists client_account_transactions_delete
  on public.client_account_transactions;

comment on table public.client_account_transactions is
  'A solicitor''s client account ledger: money the firm holds that is not '
  'its own. WRITTEN ONLY BY FUNCTION -- 0740 revoked insert, update and '
  'delete from `authenticated`, because the shipped client was inserting '
  'rows directly and so skipping app.can_post (the insert policy asked '
  'only for can_write, so a member who may not post could leave an '
  'UNPOSTED trust row) and skipping the rule that the amount is positive '
  'and its sign follows the type, and the three write POLICIES are gone '
  'too -- with RLS on and no policy, the command is denied whatever a '
  'future grant says. The overdraw rule is NOT among those: '
  'app.assert_client_funds is a deferred constraint trigger on this '
  'table and holds whichever door a write comes through. Use '
  'receive_client_money, pay_from_client_account, '
  'settle_from_client_account or transfer_between_matters; each moves '
  'every leg and posts.';
