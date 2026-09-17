# iAkauntan × AutoCount Cloud Accounting — gap matrix

**Baseline:** the handoff prepared in Cowork from the AutoCount Cloud
Accounting help site. **Method:** every item below was checked against a
database built from `supabase/migrations` in order (353 tables and
views, 1,428 functions), the edge functions, and the Flutter client
including its 123 routes. Evidence is a table, column, function,
migration, screen or route. Nothing here changed code or schema.

**Read this first.** The handoff calls its own list "candidates to
verify, not a verdict", and it was right to: **five of the nine gap
candidates turn out to be Present or Partial with substantial work
already done**, and one — G5 recurring invoices — is complete. The
useful output of this audit is therefore narrower and more actionable
than the handoff's own ranking: three real gaps, and a set of
finishing work on things that already exist.

---

## 1. Gap candidates (§2 of the handoff)

| # | Area | AutoCount function | iAkauntan status | Evidence | Effort | Recommendation |
|---|---|---|---|---|---|---|
| G1 | Bank | CSV + PDF statement import, bank rules, match-or-create, reconciliation, direct feeds | **Partial** | `bank_transactions` carries `is_reconciled`, `reconciled_at`, `reconciliation_id`, `matched_table`, `matched_id`, `import_batch_id`, `raw_data`; `bank_reconciliations` + `complete_bank_reconciliation`, `reopen_bank_reconciliation`, `bank_reconciliation_status`; `reconciliation_screen.dart`, `reconciliation_history_dialog.dart`, `book_balance.dart`; `statement_import.dart` parses **CSV by header name** (signed amount or separate debit/credit columns) **and MT940**; `bank_feeds`/`bank_feed_runs` spine from 0567, which says in as many words that it wrote no connector | **M** | Build `bank_rules` (ordered conditions → account/contact/tax code) and auto-match. That is the missing half and the one that saves the time. PDF import after. Feeds need a bank agreement — leave |
| G2 | Tax | SST Processor: period run, SST-02, payment-collection listing, 12-month unpaid service tax, commit → journal | **Partial** | `sst_returns` (`period_start`, `period_end`, `due_date`, `tax_declared`, `reference`, `filed_at`, `filed_by`), `file_sst_return`, `sst_return_lines`, `sst_taxable_periods`, `sst_period_for`, `sst_output_due`, `report_sst_summary`, `report_sst_due`, `sst_returns_card.dart` | **L** | The biggest true gap. `sst_returns` has no `status` and no `journal_id`, so filing records a figure and posts nothing to an SST control account; `tax_codes` has no payment-basis flag, so service tax on a payment basis and the 12-month rule are not modelled at all; no SST-02 print and none of the three listings. Needs a design pass before code |
| G3 | e-Invoice | Get TIN link, customer tax import, self-billed, consolidated self-billed, document inquiry, relaxation flag, tariff code | **Partial** | Self-billed: `prepare_self_billed_einvoice`, `set_requires_self_billed`, `suggest_self_billed`, `einvoice_documents.is_self_billed`. Consolidated: `einvoice_consolidations` + `prepare_consolidated_einvoice` (0616). TIN: `tin_validations` (`tin`, `id_type`, `id_value`, `is_valid`, `response`); `contacts.is_tin_verified`, `tin_verified_at`. Inquiry: `einvoice_documents` carries `submission_id`, `myinvois_uuid`, `validation_link`, `qr_code_data`, `status`, `cancel_deadline`, `rejection_reason`, `validation_errors`, `retry_count`, with `/einvoice`. Import of customer tax info: `import_screen.dart` maps `tin` and `sst_registration_no` | **M** | Three genuinely missing pieces, of which (a) is now BUILT (`0626`, `0627`): (a) ~~the **Get TIN** public link~~ — the tokenised-share pattern already existed (`app.issue_share_token`, `open_customer_portal`) and nothing yet wrote a contact's tax fields from a public form. It does now: `request_tax_details`, `open_tax_detail_request`, `submit_tax_details`, and the rule that a public submission fills a blank and never overwrites; (b) the **relaxation-period** flag on the company; (c) **tariff/HS code** — `items.classification_code` is LHDN's classification list, which is a different thing. Consolidated self-billed not evidenced |
| G4 | OCR | Document Scanner → Sales Invoice / Purchase Invoice / Cash Book Entry; CA Uploader mobile capture | **Present**, and the verdict below is corrected in §3.1 | `ocr_scans`, `scan_document_kinds` with a `destination` per kind (0614), five readers, `org_ocr_credentials`, scanning credit metered; `document_classifier.dart`; capture from camera or file via `captureAndRead`/`CaptureSource`; wired into the expense and purchase screens | **M** | **This was wrong about four of its five parts.** The emit exists (`document_list_screen.dart:_scanInto`), supplier match exists (`supplier_from_scan.dart`), line extraction exists (`pendingScanProvider` + `document_editor.dart:_applyScan`) and the editor IS the review-before-post screen. Only **duplicate detection** was genuinely missing; `0628` adds it. See §3.1 |
| G5 | Sales | Recurring invoices: frequency, end rule, pause, generation log, scheduled creation | **Present** | `recurring_documents` (`frequency`, `interval_count`, `start_date`, `end_date`, `max_occurrences`, `occurrences`, `next_run_date`, `last_run_date`, `last_document_id`, `auto_post`, `auto_email`, `is_active`, `last_error`, `last_error_at`); `create_recurring_document`, `advance_recurring_document`, `raise_recurring_document`; `recurring_journals` separately; route `/recurring-documents`; generated server-side by `run_daily_jobs` on pg_cron, not on book-open | **—** | Nothing to build. One nicety: the run "log" is three columns on the row rather than a table, so a company cannot see the last twelve runs. Note it, do not build it yet |
| G6 | Data | Excel import of sales invoices, credit notes; AR/AP opening balances as outstanding invoices | **Partial** | `import_batches`, `import_rows`, `import_accounts`, `import_bank_transactions`; **`0150_import_open_items.sql` imports AR/AP opening balances as open items** — the migration case the handoff singles out is already done; per-row provenance (`import_source`, `import_ref`, `import_batch_id`, `imported_at`) from 0610; `/import` with per-importer column headings | **M** | The hard half is done. What is missing is importing **transactions**: sales invoices, credit notes, purchase invoices and journals, with a validation report before commit and de-dup by document number |
| G7 | Accounting | Knock Off Entry: many-to-many allocation from a standalone screen, from any side | **Partial** | `payment_allocations` carries `receipt_id`, `payment_id`, **`credit_note_id`**, `invoice_id`, `bill_id`, `amount`, `discount_amount`, `withholding_id`, `contra_id`, `deposit_id`, `pdc_id`, `discount_entry_id` — so credit note → invoice, contra, deposits, post-dated cheques and withholding are all already allocatable; `apply_on_account.dart`, `deposit_apply_sheet.dart`, `allocate_payment_with_discount`, `create_contra`, `/contra` | **M** | Richer than AutoCount's on the data side. Missing: a **standalone screen** — pick a debtor, see both sides, apply many-to-many in one action — plus journal → invoice allocation (no `journal_entry_id` on the table) and a printable knock-off listing |
| G8 | Reports | Customisable P&L / Balance Sheet layouts with formula rows | **Missing** | `report_spec.dart` is the internal spec shared by screen and PDF, not a user-facing builder. MBRS taxonomy mapping exists in Financial Statements and is the natural place to hang one | **L** | Real gap, and a Pro-plan feature in AutoCount. Low urgency for an SME, high for an accounting firm |
| G9 | Platform | Own subscription invoice issued as an LHDN e-Invoice | **Missing** | `platform_invoices` already carries `issuer_name`, `issuer_registration_no`, `issuer_sst_no`, `issuer_address`, `bill_to_name`, `bill_to_registration_no`, `bill_to_tin`, `bill_to_address`, `tax_rate`, `tax_amount` — the data an e-Invoice needs is there. But `einvoice_documents_source_table_check` admits only `sales_documents` and `einvoice_consolidations` (widened by 0616), so a platform invoice cannot be prepared | **M** | Worth doing for what it says: a company selling e-Invoicing that does not e-Invoice its own customers is a question a prospect will ask. Small once the source table is admitted |

