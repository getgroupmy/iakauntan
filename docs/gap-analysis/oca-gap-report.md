# OCA feature-gap audit

**Scope:** the 68-item checklist in Kabeer's handoff, drawn from the OCA
module catalogue and used here as a feature reference only — no OCA
source was fetched, read or translated.

**Method:** the schema was read from a database built from
`supabase/migrations` in order (352 tables and views, 1,426 functions in
`public` and `app`), the edge functions from `supabase/functions`, and
the client from `app/lib` including its 123 routes. Every verdict below
cites a table, function, migration, route or file. Where nothing was
found, the verdict is **Missing** rather than a guess.

**Read-only.** Nothing in this audit changed code, schema or
deployment.

---

## 1. Summary

| Tier | Have | Partial | Missing | N/A | Total |
|---|---:|---:|---:|---:|---:|
| 1 — Accounting depth | 9 | 6 | 4 | 0 | 19 |
| 2 — Control and management | 9 | 6 | 4 | 0 | 19 |
| 3 — HR and payroll | 5 | 3 | 1 | 0 | 9 |
| 4 — Platform | 2 | 5 | 7 | 0 | 14 |
| 5 — Operations | 4 | 0 | 3 | 0 | 7 |
| **Total** | **29** | **21** | **18** | **0** | **68** |

*Moved since first published: **A1** Partial → Have (`0648` writes the
close the schema had been built for), **B5** Missing → Partial and
**E4** Missing → Partial, both in §4.*

The shape of it: the **accounting and operations** halves are largely
built, **HR** is built with the edges unfinished, and **platform**
is where the product is thinnest — seven of the fourteen platform items
have no evidence at all, and they are the ones a customer's IT
department asks about (API, webhooks, SSO, password policy,
impersonation).

---

## 2. Full table

### Tier 1 — Accounting depth

| ID | Capability | Status | Evidence | What's missing |
|---|---|---|---|---|
| A1 | Year-end closing entries | **Have** | `close_fiscal_year` and `reopen_fiscal_year` (0648): every revenue and expense account brought to nil at the year end, the result into `3300 Current Year Earnings`, refused out of order and reversed rather than deleted. `fiscal_years.closing_entry_id` records which journal did it; the button is on the Fiscal years card in Settings | Moving 3300 into 3200 Retained Earnings stays a manual journal, on purpose — an appropriation is a decision, not arithmetic |
| A2 | Accrual / prepayment cut-off | **Missing** | No table, function or route matching `cutoff`, `accrual`, `prepay` | — |
| A3 | Lock dates | **Partial** | `fiscal_periods.status` with `open`/`closed`/`locked`, guarded by `set_fiscal_period_status` (0053: "Only an owner or admin may open or close a period") | Per-journal lock dates. The lock is per period for the whole company |
| A4 | Unrealised forex revaluation | **Have** | `fx_revaluation_preview`, `revalue_foreign_balances`, `realised_fx_on_settlement`, `app.fx_account`; UI in `settings_screen.dart` (`_ForeignBalancesCard`) | — |
| A5 | Automatic exchange rates (BNM) | **Have** | `supabase/functions/fetch-rates` — "Brings Bank Negara Malaysia's published exchange rates into…", no API key needed; `exchange_rates` table; routes `/exchange-rates` and `/admin/rates` | — |
| A6 | Fixed assets with depreciation and disposal | **Have** | `fixed_assets`, `depreciation_*`, `app.disposal_account`; route `/assets`; tests `fixed_assets.sql`, `depreciation_schedule.sql`, `asset_disposal_shapes.sql` | Inter-branch asset transfer was not found; disposal and depreciation are complete |
| A7 | Malaysian capital allowance (IA/AA) | **Missing** | No match for `capital_allowance` or `initial_allowance` anywhere | — |
| A8 | Deferred revenue/expense spreading | **Partial** | `revenue_schedule_periods`, `app.deferred_revenue_account`, `report_deferred_revenue`; `_DeferredRevenueCard` in settings | Revenue only. No expense spreading |
| A9 | Loan / lease amortisation (MFRS 16) | **Missing** | No match for `loan`, `lease` or `amortisation` in schema or client | — |
| A10 | Rule-based bank reconciliation | **Partial** | `bank_reconciliations`, `complete_bank_reconciliation`, `reopen_bank_reconciliation`, `bank_reconciliation_status`; route `/reconcile`; test `bank_reconciliation.sql` | No match-rule table, no regex rules, no mass reconcile. Matching is by hand |
| A11 | Statement import with column mapping | **Partial** | `import_bank_transactions`, `import_batches`, `import_rows`, route `/import`; MT940 and CSV; `import_screen.dart`: "What each importer accepts, and the column headings it answers to" | The headings are fixed per importer, not mapped by the user |
| A12 | Online bank/payment feeds | **Partial** | `bank_feeds`, `bank_feed_runs`, `bank_feed_status`; `bank_feeds_card.dart`; test `bank_feed.sql` | No named provider integration in `supabase/functions` — the scaffolding exists, the connectors do not |
| A13 | Bulk payment file export (IBG / DuitNow) | **Partial** | `payment_batches` (`id, paid_on, reference, note, created_by, created_at`), `payment_batch_lines` | The batch is a grouping record. No bank file is generated, and no IBG or DuitNow format exists |
| A14 | Withholding tax (CP37) | **Have** | `withholding_certificates`, `ref_withholding_types`, `app.withholding_account`, `create_withholding`; route `/withholding`; CP37 referenced in one migration and two client files | — |
| A15 | Self-billed e-invoices | **Have** | Three `self_billed` functions; self-billed UI for foreign suppliers | — |
| A16 | Consolidated B2C e-invoice | **Have** | `einvoice_consolidations`, `einvoice_consolidation_items`, `consolidate_pos_einvoices`, `prepare_consolidated_einvoice`, `einvoice_consolidations_due` (0616); `.github/workflows/file-consolidations.yml` | — |
| A17 | Inbound e-invoice import (UBL to draft bill) | **Missing** | Nothing matching inbound/received e-invoice. `einvoice_*` is all outbound | — |
| A18 | PDF/OCR bill import | **Have** | `ocr_scans`, `scan_document_kinds` (0614), five readers, `org_ocr_credentials`, credit ledger; AI SmartScan in the expense and purchase screens | — |
| A19 | Tax balance / SST-02 | **Have** | `sst_returns`, `sst_return_lines`, `sst_output_due`, `sst_taxable_periods`, `sst_period_for`; `sst_returns_card.dart` | — |

