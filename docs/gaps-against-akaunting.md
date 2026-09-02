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

Every gap below started in that second category. That was the finding,
and most of them have since closed.

## What is still open

The short answer, so nobody has to reach it by scrolling. Everything
else on this page has been built, and the sections say where.

- **No ringgit has been through the payment flow.** It is built end to
  end and there is no acquirer sandbox in the environment it was built
  in, so it has never been exercised against a real gateway. Section 3.
- **Configurable dashboards**, **split transaction**, **bulk actions**
  and an **in-app notification centre**. Section 10.

That is the whole of it. This document has repeatedly been left saying
a thing was missing for months after it was built — sections 1, 2 and 9
each did, and section 2 did it twice: it claimed the shareable link was
missing when `0067` had built it, and then claimed the portal was
missing while `0493` was building it. So the list above is the part to
distrust first if it has not been re-queried lately.

## 1. Getting a document to the customer

~~Nothing ever leaves the system.~~ Closed, and it was the largest gap
on this list when it was written. What it said then — "no mail in
`supabase/functions`, no send action in the app, no SMTP configuration,
nothing" — stayed on the page long after it stopped being true, which
is the failure this document warns about in its last paragraph and had
not applied to its own first section.

Built: `email_outbox` with a dedupe key and a retry count,
`send-email` sending through Resend, `email_document` and
`email_receipt` from the app with a choice of queueing or sending now,
a per-document log of what went where, and `email_templates` letting a
company override the wording per template code over
`app.default_email_template`. `queue_overdue_reminders` chases an
overdue invoice on the days that company chose, from the daily pass.
`receive-email` handles the inbound direction, which Akaunting does
not do at all.

The same machinery now carries the platform's own subscription
invoices to its tenants — `0490` sends the bill, `0491` chases it and
confirms the payment — which is the clearest sign it is real rather
than demonstrated once.

## 2. The shareable link, and the account behind it

Two different things, and this section used to treat them as one — then
as one built and one open. Both are built now.

**The signed link**, since `0067`. `issue_share_token` and `share_url`
point the mechanism at a sales document, so somebody with the link
views the invoice and pays it with no account at all — which is what
`routes/signed.php` does in Akaunting.

**The account**, since `0493`. `routes/portal.php` gives a customer a
*login*; this gives them a scoped token, which is the same answer to
the same question without putting people who are not staff into
`auth.users` — every RLS policy in this database assumes an
`auth.uid()` belongs to a member of an organization, and a customer
account would undermine all of them. `open_customer_portal` answers
with every invoice still owed, what each owes, the total and which are
overdue; `portal_document_token` hands off to `0067`'s page for the one
they tap, so there is one renderer and one place the total can be
wrong. The page is `/account/:token` and the company issues and revokes
it from the contact.

Where Akaunting is still ahead, and it is narrow: their portal is a
durable identity — a customer who loses the email can reset a password
and get back in. Ours is a link, and a customer who loses it has to ask
for another. That is a deliberate trade and not an oversight, but it is
a difference and this section should say so rather than claim parity.

`0494` is worth reading beside this: `share_customer_portal` emailed
the *document* route for its first two commits, so every portal link
sent led to a page saying the link was invalid. Nothing caught it —
both halves were written from the same assumption, the routes live in
the Flutter app where the database cannot see them, and the test
extracted the token with a pattern happy with either path. It was found
by going to build the page it should have opened.

## 3. Taking payment from a tenant's customer

Akaunting has offline payment methods, gateway apps, a
`Portal/PaymentReceived` notification and a confirm/finish flow on the
signed invoice route. A tenant of iAkauntan still records payments only
after they have happened somewhere else. For Malaysia this would be FPX
or DuitNow.

**The distinction matters, and this section used to blur it.** iAkauntan
*does* now have gateway machinery: `payment_gateways` carries ten
Malaysian acquirers (Billplz, toyyibPay, Bayarcash, CHIP, senangPay,
iPay88, Fiuu, eGHL, Revenue Monster, Curlec), there is an admin screen
behind the platform console, and `billplz-checkout` and
`billplz-callback` are deployed edge functions with assertions in
`gateway_payments.sql`.

All of it serves **`platform_invoices`** — iAkauntan billing its own
subscribers. `billplz-checkout` says so in its own header and reads no
other table, checked rather than remembered. Nothing on a tenant's
`sales_documents` reaches it, and `open_shared_document` gives a
customer a document to read and no way to pay it.

So the user-facing gap was exactly as open as it was. What had changed
was the size of the job: the acquirer list, the checkout/callback shape,
the signature verification and the idempotency were all built and
exercised once. What was missing was per-organization gateway
credentials, a pay route on the shared invoice link, and a receipt
posted to the ledger when the callback confirms.

