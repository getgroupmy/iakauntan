-- =====================================================================
-- iAkauntan :: 0571 what posting and creating commit you to
--
-- Third slice, same argument as `0569` and `0570`. These are the verbs
-- that put things in the books: every `post_*` and `create_*` a
-- signed-in user can reach that still carried no
-- `comment on function`.
--
-- A pattern runs through nearly all of them and is worth stating once
-- here rather than twenty times below: **posting is idempotent by
-- refusal, not by silence.** Every posting function checks
-- `gl_entry_id is not null` (or `posted_at`) and RAISES on the second
-- call. It does not quietly return the first journal. So a retry after
-- a timeout gets an error, and the caller has to read it: "already
-- posted" means the first call worked.
--
-- The four writes `0307` protected are the exception, and the exception
-- proves the rule -- they were protected precisely because they have no
-- such flag to check.
--
-- The second pattern: `can_post` is the guard on almost all of these,
-- and it is not the same as `can_write`. `0018` built it as its own
-- answer to "may this person put something in the ledger", and
-- `0568` had to gate it separately for exactly that reason.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Posting a document to the ledger
-- ---------------------------------------------------------------------

comment on function public.post_sales_document(uuid) is
  'Posts an invoice, credit note, debit note or refund note to the '
  'ledger. Any other document type is refused rather than ignored -- a '
  'quotation does not post, and saying so beats appearing to succeed. '
  'Credit and refund notes move the ledger the other way. A line '
  'carrying a service period credits deferred revenue instead of '
  'revenue and opens a release schedule (`0309`); a credit note cancels '
  'the schedule it credits rather than opening a second one (`0310`). '
  'Stock lines also post cost of sales. Refuses a document already '
  'posted. Needs `can_post`.';

comment on function public.post_purchase_document(uuid) is
  'Posts a bill, or its credit or debit note, to the ledger: the '
  'expense or the asset, the input tax, and the payable. Refuses a '
  'document already posted and a type that does not post. Needs '
  '`can_post`.';

comment on function public.post_receipt(uuid) is
  'Posts money received from a customer: bank debited net of charges, '
  'bank charges to their own account, receivable credited, and any '
  'exchange movement between the invoice and the receipt struck as its '
  'own line. That adjustment is stated in ringgit with no foreign '
  'amount behind it, because deriving one would invent dollars that '
  'were never invoiced. Refuses a receipt already posted. Needs '
  '`can_post`.';

comment on function public.post_expense(uuid) is
  'Posts a recorded expense. Refuses one that has been deleted -- this '
  'was the only posting function in the schema that did not, so an '
  'expense somebody had removed from the list could still reach the '
  'accounts, where no screen would ever show it to them again. Refuses '
  'a total that does not equal amount plus tax, said plainly and BEFORE '
  'any conversion, so the person who saved it is told which number is '
  'wrong rather than what the ledger made of the result. Refuses one '
  'already posted. Needs `can_post`.';

comment on function public.post_expense_claim(uuid, uuid) is
  'Pays an approved employee claim and posts it. Refuses a claim that '
  'is not approved, one already posted, one with nothing on it, and -- '
  'the one worth knowing -- a claim marked `pay_with_payroll`, which is '
  'settled through the payroll run rather than here, so paying it twice '
  'is not possible by arithmetic rather than by care. Needs `can_post`.';

comment on function public.post_bank_transfer(uuid) is
  'Posts a transfer between two of the company''s own bank accounts, '
  'with the fee to its own account and any residual as exchange '
  'difference. That residual is only ever non-zero across currencies: '
  '`create_bank_transfer` refuses one when both ends are in the same '
  'currency. Balances move by the amount sent alone, because the fee is '
  'already inside it and is debited to a different account -- '
  'subtracting it again took it twice. Refuses a transfer already '
  'posted. Needs `can_post`.';