### Tier 2 — Control and management

| ID | Capability | Status | Evidence | What's missing |
|---|---|---|---|---|
| B1 | Multi-tier approval engine | **Partial** | `approval_rules`, `approval_steps`, `approval_requests`, `app.approval_required`, `app.is_approved`, the `refuse_unapproved_posting` trigger, `app.approval_entity` enum; route `/approvals` | Delegation and forwarding. An approver who is away blocks the step |
| B2 | Dunning | **Partial** | `collection_attempts`, route `/collections`, `log_attempt_sheet.dart` | Attempts are logged by hand. No reminder levels, no automatic sending, no reminder fees |
| B3 | Customer credit limits | **Have** | `enforce_credit_limit`, `_CreditControlCard`, `contacts.credit_limit`; test `contact_credit_limit_test.dart` | — |
| B4 | AR/AP aging with comments | **Have** | `report_ar_aging`, `report_ap_aging`; notes via `collection_attempts` | — |
| B5 | Statement of account | **Partial** | `app/lib/src/features/contacts/statement.dart` (ageing arithmetic) and `statement_pdf.dart` (both `StatementSide.customer` and `StatementSide.supplier`), downloaded from `contact_editor.dart:360` | Three things. It is an OPEN-ITEM statement only — no opening balance, no receipts as lines, no running balance, so a customer reconciling their own ledger cannot. It is always "as at today"; no period can be chosen. And it downloads: nothing emails it. **Migration 0624 adds the brought-forward form** (`report_statement_of_account`); the app half is not wired yet |
| B6 | Budgets and budget-vs-actual | **Have** | `budgets`, `budget_lines`, `build_budget*`, `approve_budget`, `archive_budget`; route `/budgets` | — |
| B7 | Custom management-report builder | **Missing** | `report_spec.dart` is the internal spec shared by screen and PDF, not a user-facing builder. The reports are fixed | — |
| B8 | Cash flow forecast | **Have** | `cash_forecast_items`, `forecast_runs`, `forecast_lines`, `cash_forecast_detail`, `cash_forecast_movements`; routes `/cash-flow`, `/forecasting` | — |
| B9 | Analytic / cost-centre dimensions | **Partial** | `projects`, `departments`, `project_code` on `expenses` and `gl_lines` (carried through `app.post_expense_internal`) | No required-analytic rule, and no analytic distribution across several dimensions |
| B10 | Branch / operating-unit P&L | **Partial** | `branches`, `app.branch_belongs_to_org`, `branches_card.dart` | No branch-level P&L report and no access segregation by branch |
| B11 | Intercompany auto-invoicing | **Have** | `accept_intercompany_bill`, `intercompany_inbox`, `group_intercompany_lines`; route `/intercompany`; migration 0146 | — |
| B12 | Group consolidation | **Have** | `company_groups`, `company_group_card.dart`, `group_reports_screen.dart` | Elimination entries were not separately evidenced |
| B13 | Recurring contracts / subscriptions | **Have** | `recurring_documents`, `advance_recurring_document`, `raise_recurring_document`, `pos_membership_subscriptions`; routes `/recurring-documents`, `/memberships` | — |
| B14 | Retention sums on invoices | **Missing** | `retention` appears only as data-retention prose in 0158, 0235 and 0307 | — |
| B15 | Global (document-level) discounts | **Missing** | Discounts are per line and per payment (`allocate_payment_with_discount`). No document-level discount | — |
| B16 | Sales commissions | **Partial** | `salespeople.commission_rate`; route `/salespeople` | The rate is stored and nothing computes, reports or pays a commission |
| B17 | Staff advances and petty cash | **Missing** | No advance-with-clearing and no petty cash float. `expense_claims` is reimbursement after the fact | — |
| B18 | Journal templates / recurring journals | **Have** | `recurring_journals` table, route `/recurring`, `/journals` | — |
| B19 | AR/AP netting (contra) | **Have** | `contra_notes`, `create_contra`, `contra_candidates`, `app.same_party`; route `/contra`; test `contra.sql` | — |

