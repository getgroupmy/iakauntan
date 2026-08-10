# iAkauntan

Accounting and CRM for Malaysian businesses, with LHDN e-Invoice (MyInvois)
built in. Flutter client for web, Android and iOS on a Supabase backend.

Modelled on what AutoCount and SQL Accounting do for the Malaysian SME
market — double-entry books, the full sales and purchase cycle, SST, and
inventory — with e-Invoice treated as part of the invoice lifecycle rather
than a bolt-on.

---

## What is here

```
app/                  Flutter client (web + mobile)
supabase/
  migrations/         Schema, RLS, business logic, reports  (0001 … 0044)
  functions/myinvois/ Deno edge function: LHDN MyInvois integration
```

**Supabase project:** `ewwcgtnniwqndrzukksm` (`iakauntan`, ap-northeast-2)
All migrations and the edge function are already deployed there.

---

## Accounting model

Everything posts through one entry point, `create_gl_entry()`, into
`gl_entries` / `gl_lines`. A deferred constraint trigger refuses to commit
an unbalanced journal, so the ledger cannot drift.

| Area | Covered |
| --- | --- |
| Sales | Quotation → Sales Order → Delivery Order → Invoice → Receipt, plus credit, debit and refund notes |
| Purchases | Purchase Request → PO → Goods Received → Bill → Payment |
| General ledger | Double entry, fiscal years and periods, period locking, journal reversal, recurring journals |
| Inventory | Weighted-average costing, multi-warehouse stock levels, stock takes, automatic COGS on posting |
| Banking | Bank accounts, statement lines, reconciliation, expense claims |
| CRM | Leads, pipelines, opportunities with stage history, activities |
| Reports | Trial balance, P&L, balance sheet, AR/AP ageing, stock valuation, SST summary |

Malaysian specifics: MPERS-aligned default chart of accounts, SST tax codes
(service tax 8% / 6%, sales tax 10% / 5%, exempt, zero-rated), and Bank
Negara 5-sen cash rounding applied to document totals.

### Verified end to end

A posted invoice of 2 lines (RM 17,900 net + 8% service tax) produced:

```
Dr  1210 Accounts Receivable   19,332.00
    Cr 4100 Sales                        17,900.00
    Cr 2130 SST Output Tax                1,432.00
```

A RM 10,000 part payment moved the invoice to `partial`, left a balance of
RM 9,332, and trial balance, balance sheet and P&L all agree.

Weighted-average costing was checked across a full cycle — buy 10 @ 1,200,
buy 10 @ 1,500 (average moves to 1,350), then sell 5, which posted:

```
Dr  5200 Cost of Goods Sold     6,750.00
    Cr 1310 Inventory                     6,750.00
```

leaving 15 units valued at RM 20,250. Supplier payments (with bank
charges) and expenses post correctly too.

---

## e-Invoice (LHDN MyInvois)

`prepare_einvoice()` freezes a posted document into `einvoice_documents` —
supplier and buyer snapshots, totals and lines — because LHDN validates
what was transmitted, not what the master data says today.

The `myinvois` edge function then handles the API side, routing on an
`action` field so the OAuth token cache stays warm:

| Action | Does |
| --- | --- |
| `submit` | Builds UBL 2.1 JSON, hashes it, submits the batch (≤100 docs) |
| `status` | Polls validation, stores the long ID and QR validation link |
| `cancel` | Cancels within LHDN's 72-hour window; refuses after it closes |
| `validate-tin` | Confirms a TIN matches a BRN/NRIC, cached 30 days |

Supported document types: 01 Invoice, 02 Credit Note, 03 Debit Note,
04 Refund Note, and the 11–14 self-billed equivalents. Item lines carry
the mandatory MyInvois classification code; all 45 are seeded, along with
state codes, tax types, payment modes and UN/ECE units of measure.

Every API call is written to `einvoice_logs` for the 7-year audit trail.

### Before you can submit

1. Register for MyInvois API access in the **MyTax portal** and get a
   client ID and secret.
2. Enter them in the app under **Settings → LHDN e-Invoice**. They are
   written to `einvoice_credentials`, which has RLS enabled and **no
   policies** — only the edge function's service role can read it.
3. Start in `sandbox`, switch to `production` when you are satisfied.

**Digital signature.** Documents are submitted as version `1.0`
(unsigned). Version 1.1 requires an XAdES signature from a Malaysian
certificate authority; `einvoice_credentials` has the columns to hold that
material, but the signing step itself is not implemented — you will need
your organisation's certificate before enabling it.

---