comment on function public.post_withholding(uuid) is
  'Posts a withholding certificate: the control account comes down and '
  'the amount becomes owed to the Inland Revenue Board. Also writes the '
  'subledger half, without which the bill goes on showing the gross '
  'outstanding while the control account has already moved. Refuses a '
  'certificate for nothing, and one already posted. Needs `can_post`.';

comment on function public.post_client_transaction(uuid) is
  'Posts money through a legal practice''s CLIENT account -- money the '
  'firm holds and does not own. In debits the client bank and credits '
  'what the firm owes the client; out does the reverse. A bank account '
  'that is not a client account is REFUSED rather than redirected: the '
  'ledger and the bank register have to name the same account, and the '
  'money is not the firm''s to move. Needs the legal module set up and '
  '`can_post`.';

comment on function public.post_stock_adjustment(uuid) is
  'Posts a stock take or write-off at current average cost, line by '
  'line, skipping lines where the count agreed. Refuses a line for an '
  'item that does not track inventory and one whose account is missing, '
  'rather than posting a partial adjustment. Does NOT fall back to a '
  'default warehouse: the adjustment already names one, and a posting '
  'function that silently picks a warehouse is one that moves stock '
  'somewhere nobody asked for. Refuses an adjustment already posted. '
  'Needs `can_post`.';

comment on function public.post_manufacturing_order(uuid, numeric) is
  'Posts a production run: components out at what they are carried at, '
  'finished goods in at what they cost. A short run consumes '
  'PROPORTIONALLY less -- costing the whole recipe against half an '
  'output is how a finished item ends up carried at twice its worth. '
  'Refuses an order that is not confirmed or in progress, one already '
  'posted, and a run that produced nothing. Needs `can_post`.';

comment on function public.post_manual_journal(uuid, date, jsonb, text, text) is
  'Posts a journal typed by hand. Refuses lines that do not balance, a '
  'date outside an open fiscal period, and an account the ledger will '
  'not take. THIS IS THE UNPROTECTED OVERLOAD: `0307` added one taking '
  '`p_idempotency_key`, and because a manual journal has no document '
  'behind it there is no "already posted" flag to catch a retry -- a '
  'repeated call here posts the journal twice. Anything that can be '
  'retried should call the protected form. Needs `can_post`.';

-- ---------------------------------------------------------------------
-- Creating
-- ---------------------------------------------------------------------

comment on function public.create_bank_transfer(uuid, uuid, numeric, date, numeric, numeric, text, text) is
  'Records a transfer between two of the company''s own bank accounts, '
  'ready to post. Refuses two accounts belonging to different companies '
  '-- one journal spanning two companies would breach the boundary the '
  'rest of this system is built on -- the same account at both ends, an '
  'amount of nothing, and a same-currency transfer where sent does not '
  'equal received plus charges. Across currencies the residual is '
  'carried as exchange difference. Needs `can_post`.';

comment on function public.create_contra(uuid, date, jsonb, jsonb, text, text) is
  'Sets a customer''s invoices against the same party''s bills and posts '
  'the offset, for a contact who is both. The protected overload: '
  '`p_idempotency_key` has no default, and a retry with the same key '
  'returns the first call''s answer rather than contra-ing twice. Both '
  'sides must belong to one company and one contact.';

comment on function public.create_fiscal_year(uuid, date) is
  'Opens a fiscal year and its periods, from the date given or from '
  'where the last one ended, honouring the company''s own year-end day. '
  'Refuses a year overlapping one that already exists, naming the '
  'dates: two periods covering one date would make "which period does '
  'this post to" ambiguous, and posting is refused outside an open '
  'period. Needs `can_post`.';

comment on function public.create_payroll_run(uuid, uuid, text) is
  'Opens a payroll run over a pay period, ready for employees to be '
  'added and the statutory amounts computed. Needs `can_run_payroll`, '
  'which is its own permission and not `can_write` -- what people are '
  'paid is not something everybody who may edit a customer should see.';

