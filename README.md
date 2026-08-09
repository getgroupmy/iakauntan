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
  migrations/         Schema, RLS, business logic, reports  (0001 … 0016)
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

## Security

Multi-tenant by `org_id` with row level security on every table. Policies
are generated in `0010_rls.sql` in three write tiers:

- **admin** (owner, admin) — numbering sequences, membership
- **post** (+ accountant) — ledger, accounts, tax codes, banking
- **write** (+ sales, purchaser) — documents, contacts, items, CRM

The helper functions RLS calls (`app.is_org_member` and friends) are
SECURITY DEFINER, which is what stops the `org_members` policies from
recursing into themselves.

Verified: a member sees their own org's rows; a non-member sees zero rows
across organizations, contacts, invoices and ledger lines, while shared
reference data stays readable to both.

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

```
demo@iakauntan.my  /  Demo!Akaun2026
```

Delete this login and its organization before going anywhere near real
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
- Payroll (EPF/SOCSO/EIS/PCB accounts exist in the chart of accounts, but
  no payroll module)
