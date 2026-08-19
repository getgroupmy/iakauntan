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
  migrations/         Schema, RLS, business logic, reports  (0001 … 0221)
  tests/              SQL assertions, run in CI on a throwaway stack
  functions/          Deno edge functions (MyInvois, email, OCR, push, …)
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
| Point of sale | Outlets, registers and counted shifts; retail variants and barcodes; loyalty; tables, modifiers and a kitchen display; bookings and memberships; offline capture; self-service kiosk — `docs/pos.md` |

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

### Fiscal years, and the day the books would have stopped

Every entry must land inside a fiscal period. `create_gl_entry` used to
check that only when it found one — a date outside every fiscal year
posted with a null `fiscal_period_id`, quietly beyond the reach of period
locking, so closing a period could not protect it and year-end had
nothing to close. Confirmed before the fix: an entry dated 15 January
2027 posted happily against a company whose periods stop at 31 December
2026. It is now refused, naming what to do:

```
No fiscal period covers 2027-01-15. Create the fiscal year before posting to it.
```

Creating that year had no caller either — the RPC existed, no screen used
it. **Settings → Fiscal years** now lists each year and its twelve
periods, warns when the last one is within three months of ending (and
again, in red, once it has), and creates the next year in one action.
With no date given it continues from the day the last year ends;
overlapping years are refused, because an overlap would give one date two
periods and the lookup would pick between them arbitrarily.

Periods can be closed and reopened from the same screen, owner or admin
only. **Locked is terminal** — it is what year-end sign-off means, so
nothing reopens it.

### Journals, and undoing one

There was no way to look at a journal at all. **Journals** lists the
ledger with its lines, filtered by source, so an invoice, a payroll run
and a hand-written correction can be compared side by side.

`reverse_gl_entry` was a working RPC with no caller. Reversing posts the
mirror image and marks the original void; nothing is deleted, because a
ledger you can erase is not a ledger. It carried the same hole
`create_gl_entry` did — it looked up the period for the reversal date
and used it without checking — so a reversal could be dated into a
closed month and quietly undo it. `0059` holds it to the same rules as
every other posting.

### The jobs that run themselves

Leave carry-forward, recurring journals and the B2C consolidation all
had schema and **no runner** — `pg_cron` was not installed and there
were no accrual or rollup functions at all. `0058` writes them and
`0060` schedules a single daily job at 01:00 MYT.

- **Leave** rolls on 1 January: next year's entitlement opens and unused
  days carry, capped by the leave type's own limit. A type with no limit
  carries nothing — silently rolling everything forward is how leave
  liability grows unnoticed. Running it twice changes nothing.
- **Recurring journals** post on their due date and the schedule
  advances by its own frequency. One that cannot post — a closed period,
  a missing fiscal year — records the reason on the row and stays due, so
  it retries once the obstruction clears instead of vanishing from the
  run with no explanation.
- **The B2C consolidation** is gathered on the first of the month for
  the month just ended, with the due date seven days out.

A scheduled job has no `auth.uid()`, so it cannot pass `can_post` — and
the first attempt actually died inside `next_document_number`, which
checks membership too. Rather than let a runner write `gl_entries`
directly and skip the fiscal period and balance rules with it, `0056`
moves both bodies into `app.*_internal` and leaves the public functions
as the permission check plus a call. One implementation, two doors, and
the internal pair is revoked from `authenticated` — asserted in the
tests, because a permission check you can walk around is decoration.

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

## Reading receipts and bills

Photograph a receipt and the supplier, the date, the number and the
figures come back filled in. It reaches a bill through **Supplier
paperwork** in the document editor, and an expense through **Record
expense**, where the capture happens before the expense exists and the
file is moved onto it once it does.

**It is off until an administrator turns it on**, per organization, under
Settings → *Read receipts and bills*. There is no settings row until
somebody creates one and no row means off. A receipt carries a supplier,
an amount and sometimes a person's movements; sending that to a third
party is a decision, not a default to discover afterwards.

**Capture first.** Where the device has a document scanner — ML Kit on
Android, VisionKit on iOS — the **Scan** button opens it rather than the
plain shutter: edge detection, perspective correction and glare removal
before anything reads the page. That sits *upstream* of the reader, so a
deskewed, cropped receipt reads better whichever reader is in force, and
better still when nobody reads it at all and the file is simply the
evidence on a claim. Where there is no scanner — a browser, or an
Android device without Play services — it falls back to the camera
silently, because somebody holding a receipt does not need to be told
which of two camera implementations opened.

On Android the scanner hands back a `content://` URI rather than a file
path, and neither Dart nor ML Kit can open one: the grant that makes it
readable is attached to the URI and understood only by Android's
ContentResolver. `MainActivity.kt` carries the twenty lines that read it
and hand back bytes, and the bytes are copied somewhere this app owns
straight away — the grant does not outlive the screen it was issued for.

**The readers are a table, not a list in the code.** `ocr_providers`
carries a name, the protocol it speaks, an endpoint, a model and a
price, and a platform operator edits it in the console. Adding one that
speaks a protocol already known is a row and a secret: no migration, no
deploy, no app release. Seeded with:

| Reader | Protocol | Notes |
|---|---|---|
| Claude | `anthropic` | Reads the document rather than the printing. Best on a long bill. |
| ChatGPT | `openai` | Set the model in the console before use. |
| Grok | `openai` | xAI, same chat-completions shape as ChatGPT. |
| Document AI | `google_docai` | Google's invoice and expense parsers. |
| On this device | `device` | Free, offline, never leaves the phone. |

The edge function switches on **protocol**, not on brand — which is why
ChatGPT and Grok are two rows and one handler.

**No model is invented.** ChatGPT and Grok ship with `model` null and
cannot be switched on until an operator sets one, because guessing an
identifier produces a migration that looks finished and a 404 at the
first scan. Platform keys follow the catalog code: `OCR_KEY_OPENAI`,
`OCR_KEY_GROK`, and so on.