## Legal firm accounting (add-on)

For law firms, where client money is not the firm's money. Built to the
Solicitors' Accounts Rules:

- **Matters** — the file, with client, fee earner, rate and deposit
- **Client account** — a designated bank account, separate from office
  money, with every movement analysed by matter
- **Time recording** and **disbursements**, tracked as unbilled work in
  progress until a bill is raised

Client money posts as an offsetting asset/liability pair — client bank
against *Client Monies Held* — so it never touches income. A deferred
constraint trigger refuses any movement that would overdraw a matter:

```
Client account for matter MAT-2026-00001 would be overdrawn by 7500.00.
Client money held for one matter cannot fund another.
```

That is enforced in the database, not the UI, so it holds however the
row is written.

---

## HRMS

Two add-on modules: **hr** and **payroll**.

| Area | Covered |
| --- | --- |
| Core HR | Employees with the statutory identifiers payroll needs (EPF, SOCSO, LHDN file number, TIN), dependants, departments, positions, document expiry |
| Time & attendance | Shifts and rosters, clock-ins recording method, GPS position, device and biometric terminal, overtime split by Employment Act multiplier |
| Leave | Types with entitlement and carry-forward, requests that hold against the balance while pending, approvals |
| Claims | Expense claims reimbursed through payroll or posted to the ledger |
| Payroll | EPF, SOCSO, EIS, PCB, HRD Corp levy, zakat; posting to the GL; year-to-date carried forward |
| Talent | Requisitions, applicants with stage history, interviews, onboarding checklists, appraisal cycles with goals |

### Statutory rates are data, not code

Every schedule in `statutory_schedules` carries an effective range, so
payroll picks the rules in force on the pay date — re-running an old
period keeps using the rules that applied then, and a gazetted change is
an insert rather than a deploy. Each payslip records which schedules
produced it.

**Read this before filing anything.** The seeded schedules are marked
`is_verified = false`. They carry the published statutory *percentages*
and thresholds, which is enough to compute correctly, but KWSP and
PERKESO also gazette contribution *tables* whose band amounts differ
from a straight percentage by a few sen. Load the authority's own table
and mark the schedule verified before submitting real returns. A payslip
produced from an unverified schedule says so on its face.

### PCB

Computed by projecting the year at the current month's rate, applying
the reliefs the employee is entitled to, taxing the result and spreading
the balance over the months that remain. That is arithmetically what
LHDN's M/R/B table does — the table is a precomputed form of the same
sum. Non-residents are deducted at a flat rate with no reliefs.

### Verified end to end

Three employees, January 2026, hand-checked against the published rules:

| | RM 5,000, single | RM 12,000, married, 2 children | RM 4,500, aged 62 |
| --- | --- | --- | --- |
| EPF employee | 550.00 | 1,320.00 | 0.00 |
| EPF employer | 650.00 (13%) | 1,440.00 (12%) | 180.00 (4%) |
| SOCSO | 25.00 / 87.50 | 30.00 / 105.00 (capped at RM6,000) | 0.00 / 56.25 (Act 800) |
| EIS | 10.00 / 10.00 | 12.00 / 12.00 | nil — stops at 60 |
| PCB | 108.25 | 1,255.20 | 80.00 |
| Net pay | 4,306.75 | 9,382.80 | 4,420.00 |

Every figure matched. The payroll journal balanced at RM 24,255.75:

```
Dr  6100 Salaries and Wages       21,500.00
Dr  6110 EPF Contribution          2,270.00
Dr  6120 SOCSO Contribution          248.75
Dr  6130 EIS Contribution             22.00
Dr  6150 HRD Corp Levy               215.00
    Cr 2150 EPF Payable                        4,140.00
    Cr 2160 SOCSO Payable                        303.75
    Cr 2170 EIS Payable                           44.00
    Cr 2180 PCB / MTD Payable                  1,443.45
    Cr 2195 HRD Corp Levy Payable                215.00
    Cr 2145 Salaries Payable                  18,109.55
```

### Paying the run

Posting books the liability against **2145 Salaries Payable**; it does
not move a ringgit. A posted run grows a **Pay** card carrying one line
per employee — bank, account number, net pay and a reference of
`<period> <run no>` — which downloads as CSV.

It is a plain RFC 4180 CSV with six columns, every field quoted. Maybank
M2E, CIMB BizChannel and RHB Reflex each want their own layout and some
want fixed width, so rather than guess at one and be wrong for everyone,
this exports something every portal can map once and reuse. On a phone,
where there is nothing to download to, it goes to the clipboard instead
and says so.

