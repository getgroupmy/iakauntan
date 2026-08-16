# Where personal data goes

Written from a full pass over the schema, the edge functions and the
client. Reproduce the inventory with:

```sql
select table_name || '.' || column_name from information_schema.columns
 where table_schema = 'public'
   and column_name ~* '(email|phone|nric|passport|dob|birth|address|postcode'
                    '|bank_account|salary|tin|gender|marital|nationality'
                    '|photo|avatar|ip_address|user_agent|device|token)';
```

This is a payroll and accounting system for Malaysian companies, so the
sensitive data is not incidental — it is the product. A national identity
number, a bank account, a date of birth and a salary all sit in it by
design.

## What is collected, and where it lands

| Category | Entered at | Stored in |
|---|---|---|
| Account identity — name, email, phone, avatar | Sign-up, Settings | `auth.users`, `profiles` |
| Password | Sign-up, reset | `auth.users.encrypted_password` only — **bcrypt**, never in `public` |
| Employee record — NRIC, passport, date of birth, gender, marital status, nationality, address, phone, email, bank account, salary, income tax number | HR → Employees | `employees` |
| Dependants — NRIC, date of birth | Employee record | `employee_dependants` |
| Payslip snapshot — NRIC, bank account, wages | Payroll run | `payslips` |
| Candidates — NRIC, phone, email, expected salary | Recruitment | `applicants` |
| Officers and shareholders — NRIC, passport, date of birth, address | Corporate secretarial | `corp_persons` |
| Customers and suppliers — name, address, phone, email, TIN | Contacts, imports | `contacts`, `contact_persons`, `contact_addresses` |
| Attendance — clock-in address and device | Clock in/out | `attendance_records` |
| IP address and user agent | Every audited write; signing and share links; payslip views | `audit_logs`, `corp_signatures`, `corp_signing_links`, `document_share_links`, `payslip_access_log` |
| Push device tokens | Enabling notifications | `device_tokens` |

Every one of these tables has row level security. Verified rather than
assumed: as `anon` with no JWT, `organizations`, `gl_lines`, `payslips`,
`profiles` and `employees` all return **0 rows** while the same queries as
owner return 3, 58 and 6 — so the zeros are the policies, not an empty
database. `einvoice_credentials` and `org_ocr_credentials` refuse
outright; they carry RLS with no policies at all and only the service
role reaches them.

Colleagues can see each other's `profiles` row — `(id = auth.uid() OR
app.shares_org_with(id))`. That is deliberate and scoped to shared
organizations, not global.

## What leaves the system

| Service | What is sent | Why |
|---|---|---|
| **LHDN MyInvois** | Buyer and supplier name, TIN, address, email, phone, and every invoice line | Statutory e-Invoice submission |
| **Resend** | Recipient address, subject, body, attachment | Sending a document or a reminder |
| **Google Document AI** | The receipt or bill image | Reading a scanned document — **off by default, opted into per company** |
| **FCM / Web Push** | Device token, notification title and body | Push notifications |
| **Bank Negara** | Nothing | Exchange rates only |
| **SFU (calls)** | A signed room token, no profile data | Voice and video |

No analytics SDK, no error-tracking SDK, no payment processor, and no AI
API beyond the OCR above. Nothing sends a user's data anywhere it is not
needed for the feature that was asked for.

`einvoice_logs` keeps the full request and response of every MyInvois
call — buyer details included — because LHDN requires the trail for seven
years. It is org-scoped and read-gated.

## Logs

Server logs carry no personal data. The one exception was
`supabase/functions/myinvois/index.ts`, which logged the raw error
object; an error thrown anywhere in that function may be carrying a
MyInvois request or response, and those hold the buyer's name, TIN,
address and every invoice line. It now logs the action, the error type
and the message. The full exchange is not lost — `persistLogs` writes it
to `einvoice_logs`, where it belongs.

The push functions log status, platform and an error message, never a
token. The Flutter client has no `print` statements at all.

## The browser

`supabase_flutter` keeps the session in browser storage, and the JWT
carries the user's id and email. That is inherent to a single-page app
holding a bearer token; the mitigations are PKCE (on), the short life of
the access token, and RLS behind it — not moving the token somewhere
JavaScript cannot read, because there is nowhere on that page it cannot.
No application code writes anything else to browser storage.

## Closing an account

`public.delete_my_account()` — Settings → Close this account.

It **anonymises**, and the wording in the app says so rather than
promising a delete it does not perform. Name, email, phone and avatar are
scrubbed from `profiles` and `auth.users`, membership and push tokens are
deleted, sessions are killed and sign-in is shut with `banned_until`.

The `auth.users` row itself stays, because about a hundred foreign keys
point at it — `gl_entries.posted_by`, `payroll_runs.approved_by`,
`corp_signatures.signed_by` — almost all `ON DELETE NO ACTION`. Those
columns are the audit trail. Deleting the row would either cascade
through the ledger or leave a journal that cannot say who posted it, and
both destroy records the Companies Act 2016 s.245 and the Income Tax Act
1967 s.82 require to be kept for seven years. Anonymisation is the
correct answer here, not a lesser one.

The sole owner of an organization is refused, by name, before the button
is offered — closing would leave a company's books with nobody able to
administer them.

**What this does not do:** it does not remove an employee's payroll
records. Those belong to the employer's statutory records, not to the
account that happened to log in, and erasing them on request is not
something an employer may lawfully do inside the retention window.
Someone acting on a PDPA request needs to handle that separately and
deliberately.
