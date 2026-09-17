-- =====================================================================
-- iAkauntan :: 0572 what survives the undo
--
-- Fourth slice. `0569` did the open doors, `0570` the thirteen that
-- move money, `0571` the posting and creating verbs. This one takes
-- the writes that UNDO something, and they share a question none of
-- the others had to answer:
--
--     what is left afterwards?
--
-- "Void" and "cancel" and "revoke" and "clear" all sound total, and
-- none of them is. A voided transfer keeps its journal and gains a
-- reversing one. A reopened reconciliation keeps every match it had.
-- Detaching a practice leaves the people the client invited itself.
-- Clearing a scanning key switches scanning off; clearing an e-Invoice
-- key does not. A caller who assumes "gone" gets one of those wrong.
--
-- Seventeen of the thirty-four undo verbs, in three groups: the ones
-- that move money back, the ones that take away access somebody
-- currently has, and the ones that delete a credential. The remaining
-- seventeen are `retire_*` and `delete_*` over configuration rows --
-- menu links, kitchen stations, scale formats -- where the stakes are
-- a dropdown, not a ledger.
--
-- Comments only. No behaviour changes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Money, put back
--
-- None of these deletes the original. The ledger is append-only: what
-- undoing means here is a second entry that cancels the first, with
-- both on the page.
-- ---------------------------------------------------------------------

comment on function public.void_bank_transfer(uuid, text) is
  'Voids a transfer between the company''s own bank accounts and '
  'reverses its journal if it had one. Puts back exactly what '
  '`post_bank_transfer` took -- the amount SENT, which already includes '
  'the fee -- so the two are symmetric and the balance lands where it '
  'started. Refuses one already void. The original journal stays '
  'posted and a reversing one is added beside it. Needs `can_post`.';

comment on function public.void_contra(uuid, text) is
  'Voids a contra -- the set-off between what a contact owes and what '
  'they are owed -- and reverses its journal. The reason is REQUIRED, '
  'and the function says why when it is missing: a contra reversed '
  'without a reason is a set-off nobody can account for afterwards. '
  'Refuses one already void. Both invoices and bills go back to '
  'standing on their own.';

comment on function public.cancel_pdc(uuid, text) is
  'Hands a post-dated cheque back to whoever wrote it, before it has '
  'been banked. Only a cheque still `held` can be cancelled: one '
  'already deposited is with the bank and its fate is the bank''s to '
  'report, not ours to decide. The reason is required. Any journal '
  'raised for it is reversed.';

comment on function public.clear_pdc(uuid, date, uuid) is
  'Records that a post-dated cheque actually cleared, which is the '
  'moment it stops being a promise and becomes money: the bank balance '
  'moves and the receivable or payable is discharged. Accepts a cheque '
  'that is `held` or `deposited` and nothing else. The bank account, if '
  'given, is checked against the cheque''s own company -- it was once '
  'org-checked only in the lookup that resolves the ledger account, '
  'while the balance update and the cheque row used it raw.';

comment on function public.cancel_stock_transfer(uuid) is
  'Cancels a transfer between warehouses. DRAFT ONLY: once a transfer '
  'is sent, stock has physically left one shelf, and cancelling would '
  'leave that stock nowhere. Reverse the movement instead. Needs the '
  '`inventory` module.';

comment on function public.cancel_landed_cost_run(uuid) is
  'Cancels a landed-cost run -- freight, duty and handling being spread '
  'across the items on a shipment. DRAFT ONLY: once applied, those '
  'costs are inside what each item is carried at, and every sale since '
  'has taken its cost of sales from that figure. Needs the `inventory` '
  'module.';

comment on function public.reopen_bank_reconciliation(uuid) is
  'Reopens a completed bank reconciliation. Refuses if the SAME ACCOUNT '
  'has been reconciled again to a later statement date, naming that '
  'date and saying to reopen it first -- reopening an earlier one would '
  'release lines the later one was closed over, and that later '
  'reconciliation balanced against having them. Nothing about the '
  'matching itself is undone: the lines go back to matched-but-unclosed, '
  'which is what they were a moment before it was completed. Needs '
  '`can_post`.';

-- ---------------------------------------------------------------------
-- Access, taken away
--
-- Each of these turns off a link somebody outside this system is
-- holding. What matters is what the holder sees next, and what the
-- company keeps.
-- ---------------------------------------------------------------------

comment on function public.revoke_document_share(uuid) is
  'Turns off every share link for one sales document at once, and '
  'returns how many it turned off. A link already sent stops working '
  'immediately: `open_shared_document` answers with the state '
  '`revoked` and no document. The record of who opened it and when is '
  'kept -- revoking removes the access, not the evidence of it. Needs '
  '`can_write`.';

comment on function public.revoke_ticket_share(uuid) is
  'Turns off every share link for one support ticket, returning the '
  'count. The customer''s link stops opening and stops accepting '
  'replies. The conversation itself is untouched; what goes is the way '
  'in. Needs the `ticketing` module.';

