# SST-02: what the return has to do, and what has to be confirmed first

**Status:** design note. No migration, no code. Written because
`docs/audits/autocount-gap-matrix.md` ranks this second and calls it the
only large item with a statutory deadline behind it, and because the
handoff that produced that matrix says a design pass comes first.

**Do not code a figure out of this document.** Section 4 lists what
could not be verified from this machine and has to be read from the Act
and the current RMCD guide before anything is committed.

---

## 1. What is wrong today, verified at source

`public.report_sst_summary(org, from, to)` — added by `0014`, corrected
by `0278` — is what an SST-02 is filled in from. It is a good report and
it is an **invoice-basis** report:

```sql
where d.org_id = p_org_id
  and d.doc_type in ('invoice', 'credit_note', 'debit_note', 'refund_note')
  and d.status not in ('draft', 'void')
  and d.doc_date between p_from and p_to
```

`0278` fixed a real defect there — credit notes were not counted, so the
return overstated the tax due and a company paid Customs money it did
not owe — and its reasoning is the right one: *the same document types
that post, with the same signs, so the return and the accounts cannot
disagree.*

That reasoning is exactly why the remaining problem matters. **Sales tax
is accounted for on an invoice basis and service tax is not.** One
report, one date filter, two taxes with different rules.

Three things follow, and all three are visible in the schema rather than
inferred:

- **`tax_codes` has no basis.** Columns are `code`, `name`,
  `tax_type_code`, `rate`, `is_inclusive`, `applies_to`,
  `sales_tax_account_id`, `purchase_tax_account_id`, `is_exempt`,
  `exemption_reason`, `is_default`. Nothing distinguishes a code that
  falls due on invoice from one that falls due on payment.
  `ref_tax_types` knows `01 Sales Tax` from `02 Service Tax`, so the
  *type* is there; the *consequence* is not.
- **`sst_returns` records a figure, not a return.** Columns are
  `period_start`, `period_end`, `due_date`, `tax_declared`, `reference`,
  `filed_at`, `filed_by`. There is no `status`, so nothing separates a
  draft from a committed return; and no `journal_id`, so committing a
  return posts **nothing** to an SST control account and the liability
  never leaves the output tax account.
- **Nothing tracks unpaid service tax.** There is no view of service tax
  on invoices that have been outstanding for approaching twelve months,
  which is the report a company needs before it becomes payable anyway.

**The consequence, stated plainly: a company that files what
`sst_returns.tax_declared` holds today is filing an invoice-basis number
for both taxes.** For a service-tax registrant with customers who pay
late, that is tax paid before it is due — the error runs against the
taxpayer, which is why it has not been noticed.

---

## 2. What the return has to do

Structure only. Every rate, threshold and box number is section 4's
problem.

### Sales tax — invoice basis

What `report_sst_summary` already does. Taxable sales in the period,
less credit notes, at the rate on the line. Nothing here changes.

### Service tax — payment basis, with a long stop

The design assumes the following, **which must be confirmed** (§4):

1. Service tax is due when **payment is received**, not when the invoice
   is raised.
2. Where payment has **not** been received within twelve months from the
   date of the invoice, the tax becomes due on the day immediately after
   that twelve-month period.

Both halves matter and the second is the one a naive implementation
misses. A return that only counts receipts will understate the liability
of a company whose customers do not pay, for ever.

So the period figure for service tax is, structurally:

```
service tax due in the period
  = tax on payments RECEIVED in the period against service-tax invoices
  + tax on service-tax invoices whose twelfth month ENDED in the period
    and which were still unpaid at that moment
  - tax on credit notes … (see the open question in §4)
```

The data to compute the first line already exists: `payment_allocations`
links a receipt to an invoice with an `amount`, and
`sales_document_lines` carries `tax_code_id` and `tax_amount` per line.
A part payment carries a proportion of the tax; the proportion has to be
taken against the invoice's own total, not against the outstanding
balance, or two part payments will not sum to the whole.

The second line needs no new data either — an invoice's date and its
allocations are enough — but it needs a **date** to be computed as at,
and that is why it cannot be a report alone.

### Committing

A return that is committed should post a journal moving the period's
output tax and input tax balances to an SST control account, so that
what is owed to Customs sits in one place and can be paid from it. That
is the step that turns a report into a liability, and it is why
`sst_returns` needs a `status` and a `journal_id`.

The posting must be idempotent and reversible in the way this schema
already does both: `0307`'s idempotency key for the first,
`void_sales_document`'s shape for the second.

---

## 3. The shape, if the assumptions in §2 hold

