-- =====================================================================
-- iAkauntan :: 0570 what the money writes actually do
--
-- `0569` closed the open doors: every function `anon` may call now says
-- what it hands to a stranger, and `statutory.sql` refuses a thirteenth
-- without one. This is the next slice by the same argument.
--
-- Of the 398 writes a signed-in user can reach, 278 carry no
-- `comment on function`. Thirteen of those touch `gl_entries`,
-- `gl_lines`, `post_document`, `payments` or `balance_amount` -- they
-- move the ledger or somebody's money -- and those are the ones where a
-- caller's wrong assumption is most expensive.
--
-- Not the whole 278. A slice small enough to write carefully is worth
-- more than a sweep of one-liners, and the verb counts say where the
-- rest is: `platform_*` (27) serves our own console and `chat_*` (20)
-- is ephemeral messaging. Neither is what anybody builds against.
--
-- ---------------------------------------------------------------------
-- What these comments are for
--
-- Each of these thirteen refuses more than it accepts, and the refusals
-- ARE the accounting. `void_sales_document` will not void an invoice
-- with a payment against it; `reverse_gl_entry` will not reverse the
-- same journal twice; `apply_deposit` will not settle an invoice in
-- another currency. Every one of those is a rule somebody decided, and
-- until now a caller found out by being refused.
--
-- So each comment says what the function does, what it refuses, and --
-- where it is surprising -- what it does NOT do. `reverse_gl_entry`
-- leaving the original posted is the shape: it reads as an omission and
-- is the whole design.
--
-- No behaviour changes here. Comments only.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The ledger itself
-- ---------------------------------------------------------------------

comment on function public.reverse_gl_entry(uuid, date) is
  'Posts the contra of a journal: the same lines with debit and credit '
  'swapped, dated today or the date given, numbered as a new journal '
  'and marked `is_reversal` pointing back at the original. The original '
  'STAYS POSTED, which reads as an omission and is the design -- the '
  'pair nets to zero and both halves are on the page where an auditor '
  'can see what happened. Refuses a journal that is not posted, one '
  'already reversed (reversing twice would contra the contra and put '
  'the entry back), a date no fiscal period covers, and a date whose '
  'period is not open. Returns the new journal''s id.';

comment on function public.void_sales_document(uuid, text) is
  'Voids an invoice or other sales document and reverses its journal if '
  'it had one, recording the reason in `internal_notes` where the '
  'customer will not see it. Refuses outright if any payment has been '
  'applied -- a document somebody has paid against is corrected with a '
  'credit note, not erased -- and refuses if the e-Invoice is `valid`, '
  'because LHDN has it and the cancellation belongs there first. '
  'Needs `can_post`.';

comment on function public.revalue_foreign_balances(uuid, date) is
  'Restates foreign-currency balances at the rate ruling on the date, '
  'posting the gain or loss. Undoes its own previous standing '
  'revaluation first, dated the same day, so running it twice does not '
  'compound: the figure is always the difference from cost, never from '
  'the last run. Needs `can_post`. Returns the journal''s id.';

comment on function public.submit_for_approval(app.approval_entity, uuid) is
  'Opens an approval request over a sales document, a purchase document '
  'or a journal, and builds one step per matching rule in the rules'' '
  'own step order. Refuses when no rule covers a document of that type '
  'and amount -- saying so rather than creating a request nobody needs '
  '-- when it is already approved, and when rules match but no approver '
  'is configured, which would otherwise be a request that can never be '
  'granted. Two rules on one step number is a configuration error and '
  'is caught here rather than by whoever tries to approve it.';

-- ---------------------------------------------------------------------
-- Money in and out
-- ---------------------------------------------------------------------

comment on function public.post_purchase_payment(uuid) is
  'Posts a payment to a supplier: money out of the bank, the payable '
  'discharged, and any exchange difference struck as its own line. '
  'Refuses a payment already posted, so a retry cannot pay twice. Needs '
  '`can_post`. Returns the journal''s id.';