The on-device reader is different in kind. It costs nothing, holds no
key, and the server never sees it — so `ocr_begin` refuses it by name
and `ocr_record_local` writes the log instead, which is safe for an
ordinary user to call precisely because there is no money in it. It
returns printing rather than fields, so `receipt_text.dart` turns
"JUMLAH 45.90" into a total, asserted in `receipt_text_test.dart`
against four real receipt shapes.

And two ways to pay for the readers that charge:

- **Your own key.** Scans run on your account with the provider and cost
  nothing here. The key is stored the way LHDN client secrets are — RLS
  on with no policies, and the grants to `anon` and `authenticated`
  revoked outright, so both have to fail together before it is readable
  by anyone holding the publishable key that ships in the web bundle.
  Nothing returns it, including the administrator who set it.
- **The platform's key**, drawn against credit bought in advance.

**Credit is in ringgit, not in scans.** The price per scan is set in the
platform console and will move; a balance of "40 scans" bought at one
price and spent at another is an argument waiting to happen. The balance
is one row taken `FOR UPDATE` with an append-only ledger beside it, and
the charge is taken *before* the provider is called and given back if the
call fails — taking it afterwards makes a crashed function a free scan,
and not returning it makes a provider outage a paid-for nothing. Both
directions are ledger lines, so the statement shows what happened rather
than a balance that quietly healed.

**A top-up raises a real invoice**, from Kabeer Holdings Sdn Bhd
(registration `201901030189`, formerly `1339519K`), with both parties
snapshotted onto the document so a later rename does not rewrite it.
Deliberately not a `sales_documents` row: that would put the platform's
revenue inside a customer's trial balance.

Service tax is off. `platform_settings.platform_issuer` carries
`sst_registered`, `sst_no` and `sst_rate`, so the day the issuer
registers those go in the console and every invoice raised afterwards
carries them — nothing already issued changes. These invoices are issued
by the platform rather than by a tenant, so they sit outside every
MyInvois submitter this system holds credentials for; bringing them
within the e-Invoice mandate needs Kabeer Holdings' own credentials and
its own submission path, which is not built.

What is read is shown before it is applied, and a figure the reader could
not make out comes back as *absent* rather than as zero. The supplier is
never matched by name: two contacts called the same thing are ordinary,
and putting a bill against the wrong one surfaces months later in an aged
payables listing.

Secrets for the platform key live in **Edge Functions → Secrets**, never
in the repository or the database: `OCR_ANTHROPIC_API_KEY`, or
`OCR_GOOGLE_CREDENTIALS` with `OCR_GOOGLE_PROJECT`,
`OCR_GOOGLE_LOCATION` and `OCR_GOOGLE_PROCESSOR`.

The catalog decides where documents are sent, which makes it an
exfiltration path if a tenant could write it: readable by anyone signed
in, written by the platform alone. A reader an organization is using
cannot be deleted out from under them — retiring one is
`is_active = false`.

`supabase/tests/ocr_credit.sql` asserts the money: that an empty balance
refuses before the provider is called, that a failed scan returns exactly
what it took and does so once however often the callback arrives, that
the ledger and the balance agree after every move, and that a signed-in
user reaches neither the key table nor the function that refunds.

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

## Corporate secretarial (add-on)

For a firm acting as company secretary. The tenant is the firm; the
companies it acts for are `corp_entities` — deliberately **not**
organizations, because a client company is a subject of record, not a
tenant with logins.

Built to the Companies Act 2016, which replaced the numbered forms of
the 1965 Act with sections. Practitioners still say "Form 49", so the
filing types carry both.

| Register | Section |
| --- | --- |
| Directors, managers and secretaries | s.57 |
| Members | s.50 |
| Beneficial owners | s.60B, in force since 1 April 2024 |
| Charges | s.357 |

### The dates are the product

A secretarial firm's whole risk is a missed date, so none of them are
typed in. Each is computed from the company's own dates against the
section that imposes it:

| Filing | Runs from | Days |
| --- | --- | --- |
| Annual Return (s.68) | **anniversary of incorporation** | 30 |
| Financial statements (s.258, s.259) | financial year end | 180 + 30 |
| Change of officers (s.58, "Form 49") | the change | 14 |
| Change of registered office (s.46(3)) | the change | 14 |
| Return of allotment (s.78) | the allotment | 14 |
| Registration of a charge (s.352) | creation of the charge | 30 |
| Beneficial ownership (s.60B) | obtaining the information | 14 |

The Annual Return running from the **incorporation anniversary and not
the year end** is the single most common reason a company is late, so it
is what the module is built around.

Two things the tests pin down, because both are easy to get wrong and
neither is visible until it matters:

- **The anniversary is interval arithmetic, not date rebuilding.** The
  first cut clamped the day to the 28th to dodge 29 February, which
  quietly moved every company incorporated after the 28th of a month two
  or three days early. A statutory date that is wrong in the safe
  direction is still wrong.
- **Only public companies hold an AGM.** The 2016 Act removed the
  requirement for private companies entirely. Opening an AGM filing
  against a Sdn Bhd is refused outright — telling a client to hold a
  meeting the Act does not require is teaching them the wrong law.

### The register of members is computed

Share movements are kept as events — allotment, transfer, transmission,
cancellation — and positions are derived from them, the way the ledger
derives balances from journals. A register you can edit directly is a
register that will drift from the returns already lodged. A transfer of
more shares than the holder holds is refused by the database:

```
Holder has 60 shares of that class on 2026-03-01, cannot move 1000
```

Anything over 20% is flagged against the s.60B tests rather than left
for the secretary to eyeball percentages.

### Documents are built from the registers

A resolution that disagrees with the register is worse than no
resolution, because it looks authoritative. So `corp_generate_document`
reads the merge values out of the registers — company name, registration
number, directors, members, issued capital — and substitutes them into a
template. Six are shipped: appointment of a director, change of
registered office, allotment of shares, special resolution changing the
name, first board minutes, and a statutory particulars extract. A firm
that wants its own wording copies a template against its own `org_id`
and that version wins.

Before generating, `corp_template_placeholders` reports which fields the
register can answer and which it cannot — a new director's NRIC is not
in the register yet, by definition — so a gap is caught before signature
rather than after. Nothing is silently blanked: an unfilled placeholder
would stay visible as `{{director_name}}`, which is why the gaps are
collected up front instead.

