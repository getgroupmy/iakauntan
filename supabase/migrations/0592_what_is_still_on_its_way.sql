-- =====================================================================
-- iAkauntan :: 0592 what is still on its way
--
-- The seventh slice of the undocumented writes, and the first chosen by
-- a fact about the BOOKS rather than about a feature: these are the
-- seven functions that deal with something which has left one place and
-- not arrived at the other.
--
-- A cheque taken in on Tuesday and dated for the month end. A statement
-- line the bank has and the ledger has not. A van of stock that left
-- the main store this morning. In every one of them the interesting
-- question is the same, and it is the question a caller cannot answer
-- from a name and an argument list:
--
--     WHEN does this move the money, and when does it only move the
--     record of it?
--
-- Get that wrong and nothing complains. The bank balance is simply
-- three days ahead of the bank, or a case of stock is in two warehouses
-- at once, and the person who finds out is the one reconciling next
-- month.
--
-- ---------------------------------------------------------------------
-- The two that deliberately post nothing
--
-- `deposit_pdc` is the clearest thing in this migration. Paying a
-- cheque in is not the same as it clearing, so the function moves the
-- cheque to `deposited` and writes no journal at all. An entry on the
-- day of the deposit would put the money in the bank three days early,
-- which is exactly the error the post-dated cheque register exists to
-- prevent.
--
-- `record_pdc` posts nothing either when the cheque is against nothing
-- yet. It is in the register, and the register is the point.
--
-- ---------------------------------------------------------------------
-- The overload that carries the description and the one that does not
--
-- `record_pdc` has two signatures. The eleven-argument one is
-- documented. The twelve-argument one -- the same call with
-- `p_idempotency_key` on the end -- is not, and that is the one a
-- client should be using: it is the overload that survives a retry,
-- and `check_idempotent_calls.py` exists because a payment taken twice
-- on a flaky connection is the expensive kind of mistake.
--
-- So the published description named the unprotected call and said
-- nothing about the protected one. Corrected here.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Money that has not cleared
-- ---------------------------------------------------------------------

comment on function public.record_pdc(
  uuid, text, uuid, text, date, numeric, jsonb, uuid, text, date, text, text) is
  'The same as the eleven-argument `record_pdc`, and THE ONE TO CALL: '
  'the extra `p_idempotency_key` makes a retry return the cheque the '
  'first attempt recorded rather than recording a second one. A '
  'connection that drops after the write and before the answer is the '
  'ordinary case, not the rare one. Everything below about the '
  'unprotected overload applies unchanged.';

comment on function public.deposit_pdc(uuid, date) is
  'Marks a held cheque as paid in, and POSTS NOTHING. That is the '
  'point rather than an omission: a cheque paid in on Monday is still '
  'a cheque until it clears, and a journal on Monday would put the '
  'money in the bank three days early. The entry that moves it out of '
  '`1140` belongs to the receipt raised when it clears. Refuses a '
  'cheque that is not `held`, which is how a double deposit is caught. '
  'Needs write access to sales for an incoming cheque and to purchases '
  'for an outgoing one, because those are the ledgers it will settle.';

-- ---------------------------------------------------------------------
-- What the bank says, and what the books say
-- ---------------------------------------------------------------------

comment on function public.complete_bank_reconciliation(uuid, date, numeric) is
  'Closes a reconciliation, and refuses two things in an order that '
  'matters. FIRST that the statement date is after the last completed '
  'one -- because a repeat of a closed period passes the difference '
  'test for the wrong reason: every line up to that date is already '
  'reconciled, so there is nothing left to be out by, and a nil '
  'difference means agreement only the first time. THEN that the '
  'difference is zero, naming how many statement lines are still '
  'unmatched, because completing it while it is out buries the '
  'difference in a period somebody has signed off. Reopen the earlier '
  'one if it was wrong. Needs `can_post`.';

comment on function public.unmatch_bank_transaction(uuid) is
  'Breaks the link between a statement line and what it was matched '
  'to, leaving the line on the statement and the document alone. '
  'Refuses a line that belongs to a COMPLETED reconciliation: that '
  'line is part of an agreement somebody signed, and unpicking it '
  'would leave the reconciliation claiming a difference of zero it can '
  'no longer support. Reopen the reconciliation first. Needs '
  '`can_post`.';

comment on function public.disconnect_bank_feed(uuid) is
  'Revokes a bank feed''s stored credentials and stops it importing. '
  'The FEED ROW AND ITS RUNS STAY: what was imported and when is the '
  'company''s record of where its statements came from, and deleting '
  'the feed would take that with it. Needs `can_admin` rather than the '
  '`can_post` the rest of banking takes -- a feed is a credential '
  'arrangement with a bank, not a day''s bookkeeping.';

-- ---------------------------------------------------------------------
-- Stock that has left and not arrived
-- ---------------------------------------------------------------------

comment on function public.send_stock_transfer(uuid) is
  'Takes stock out of the sending store and puts its value in goods in '
  'transit -- debit transit, credit inventory -- so the stock is on '
  'neither shelf and the balance sheet still has it. Refuses a '
  'transfer that is not `draft`, and one with no lines. Refuses more '
  'than the store holds unless the company has allowed negative stock, '
  'and refuses more than its BATCHES hold whatever that setting says, '
  'because a van cannot carry a batch nobody has. Needs the inventory '
  'module.';

comment on function public.receive_stock_transfer(uuid, jsonb) is
  'Books the stock in at the far end and clears goods in transit. '
  '`p_counts` is what actually arrived, line by line; a line not named '
  'is taken as arriving in full. Refuses a transfer that is not '
  '`sent`, and refuses a count larger than what was sent, because '
  'there is no such thing as receiving more than left. WHAT IS SHORT '
  'IS NOT LOST QUIETLY: the difference is charged to `5900`, the '
  'account 0087 already uses for a stock difference nobody can '
  'explain, so transit always clears to nil and the loss is on the '
  'profit and loss where somebody will see it. Stock arrives at the '
  'cost it LEFT at, not the destination''s average, because averaging '
  'it in would move value between two warehouses of one company. Needs '
  'the inventory module.';