Not a migration. A sketch to argue with.

```
tax_codes
  + basis text not null default 'invoice'
      check (basis in ('invoice', 'payment'))
```

One column, defaulted so nothing existing changes, and set to
`'payment'` for service-tax codes by the same migration — which is a
**data decision about live companies' tax codes** and must be made
deliberately rather than by a blanket update on `tax_type_code = '02'`.

```
sst_returns
  + status text not null default 'draft'
      check (status in ('draft', 'committed'))
  + journal_id uuid references gl_entries (id)
  + sales_tax_due numeric(18,2)
  + service_tax_due numeric(18,2)
  + committed_at timestamptz, committed_by uuid
```

Split by tax rather than one `tax_declared`, because the SST-02 asks for
them separately and a single number cannot be checked against either.

```
app.service_tax_due_in(org, from, to)     -- receipts + the twelve-month long stop
public.report_sst_return(org, from, to)   -- both taxes, the way the form wants them
public.report_service_tax_unpaid(org, as_at) -- approaching the long stop
public.commit_sst_return(id)              -- posts the journal, sets the status
```

`report_sst_summary` **stays**, unchanged, and keeps its callers. It is
a correct invoice-basis summary and it is what the SST summary screen
shows today; replacing it in place would be a silent change of meaning
on a screen somebody already trusts.

### What the tests have to assert

Following `CLAUDE.md`: anything touching a statutory figure needs a test
that fails when the number moves.

- A service-tax invoice raised in one period and paid in the next falls
  in the **second**.
- A part payment carries a proportion of the tax, and two part payments
  sum to the whole invoice's tax — to the sen.
- An invoice unpaid at its twelfth month falls due in the period
  containing that day, and **does not fall due again** when it is later
  paid.
- A sales-tax invoice is unaffected by any of it.
- Committing posts a journal; committing twice does not post two.
- The period figures and `report_sst_summary` agree for a company whose
  customers pay immediately, and are permitted to differ for one whose
  customers do not — the second assertion is what proves the first is
  not vacuous.

---

## 4. What could not be verified from this machine

`mysst.customs.gov.my` and `www.customs.gov.my` are refused at CONNECT
by this environment's network policy — `gateway answered 403 to CONNECT
(policy denial)`, not a timeout and not a DNS failure. npm and PyPI are
reachable and carry nothing: a search for "SST-02 malaysia" returns the
SST serverless framework and a postcode list.

So the following are **assumptions, not facts**, and every one has to be
read from the Service Tax Act 2018, the Sales Tax Act 2018 and the
current RMCD guides before a line of this is coded:

1. **That service tax is due on payment**, and the section that says so.
   The design above assumes Service Tax Act 2018 s.11.
2. **The twelve-month long stop**, its exact trigger (date of invoice
   versus date of supply) and the day it falls due.
3. **What a credit note does on a payment basis.** An invoice-basis
   credit note reduces the period it falls in. On a payment basis, a
   credit note against an invoice that was never paid has no tax to
   reverse, and one against an invoice already paid does. This is the
   open question most likely to be got wrong.
4. **The SST-02 box numbers and layout**, which the print has to mirror.
5. **The current rates and their effective dates.** Sales tax and
   service tax rates and the scope changes of 1 July 2025 are widely
   reported and **none of them was read from a primary source here.**
   They belong in a dated rate table with a test, the way
   `supabase/tests/statutory.sql` holds the EPF, SOCSO, EIS and PCB
   figures, and they must be entered from the gazette rather than from
   this document.
6. **Whether a company can be registered for one tax and not the other**
   in a way the return has to reflect. `0145` already knows the two
   registrations are separate; whether the return is one form or two is
   not established here.

**A company filing on figures derived from an unverified reading of the
Act is worse off than one filing on the invoice-basis number it has
today, because it will believe the number.** That is the reason this is
a design note and not a migration.

---

## 5. Suggested order

1. **Confirm §4.** Nothing below starts before it.
2. `tax_codes.basis`, defaulted, with the data decision made explicitly
   per company rather than by a blanket update.
3. `app.service_tax_due_in` and `report_service_tax_unpaid`, as reports
   only — no posting, no schema on `sst_returns`. This is useful on its
   own: a company can see what it will owe and what is approaching the
   long stop, and it can be checked against the period the old summary
   reports.
4. `sst_returns.status` and `journal_id`, and `commit_sst_return`.
5. The SST-02 print and the supporting listings.

Steps 3 and 4 are the line between "reads the ledger" and "changes it",
and they should be separate commits for the same reason `0625` suggests
a bank coding and refuses to post one.