comment on function public.create_deposit(uuid, text, uuid, date, numeric, uuid, text, text, text) is
  'Records a deposit taken from a customer or paid to a supplier, and '
  'posts it: money moved, and a LIABILITY for a customer deposit rather '
  'than revenue, because it is not earned until the invoice it is held '
  'against exists. THIS IS THE UNPROTECTED OVERLOAD. `0307` added one '
  'taking `p_idempotency_key` as a further argument, and a retried call '
  'that omits the key resolves HERE and takes the money twice. Anything '
  'that can be retried -- a browser, a queue, an integration -- should '
  'call the protected form.';

comment on function public.apply_deposit(uuid, uuid, numeric, date) is
  'Settles an invoice or bill out of a deposit already held, posting '
  'the transfer and recording the allocation. Refuses more than the '
  'deposit has left, more than the document has outstanding, a voided '
  'deposit, a document that is not posted or partly paid, and a deposit '
  'belonging to a different contact. Refuses a currency mismatch on '
  'purpose and says why: the exchange difference belongs where the rest '
  'of them are struck, so settle that one with a receipt. Returns the '
  'journal''s id.';

comment on function public.void_deposit(uuid, text) is
  'Voids a deposit and reverses its journal. Refuses one already void, '
  'and refuses any deposit that has been touched at all -- applied, '
  'refunded or forfeited -- naming the three figures and saying to undo '
  'those first, because voiding underneath them would leave allocations '
  'pointing at a deposit that never happened.';

comment on function public.create_withholding(uuid, text, numeric, numeric, date) is
  'Records withholding tax deducted from a supplier bill under the '
  'named LHDN code: what was withheld becomes a liability owed to the '
  'Inland Revenue Board rather than money paid to the supplier, so the '
  'bill is settled by a smaller payment plus this. The certificate date '
  'is what the remittance is due from.';

-- ---------------------------------------------------------------------
-- Reconciling, importing, and the chart
-- ---------------------------------------------------------------------

comment on function public.match_bank_transaction(uuid, text, uuid) is
  'Ties a statement line to the thing in the books that caused it, '
  'posting a journal where the match implies one. Refuses a line '
  'belonging to a reconciliation that has been completed: a closed '
  'reconciliation balanced against the lines it had, and changing one '
  'afterwards would silently unbalance it. Needs `can_post`.';

comment on function public.import_open_bills(uuid, jsonb, date, boolean) is
  'Brings unpaid supplier bills in from another system as opening '
  'balances, against the opening-balance equity account. `p_commit` '
  'DEFAULTS TO FALSE and the call is a dry run: it returns a row per '
  'input row with its status and message and writes nothing. With '
  '`p_commit` true it is all or nothing -- if any row has a problem, '
  'the whole run is refused naming how many, so a half-imported ledger '
  'cannot happen. Returns the per-row report either way.';

comment on function public.accept_intercompany_bill(uuid, uuid) is
  'Raises, in this company, the bill matching an invoice another company '
  'in the group has issued to it. Copies the figures, the dates and the '
  'issuer''s own document number -- which an SST audit and a self-billed '
  'e-Invoice both ask for -- and matches tax codes BY CODE, because the '
  'two companies have their own `tax_codes` rows and an id from theirs '
  'would point at nothing here, or worse at one of ours by coincidence. '
  'Deliberately does NOT copy `item_id` or `account_id`: which of our '
  'items this is and which expense account it belongs in are decisions '
  'for this company, which is why the bill arrives as a DRAFT rather '
  'than posted. Refuses an invoice not addressed here, one not yet '
  'posted, one already billed, and one whose issuer has no supplier '
  'record on this company''s books.';

comment on function public.retire_account(uuid) is
  'Removes an account from the chart if it can be removed and switches '
  'it off if it cannot, returning ''deleted'' or ''deactivated'' so the '
  'caller can say which happened. Anything ever posted to it, a '
  'non-zero opening balance, or any other row still naming it -- a bank '
  'account, a budget line, an item''s posting account -- means '
  'deactivated: deleting would take a balance out of the trial balance '
  'or answer with a constraint name instead of a sentence. Refuses '
  'outright for an account the ledger posts to by number, which can be '
  'renamed but not removed, and for one that still has accounts under '
  'it. Needs `can_post`.';