comment on function public.create_organization(text, text, app.entity_type, text, text, text, text, text, text, text, text, text, text, boolean, text, smallint, text) is
  'Creates a company, seeds its chart of accounts, and makes the caller '
  'its owner. The FIRST company is what signing up is for; every one '
  'after it needs the Multi-Company module, and the refusal names the '
  'way out because somebody who has just typed a company''s details '
  'into a form is owed better than "no" (`0486`). Requires a signed-in '
  'user.';

comment on function public.create_firm(text, text, text, text) is
  'Starts an accounting practice and makes the caller a partner in it '
  '-- without that, nobody could do anything with it afterwards. Needs '
  'the same entitlement as a second company: a practice is the '
  'multi-company case with a nameplate on it, and one that could be '
  'started for nothing and then used to attach companies would be the '
  'module with the price taken off (`0486`).';

comment on function public.create_item_variants(uuid, jsonb) is
  'Expands a style into its variants across the axes given -- size and '
  'colour and the like -- returning a row per combination saying '
  'whether it was created or already existed, so re-running after '
  'adding one axis value is safe. Refuses an item that is itself a '
  'variant, an empty axis set, and a style that already holds stock: '
  'that stock has nowhere to go once the style stops holding any, and '
  'this function will not decide between moving it and writing it off. '
  'Needs `can_write`.';

comment on function public.create_recurring_document(uuid, text, text, date, integer, date, integer, boolean, boolean) is
  'Turns a posted invoice or bill into a schedule that raises it again '
  'on a cycle, optionally posting and emailing each one unattended. '
  'Due dates come from the terms this customer was actually given last '
  'time rather than a number somebody has to remember to type. Only an '
  'invoice or a bill can recur. Refuses an end date before the start '
  'and a schedule with no name. Needs `can_post`.';

comment on function public.create_ticket(uuid, text, text, text, app.ticket_priority, app.ticket_type, app.ticket_channel, uuid, uuid, uuid) is
  'Raises a support ticket. With neither requester given, the caller is '
  'raising it for themselves, which is the self-service case. A '
  'contact or asset that does not exist is refused with a sentence '
  'rather than a foreign-key name: a support desk that picked the wrong '
  'customer from a stale list should read English, not '
  '`tickets_contact_fk`. Needs the `ticketing` module.';

-- ---------------------------------------------------------------------
-- The protected overloads
--
-- These are the forms to call. Each is commented separately from its
-- unprotected twin on purpose: PostgREST picks between them on the
-- argument names in the request body, so the two are different
-- endpoints to a caller, and a description that covered only one would
-- leave the other looking like the plain choice.
-- ---------------------------------------------------------------------

comment on function public.post_manual_journal(uuid, date, jsonb, text, text, text) is
  'Posts a journal typed by hand, once. THE FORM TO CALL: a retry with '
  'the same `p_idempotency_key` returns the first call''s journal '
  'instead of posting a second, and the same key with different '
  'arguments is refused rather than quietly answered. A manual journal '
  'has no document behind it, so there is no "already posted" flag to '
  'catch a repeat -- which is why this overload exists (`0307`). The '
  'key has no default, because a call that omits it resolves to the '
  'unprotected original. Refuses lines that do not balance and a date '
  'outside an open fiscal period. Needs `can_post`.';

comment on function public.create_deposit(uuid, text, uuid, date, numeric, uuid, text, text, text, text) is
  'Records and posts a deposit taken from a customer or paid to a '
  'supplier, once. THE FORM TO CALL: a retry with the same '
  '`p_idempotency_key` returns the first call''s deposit rather than '
  'taking the money twice, and the same key with different arguments is '
  'refused. A customer deposit posts as a LIABILITY rather than '
  'revenue, because it is not earned until the invoice it is held '
  'against exists. The key has no default, because a call that omits it '
  'resolves to the unprotected original (`0307`).';