---

## 2. "Probably present" (§3 of the handoff), verified

| # | Area | AutoCount function | iAkauntan status | Evidence |
|---|---|---|---|---|
| P1 | Master data | Department | **Present** | `departments` |
| P2 | Master data | Area | **Missing** | Nothing. `pos_floor_areas` is a restaurant floor plan |
| P3 | Master data | Sales Agent | **Present** | `salespeople` with `commission_rate`, `employee_id`, `member_id`; `app.check_salesperson_org`; route `/salespeople`. Note: the rate is stored and nothing computes a commission |
| P4 | Master data | Journal Type | **Missing** | No table, no column |
| P5 | Master data | Payment Method with a bank-charge account | **Partial** | `ref_payment_modes` (8 LHDN modes, platform-wide). No per-company payment method and no bank-charge account on one |
| P6 | Master data | Multiple AR/AP control accounts | **Present** | `contacts.receivable_account_id`, `contacts.payable_account_id`, resolved by `coalesce` against the org default in `app.post_sales_document_internal`; `app.control_account_balance`; asserted in `supabase/tests/control_accounts.sql` |
| P7 | Master data | Product Posting groups | **Partial** | `items.sales_account_id`, `purchase_account_id`, `inventory_account_id`, `cogs_account_id` — per item, which is finer than AutoCount. No named posting GROUP to apply to many items, and no sales-return/purchase-return account |
| P8 | Product | Two-level variants, minimum price, separate supply vs purchase tax code | **Present** | `create_item_variants`, `item_variant_matrix`, `app.items_variant_guard`; `items.min_price`; `items.sales_tax_code_id` and `purchase_tax_code_id` |
| P9 | Cash book | One receipt settling several invoices, several payment methods, bank-charge line | **Partial** | `receipts` + `payment_allocations` settle several invoices. One payment mode per receipt (`payment_mode_code`); no several-methods-per-voucher and no bank-charge line on the voucher |
| P10 | Stock | Periodic inventory mode, Periodic Stock Value | **Missing** | Perpetual only — `stock_movements`, `stock_levels`, `v_stock_valuation`, weighted average in 0009. A decision rather than a gap: say "perpetual only" |
| P11 | Stock | Stock Opening Balance, Adjustment, Transfer | **Present** | `stock_adjustments`, `stock_transfers`, `/stock-take`, `/transfers`; opening balances through `0150` |
| P12 | Stock | Product Inquiry with price history by customer/supplier | **Partial** | `/items`, `v_stock_valuation`, forecasting. No price-history-by-contact view |
| P13 | Settings | Decimal places per field type | **Partial** | `organizations.decimal_places` — one setting for the company, not per field type |
| P14 | Settings | 5-sen rounding Disable / Optional / Enforce | **Partial** | `organizations.rounding_method` (`none`, `nearest_5cent`, `nearest_10cent`) and `app.round_amount`; POS applies it (`pos_rounding_adjustment`). Not offered as a per-document choice on invoices and receipts |
| P15 | Settings | Numbering format: prefix, suffix, year/month tokens, start, width, per document type | **Present** | `number_sequences` (`doc_type`, `prefix`, `suffix`, `padding`, `next_value`, `reset_policy`, `period_key`); `document_numbering`, `set_document_numbering`; `document_numbering_card.dart` |
| P16 | Settings | Default journal type / description per transaction class | **Missing** | No journal types at all (see P4), and no default-description setting |
| P17 | Reports | Debtor and Creditor Statements | **Present** | `statement.dart`, `statement_pdf.dart` (customer and supplier sides), from `contact_editor.dart`; and since `0624` `report_statement_of_account` adds the brought-forward form |
| P18 | Reports | Trial Balance, Ledger, P&L, BS, Debtor/Creditor Aging, Journal listing | **Present** | `report_trial_balance`, `general_ledger`, `report_ar_aging`, `report_ap_aging`, `report_changes_in_equity`, `/reports`, `/financial-statements` |
| P19 | Reports | Monthly Sales Analysis, P&L by Document | **Partial** | `revenue_trend`, `/dashboard`, `/pos-reports`. No per-document margin report |
| P20 | Sales | Void / unvoid, status board, copy from quotation | **Present** | `void_sales_document`, `sales_documents.status`, `/sales` with Draft/Outstanding filters, quotation → order → invoice conversion |
| P21 | e-Invoice | Approval stage before submission | **Present** | `approval_rules`, `approval_steps`, `approval_requests`, `app.approval_entity`, `app.refuse_unapproved_posting`, `/approvals`. Draft expiry and a draft-only role were not evidenced |
| P22 | Tools | Audit Trail with filters | **Present** | `audit_trail(uuid, text, uuid, integer)` — org, record type, record id, limit; `audit_logs` with `old_data`/`new_data`; `/admin/trail`, `/security`. Filtering by **user** and by **date** is not in that signature |
| P23 | Tools | File attachments | **Present** | `attachments`, `attachments_card.dart`, storage policies from 0068 |