Every generated document is kept — the **Documents** tab on a company
lists them, newest first, and each one can be read, amended, signed and
downloaded. They are stored, not regenerated on demand, because a
resolution is a record of what was circulated on a date, not a view over
today's register.

**Amending, and when you cannot.** A template cannot anticipate every
recital, so the body is editable. Once anybody has signed it, it is not.
The signature layer already *detects* an edit — the text is hashed when
signing opens and again as each person signs — but detecting is not
preventing, and a signed resolution whose words were later rewritten says
one thing while a signature attests to another. The rule is a trigger on
`corp_documents` rather than a check inside the RPC, because RLS grants
`can_write` full `ALL` on that table: a guard that only lives in one
function is not a guard, since a PATCH straight to PostgREST would walk
around it. `supabase/tests/secretarial.sql` asserts both paths are shut.

**Downloads come out as PDF**, on A4 with the company's typeface
embedded, page numbers and the generation date in the footer. The
Markdown is still available from the row's overflow menu, and it is the
copy to keep if the exact bytes matter: it is what the database stores
and what the signature hash covers. The PDF is a rendering of it.

### Signatures

A generated document can be circulated for signature. This is an
**electronic signature under the Electronic Commerce Act 2006** — a
recorded act of signing, attributable to a person — and **not a digital
signature under the Digital Signature Act 1997**, which requires a
certificate from a licensed certification authority. The screen says so
rather than letting anyone assume otherwise.

What makes it worth anything is the hash. The document body is
fingerprinted with SHA-256 when signing opens, and again as each person
signs. So:

- Signing a text that has changed since it was circulated is **refused**.
- A signature taken before an edit is shown as no longer covering the
  text on screen, in red, rather than carrying a tick that quietly
  stopped meaning anything.

The time, the hash, the caller and the request headers are written by the
database at the moment of signing — none of it comes from the client,
because a signature record the signer can write is not evidence of
anything.

### Signing without an account

A director will not sign up to an accounting system to sign one
resolution. So the secretary can issue a **signing link**: a URL at
`/sign/<token>` that opens one document, for one named signatory, and
grants exactly one action. No login, no session, no sight of anything
else in the company.

The token is 256 bits of randomness and is **stored only as a SHA-256
hash**. It is returned once, at the moment it is created, and cannot be
read back afterwards — if it is lost the secretary issues a new one,
which retires the old, so "I sent you a new link" never means two links
work. The link table itself is closed to `anon` at the privilege level as
well as by policy, so a future policy mistake cannot open it.

Two functions are the only things in the entire database reachable
without an account, and `supabase/tests/statutory.sql` asserts that by
name, so a third cannot appear by accident.

Every way a link can be unusable gets its own answer rather than being
flattened into "invalid" — `expired`, `used`, `revoked`, `withdrawn`,
`already_signed`, `changed` — because telling somebody their link expired
saves them hunting for a problem that is not there. The document text is
handed over **only** when the link can actually be signed; a stale or
spent link shows the company and the title and nothing else. Signing
through a link runs every check that signing while logged in does,
including the hash of the body, and `signed_by` is deliberately left
null: nobody was signed in, the link is the attribution, and it is
recorded beside the signature along with the time the link was opened.

**This is not a second factor.** The app sends no e-mail yet, so the link
is exactly as strong as the channel it is sent over. It is short-lived
(14 days by default, 90 at most), single-use, bound to one signature
line, and dies if the document moves — but anyone holding the URL can
sign. Send it to the person, not to a group.

The same primitive is what a client portal invitation needs, which is why
it is a table of scoped credentials rather than a column on the signature
row.

### Attachments

Files are filed against a record at `<org>/<table>/<record>/<file>`, and
that path is not decoration: the storage policies read the organization,
the table and the record straight out of the object name, and a trigger
refuses any row whose path disagrees with its own columns.

**An attachment inherits the sensitivity of what it hangs off.** Both the
table and the bucket previously let any member of the organization read
any file, which was harmless only while nothing could upload — a scan of
a payslip or a passport would otherwise have been readable by every
signed-in colleague, undoing the payslip access rules by the simple
expedient of attaching a photograph. Now an accounts clerk reads a bill
attachment and not a personnel one, and an employee reads their own and
nobody else's. Links are signed and expire in ten minutes; the bucket is
private, so there is no URL to leak.

### Not built

- **Direct SSM lodgement.** SSM publishes no general API for filing;
  MBRS submission goes through their own tool in XBRL. The module tracks
  what is due and produces the paperwork — a human still lodges it.
- **A full client portal** — a standing place for owners to sign in,
  upload identity documents and see their own company's file. The token
  layer it needs is built and in use (see *Signing without an account*);
  what is missing is the rest of the surface, and e-mail delivery so an
  invitation can be sent rather than copied out by hand.

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

### Starting mid-year

PCB projects the year from the month in hand, so an employee who joined
in July with nothing recorded has six months of pay projected as if it
were the whole year — and is deducted a fraction of what they owe. On
RM8,000 a month that is **RM 32.00 instead of RM 769.95**, and the
shortfall lands on the employee at filing.

`calc_pcb` has always read `employee_ytd_opening` and
`employee_tax_reliefs`; neither had a screen, so the figures could not be
entered. **Edit an employee → Tax year** now takes them: gross already
earned, EPF and PCB already deducted, zakat paid, and benefits in kind,
copied from the last payslip or the previous employer's EA form. Saved
separately from the rest of the form, so an accidental Save cannot
rewrite what a previous employer paid.

Declared reliefs — the employee's TP1 — go in the same place. Reliefs the
company can work out for itself (the individual allowance, EPF, SOCSO,
spouse, children on file) are applied automatically and are deliberately
absent from that list, so nothing gets claimed twice. Each entry is held
to the statutory ceiling: over-claiming here under-deducts, and the
employee pays for it later.

Benefits in kind were being stored and ignored. They are employment
income under section 13, so `0054` folds them into the projection.

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

### And every change is recorded too