Lines that cannot be paid — no bank account, no bank named, nothing
owing — are **shown but left out of the file**, and the card says how
many. An employee who quietly falls out of the export is an employee who
does not get paid and nobody notices; a bank will also reject the whole
batch over one bad row.

Marking the run **paid** is a separate action from producing the file,
because only a person can know whether the bank actually took it. A run
can be marked paid once: `mark_payroll_paid` refuses anything that is not
`posted`, so the second attempt fails rather than paying twice.

### Who sees what

An employee sees only their own record, payslips, leave and claims. A
manager sees their reporting line — but **not** what their reports are
paid. HR sees the company; payroll needs a finance role as well. The
company directory is a separate function returning name, department,
role and contact only, so colleagues can find each other without salary
travelling to the client.

Verified: an accounts clerk linked to an employee record could read
exactly one payslip and one employee row, no payroll runs at all, and
the full directory.

### An auditor asking to see payslips

An auditor cannot audit payroll without seeing it, but standing access
to everyone's pay is not the answer either. So they ask, and a company
admin decides:

- The request carries a **reason** and a **period**, both on the record
- Only an **auditor** can ask; only a **company admin** can decide, and
  never their own request
- Approval is for a stated number of days. Access is **read-only** and
  **lapses on its own**, so nobody has to remember to take it away
- An admin can revoke early; a grant that has run out reads *expired*
- A grant opens the payslips and their run headers. It does **not** open
  the employee master — the auditor reads the frozen payslip, not live
  salary records

Verified end to end against the deployed database:

| Step | Payslips visible |
| --- | --- |
| Auditor before asking | 0 |
| Request submitted, still pending | 0 |
| Auditor tries to approve their own | refused, stays pending |
| Accounts clerk tries to approve | refused — admins only |
| Owner approves for 30 days | 3 payslips, 23 lines, 1 run, **0 employee rows** |
| Grant narrowed to a period the payslips fall outside | 0 |
| Grant past its expiry | 0 |
| Admin revokes | 0, and the auditor still sees their own request history |

### Every read is recorded

Postgres cannot fire a trigger on `SELECT`, so a log sitting beside an
open read path is a log you can walk around. The grant therefore does
**not** widen the table policies at all. A granted reader gets in only
through `audit_list_payslips()` and `audit_view_payslip()`, and those
write the log entry before they return the rows — there is no other
route, so there is no unlogged read.

`payslip_access_log` records who looked, what they opened (employee and
period, denormalised so the entry still reads correctly if the payslip
is later removed), which grant permitted it, and the caller's IP and
user agent where PostgREST supplied them. It has a select policy and
**no insert, update or delete policy** — the read functions write it and
nobody edits it afterwards.

Company admins and payroll see the whole log on Team & access. The
auditor sees their own entries: being watched is not the same as being
watched secretly.

Verified: with a live grant, a direct `select` on `payslips` returns **0**
rows while `audit_list_payslips()` returns 3 and writes one `list` entry;
opening one writes a `view` entry naming the employee and period; a
payslip outside the grant's period is refused and leaves **no** entry,
because nothing was disclosed; and an auditor's `delete` against the log
removed nothing.

Payroll staff reading the table directly are not tracked — they are the
data's custodians, and logging their every glance would bury the entries
that matter. Run headers also stay directly readable under a grant: they
are org-level totals that already appear in the payroll journal in the
general ledger.

---

## Access and administration

### Access types

Assigned per company and enforced by RLS:

| Access type | Can do |
| --- | --- |
| Owner | Everything, including ownership |
| Company Admin | Everything except ownership transfer |
| Accountant | Prepares **and posts** to the ledger, closes periods |
| Accounts Clerk | Prepares documents but **cannot post** — preparation and approval stay in different hands |
| Auditor | Reads everything including journals and audit trail; writes nothing |
| HR Manager | Employee records, leave, claims, payroll and talent |
| Employee | Self-service only — their own record, payslips, leave and claims |
| Sales / Purchasing | Their own documents; no access to journals |
| View Only | Read-only on day-to-day records |

Verified: a clerk can write but not post, an auditor can read the ledger
but every write is refused by RLS.

### Super admin

A platform tier *above* tenancy. `platform_admins` has RLS enabled with no
write policy, so membership is granted out of band by the service role —
a company admin can never escalate into it. Platform staff get
cross-tenant stats, an organization list, account suspension, module
toggles and backend service settings.

Verified: a company owner calling any platform function is refused.

### Modules and add-ons