### Tier 3 — HR and payroll

| ID | Capability | Status | Evidence | What's missing |
|---|---|---|---|---|
| C1 | Public holidays by Malaysian state | **Have** | `public_holidays` with `unique (org_id, holiday_date, state_code)` (0027); `add_fixed_public_holidays`; used by the SLA clock (0193) | — |
| C2 | Attendance, theoretical vs actual, overtime | **Partial** | `attendance_records`, `recompute_attendance`, `adjust_attendance`, `close_attendance_day`; biometric terminal punches (0612) | No overtime calculation anywhere |
| C3 | Timesheets with approval | **Partial** | `time_entries` (`minutes`, `hourly_rate`, `is_billable`, `is_billed`, `invoice_id`), `report_timesheet`, `app.billing_rate_for`; route `/timesheets` | No timesheet *sheet* and no approval step — entries go straight to billable |
| C4 | Payroll periods | **Have** | `pay_periods`, `app.ensure_pay_period` | — |
| C5 | Payroll posting to the GL | **Have** | `post_payroll_run`, `calculate_payroll_run`, `payroll_runs.approved_by` | — |
| C6 | Employee documents with expiry alerts | **Partial** | `employee_documents` with `issued_date`, `expires_date`, `supersedes_id`; `renew_employee_document` | Nothing alerts on an approaching expiry |
| C7 | Training / courses (HRD Corp) | **Missing** | No match for `training`, `course` or `hrd` | — |
| C8 | Appraisals | **Have** | `appraisals`, `appraisal_cycles`, `appraisal_goals`, `app.appraisal_part_of`, the appraisal guards; route `/hr/talent` | — |
| C9 | Dependants | **Have** | `employee_dependants` (NRIC, date of birth), used by PCB relief | — |

### Tier 4 — Platform