`audit_logs` existed with a select policy, no write policy, and **no
writer at all** — zero rows, no `insert` anywhere in the schema. So the
system recorded every auditor's glance at a payslip and nothing at all
about who changed a salary. `0055` fixes the asymmetry.

A SECURITY DEFINER trigger writes it, the table still has no insert,
update or delete policy, and it covers the tables where a quiet change
would matter: employees and their salary components, opening year to
date and declared reliefs, payroll settings, bank accounts, the chart of
accounts, tax codes, fiscal periods, memberships, modules and the
company record. Deliberately not everything — an audit trail nobody reads
because it is mostly invoice lines is the same as no audit trail.

Only the fields that moved are stored, from and to, so a raise reads as
a raise:

```json
{ "from": { "basic_salary": 5000.00 }, "to": { "basic_salary": 6500.00 } }
```

An update that changes nothing is not written at all.

Reads are **owner and admin only**, tightened from `can_read_ledger`:
those diffs carry salaries, bank account numbers and statutory
identifiers, which is precisely what the payslip rules above keep away
from an auditor without an approved request. It appears on Team & access,
beside the read log — one records who looked, the other who changed it.

Verified: an insert and a real update are recorded while a no-op update
is not, only the moved field is kept, and a caller without admin is
refused with `42501`.

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

Property is sold as two: `property_strata` and `property_nonstrata`. A
building either has strata titles or it does not, and the Strata
Management Act 2013 governs only the first — share units, a sinking
fund, a management corporation. The two modules share the site and unit
tables and nothing else. See `docs/property.md`.

### Registration and invitations

Anyone can register and create a company. An admin invites colleagues by
e-mail with an access type; when the invited person registers, the
database claims the pending invitation and drops them into the right
company with the right role.

### Forgetting and changing a password

Two different situations, and they are deliberately not the same screen.

**Forgotten.** "Forgot password?" sends a reset e-mail pointing at
`/#/reset-password`. Redeeming that link *signs the user in* — which is
the trap in the naive version of this flow, because they would otherwise
land on the dashboard with the password they had forgotten still in
force, having proved only that they can read their own e-mail. So the
router watches for the recovery event and holds them on the reset screen
until `updateUser` has actually returned. No current password is asked
for: they do not have one they can remember, and possession of the link
is the proof. There is a way out — "I did not ask for this" signs them
straight back out.

**Known, and being changed.** Settings → Your account → Change password
*does* ask for the current one, and verifies it by signing in with it
before changing anything. Supabase's `updateUser` will change a password
on the strength of the session alone, so without that step a borrowed
laptop is enough to lock the owner out of their own books.

For this to work on a deployment, the origin must be in Supabase's
**Authentication → URL Configuration → Redirect URLs**. Add
`https://*.vercel.app/**` too if you want reset links from preview
deployments to come back to that preview instead of production.

---

## Security

`docs/pre-deployment.md` is the checklist run before this went live —
environment variables, debug code, what an error is allowed to say,
security headers, rate limiting, CORS and the database — with what each
check found, what was changed, and the four things that can only be done
from a dashboard. `docs/personal-data.md` is the companion map of where
personal data is collected, where it goes and what closing an account
does.

### Where secrets live, and what is public

`.env.example` lists every value the system reads from its environment
and names the one place each really lives. The short version:

| Class | Home | May it be in the repo or the bundle? |
|---|---|---|
| Publishable (anon) key, project URL, VAPID **public** key | `--dart-define`, defaults in `lib/src/core/env.dart` | Yes — public by design |
| Service role key, `SCHEDULER_SECRET`, `RESEND_API_KEY`, `WEB_PUSH_PRIVATE_KEY`, `FCM_SERVICE_ACCOUNT`, `CALL_SFU_SECRET`, `CALL_TURN_SECRET`, OCR provider keys | Supabase → **Edge Functions → Secrets** | Never |
| A company's own LHDN and OCR credentials | `einvoice_credentials`, `org_ocr_credentials` | Never — those tables are service-role-only |
| Deploy credentials, `SUPABASE_DB_PASSWORD` | GitHub → Actions **Secrets** | Never |

The publishable key being in the bundle is the design and not an
oversight: **row level security is the boundary, that key is not.** It is
safe for exactly as long as two things hold, and both are worth
re-checking after any schema change —

1. Every table in `public` has RLS enabled. All 177 do.
2. No SECURITY DEFINER function is granted to `anon` without a token
   check of its own. Three are: `open_shared_document`,
   `corp_open_signing_link` and `corp_sign_with_link`, each of which
   takes an unguessable token and is the whole point of the share and
   signing-link features.

`einvoice_credentials` and `org_ocr_credentials` carry RLS with **no
policies at all**, which denies everyone. Only the service role reaches
them, and it does so by bypassing RLS. That is deliberate: a company's
LHDN client secret should not be readable by that company's own owner
through the API.

### Rotate anything that was ever hardcoded

Git history keeps what the working tree has dropped. Removing a value
from a file does not remove it from the repository — anyone with a clone
still has every version of it.

At the time of writing, the values that have been committed to this
repository are the Supabase **publishable/anon** key (in
`lib/src/core/env.dart`, and formerly as a fallback in two workflow
files) and the **demo account password**. Both are public by design, so
neither is an incident. Nothing else — no service role key, no API key,
no connection string, no `.env` file — has ever been committed.

All the same, before this deployment carries real books:

- **Rotate the demo password and delete the demo users.** It is
  `Demo!Akaun2026` in the history and in every built bundle.
- **Do not set `DEMO_MODE`.** It now defaults to off, so a build that
  forgets the flag ships a closed door; `--dart-define=DEMO_MODE=true` is
  what puts the one-tap logins back on the sign-in page.
- **Rotate any secret you believe may have been pasted anywhere** — a
  chat window, a ticket, a screenshot. Rotation is cheap; the assumption
  that it never leaked is not.

If a real secret is ever committed by accident, rotating it is the fix.
Rewriting history is not: the old object survives in every clone and
fork that already pulled.

### Row level security

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

### What CI actually runs, and a day it was not running

