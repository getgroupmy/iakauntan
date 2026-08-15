# What Akaunting has that iAkauntan does not

Read against `akaunting/akaunting` at 3.2.2 (commit `fb67f93`), a Laravel
accounting application under BUSL-1.1. Not a feature checklist — the
question is what a user can do there and cannot do here, and whether it
matters.

## Where the two products actually stand

Akaunting's core has **no chart of accounts and no general ledger**.
`app/Models/Banking/Account.php` is bank accounts; the six reports in
`app/Reports/` — ProfitLoss, IncomeSummary, ExpenseSummary,
IncomeExpenseSummary, TaxSummary, DiscountSummary — all run off
*categories*, not a ledger. Double-entry is sold as a marketplace app.

So the comparison is lopsided in both directions. iAkauntan is far ahead
on accounting depth (a real ledger with period control, MyInvois,
payroll and statutory deductions, corporate secretarial, FX
revaluation, fixed assets, inventory costing, RLS-enforced
multi-tenancy). Akaunting is ahead on **everything that happens after a
document exists**: getting it to the customer, getting money back, and
getting data in.

Every gap below is in that second category. That is the finding.

## 1. Nothing ever leaves the system

There is no email anywhere in iAkauntan. No mail in `supabase/functions`,
no send action in the app, no SMTP configuration, nothing.

Akaunting has:

- eleven seeded templates in `database/seeds/EmailTemplates.php`
  (`invoice_new_customer`, `invoice_remind_customer`, `invoice_recur_customer`,
  `invoice_payment_customer`, `bill_remind_admin`, `payment_received_customer`
  and the rest), each editable from `settings/email-templates`;
- `app/Console/Commands/InvoiceReminder.php` and `BillReminder.php`, run
  on a schedule;
- a notification to the admin when a customer *views* an invoice.

iAkauntan builds a PDF and the user downloads it. Nobody is ever chased
for payment. `balance_amount`, `due_date` and the `iakauntan-daily` cron
already exist, so the reminder logic is nearly free — the mail transport
is the work, and it needs a provider and a secret.

**This is the largest gap on the list.**

## 2. No customer portal, and no shareable invoice link

`routes/signed.php` lets somebody with a signed URL view, print,
download and **pay** an invoice with no account at all.
`routes/portal.php` gives a customer a login where they see their own
invoices and payments.

iAkauntan already built this mechanism — `corp_signing_links`, scoped
tokens for people who are not staff — and never pointed it at an
invoice.

## 3. No payment collection

Akaunting has offline payment methods, gateway apps, a
`Portal/PaymentReceived` notification and a confirm/finish flow on the
signed invoice route. iAkauntan records payments only after they have
happened somewhere else. For Malaysia this would be FPX or DuitNow.

## 4. Missing reports, two of them statutory

- ~~**Aged receivables and aged payables.**~~ Built — `report_ar_aging`
  and `report_ap_aging`, as at a date rather than as of now, footing to
  the receivable and payable control accounts. Both listings carry the
  credits, which is what makes them foot.
- ~~**Statement of cash flows** and **statement of changes in equity**.~~
  Built — `report_cash_flow` (indirect method) and
  `report_changes_in_equity`. Both are derived from the ledger rather
  than classified by hand, and both are asserted against something
  outside themselves: the cash flow against the movement in the bank and
  cash accounts, the equity statement against net assets on the balance
  sheet. With these, the set of financial statements MFRS 101 and MPERS
  Section 3 ask for is complete.

## 5. Recurring covers journals only

`app/Models/Common/Recurring.php` is polymorphic — `recurable_type` —
so an invoice, a bill or a transaction can recur, with `auto_send` and
`limit_by` (never, by date, or by count).

Built — `recurring_documents`, for invoices and bills. The schedule
holds a snapshot of a real document rather than a pointer to one, so
editing the document it was made from does not silently change next
month's billing. `limit_by` is an end date or a number of occurrences,
either or neither. The nightly run catches up rather than raising one
document per run, and posts through the same code a person does.

## 6. No bank-to-bank transfer

Built — `bank_transfers`, one document with both ends on it. Sent,
received and the fee are three separate figures that have to reconcile,
which handles either place the bank took its cut from and catches a
typo. Across currencies the residual is realised exchange; in one
currency it is refused. Voiding reverses rather than deletes.

Finding the cash flow statement already treats it correctly — both ends
are cash, so a transfer moves nothing — is what the test asserts, since
a transfer that inflated operating cash would flatter every set of
accounts filed.

## 7. Import is bank statements only

Contacts and items are built — `import_contacts` and `import_items`,
with the header row mapped onto field names so a file exported from
another system does not have to be renamed first. Nothing is written
unless every row is good, and the same call previews and imports, so the
preview cannot promise something the import then refuses.

Open invoices and bills are built too, in 0150 — `import_open_invoices`
and `import_open_bills`, on the same screen and under the same rule that
nothing is written unless every row is good. The four decisions this was
waiting on were settled as:

- **numbering** — the old system's, kept exactly, because that is the
  number a customer quotes when they pay;
- **tax** — none, because the SST was declared under the old system and
  putting it in the tax account again would put it in this system's
  return again;
- **the other side of the entry** — `3900 Opening Balance Equity`,
  created on demand, whose remaining balance is the migration's own
  error check (`report_opening_balance_suspense`);
- **the date** — two of them. The document keeps the day it was raised
  so the ageing is right; the ledger entry is dated at the changeover so
  the trial balance moves once.

What is imported is the *outstanding* amount, not the original total.
Anything already collected stays in the old system, which is where
anybody asking about it will look.

Still missing: opening stock quantities and the opening trial balance
itself. Both leave a balance in 3900 until they are brought across,
which is exactly what that account is for and what the suspense report
reports.