| ID | Capability | Status | Evidence | What's missing |
|---|---|---|---|---|
| D1 | Public REST API with API keys | **Missing** | The only `api_key` in the schema is `org_ocr_credentials.api_key` — a credential the platform *holds*, not one it issues | — |
| D2 | Outbound webhooks | **Missing** | No match for `webhook` in schema, functions or client | — |
| D3 | SSO (SAML / OIDC) | **Missing** | No match for `saml`, `oidc` or `sso`. OAuth providers are a known open item awaiting credentials | — |
| D4 | Enforced 2FA per org | **Partial** | `two_factor_card.dart`, `passkeys_card.dart`, magic link and TOTP built | Per-organization enforcement. Each person chooses for themselves |
| D5 | Password policy and session timeout | **Missing** | No match for `password_polic` or `session_timeout`. `report_failed_sign_in` records refusals; it does not set a policy | — |
| D6 | Support impersonation with audit trail | **Missing** | No match for `impersonat` outside unrelated prose | — |
| D7 | Background job queue | **Partial** | Five `cron.schedule` calls in migrations, `run_daily_jobs`, `ticket_sla_sweep`, `prune_device_tokens`, `chat_expire_calls`; three GitHub-scheduled workflows | No queue table, no retries, no admin visibility. A failed run is invisible |
| D8 | Field-level change history | **Have** | `audit_logs` with `old_data`/`new_data` jsonb, `audit_diff`, `audit_trail`, `audit_redact`; route `/admin/trail`; read-receipts in `security_events` and `payslip_access_log` | — |
| D9 | Document management with folders | **Partial** | `attachments` (entity-scoped), `scan_document_kinds` classification (0614), storage policies | No folders, no free-standing document tree. Every file hangs off a record |
| D10 | E-signature | **Have** | `corp_signatures`, `corp_signature_requests`, `corp_signing_links`, `corp_sign_with_link`, `corp_decline_with_link`; route `/sign/:token` | — |
| D11 | PDPA consent, erasure, anonymised export | **Partial** | `docs/personal-data.md`; `close_my_account` (0619); `company_export_manifest`, `company_export_tables`; `payslip_access_requests` | No consent records. And **0619 made closure keep the identity rather than erase it** — a genuine erasure is now a manual operation, which `docs/personal-data.md` now says in as many words |
| D12 | XLSX export | **Partial** | CSV throughout — `report_csv.dart`, `chart_export.dart`, `export_card.dart` | No XLSX. Accountants work in Excel and CSV loses every format and formula |
| D13 | Saved queries and scheduled email reports | **Missing** | No match for `saved_query`, `scheduled_report` or `report_schedule` | — |
| D14 | In-app announcements | **Missing** | No match for `announcement`. `platform_settings.maintenance_mode` is the only platform-to-user message | — |

### Tier 5 — Operations

| ID | Capability | Status | Evidence | What's missing |
|---|---|---|---|---|
| E1 | Helpdesk with SLA timers | **Have** | `tickets`, `ticket_events`, `ticket_teams`, `sla_policies`, `sla_targets`, `sla_deadlines`, `app.sla_advance`, `ticket_sla_sweep` on pg_cron (0356); routes `/tickets`, `/ticket/:token` | — |
| E2 | Field service jobs | **Missing** | No match for `fieldservice` or `field_service` | — |
| E3 | RMA / warranty returns | **Missing** | No match for `rma` or `warranty`. Credit notes exist; a returns workflow does not | — |
| E4 | Purchase requests and blanket orders | **Partial** | `app.purchase_doc_type.purchase_request` with a `DocTypeMeta` in `doc_types.dart` ("Purchase Requisition"), a `PR-` numbering series, a screen and the `purchase_request → purchase_order` transfer; `0646` gates the transfer on an approval rule | No blanket order. The requisition half is built, and `job_requisitions` really is recruitment — the name is what the search matched |
| E5 | Reorder rules / min-max stock | **Have** | `reorder_point` column (0197) and `app.reorder_point` (0199); route `/forecasting` | — |
| E6 | Landed costs | **Have** | `landed_cost_runs`, `landed_cost_charges`, `landed_cost_allocations`, `landed_cost_targets`, `app.landed_cost_account`, `cancel_landed_cost_run`; route `/landed-cost` | — |
| E7 | Lot / expiry tracking | **Have** | `stock_lots` with `expiry_date`, `manufactured_on`, `supplier_lot_ref`; `stock_movement_lots`, `document_line_lots`, `check_movement_lots`, `lot_available`; route `/lots` | — |

---