**Two of the three are now built.** `0412` gives an organization its own
acquirer credentials, held the way `0107` holds the LHDN ones — RLS with
no policies, every client grant revoked, a status function that never
returns a secret. `0413` gives the shared invoice link a way to pay:
`shared_payment_options` tells the person holding the link which
acquirers the shop can actually settle through, `begin_shared_payment`
opens a pending payment for **the balance on the document and never an
amount the caller chose**, and `settle_shared_payment` posts a receipt
through `app.post_receipt_internal` — so the money comes off the
receivable and lands in the bank account the shop nominated, by the same
door a receipt keyed in by hand uses. `shared_invoice_payment.sql` has
58 assertions on it, including the retry, the short payment, and the
invoice that was settled by bank transfer while the acquirer was still
thinking.

**The third is the acquirer call**, and `0414` with `pay-invoice` and
`pay-invoice-callback` is it. A shop enters its Billplz credentials on
the Settings screen and nominates the account its takings land in; a
customer holding an invoice link gets a Pay button; the callback is
verified against **that shop's** X Signature key — found from the
reference in the unverified body, which selects a key and decides
nothing — and `settle_shared_payment` posts the receipt.

**What has not happened is a payment.** There is no acquirer sandbox in
the environment this was built in, so what is asserted is everything
either side of the HTTP: the token check, the pending row, the
signature verification (whose own assertions run in CI), the five
settlement outcomes, the receipt and the ledger. The call itself is
`createBillplzBill`, the helper `billplz-checkout` has been using
against real bills, with the tenant's key instead of the platform's.
Section closed as far as code goes; a first live ringgit is still a
thing somebody has to do.

## 4. The reports, including the two statutory ones

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

## 5. Recurring documents

`app/Models/Common/Recurring.php` is polymorphic — `recurable_type` —
so an invoice, a bill or a transaction can recur, with `auto_send` and
`limit_by` (never, by date, or by count).

Built — `recurring_documents`, for invoices and bills. The schedule
holds a snapshot of a real document rather than a pointer to one, so
editing the document it was made from does not silently change next
month's billing. `limit_by` is an end date or a number of occurrences,
either or neither. The nightly run catches up rather than raising one
document per run, and posts through the same code a person does.

## 6. Bank-to-bank transfer

Built — `bank_transfers`, one document with both ends on it. Sent,
received and the fee are three separate figures that have to reconcile,
which handles either place the bank took its cut from and catches a
typo. Across currencies the residual is realised exchange; in one
currency it is refused. Voiding reverses rather than deletes.

Finding the cash flow statement already treats it correctly — both ends
are cash, so a transfer moves nothing — is what the test asserts, since
a transfer that inflated operating cash would flatter every set of
accounts filed.

## 7. Import

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

The opening trial balance is built too, in 0151 —
`import_opening_balances`, on the same screen. Its one real decision is
what to do about the control accounts: an old system's trial balance
lists Accounts Receivable as a single figure, and the open invoices have
already posted it customer by customer. Posting it again doubles the
receivables; leaving it out of the file throws away the most useful
number in a migration. So it stays in the file, is **not** posted, and is
**compared** — and the residual then goes to 3900, which lands on zero
exactly when the two halves agree. A disagreement is reported as a
warning naming both figures, and does not block the import: the
difference is what 3900 is then left holding, and
`report_opening_balance_suspense` says so.

Opening stock is built, in 0152 — `import_opening_stock`, the last of
the six on that screen. Quantities and a cost per unit, per warehouse
and per batch or serial where an item is tracked that way. It writes
stock movements, which is what gives every item a quantity on hand and a
weighted average cost, and it posts **no journal at all** — the
inventory figure came in with the trial balance and posting it again
would double it, the same reasoning the control accounts follow above.
What it does instead is compare its own value against the inventory
accounts and report the difference, adjusting neither: writing off stock
nobody has looked at is not a thing an import should do on its own.

One thing had to change underneath it. `app.materialise_movement_lots`
reads lots off a document line, and an opening balance has no document,
so the trigger now stands aside for `source_table = 'opening_stock'` and
the importer names the batches itself. Everything else that trigger
refuses, it still refuses.

So the opening position is complete: contacts, items, open invoices,
open bills, the trial balance, and stock.

0153 adds the thing six importers on one screen needed and did not have
— `report_migration_progress`, the order they must be done in with what
is there for each, and the balance of 3900 as the only line that can say
the job is finished. Counts rather than ticks: for four of the six there
is no honest "done", because a firm with no stock has finished that step
by having nothing to bring across.

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
and the one-month deadline.

**Compound tax needs saying more carefully than "still not there",**
which is what this line said until the code moved under it. There is
still no general mechanism: no `is_compound` on `tax_codes`, nothing
that lets a shop declare that one tax computes on a base including
another. Grepped, not recalled — the only `is_compound` in the tree is
inside `0410`'s own header, arguing this point.

