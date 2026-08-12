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

`Banking/Transfer.php` with its own create, update and delete jobs.
Moving money between your own accounts in iAkauntan means writing a
manual journal — possible since `0089`, but not what a bookkeeper
reaches for, and nothing records that the two sides are one movement.

## 7. Import is bank statements only

Akaunting imports customers, vendors, items, invoices, bills, categories
and transactions (`*/import` under `routes/admin.php`, with export to
match). iAkauntan parses a pasted bank statement and nothing else, so
migrating onto it means typing the customer list.

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
statutory statements. What is left is smaller: bank transfer, CSV
import, compound tax, granular permissions, and taking payment.