`.github/workflows/ci.yml` analyzes and tests the Flutter app, then
starts a throwaway Supabase stack and runs every file in
`supabase/tests/` against the migrations *in that commit* rather than
against the hosted project. A third job, `edge`, runs `deno test` over
the one piece of edge-function logic worth asserting — the check that
decides whether a caller may act for every organization at once, where a
mistake in the permissive direction does not fail but hands the outbox to
whoever asks.

Two more jobs publish what those have passed, and wait on them: `deploy`
builds the web bundle and hands it to Vercel — see the Vercel pipeline
below for why that gate is there — and `functions` pushes the three edge
functions to Supabase. `functions` additionally runs on the default
branch only, since there is one Supabase project and no such thing as a
preview of it; [docs/edge-functions.md](docs/edge-functions.md) has the
rest, including the drift it was written to end, and
[docs/schedulers.md](docs/schedulers.md) covers the two timers and the
credential they share.

`migrate` sits between the two, on the default branch only and before
either deploys, because a function or a screen that expects a column the
database does not have yet is the failure that ordering prevents. It
reports what is applied and what is pending once
`SUPABASE_DB_PASSWORD` is set, and applies it once the repository
variable `MIGRATIONS_AUTOPUSH` is `true` as well —
[docs/migrations.md](docs/migrations.md) explains why those are two
separate switches, and records the reconciliation of the hosted
project's migration history that had to happen before any of this could
be turned on.

That second job had been failing, unnoticed, since the suite grew a
second fixture organization. `app.seed_chart_of_accounts` creates a temp
table `on commit drop`, which only drops at COMMIT — and the whole suite
runs inside one transaction that is rolled back, so the second call died
on `relation "_coa" already exists`. The hosted project had been given
the one-line fix directly and the repository never received it, so the
assertions passed by hand and failed from a clean build. `0071` writes
that fix down. **A clean build from the migrations is the only thing that
tests the migrations**, which is the whole reason that job exists.

Both jobs that touch Flutter pin `flutter-version: 3.32.0` rather than
tracking `channel: stable`. A newer stable deprecated `DropdownButtonFormField`'s
`value` argument; with `--fatal-infos` that turned into 37 errors in code
nobody had touched. Bump the pin deliberately, with the deprecations
fixed in the same commit.

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

### Deploying the web app

The build is a folder of static files. There is no server to run: any
static host will do, and the app talks to Supabase straight from the
browser.

```bash
cd app
flutter build web --release --no-web-resources-cdn
# → app/build/web/  (~26 MB on disk; the browser fetches far less)
```

**`--no-web-resources-cdn` is not optional.** Without it the bundle
fetches the CanvasKit renderer from `www.gstatic.com` at run time. That
request happens *before* `main()` runs, so if the CDN is blocked — a
corporate firewall, a filtered network, a captive portal — the user gets
a blank white page and the "Cannot reach iAkauntan" screen never gets a
chance to explain itself. Verified: with the flag off and gstatic blocked
the page renders nothing; with it on, the same environment boots to the
sign-in screen. The renderer is 20 MB of the build output, and it is why
the flag costs nothing but a slightly larger upload.

Routing is Flutter's default hash strategy, so `/#/sign/<token>` and
every other deep link resolve client-side — **no rewrite rules, no
`try_files`, no SPA fallback configuration**. Serving `index.html` at the
root is the whole requirement.

Under a sub-path (a GitHub Pages project site, say) add
`--base-href=/<repo>/`.

Then, in the Supabase dashboard under **Authentication → URL
Configuration**, set **Site URL** to the deployed origin and add it to
**Redirect URLs**. Sign-up confirmation uses Site URL; password reset
links are aimed explicitly at `<origin>/#/reset-password` and are refused
unless that origin is allowed. Left at the defaults, both send your users
to `localhost`.

Two things to do before real users arrive:

- Delete the demo logins and the demo organization (below).
- Replace the seeded statutory schedules, which are `is_verified = false`
  on purpose.

#### The Vercel pipeline

The `deploy` job in `.github/workflows/ci.yml` builds the bundle and
uploads it to Vercel **prebuilt**. Vercel has no Flutter build image, and
teaching its build container to install one on every deploy is slow and
brittle — so Vercel never sees Dart, it serves a folder.

Pushes to the default branch go to production. Every other branch gets a
preview URL. A pull request gets neither: it is somebody else's commit by
definition, so it gets the checks and not the deploy credentials.

**It waits on the tests, and that is not how it started.** Publishing
used to live in its own `deploy.yml`, which repeated the Flutter checks
rather than trusting CI — sound reasoning about a separate workflow,
since green last time is not green now. What it could not repeat was the
database job, and nothing connected the two: a red ledger suite and a
green deploy on the same commit were not a contradiction. Three commits
published to production while `ledger.sql` was failing. Nothing harmful
got out, because the failure was a test asserting behaviour that had been
deliberately removed — but the same arrangement would have shipped wrong
EPF arithmetic or a period control that had stopped holding, just as
quietly.

So the deploy is now a job in this workflow with `needs: [flutter,
database]`. Inside one workflow the dependency is real — the same commit,
the same checkout, the same pinned SDK, and the job does not start unless
both passed — which is why the repeated `flutter analyze` and `flutter
test` have gone with it. The concurrency group that supersedes an
in-flight deploy sits on the job rather than the workflow, so a newer
commit cancels the older one's *deploy* without cancelling its tests;
those are the record of whether that commit was sound and are worth
keeping even once it has been passed.

**Do not import the repository into Vercel as a Git project.** If you do,
Vercel runs its own build, finds no Flutter and no output directory, and
publishes an empty deployment — which is what a bare `404: NOT_FOUND` on
your Vercel URL means. The root `vercel.json` sets
`git.deploymentEnabled: false` to stop that happening; if a Git
integration was already connected, disconnect it under Project Settings →
Git, because deployments it already made will otherwise stay as
production. Create the project instead with one `vercel link` from a
local checkout, and let the workflow do every deploy.

**One repository secret is needed**: `VERCEL_TOKEN`, from Vercel →
Account Settings → Tokens. Until it is set, **nothing is deployed** — the
job emits a warning and a "Nothing was deployed" run summary saying so,
and passes rather than painting every push red. A green tick on this
workflow is not proof that anything shipped; read the summary.