But the single form compounding actually takes in this country is
built. A Malaysian restaurant bill charges service tax on the food
*plus* the ten per cent service charge — 8% of 110.00, not of 100.00 —
and `0410` gives the outlet, the sale and the document a service charge
and taxes it that way. `pos_service_charge.sql` asserts the identity
rather than the number, and the chain is followed the whole way out:
`0415` to the e-Invoice, `0418` to the SST-02 return, and the invoice
PDF the customer receives.

So the accurate statement is that the general tax type is absent and
the specific compound is present and asserted. A reader deciding
whether a Malaysian restaurant can be billed correctly needs the second
half, and the flat sentence hid it.

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

## 9. Permissions

Akaunting seeds per-resource permissions
(`database/seeds/Permissions.php`) and composes roles from them.

~~iAkauntan has a fixed role set behind `can_post`, `can_write`,
`can_admin` and `can_manage_hr`. Adequate until somebody wants "sees
purchases, not payroll".~~ Closed at `0127` and `0129`: `access_types`
and `access_type_modules` compose what a person may reach, the Team
screen edits it, and `app.module_access` answers per person as well as
per company — so exactly "sees purchases, not payroll" is now
expressible. The Order section below has said so for some time while
this section went on saying the opposite.

## 10. Smaller

- **Split transaction** — one payment divided across several accounts.
- ~~**Per-document history.** `Document/DocumentHistory.php` gives an
  invoice its own timeline. iAkauntan has `audit_logs`, a global trail
  that answers a different question — "who changed what" rather than
  "what happened to this invoice".~~ Closed at `0495`. It was narrower
  than this said: `document_activity` had shown one document's emails,
  share links and downloads since `0082`, so what was missing was not a
  timeline but three sources on it. `0495` unions in the document's own
  changes from `audit_logs` — read on the `(table_name, record_id)`
  index `0038` built for exactly that and which nothing had ever used —
  the money allocated against it, and what LHDN said. Nothing new is
  recorded; all of it was already being written and none of it read.
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
master files — and so, now, is the whole opening position: the open
invoices and bills, the trial balance that squares them off, and the
stock behind the inventory figure. Together they are what makes moving
onto this system mid-year possible at all. Compound tax closed at
`0410`, in the shape a Malaysian bill actually has one, and taking
payment at `0412`–`0414` — with the caveat above, which is that no
ringgit has yet gone through it.

What is left is listed at the top of this page rather than here, which
is the change this revision makes to the shape of the document: the
answer to "what can it not do" was previously only reachable by
reading to the end, and the beginning said things that had been false
for months.

**Granular permissions closed** — `access_types` and
`access_type_modules` in `0127`, who holds which one in `0129`, and the
editor on the Team screen. `app.module_access` answers per person as
well as per company, so a member can be let into purchasing and kept out
of sales. This line listed it as open until `6207faa`, and section 9
went on contradicting this line until the revision that added the
summary at the top.

The other two were "confirmed open by querying for them rather than by
memory", and one of them has since stopped being true in the form it was
written. Re-queried at `0404`:

- ~~**Compound tax is still absent.**~~ Closed at `0410` and `0411`, in
  the form it actually takes in this country. `is_compound` still
  appears nowhere, and does not need to: a Malaysian bill compounds in
  exactly one place — "subject to 10% service charge and 8% service
  tax", where the service tax is charged on the amount that already
  includes the charge. The schema had no service charge at all, on the
  outlet, the sale or the document, so a restaurant could not produce a
  correct bill and every part of the food and beverage module sat on a
  total that was ten per cent plus the tax on it short. The outlet now
  carries the percentage and the tax code that rides it, the charge
  posts to `4250`, and the receipt prints it above the tax line with
  the percentage on it. `pos_service_charge.sql` asserts the worked
  example — 100.00 food, 10.00 charge, 8.80 tax, 118.80 total — and the
  identity behind it rather than the number.
- **"No payment gateway of any kind — no Billplz, no ToyyibPay, no
  Stripe" is now false as a statement about the codebase.** Ten
  acquirers are registered and four payment edge functions are deployed.
  This bullet used to end by saying that what the sentence was *for* was
  still true — the gateways settled **platform** invoices and a tenant's
  customer still could not pay a sales invoice online. That half has
  since gone stale in its turn: `0412` to `0414`, `pay-invoice` and
  `pay-invoice-callback` built the tenant side, and section 3 has said
  so for some time while this line went on saying the opposite. The
  document contradicted itself, and the stale half was the one a reader
  reached last.

  What remains true, and section 3 states it precisely, is narrower than
  what this line claimed: no ringgit has been through the flow, because
  there is no acquirer sandbox in the environment it was built in.

The lesson is the one this document already states about itself. A gap
register is only worth reading if it is re-queried, because the thing it
describes gets built underneath it and the sentence stays where it
was.