## 8. Withholding and compound tax

Akaunting's tax types are normal, inclusive, compound, fixed and
withholding (`app/Models/Setting/Tax.php`). `tax_codes` here carries
`rate` and `is_inclusive` and stops.

Withholding is built — `ref_withholding_types` carries the eight
sections and their statutory rates, and a certificate is modelled as a
settlement rather than a tax code: it debits the payable, credits
`2145 Withholding Tax Payable` and writes a `payment_allocations` row,
so the bill shows what the supplier will actually be paid and the aged
listing still foots. `supabase/tests/withholding.sql` asserts every rate
and the one-month deadline. Compound tax is still not there.

## 8b. Live currency

Built — `ingest_exchange_rates` takes Bank Negara's published quotes and
writes them as rows belonging to no organization, which
`app.exchange_rate_for` falls back to. The organization's own rate wins
for its own date and is never touched by the feed; a later published rate
beats an earlier typed one, because a rate entered on 1 March says what
the rate was on 1 March.

This was less a convenience than a hole. `revalue_foreign_balances`
refuses a currency it cannot price rather than assuming par — so with an
empty rate table the month-end revaluation did not fail, it did not
happen. `docs/exchange-rate-feed.md` has the deployment.

Crypto currency, the other half of that pair in Akaunting's marketplace,
is deliberately not built. Modelling it as a currency would route it
through `revalue_foreign_balances` into exchange gain and loss, and it is
not functional currency under MFRS — it is an intangible asset, or
inventory for a dealer, with disposals revenue in nature where trading is
habitual. It would produce accounts that foot and are wrong.

## 8c. Salesperson, and the vendor statement

Both built, and both were half-present already.

**Vendor statement** — the customer statement now runs either way round.
The two are not mirror images whatever the arithmetic says: a customer
statement is a demand, a supplier statement is what *our* books show we
owe, printed so somebody can hold it against the statement the supplier
sent and find the difference. The wording changes with the side; the
figures do not.

**Salesperson** — `sales_documents.salesperson_id` had been in the
schema since 0005 with no screen and no report. It did have a foreign
key, and it was the wrong one: it pointed at `auth.users`, so only people
with a login could be credited, and because `auth.users` is global it let
one organization's invoice name another organization's user with no
policy to catch it. `0105` repoints it at a `salespeople` table of its
own — org-scoped, optional links to an employee and to a member, so an
agent who never signs in can still be credited — and adds a trigger that
refuses a salesperson from another organization.

`report_sales_by_person` is invoices less credit notes, because paying
commission on a sale that was credited back out is paying twice for one
mistake, and it carries an explicit **unattributed** line, since the
sales nobody was credited with are the figure an argument will be about.
Commission is computed from the rate on file and **posted nowhere** —
whether it falls due on invoice, on payment or on margin is a policy
decision, and a figure accrued on a guess is worse than no figure.

## 8d. Serial numbers and batches

Built. `stock_movements` had carried `batch_no`, `serial_no` and
`expiry_date` since 0006 with nothing ever written to any of them — the
third dead column found in a week, and the wrong shape besides: one issue
of ten units can draw on three batches and a scalar column holds one.
They are dropped.

`items.tracking` is `none`, `batch` or `serial`, defaulting to none, so
nothing that exists changes. Turn it on and the detail stops being
optional — posting refuses a line that has not been broken down.

**It does not touch costing.** A serialised item still values at weighted
average. MFRS 102 permits weighted average and requires specific
identification only for items not ordinarily interchangeable, so tracking
here is identity — which unit, whose it was, when it expires — and not
value. Making serials cost-specific would restate figures already filed
and is separate work.

Numbers are typed on the **document line** before posting, because once a
movement exists the posting has happened and it is too late to ask
anybody anything. Posting itself was not reopened: it already writes
`source_line_id` onto every movement, so a trigger copies the allocation
across. Balances are derived from movements and never stored — the one
failure that would make this worse than useless is a recall list saying a
batch is on the shelf when it was sold last month.

Picking is first-expired-first-out, not first-in-first-out; for anything
with a shelf life those differ, and the difference is stock written off at
the back of the warehouse. `report_expiring_stock` includes what is
already past its date, because it is still there and still on the balance
sheet at cost. `trace_lot` answers the recall question in both
directions, which is the only thing that justifies making somebody type a
batch number on every receipt.

## 9. Coarse permissions

Akaunting seeds per-resource permissions (`database/seeds/Permissions.php`)
and composes roles from them. iAkauntan has a fixed role set behind
`can_post`, `can_write`, `can_admin` and `can_manage_hr`. Adequate until
somebody wants "sees purchases, not payroll".

## 10. Smaller

- **Split transaction** — one payment divided across several accounts.
- **Per-document history.** `Document/DocumentHistory.php` gives an
  invoice its own timeline. iAkauntan has a global audit trail, which
  answers a different question.
- **Configurable dashboards and widgets.** `Common/Dashboard.php`,
  `Common/Widget.php`, and eight widgets a user arranges themselves.
  iAkauntan's dashboard is fixed.
- **Bulk actions** across a list.
- **In-app notification centre** (`Common/Notification.php`).

## Order

1 and 2 belong together: email plus a signed invoice link is one
workflow, and it is the difference between a bookkeeping tool and a
business system. Both are built, and so is the aging, and so are
recurring invoices and bills, and so is withholding, and so are the two
statutory statements, and so is bank transfer, and so is importing the
master files — and so, now, are the open invoices and bills that make
moving onto this system mid-year possible at all. What is left: compound
tax, granular permissions, taking payment, and the rest of the opening
position (stock quantities and the opening trial balance).