`VERCEL_ORG_ID` and `VERCEL_PROJECT_ID` are written into the workflow
rather than stored as secrets. They are identifiers, not credentials:
they name the project and grant nothing without the token. Setting a
secret or a repository **variable** of either name overrides them, which
is what to do if this repo ever deploys to a different project.

Optionally set the repository **variables** `SUPABASE_URL` and
`SUPABASE_ANON_KEY` to point a deployment at a different project; unset,
the build uses the defaults compiled into `lib/src/core/env.dart`. Only
ever the publishable key.

`deploy/vercel-output-config.json` carries the response headers. Two
things in it were established by testing the real bundle in a browser
rather than copied from a template:

- **`Cache-Control: public, max-age=0, must-revalidate` on everything.**
  Flutter's web output has no content hashes in its filenames —
  `main.dart.js` is `main.dart.js` in every build — so caching anything
  for long would serve stale code after a deploy. Revalidation still
  returns 304s, and the service worker does the real offline caching from
  its own hashed resource map.
- **A Content-Security-Policy that the app actually runs under.** It needs
  `'wasm-unsafe-eval'` for CanvasKit and `'unsafe-inline'` styles because
  Flutter injects them. It also has to allow `fonts.gstatic.com`: the
  Flutter engine fetches its fallback Roboto at start-up. The app does not
  need that font — it bundles Plus Jakarta Sans and renders identically
  with the request blocked, which I checked — but without the exception
  every page load logs a violation, and a real one would be lost in the
  noise. Verified: the app boots with zero CSP violations under this
  policy. If you point the app at a different Supabase project, change
  `connect-src` and `img-src` to name it or every request will be refused.

### Backend changes

```bash
supabase link --project-ref ewwcgtnniwqndrzukksm
supabase db push
```

The edge functions are **not** in that list. All three are redeployed by
CI on every push to the default branch, so a hand deploy is only ever a
way for the hosted copy to stop matching the repository — which is what
it did, undetected, until the `functions` job existed. See
[docs/edge-functions.md](docs/edge-functions.md), which is also where the
one repository secret it needs is written down.

### The knowledge graph