---

## 3. Ranked plan

> **Progress, 17 September 2026.** Ranks 1 and 3 are built and on the
> branch; rank 2 got as far as a design note and stopped there
> deliberately, because `mysst.customs.gov.my` is unreachable from the
> machine this was written on and the payment-basis rule, the
> twelve-month long stop and the SST-02 box layout are all assumptions
> until somebody checks them at source. A company filing on figures
> derived from an unverified reading of the Act is worse off than one
> filing the invoice-basis number it has today, because it will believe
> the number. The rows below are struck through rather than deleted:
> what was ranked and why is the record.


Ranked by Malaysian compliance value, then by how often an SME
accountant touches it, then by effort. The handoff's own ranking is
adjusted for what the audit found: G5 drops off entirely, G6 and G7
move down because their hard halves are done, and G3 splits.

| Rank | Item | Why here | Effort |
|---|---|---|---|
| 1 | ~~**G1 bank rules and auto-match**~~ — **BUILT**, `0625` and `bank_rules_card.dart`. Applying a suggestion (creating or matching a voucher) was deliberately left out: it is the step that would post, and it is a separate decision | The single biggest recurring time cost in SME bookkeeping, and the only missing half: import (CSV + MT940) and reconciliation are both built. A rules table and a match-or-create step is a contained piece of work on top of `bank_transactions.matched_table`/`matched_id`, which were put there for it | M |
| 2 | **G2 SST-02 processing** — design pass done, `docs/design/sst-02.md`; BLOCKED on statutory verification | The one item with a statutory deadline behind it. Service tax on a payment basis and the 12-month unpaid rule are not modelled at all, and a company that files on what `sst_returns.tax_declared` holds today is filing on an invoice-basis number. Needs a design pass and dated rate tables with tests before any code | L |
| 3 | ~~**G3(a) the Get TIN link**~~ — **BUILT**, `0626`/`0627` | Every customer of every user needs a TIN before that user can e-Invoice them, and collecting them by phone is the thing that stalls an onboarding. The tokenised-share pattern and `tin_validations` both already exist; this is a public form and a writer | M |
| 4 | ~~**G4 OCR emitting purchase documents**~~ — **mostly already built; the verdict was wrong. See §3.1.** Duplicate detection was the one real gap and is now `0628` | The pipeline, the credit metering and the mobile capture are built. Emitting a bill — supplier match, lines, duplicate detection, review before post — is the step that turns a demo into a day's work saved | M |
| 5 | **G7 the knock-off screen** | The allocation model is already richer than AutoCount's. What is missing is one screen, and it is the screen an accounts clerk lives in at month end | M |
| 6 | **G6 transaction import** | Opening balances already import as open items, which was the migration blocker. Invoice and journal import is a convenience after that, and matters most in the first week of a new customer | M |
| 7 | **G9 own subscription e-Invoices** | Small, and it answers a question every prospect asks. Mostly a matter of admitting `platform_invoices` to `einvoice_documents_source_table_check` | M |
| 8 | **G3(b,c) relaxation flag and tariff code** | Both are single fields with a UI. Do them with whatever e-Invoice work comes next rather than alone | S |
| 9 | **G8 statement layouts** | Real, and an accounting-firm feature rather than an SME one. Hang it off the MBRS taxonomy mapping | L |