Core modules (sales, ledger, contacts) are always on. Purchasing,
Inventory, CRM, e-Invoice and Legal are add-ons granted per tenant, and
the entitlement is checked **in the RLS write policies** — not merely
hidden in the UI. Reads stay open, so switching an add-on off stops new
records without hiding a tenant's own history.

### Registration and invitations

Anyone can register and create a company. An admin invites colleagues by
e-mail with an access type; when the invited person registers, the
database claims the pending invitation and drops them into the right
company with the right role.

---

## Security

Multi-tenant by `org_id` with row level security on every table. Policies
are generated in `0010_rls.sql` in tiers:

- **admin** (owner, admin) — numbering sequences, membership
- **post** (+ accountant) — ledger, accounts, tax codes, banking
- **write** (+ accounts clerk, sales, purchaser) — documents, contacts, items
- **read ledger** (+ auditor) — journals and audit trail

The helper functions RLS calls (`app.is_org_member` and friends) are
SECURITY DEFINER, which is what stops the `org_members` policies from
recursing into themselves.

Verified: a member sees their own org's rows; a non-member sees zero rows
across organizations, contacts, invoices and ledger lines, while shared
reference data stays readable to both.

### A guard that failed open

Found while testing the payment file, fixed in `0052`. `app.org_role`
returns null for someone who is not a member of the organization at all,
and in SQL `null = any (...)` is null rather than false — so
`app.has_org_role` handed a null to every `can_*` helper built on it.

RLS was never at risk: a policy whose `using` clause is null filters the
row out, which is the safe direction. The damage was in the twenty-six
SECURITY DEFINER functions guarded as `if not app.can_x(org) then raise`,
because `not null` is null and the branch never fired. Confirmed against
the live database: a signed-in user belonging to no organization could
read another company's payroll payment instruction — names, banks,
account numbers and net pay.

The fix is one `coalesce(..., false)` in `has_org_role`, which closes all
twenty-six call sites at once. Re-verified after the change: the outsider
is refused with `42501`, and the organization's owner still reads the
same three lines. `statutory.sql` now asserts that the predicate is a
hard `false` for a stranger organization, and exercises the refusal
through a real call, so this cannot come back quietly.

Supabase's linter reports no errors. Two warnings remain and are expected:
`citext` and `pg_trgm` living in `public` (moving them would break the
`citext` columns already in use), and signed-in users being able to call
the SECURITY DEFINER RPCs — which is the point, since each one checks
membership and role itself.

---

## Running it

The Flutter client defaults to the deployed project, so it runs with no
configuration:

```bash
cd app
flutter pub get
flutter run -d chrome          # web
flutter run                    # connected device or emulator
```

Point it elsewhere with:

```bash
flutter build web --release \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<publishable key>
```

Only the **publishable** key belongs in the client — RLS is what protects
the data. The service role key must never appear in the app or the repo.

### Backend changes

```bash
supabase link --project-ref ewwcgtnniwqndrzukksm
supabase db push
supabase functions deploy myinvois
```

---

## Demo data

A worked example is loaded in the project: **Sinar Teknologi Sdn Bhd**,
with a customer, two invoice lines, a posted journal and a part payment.

All four logins share the password `Demo!Akaun2026`:

| Login | Sees |
| --- | --- |
| `demo@iakauntan.my` | Owner — the whole company |
| `clerk@iakauntan.my` | Accounts Clerk — can prepare, cannot post |
| `auditor@iakauntan.my` | Auditor — reads the ledger, writes nothing |
| `superadmin@iakauntan.my` | Platform operator — the admin console |

There is also a worked legal matter (`MAT-2026-00001`) with RM 5,500 held
in the client account and unbilled time against it.

Delete these logins and the organization before going anywhere near real
books.

---

## Not built yet

Stated plainly so nothing here is mistaken for finished:

- XAdES digital signature for e-Invoice version 1.1 (see above)
- Consolidated B2C e-Invoice: tables and the 7-day deadline are modelled,
  the monthly rollup job is not written
- Self-billed e-Invoice for foreign suppliers: schema supports it, no UI
- Goods Received and Purchase Request screens (the types exist in the
  schema; only PO, Bill and Purchase Credit Note are exposed in the app)
- Invoice PDF rendering and email delivery
- Bank statement import and auto-matching
- Statutory submission files: CP39, Borang A, Lampiran 1 and the EA form
  are all computable from what is stored, but no exporter is written
- The gazetted KWSP and PERKESO contribution tables (see HRMS above)
- Biometric terminal integration: attendance records carry a terminal
  identifier, but nothing pushes punches in from a device yet