comment on function public.revoke_customer_portal(uuid) is
  'Turns off a customer''s standing portal link -- the one that shows '
  'them everything outstanding rather than a single document. Their '
  'invoices, payments and documents are all unaffected: what ends is '
  'their ability to look at them without being chased. Needs '
  '`can_write`.';

comment on function public.revoke_payslip_access(uuid, text) is
  'Withdraws an employee''s approved access to their own payslips, with '
  'a note saying why. Only an APPROVED request can be revoked -- a '
  'pending one is declined, not revoked, and the two read differently '
  'to the person waiting. Needs `can_admin`, not merely `can_write`: '
  'payslip access is the company''s own people''s pay.';

comment on function public.detach_company_from_firm(uuid) is
  'Ends the appointment between a company and the accounting practice '
  'keeping its books, and returns how many memberships it removed. '
  'EITHER SIDE MAY END IT -- the company''s administrator or the firm''s '
  'partner -- because an appointment only one party can end is not an '
  'appointment. Removes exactly the memberships the attachment created: '
  'somebody from the practice whom the client separately invited on '
  'their own account keeps their place, because that was never the '
  'firm''s doing.';

-- ---------------------------------------------------------------------
-- Credentials, deleted
--
-- These remove a secret this company gave us to act on its behalf. The
-- question each one has to answer is whether the feature behind it is
-- switched off too, and they do not all answer the same way.
-- ---------------------------------------------------------------------

comment on function public.clear_ocr_credentials(uuid, text) is
  'Removes a company''s own document-scanning key and SWITCHES SCANNING '
  'OFF in the same call. The second half is the point: leaving the '
  'company switched on with a key that is gone would turn a deliberate '
  'removal into a run of failed scans, which reads as a broken feature '
  'rather than a decision somebody made. Needs `can_admin`.';

comment on function public.clear_einvoice_credentials(uuid, text) is
  'Removes a company''s MyInvois credentials for one environment -- '
  'sandbox or production -- so nothing further is submitted with them. '
  'Unlike `clear_ocr_credentials` this does NOT switch e-Invoicing off; '
  'the company''s LHDN settings stay as they are and submissions will '
  'fail for want of a key until new ones are set. Documents already '
  'submitted and validated are LHDN''s records and are unaffected. '
  'Needs `can_admin`.';

comment on function public.clear_org_payment_gateway(uuid, text, text) is
  'Removes a company''s own acquirer credentials for one gateway in one '
  'mode, live or test. Customers stop being offered that gateway on a '
  'shared invoice -- `shared_payment_options` returns only gateways '
  'that are configured and active with a settlement account. Payments '
  'already taken are unaffected; what ends is the ability to take more. '
  'Needs `can_admin`.';

comment on function public.clear_ai_credentials(uuid, text) is
  'Removes a company''s own key for one AI provider. The assistant '
  'falls back to the platform''s key where one is configured, so this '
  'is "stop billing us for it" rather than necessarily "switch it off". '
  'Needs `can_admin`.';

comment on function public.clear_platform_ai_key(text) is
  'Removes the PLATFORM''s key for one AI provider -- ours, not a '
  'tenant''s. Every company relying on the platform key rather than its '
  'own loses the assistant at once. Needs a platform administrator, '
  'which is a different question from being an administrator of any '
  'company.';

-- ---------------------------------------------------------------------
-- Put back in play
--
-- The other half of "undo": not taking something away, but returning
-- something to a state it was in before. Each of these has one decision
-- in it — WHERE it comes back to — and each answers differently.
-- ---------------------------------------------------------------------

comment on function public.reopen_lead(uuid) is
  'Puts a lost lead back in play. Returns it to CONTACTED rather than '
  'to new, because somebody did speak to them and pretending otherwise '
  'loses the only thing the record knew. Refuses a lead that is not '
  'lost. Needs `can_write`.';

comment on function public.reopen_opportunity(uuid, uuid) is
  'Puts a closed deal back in play, at the stage given or the one it '
  'was working in. Never at the stage it DIED in: that is a closed '
  'column, and a deal sitting in it would read as closed again. Falls '
  'back to the first open stage when neither is available, and refuses '
  'if the pipeline has no open stage at all. Refuses a deal already '
  'open. Needs `can_write`.';

comment on function public.reopen_project(uuid) is
  'Makes a closed project active again so time and cost can be booked '
  'to it. Refuses one already open. Needs `can_post` rather than '
  '`can_write` -- a reopened project is somewhere the ledger can be '
  'told to put money.';

comment on function public.reopen_appraisal(uuid, text) is
  'Reopens one half of an appraisal -- `self`, `manager` or `final` -- '
  'by clearing that half''s submission stamp, which is what the guard '
  'reads when it refuses a change. NOTHING WRITTEN IS ERASED: the '
  'author comes back to their own words and edits them rather than '
  'starting from a blank box. Any other side name is refused. Needs '
  '`can_manage_hr`.';