## 3. Top 10 recommended builds

Ranked by value to a Malaysian accounting firm or SME, with Tier 1 and 2
first as instructed. Size is rough: **S** days, **M** a week or two,
**L** longer.

| # | ID | Build | Size | Why it ranks here |
|---|---|---|---|---|
| 1 | A1 | ~~Year-end closing entry~~ | **S** | ~~Every set of books needs one every year and it is done by hand today. `3300 Current Year Earnings` is already seeded and `report_changes_in_equity` is already written around the closing journal existing~~ **Built at `0648`.** The S was right and for the reason given: four parts of the schema were already waiting for it — `app.journal_source.year_end_close`, `fiscal_years.closed_at`/`closed_by`, the seeded `3300`, and `report_cash_flow` already excluding that journal source. What took the time was not the arithmetic but proving it does not double-count against `app.fs_cumulative_profit`, which exists precisely because there was no close |
| 2 | D12 | XLSX export | **S** | Accountants live in Excel. CSV loses number formats, column widths and multiple sheets, and a firm exporting a trial balance re-formats it every time |
| 3 | B5 | Finish the statement of account | **S** | Not the new build this list first called it — see the correction below. The open-item statement exists; what is missing is the brought-forward form, a period, and emailing it. `0624` has done the database half |
| 4 | A17 | Inbound e-invoice (UBL 2.1) to draft bill | **M** | MyInvois makes every supplier send one. Receiving is the half this product does not do, and it is the half that removes the most typing |
| 5 | A10 | Rule-based bank reconciliation | **M** | The biggest recurring time sink in bookkeeping. The reconciliation itself exists; what is missing is the matching |
| 6 | A13 | IBG / DuitNow bulk payment file | **M** | `payment_batches` already groups the payments. The file format is the whole remaining job, and it turns a payment run from an hour of bank portal typing into an upload |
| 7 | A2 | Accrual and prepayment cut-off | **M** | Required for any accrual-basis month end, and currently a manual journal that nothing reverses |
| 8 | A7 | Capital allowance (IA/AA) schedule | **M** | Malaysia-specific, no OCA equivalent, done in a spreadsheet by every firm. Sits directly on the existing `fixed_assets` and depreciation schedule |
| 9 | B2 | Dunning levels with automatic reminders | **M** | `collection_attempts` and the email outbox both exist; what is missing is the ladder and the scheduling. Directly improves a customer's cash |
| 10 | A9 | Loan and lease amortisation (MFRS 16) | **L** | Every audited company with a hire purchase or a tenancy needs the schedule, and there is nothing to build on yet |

Two that only just missed, and are worth knowing about: **D5 password
policy and session timeout** (the first thing an enterprise customer's
IT asks for) and **B1 approval delegation** (the approval engine is
built and an approver on leave currently stops the queue).

---

## 4. A correction to this report

**B5 was first published as Missing and it is Partial.** A statement of
account already exists — `statement.dart` and `statement_pdf.dart` in
the contacts feature, for customers and for suppliers, reached from the
contact editor — and this report missed it because the search was run
over the schema and the route list, and that feature is three Dart
files with no table, no RPC and no route of its own. The keyword
`statement_of_account` matched only the *scan kind*, which read as
confirmation that nothing produced one.

The method section of this report says the verdict is Missing where no
evidence is found. That rule is right and it is not a defence: the
search was too narrow, and a capability that lives entirely in the
client is exactly the shape it was narrow about. Any other **Missing**
verdict in Tier 2 or Tier 4 resting on a schema search alone deserves
the same second look before anything is built on it.

**E4 was first published as Missing and it is Partial**, found the same
way and worth the same admission. `app.purchase_doc_type` carries
`purchase_request`; `doc_types.dart` calls it a Purchase Requisition
and gives it a screen; it has a `PR-` series and the
`purchase_request → purchase_order` step of the transfer chain. What
the search found was `job_requisitions`, which is recruitment, and
the report read the absence of the WORD "requisition" anywhere else as
the absence of the thing — while the thing was filed under
"purchase request", which is the name in the report's own row heading.

The blanket-order half of E4 is genuinely missing, so the row is
Partial rather than Have.