### 3.1 A correction to the G4 verdict

This audit recorded G4 as *Partial*, naming five missing pieces, and
ranked it fourth. Four of the five already existed:

| Claimed missing | Where it actually is |
|---|---|
| a scan cannot become a purchase document | `document_list_screen.dart:_scanInto` creates it, files the capture against it and routes to the editor |
| no supplier match | `supplier_from_scan.dart` — `resolveSupplier` searches on the name as printed, narrows on the registration number, offers to create, and asks where two candidates tie |
| no line-item extraction | `pendingScanProvider.park` on the list screen, `document_editor.dart:_applyScan` on the other end. `foldOcrContinuations` in `ocr_repository.dart` even handles the reader that splits one charge across two printed rows |
| no review-before-post screen | the document editor is it — the draft is created empty but for the supplier, number and date, and nothing posts until somebody presses post |
| no duplicate detection by supplier + invoice number | **correct.** Nothing looked for it. `0628`. |

The audit went wrong the same way the OCA report's B5 verdict did, and
the warning written there applies here too: the search ran over the
SCHEMA and the route list, and this feature is Dart with no table, no
RPC and no route of its own. `ocr_scans` has no column that says "this
became a bill", because the link runs the other way — the attachment is
refiled against the document — so a schema search finds a pipeline that
appears to end in a `jsonb`.