[graphify](https://github.com/Graphify-Labs/graphify) maps the repository
into a queryable graph — 2,946 nodes and 4,409 edges across the Dart app,
the SQL migrations and the edge functions — so a question can be answered
by traversal instead of grep. `graphify-out/graph.json` and
`GRAPH_REPORT.md` are committed, so a fresh checkout starts with the map
already built.

```bash
uv tool install "graphifyy[sql]"   # the [sql] extra is not optional here
graphify claude install --project  # your machine's hooks (git-ignored)
```

The `[sql]` extra matters: without `tree-sitter-sql` all 74 migrations
contribute nothing, and in this codebase the migrations *are* the
business logic — the graph goes from 2,212 nodes to 2,946 with it.

```bash
graphify explain "public.corp_sign_with_link"  # a symbol and its neighbours
graphify god-nodes --top 12                    # what everything hangs off
graphify update .                              # after code changes, no API cost
```

Everything above is local tree-sitter parsing — deterministic, no model
involved, nothing leaves the machine. Community names in `GRAPH_REPORT.md`
are file-name placeholders because no LLM key is configured; `graphify
label .` with a key set will name them properly. Rebuild the clickable
`graph.html` (git-ignored, 2.3 MB) with `graphify cluster-only .`.

**Two things to know before you trust an answer from it**, both caused by
this schema being a stack of `create or replace` migrations rather than one
file:

- A function replaced across several migrations is several nodes.
  `graphify explain "public.post_payroll_run"` reports the ambiguity and
  lists all three definitions with their ids — which is useful in itself,
  but you must then ask about the id of the *latest* one to see what the
  function actually does today.
- A table is minted once by the migration that created it and again as a
  bare node carrying references from every other migration. So "what
  touches this table" means looking at both nodes, and `affected` needs
  the SQL edge kinds spelled out, since it traverses call and import edges
  by default:

  ```bash
  graphify affected "supabase_migrations_0069_document_signatures_public_corp_signatures" \
    --relation reads_from --relation writes_to
  ```

The graph is a fast index, not a source of truth. For anything statutory,
read the migration.

`graphify extract . --postgres <dsn>` can also map the live schema
directly, which would pick up what the migrations describe only
cumulatively. It has not been run here — it needs a database password,
and that does not belong in this repo.

---

## Demo data

Four worked companies are loaded in the project, rebuilt together by
`app.demo_rebuild()`: **Sinar Teknologi Sdn Bhd** (a trading company with
a full financial year, payroll, a helpdesk and a trade counter),
**Amanah Setiausaha Sdn Bhd** (a corp-sec practice), **Harta Prima
Management Sdn Bhd** (a strata scheme and a commercial block) and
**Warung Sedap Enterprise** (a sole proprietor café mid-service — see
`docs/pos.md`).

All six logins share the password `Demo!Akaun2026`:

| Login | Sees |
| --- | --- |
| `demo@iakauntan.com` | Owner — the whole company |
| `clerk@iakauntan.com` | Accounts Clerk — can prepare, cannot post |
| `auditor@iakauntan.com` | Auditor — reads the ledger, writes nothing |
| `secretary@iakauntan.com` | Company secretary — a practice and its clients |
| `property@iakauntan.com` | Property manager — a strata scheme and a commercial block |
| `warung@iakauntan.com` | Café owner — tables, kitchen screen and a kiosk |

**None of that needs typing.** The sign-in page lists those six accounts
under *or look around a demo*, each described by what it will show rather
than by the name of its role, and a tap signs straight in.

**`superadmin@iakauntan.com` is deliberately not among them.** Every other
demo login is scoped to a demo company, so the worst a visitor can do is
scribble on invented books. The platform operator console is scoped to
nothing — it lists every tenant on the deployment and can change their
status, which would include a real company the day one signs up.

Leaving it off the list is not the same as closing it: the account still
signs in if somebody types the password above, which this file publishes.
**Rotate it.** `0077` has already taken the credential lock off that one
account, which is what makes the password changeable — so the only step
left is setting a new one, in **Supabase → Authentication → Users →
superadmin@iakauntan.com → Reset password**.

Until that is done the account is at its least protected: the published
password works *and* can now be changed by anybody who uses it. That is
the unavoidable shape of the fix — a password cannot be rotated while it
is frozen — but it is a reason to do it now rather than later. To put the
freeze back instead, reverse `0077`. It is the same
`signInWithPassword` call the form makes, not a side door — a visitor
should reach the app the way everybody else does, or the demo is
demonstrating something other than the product.

**Turn it off before this project holds a real ledger.** The panel ships
the demo password inside the bundle, which is harmless only while those
six accounts are the only thing it opens. Two things to do, together:

- set the repository variable `DEMO_MODE` to `false` (or build with
  `--dart-define=DEMO_MODE=false`), which removes the panel; and
- delete the demo users and every demo organization — `app.demo_teardown()`
  does both, and is what `app.demo_rebuild()` calls first.

The switch is compile-time on purpose. A door that can be reopened by
editing a row is not closed.

**The demo credentials are frozen in the database.** Handing a stranger a
session on a shared account means handing them the ability to change its
password and lock out every visitor after them — or move its email and
take the account. `0076` puts a trigger on `auth.users` that refuses any
change to the password, email or phone of an account flagged
`app_metadata.demo`, and the six seeded logins carry that flag.

It is a trigger rather than a hidden button because the change is an
ordinary POST to GoTrue's `/auth/v1/user`, which never passes through
this app: anyone with a demo session and the publishable key can make it
with curl. Settings hides the button and the sign-in page refuses to
e-mail a reset link, but neither is the rule.

Signing in still writes `last_sign_in_at`, and a reset link can still be
requested — only the columns that would take the account away are
frozen. To rotate the demo password later, clear the flag first, which
needs the service role:

```sql
update auth.users set raw_app_meta_data = raw_app_meta_data - 'demo'
 where email = 'demo@iakauntan.com';
```

### Printing what a customer or an employee receives

Six things render to PDF and download: the **invoice** (from its
editor), the **payslip** (from the payslip screen), any **secretarial
document** (from the company's Documents tab), the four **reports**
(Profit & Loss, Balance Sheet, Trial Balance, SST Summary — the icon in
the Reports app bar exports whichever tab you are on), and a customer
**statement of account** (from the customer's own screen). They share one
letterhead and one embedded typeface, so an invoice and a report cannot
disagree about the company's own address.

**The letterhead carries the company logo**, uploaded under Settings →
Company (administrators only, matching the storage policy — the bucket
refuses a write whose first path segment is not an organization the
caller administers). It prints top left, wherever the letterhead appears,
at a fixed size with the aspect ratio preserved, so a tall logo cannot
push the identity block down the page. A company without one still prints a
proper letterhead: the mark is an addition to the registered name and
numbers, never a replacement, because a tax invoice has to carry those
whatever it looks like.

**A company that prints onto its own letterhead paper turns the block
off** — Settings → Company → *Printed stationery*. It is a company
setting rather than a choice on every download, because owning headed
paper is a fact about the business, not about one invoice. With it on,
invoices and payslips start 42 mm down the first page
(`PdfKit.stationeryReserve`, a guess about somebody else's stationery and
therefore written down where it can be changed) so nothing lands on top
of the printed header, and the logo is not embedded at all.

What the setting does **not** do is drop the registration, TIN and SST
numbers. Those move down the page in small type instead. Printed
stationery routinely carries a company's name and address but not its SST
registration, and the Sales Tax Act asks for those on the invoice rather
than on the paper — so suppressing them to tidy the layout would quietly
produce invalid tax invoices. The default is off, which is the only safe
assumption for a PDF that gets e-mailed: nothing outside the file
supplies the company's details.

**On a secretarial document the letterhead is an option, never the
default.** The PDF button gives a bare copy; "Download PDF on your
letterhead" is a separate entry in the row's overflow menu, and it saves
under a different filename so the two are distinguishable on disk. The
distinction is not cosmetic: a board resolution belongs to the client
company whose board passed it — its name is already the first line of the
text — so a practice's mark at the top could be read as though the
practice resolved something. When the letterhead is used, the identity
block is followed by **"Prepared by …"** and a rule, and the document
proper starts below the line still announcing its own company in its own
first words.

**A report and a statement carry the letterhead too**, for the same
reason an invoice does: once the PDF leaves the app nothing else says
whose numbers these are, and a balance sheet with no name on it is not
evidence of anything. Both honour the printed-stationery setting.

Two structural decisions there are worth knowing about:

- **The screen and the PDF render the same spec.** `report_spec.dart`
  turns the rows the database returns into sections, grids and
  highlights; `reports_screen.dart` draws that on screen and
  `report_pdf.dart` draws it on a page. Neither computes a figure of its
  own. A printed profit and loss that disagrees with the one on screen is
  worse than having no PDF at all, and the way that happens is two copies
  of the same filter drifting apart — so there is only one copy, and the
  arithmetic is tested without a widget tree.
- **The statement is an open-item statement and says so.** It lists what
  is still unpaid as at a date, with an ageing summary; it is not a
  transaction history and carries no balance brought forward. A customer
  reconciling against their own ledger needs to know which of the two
  they are holding. The bands are inclusive at the top — 30 days overdue
  is in *1–30*, not *31–60* — because that is what the customer's own
  aged listing will assume, and a document with no due date is counted as
  not yet due rather than as maximally overdue.

Two things the layouts get right on purpose:

- **Tax is a column on the invoice, not a line at the bottom.** A bill
  carrying two tax rates has to show which line bore which, and the
  discount and tax columns only appear when some line actually uses them.
  An unposted document prints `DRAFT — not yet posted to the ledger`,
  because a draft that looks like a tax invoice is a document somebody
  pays against.
- **The payslip itemises from the payslip lines, never the summary
  fields.** Basic salary is an earning line and EPF, SOCSO, EIS and PCB
  are deduction lines, so printing the scalar columns beside them would
  list every statutory figure twice — and the totals would still foot,
  which is exactly what would make it hard to notice. Employer
  contributions sit below the net pay, outside it, labelled as not
  deducted. If the contribution schedules are unverified, the payslip
  says so on its face, because the payslip is what the employee keeps.

### The secretarial practice

`secretary@iakauntan.com` owns a second organization, **Amanah Setiausaha
Sdn Bhd**, with the secretarial add-on enabled — a separate company
rather than a role inside Sinar Teknologi, because the module is about
managing *other people's* companies. Nurul Aina is the named s.236
secretary on all three client boards.

| Client | Incorporated | FYE | Why it is there |
| --- | --- | --- | --- |
| Kilang Lestari Sdn Bhd | 14 Mar 2019 | 31 Dec | Two directors and a share transfer |
| Bayu Digital Sdn Bhd | 30 Sep 2022 | 30 Jun | A 30 September anniversary, and a June year end |
| Pinang Holdings Berhad | 20 Jan 2015 | 31 Mar | Public, so the AGM obligation applies |

The clients differ on purpose, so the deadline list exercises the
arithmetic rather than repeating one date:

- Annual Returns fall 30 days after the **incorporation anniversary**, not
  the year end — 30 Sep 2025 gives 30 Oct 2025, 14 Mar 2026 gives
  13 Apr 2026.
- Financial statements are 180 days from the year end plus 30 to lodge, so
  a 30 June year end is due 26 Jan and a 31 December one 29 July.
- **Only Pinang Holdings gets an AGM.** s.340 binds public companies; the
  two Sdn Bhds are absent from that line, which is the rule working rather
  than data missing.

Kilang Lestari also carries a share transfer — 10,000 of Lim Wei Ming's
70,000 to Siti Zubaidah on 19 Feb 2024 — so the register of members shows
60/40 computed from the event stream rather than stored, with the
movement date against both holders.

There is also a worked legal matter (`MAT-2026-00001`) with RM 5,500 held
in the client account and unbilled time against it.

Delete these logins and **both** organizations before going anywhere near
real books.

None of this is in a migration. The demo users and their companies were
made directly against the hosted project, so a fresh `supabase db push`
gives you an empty system rather than somebody else's fictional clients —
which is the right default, and the reason there is nothing here to
delete from the repository.

### `Database error querying schema`

If sign-in fails with

```json
{"code":"unexpected_failure","message":"Database error querying schema"}
```

the password is not the problem and neither is the deployment. GoTrue
reads `auth.users` into Go structs where the token columns are
non-nullable strings, so a user whose `confirmation_token`,
`recovery_token`, `email_change_token_new`, `email_change_token_current`,
`phone_change_token`, `reauthentication_token`, `email_change` or
`phone_change` is **NULL** cannot be scanned at all. The API answers 500
before it ever looks at the password, which is why the message points
nowhere near the cause. The auth log says it plainly:

```
error finding user: sql: Scan error on column index 3,
name "confirmation_token": converting NULL to string is unsupported
```

It happens to any user inserted with plain SQL rather than created
through the Auth API, which writes `''`. The demo logins were made that
way and hit it. The fix is NULL → empty string on those columns, and it
touches no credentials:

```sql
update auth.users set
  confirmation_token         = coalesce(confirmation_token, ''),
  recovery_token             = coalesce(recovery_token, ''),
  email_change_token_new     = coalesce(email_change_token_new, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  phone_change_token         = coalesce(phone_change_token, ''),
  reauthentication_token     = coalesce(reauthentication_token, ''),
  email_change               = coalesce(email_change, ''),
  phone_change               = coalesce(phone_change, '');
```

Make users through the Auth API where you can. `supabase/tests/_helpers.sql`
writes the empty strings explicitly, because that is the fixture anyone
will copy.

---

## Not built yet

Stated plainly so nothing here is mistaken for finished:

- XAdES digital signature for e-Invoice version 1.1 (see above)
- Consolidated B2C e-Invoice: the monthly rollup now runs and starts the
  7-day clock, but **submitting** the consolidation is still manual — the
  scheduler does not hold MyInvois credentials
- Self-billed e-Invoice for foreign suppliers: schema supports it, no UI
- Goods Received and Purchase Request screens (the types exist in the
  schema; only PO, Bill and Purchase Credit Note are exposed in the app)
- ~~E-mail delivery of anything.~~ Built and deployed: documents send
  through Resend, overdue invoices are chased on a schedule, and every
  send is logged per document. What is left is not code — a provider
  account, two secrets and a DNS record. See `docs/email-setup.md`
- Bank statement import and auto-matching
- Statutory submission files: CP39, Borang A, Lampiran 1 and the EA form
  are all computable from what is stored, but no exporter is written
- The gazetted KWSP and PERKESO contribution tables (see HRMS above)
- Biometric terminal integration: attendance records carry a terminal
  identifier, but nothing pushes punches in from a device yet
- Sign-in with anything other than a password: no OAuth, no magic link,
  no two-factor
- Migration from another accounting system. `docs/migrating-from-autocount.md`
  plans one from AutoCount Cloud and names what has to be built first —
  chiefly that **no table records where a row came from**, so no import
  can be re-run, reconciled or rolled back until it does

### Built, but not reachable from the app

Worse than unbuilt, because the schema suggests otherwise.
`docs/gaps-against-autocount.md` has the detail; the short version is
that four capabilities exist in the database with **zero references in
`app/lib`**:

- **Multi-currency.** `ref_currencies`, `exchange_rates` and a `currency`
  and `exchange_rate` on every document and journal. The editor holds
  `_currency`, reads it from a saved document and writes it back, but no
  widget ever changes it — so no foreign-currency document can be raised,
  and there is no revaluation function to restate balances if one could be
- ~~**Project and department dimensions.**~~ Both are now written from
  the document header and read by the P&L's dimension filter. See
  `docs/departmental-accounting.md`, which also names what is still not
  covered: expenses and manual journals offer no department, so costs
  arriving by those two routes are under-reported by department
- **Price levels.** `price_levels` and `item_prices`, unused by the line
  editor