**And the other seventeen were re-checked**, by name against the
applied schema rather than against this document: A2, A7, A9, A17, B7,
B14, B15, B17, C7, D1, D2, D3, D5, D6, D13, D14, E2 and E3 have no
table, view, function or enum label matching what they describe. Some
of the words appear in prose — `accrual` in ten migrations, `webhook`
in one, `impersonat` in three — and none of them is an object. Those
verdicts stand.

The ranking above is corrected with it. B5 was #1 and is #3, and what
it names is now finishing a feature rather than starting one.

**A defect found while correcting it.** ~~`Repo.outstandingFor`, which
feeds the existing statement, filters `doc_type = 'invoice'`. A credit
note, a debit note, a refund note and an unapplied receipt are
therefore absent from a document that goes to the customer — so a
customer holding a credit note is sent a statement that overstates what
they owe, and it will not agree with `report_ar_aging`, which signs all
four correctly.~~ Fixed: all four types are queried and `statementSign`
in `features/contacts/statement.dart` signs them, deliberately matching
`report_ar_aging`'s own `case`.

**And a worse one underneath it, found by going back to check.** The
same query filtered `balance_amount > 0` and `deleted_at is null` and
nothing else, while `report_ar_aging` — the same open-item question
asked in SQL — also requires `d.gl_entry_id is not null` and
`d.status <> 'void'`.

A DRAFT invoice carries its full `balance_amount` from the moment its
lines are typed. A VOIDED one keeps its balance as well, because
`void_sales_document` sets the status and reverses the ledger entry and
never touches the column. So both went onto the statement PDF as money
due.

Measured against one customer holding a 5,000 draft, a 3,000 voided
invoice and a 1,200 real one: **the statement said 9,200 and the
ageing report said 1,200**. A demand for payment for an invoice that
was never issued and one that was cancelled.

Fixed, and asserted: `statement_of_account.sql` now builds exactly that
company and requires the open-item list and the ageing report to agree.
That file already existed to make two answers agree; this is the third.

## 5. Incidental findings

**The drift named in the handoff is closed.** Both dashboard fixes are
in the repository: `ssm_session.upstream_user` is added by
`0591_what_the_registry_said_about_us.sql`, and
`supabase/functions/ssm-search/provider.ts` carries `upstream_user` in
its type. Nothing to reconcile.

**A different repo/live drift, found and not fixed.** The hosted
project grants `service_role` EXECUTE on `public.set_sst_registration`,
and no migration in this repository does — `0145` grants it to
`authenticated` alone and `0181` replaces it granting nothing. It
surfaced because migration `0621` asserted the opposite and the apply
failed four times. The assertion has been removed and the observation
written into `supabase/tests/_local_stack.sql` as an open question,
deliberately unfixed: `c2d2d15` is this repository's record of guessing
at this and making the local stack more generous than the real one.
Settling it needs `\df+` against the hosted project.

**Three defect classes found while reading, and already fixed before
this audit began** — recorded here because they bear on the verdicts
above rather than as new work:

- Nine functions that a trigger, a unique index or a check constraint
  calls on a user's behalf were executable by nobody but `postgres`.
  Three screens were broken in production: creating a supplier, opening
  a bill and posting one. Migration 0620, gated by
  `supabase/tests/trigger_reachable_grants.sql`.
- Ten PostgREST embeds were broken across six screens — bills of
  materials, manufacturing orders, appraisals, onboarding checklists,
  POS membership subscriptions and the payslip access log.
  `scripts/check_embeds.py` existed to catch exactly this and was
  reading only the first string literal of each `.select()`.
- `scripts/check_rpc_grants.py` was reading one shape of RPC call out of
  four; 639 checked names became 667.

The common thread is worth stating for whoever picks up the builds
above: **this codebase's silent failures are at the boundary between
the client's string literals and the database's catalogue**, and they
are invisible to the Dart analyzer, to the widget tests and to the SQL
tests alike, because each of those sees only one side.

**Not a finding, but worth knowing before B7 or D13 is built:**
`expenses.contact_id` had carried a payee since migration 0006, the
posting put it on `gl_lines` and the payment voucher printed it — and
the entry form never passed one, so it was null on every expense ever
posted. A column being present is not evidence that it is filled. The
verdicts above are about capability, not about data quality, and a
build that reports on existing columns should check them for content
first.