The lesson is the one already on record: **a Missing verdict resting on
a schema search alone deserves a second look.** Two of the ten audited
gaps in two reports have now failed on it.

What `0406` got right and this did not: it swept `_no` COLUMNS for
missing unique indexes and deliberately left `supplier_doc_no` alone,
because "two suppliers may perfectly well send invoices numbered
`INV-1`". True. The duplicate that matters is a PAIR — the same
supplier's number twice — and sweeping columns cannot see a pair.

### A separate, small PR

The handoff permits settings-level items to go together. These are the
ones the audit found genuinely missing and genuinely small, and none of
them changes ledger behaviour:

- **P5** per-company payment methods with a bank-charge account
- **P13** decimal places per field type, rather than one company-wide
- **P14** 5-sen rounding offered as Disable / Optional / Enforce on
  invoices and receipts, reusing `app.round_amount` and the POS
  rounding account
- **P22** date and user filters on `audit_trail`

**P4/P16 journal types are deliberately excluded from that PR.** A
journal type is not a setting: it decides which journal an entry lands
in and what it is called on the trial balance, and adding one after
four hundred migrations of entries that have none is a data question
rather than a form.

---

## 4. Notes for whoever builds from this

- **G1–G4 are not to be started without Kabeer's go-ahead**, per §0.4
  of the handoff. Nothing in this audit changes that.
- The `live_change_*` rule in §0.5 is live and enforced:
  `supabase/tests/live_change_feed.sql` fails the build on a table with
  an `org_id` that is missing the trigger, and keeps a named exception
  list for tables written by read paths. `account_closures` was added
  to that list this week for the same reason.
- Two audits now exist. `docs/gap-analysis/oca-gap-report.md` covers
  the OCA catalogue and carries a correction worth reading before
  trusting any **Missing** verdict in either document: a capability
  that lives entirely in Dart, with no table, RPC or route, does not
  show up in a schema search. **P17 in this matrix is exactly that
  case**, found the hard way.
