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
| G3 | e-Invoice | Get TIN link, customer tax import, self-billed, consolidated self-billed, document inquiry, relaxation flag, tariff code | **Partial** | Self-billed: `prepare_self_billed_einvoice`, `set_requires_self_billed`, `suggest_self_billed`, `einvoice_documents.is_self_billed`. Consolidated: `einvoice_consolidations` + `prepare_consolidated_einvoice` (0616). TIN: `tin_validations` (`tin`, `id_type`, `id_value`, `is_valid`, `response`); `contacts.is_tin_verified`, `tin_verified_at`. Inquiry: `einvoice_documents` carries `submission_id`, `myinvois_uuid`, `validation_link`, `qr_code_data`, `status`, `cancel_deadline`, `rejection_reason`, `validation_errors`, `retry_count`, with `/einvoice`. Import of customer tax info: `import_screen.dart` maps `tin` and `sst_registration_no` | **M** | Three genuinely missing pieces, of which (a) is now BUILT (`0626`, `0627`): (a) ~~the **Get TIN** public link~~ — the tokenised-share pattern already existed (`app.issue_share_token`, `open_customer_portal`) and nothing yet wrote a contact's tax fields from a public form. It does now: `request_tax_details`, `open_tax_detail_request`, `submit_tax_details`, and the rule that a public submission fills a blank and never overwrites; (b) the **relaxation-period** flag on the company; ~~(c) **tariff/HS code**~~ — **BUILT (`0636`)**. The matrix was right that `items.classification_code` is a different thing and wrong about where the hole was: see §3.7. Consolidated self-billed not evidenced |
| G4 | OCR | Document Scanner → Sales Invoice / Purchase Invoice / Cash Book Entry; CA Uploader mobile capture | **Present**, and the verdict below is corrected in §3.1 | `ocr_scans`, `scan_document_kinds` with a `destination` per kind (0614), five readers, `org_ocr_credentials`, scanning credit metered; `document_classifier.dart`; capture from camera or file via `captureAndRead`/`CaptureSource`; wired into the expense and purchase screens | **M** | **This was wrong about four of its five parts.** The emit exists (`document_list_screen.dart:_scanInto`), supplier match exists (`supplier_from_scan.dart`), line extraction exists (`pendingScanProvider` + `document_editor.dart:_applyScan`) and the editor IS the review-before-post screen. Only **duplicate detection** was genuinely missing; `0628` adds it. See §3.1 |
| G5 | Sales | Recurring invoices: frequency, end rule, pause, generation log, scheduled creation | **Present** | `recurring_documents` (`frequency`, `interval_count`, `start_date`, `end_date`, `max_occurrences`, `occurrences`, `next_run_date`, `last_run_date`, `last_document_id`, `auto_post`, `auto_email`, `is_active`, `last_error`, `last_error_at`); `create_recurring_document`, `advance_recurring_document`, `raise_recurring_document`; `recurring_journals` separately; route `/recurring-documents`; generated server-side by `run_daily_jobs` on pg_cron, not on book-open | **—** | Nothing to build. One nicety: the run "log" is three columns on the row rather than a table, so a company cannot see the last twelve runs. Note it, do not build it yet |
| G6 | Data | Excel import of sales invoices, credit notes; AR/AP opening balances as outstanding invoices | **Partial** | `import_batches`, `import_rows`, `import_accounts`, `import_bank_transactions`; **`0150_import_open_items.sql` imports AR/AP opening balances as open items** — the migration case the handoff singles out is already done; per-row provenance (`import_source`, `import_ref`, `import_batch_id`, `imported_at`) from 0610; `/import` with per-importer column headings | **M** | The hard half is done. What is missing is importing **transactions**: sales invoices, credit notes, purchase invoices and journals, with a validation report before commit and de-dup by document number |
| G7 | Accounting | Knock Off Entry: many-to-many allocation from a standalone screen, from any side | **Partial**, and this verdict understated the gap — see §3.2 | `payment_allocations` carries `receipt_id`, `payment_id`, **`credit_note_id`**, `invoice_id`, `bill_id`, `amount`, `discount_amount`, `withholding_id`, `contra_id`, `deposit_id`, `pdc_id`, `discount_entry_id` — so credit note → invoice, contra, deposits, post-dated cheques and withholding are all already allocatable; `apply_on_account.dart`, `deposit_apply_sheet.dart`, `allocate_payment_with_discount`, `create_contra`, `/contra` | **M** | Richer than AutoCount's on the data side. Missing: a **standalone screen** — pick a debtor, see both sides, apply many-to-many in one action — plus journal → invoice allocation (no `journal_entry_id` on the table) and a printable knock-off listing |
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
| ~~P5~~ | Master data | Payment Method with a bank-charge account | **Built (0635)** | `payment_methods` per company, pointing at an LHDN mode and naming the account its charge is debited to; `app.bank_charge_account` resolves method → company default → 6300. See §3.5 — the charge was never missing, its account was hardcoded |
| P6 | Master data | Multiple AR/AP control accounts | **Present** | `contacts.receivable_account_id`, `contacts.payable_account_id`, resolved by `coalesce` against the org default in `app.post_sales_document_internal`; `app.control_account_balance`; asserted in `supabase/tests/control_accounts.sql` |
| P7 | Master data | Product Posting groups | **Partial** | `items.sales_account_id`, `purchase_account_id`, `inventory_account_id`, `cogs_account_id` — per item, which is finer than AutoCount. No named posting GROUP to apply to many items, and no sales-return/purchase-return account |
| P8 | Product | Two-level variants, minimum price, separate supply vs purchase tax code | **Present** | `create_item_variants`, `item_variant_matrix`, `app.items_variant_guard`; `items.min_price`; `items.sales_tax_code_id` and `purchase_tax_code_id` |
| P9 | Cash book | One receipt settling several invoices, several payment methods, bank-charge line | **Partial** | `receipts` + `payment_allocations` settle several invoices. One payment mode per receipt (`payment_mode_code`); no several-methods-per-voucher and no bank-charge line on the voucher |
| P10 | Stock | Periodic inventory mode, Periodic Stock Value | **Missing** | Perpetual only — `stock_movements`, `stock_levels`, `v_stock_valuation`, weighted average in 0009. A decision rather than a gap: say "perpetual only" |
| P11 | Stock | Stock Opening Balance, Adjustment, Transfer | **Present** | `stock_adjustments`, `stock_transfers`, `/stock-take`, `/transfers`; opening balances through `0150` |
| P12 | Stock | Product Inquiry with price history by customer/supplier | **Partial** | `/items`, `v_stock_valuation`, forecasting. No price-history-by-contact view |
| P13 | Settings | Decimal places per field type | **Partial, and the one setting is DEAD.** `organizations.decimal_places` has a check constraint, a default of 2, a field on the Dart `Organization` model — and no reader anywhere: no Dart consumer, no SQL function, no settings UI. Setting it changes nothing. `ref_currencies.decimal_places` was the same until `0634`, which made `Fmt.money` read it. See §3.4 |
| P14 | Settings | 5-sen rounding Disable / Optional / Enforce | **Present as a company setting; the per-document choice is a decision, not a gap** | `organizations.rounding_method` (`none`, `nearest_5cent`, `nearest_10cent`), `app.round_amount`, read by `app.recalc_sales_totals` and by `document_editor.dart`, editable in `company_card.dart`; POS applies it (`pos_rounding_adjustment`). See §3.6 |
| P15 | Settings | Numbering format: prefix, suffix, year/month tokens, start, width, per document type | **Present** | `number_sequences` (`doc_type`, `prefix`, `suffix`, `padding`, `next_value`, `reset_policy`, `period_key`); `document_numbering`, `set_document_numbering`; `document_numbering_card.dart` |
| P16 | Settings | Default journal type / description per transaction class | **Missing** | No journal types at all (see P4), and no default-description setting |
| P17 | Reports | Debtor and Creditor Statements | **Present** | `statement.dart`, `statement_pdf.dart` (customer and supplier sides), from `contact_editor.dart`; and since `0624` `report_statement_of_account` adds the brought-forward form |
| P18 | Reports | Trial Balance, Ledger, P&L, BS, Debtor/Creditor Aging, Journal listing | **Present** | `report_trial_balance`, `general_ledger`, `report_ar_aging`, `report_ap_aging`, `report_changes_in_equity`, `/reports`, `/financial-statements` |
| P19 | Reports | Monthly Sales Analysis, P&L by Document | **Partial** | `revenue_trend`, `/dashboard`, `/pos-reports`. No per-document margin report |
| P20 | Sales | Void / unvoid, status board, copy from quotation | **Present** | `void_sales_document`, `sales_documents.status`, `/sales` with Draft/Outstanding filters, quotation → order → invoice conversion |
| P21 | e-Invoice | Approval stage before submission | **Present** | `approval_rules`, `approval_steps`, `approval_requests`, `app.approval_entity`, `app.refuse_unapproved_posting`, `/approvals`. Draft expiry and a draft-only role were not evidenced |
| P22 | Tools | Audit Trail with filters | **Present**, and the two missing filters are now built (`0634`) | `audit_trail(uuid, text, uuid, integer)` — org, record type, record id, limit; `audit_logs` with `old_data`/`new_data`; `/admin/trail`, `/security`. Filtering by **user** and by **date** is not in that signature |
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
| 5 | ~~**G7 the knock-off screen**~~ — **BUILT**, `0629`/`0630` and `/knock-off`. The verdict understated it: nothing could write `credit_note_id` at all. **See §3.2** | The allocation model is already richer than AutoCount's. What is missing is one screen, and it is the screen an accounts clerk lives in at month end | M |
| 6 | ~~**G6 transaction import**~~ — **BUILT**: sales `0631`, purchase `0632`, journals `0633` (which posts; see its header and `docs/unreachable.md`) | Opening balances already import as open items, which was the migration blocker. Invoice and journal import is a convenience after that, and matters most in the first week of a new customer | M |
| 7 | **G9 own subscription e-Invoices** — **BLOCKED, and not for the reason given. See §3.3** | Small, and it answers a question every prospect asks. Mostly a matter of admitting `platform_invoices` to `einvoice_documents_source_table_check` | M |
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


### 3.2 A correction to the G7 verdict

This audit called the allocation model "richer than AutoCount's on the
data side" and said what was missing was "a **standalone screen**". The
first half is true of the schema and false of the product.

`payment_allocations.credit_note_id` has existed since `0005`. `0272`,
`0273` and `0275` each restated the check constraint that names it.
`0096`'s aged listing works out how much of a credit note has been used.
`app.apply_allocation` looks the credit note up to check whose money it
is. **Nothing had ever written the column.**

So the feature was not "present but unreachable from one screen". It
was four hundred migrations of infrastructure around a door with no
handle, and a customer holding a credit note had no way in the product
to put it against an invoice — the single most common thing an accounts
clerk does at month end.

Worse, the column was not safe to write. Every other source on that
table is guarded — a receipt cannot be spread further than the money
that arrived — and the credit note had no guard, because it had no
writer. A credit note for 500 could have been spread over 5,000 of
invoices.

The audit read the SCHEMA and found a rich one. It did not ask *what
writes this*. That is the third verdict in two reports to fail on the
same move, after OCA B5 and G4 above, and the three failures are the
same shape from two directions:

| | The search found | The truth |
|---|---|---|
| OCA B5 | no table, no RPC, no route → **Missing** | three Dart files, working for years |
| G4 | a pipeline ending in a `jsonb` → **Partial** | four of five pieces built |
| G7 | a rich set of columns → **Partial, one screen** | one of those columns had no writer and no guard |

**A column is not a feature, and an absent table is not an absent
feature.** The question that separates them is *what writes this, and
what reads it* — and it cannot be answered by searching the schema.
`0629` and `0630` build the writer, the guard, the reader and the
screen.


### 3.3 A correction to the G9 verdict, and why it stops there

This audit called G9 "small ... mostly a matter of admitting
`platform_invoices` to `einvoice_documents_source_table_check`". The
constraint is the least of it. The whole e-Invoice stack is built on a
TENANT identity, and the platform billing its own customers is not a
tenant.

| What a submission needs | Where a tenant gets it | Where the platform would |
|---|---|---|
| a TIN | `organizations.tin` | **nowhere.** `platform_settings.platform_issuer` holds name, registration number, old registration number, SST number and address — and no TIN, no id type, no id value |
| MyInvois credentials | `einvoice_credentials`, keyed `org_id` | **nowhere.** There is no platform row, because there is no platform org |
| an `org_id` on the document | its own | `einvoice_documents.org_id` is NOT NULL, and the only candidate is the tenant being billed — who is the BUYER. Submitting a document under the buyer's credentials, with the buyer's client id, reporting the seller's TIN, is not a smaller version of the right thing |

So the shape of the work is a platform-level e-Invoice identity:
`platform_issuer` gains a TIN and an identification pair, the
credentials table gains a row that belongs to no organization (and the
usual rule applies — the secret stays where `einvoice_credentials`
already keeps one, service-role only), and the preparer maps
`platform_invoices` with the platform as supplier and the tenant as
buyer.

**And then it stops, for the reason `docs/design/sst-02.md` stops.**

The platform's TIN is a real number issued to a real company, and its
MyInvois enrolment is a real registration. Neither can be invented
here, and a payload built on a guessed TIN is worse than no payload:
it would be submitted, rejected, and rejected again every month, with
the operator's own billing the thing that breaks.

This is the same wall as the gazetted KWSP figures, the CP39 layout and
the RMCD rules — the third item on this branch to reach it — and it is
recorded rather than worked around.

**What is needed from outside this machine:** the issuing company's
TIN, its identification type and number as LHDN holds them, and whether
it is enrolled in MyInvois (and in which environment). With those, the
work above is a day. Without them it cannot start, and a migration that
put a placeholder TIN into `platform_settings` would be a migration
somebody later believed.


### 3.4 P13: the setting was dead, and so was the one beside it

Verifying P13 turned up something the verdict missed. It is right that
`organizations.decimal_places` is one company-wide setting rather than
one per field type. What it does not say is that **the setting does
nothing at all**:

  * it has a check constraint (`between 0 and 6`) and a default of 2,
    from `0001`;
  * it is parsed onto the Dart `Organization` model as `decimalPlaces`;
  * and nothing reads it. No Dart consumer, no SQL function, no
    settings screen. Changing it changes nothing anybody can see.

`ref_currencies.decimal_places` was in the same state, and worse,
because it was right and unused. The `Currency` model even carries the
reason, written when the field was added: *"Yen and won have none. Kept
because a rate field that offers cents on a currency without them
invites a figure that cannot be paid."* `Fmt.money` meanwhile hardcoded
`#,##0.00`, so every yen, won and dong figure — on screen, on a
statement, on a PDF that goes to a customer — was printed with two
decimals it does not have.

**What was built** is the currency half: `Fmt.money` prints at the
currency's own precision, and `scripts/check_currency_decimals.py`
keeps the app's copy of the exceptions in step with the seed.

**What is left** is the company setting, and it needs a decision rather
than code. Money is now answered by the CURRENCY, which is the right
authority for it — so `organizations.decimal_places` has no job unless
it is given the one AutoCount gives it: the precision of a UNIT PRICE
and a QUANTITY, which are not money and where four decimals are
ordinary. That is a real feature and a small one, but it is a choice
about what the setting means, and inventing one would be inventing a
requirement.

### 3.5 P5: the charge was not missing, its account was hardcoded

The verdict read `ref_payment_modes` and concluded there was no
bank-charge account anywhere. Reading what actually POSTS turns that
around twice.

`receipts.bank_charges` and `purchase_payments.bank_charges` have been
columns since `0005` and `0006`, and they post. `post_receipt` debits
the charge and credits the customer gross; `post_purchase_payment`
does the mirror; `post_bank_transfer` does it for a transfer fee. So
the feature existed. What did not exist was any way to say WHERE it
goes — all three said:

```sql
(select id from public.accounts where org_id = ... and code = '6300')
```

6300 is Bank Charges in the bootstrap chart, so a company that took the
chart as given was fine. A company that did not had no account at all,
and `gl_lines.account_id` is `not null`, so the subquery returning
nothing did not fall back to anything. It aborted the posting with

```
null value in column "account_id" of relation "gl_lines" ...
```

naming neither the receipt, nor the charge, nor 6300. That is every
company migrating a chart in from somewhere else, which is the audience
this document is written for.

`app.fx_account` — three lines below the charge block, in the same
function, added in `0079` — had already solved this for the exchange
gain and loss accounts: look the code up, and raise something a person
can act on if it is not there. The charge block was simply never given
the same treatment.

**What was built.** `payment_methods` is org-scoped master data that
points at an LHDN mode rather than replacing it: a company has "Maybank
cheque", "CIMB FPX", "Stripe", several of which report as the same code
and which differ in where the money lands and what the provider keeps.
`app.bank_charge_account` resolves method → company default → 6300 →
a sentence. The three posting functions are restated with one line
changed each.

**Nothing moves for a company that configures nothing**, and that is
asserted rather than argued: `supabase/tests/payment_methods.sql` posts
a receipt, a payment and a transfer in a company with no payment method
in existence and checks the charge landed on 6300 and the rest of the
journal is what it was. The one behaviour that changes is the failure —
from a constraint violation to a sentence.

**The rate is recorded and not applied.** A method carries
`charge_percent` and `charge_fixed` because "Stripe keeps 2.9% + RM1"
is worth storing once, and `suggested_charge` computes it for the
screen. Posting never calls it: `bank_charges` stays what somebody
typed. A journal that depended on a master-data row which can be edited
afterwards would stop reproducing the moment the rate changed, and
reproducing is what a ledger is for.

### 3.6 P14: the setting is live, and the missing half is not a setting

Unlike `decimal_places` (§3.4), `rounding_method` is wired end to end
and always was. It is read by `app.recalc_sales_totals` and its POS
sibling in `0410`, mirrored in `document_editor.dart` so the screen and
the database agree before a save, edited in `company_card.dart`, and
shown on the company card. Nothing about the company-wide setting is
missing.

What AutoCount's "Disable / Optional / Enforce" adds is a different
axis. It is not *how much* to round — that is the three values the
column already holds — but *whether a document may disagree with the
company*. "Optional" means a per-document override.

**That is not a settings item, and it is the one line of this PR that
would change what a document totals to.** Every invoice raised so far
totals what the company setting says; introducing an override means
some documents deliberately total something else, and there is no
reading of the requirement that leaves existing documents alone while
also doing anything. There is also no defect underneath it to justify
the risk the way there was for P5 (§3.5) — nothing crashes, nothing is
silently wrong, no column is dead.

So this one stops here, as a verdict correction rather than code. It
needs a decision on two questions that cannot be inferred from the
schema:

  * **Who may override?** A clerk raising an invoice, or only somebody
    who can post? An override that anybody can set is a rounding policy
    that is not a policy.
  * **What happens to a document already raised** when the company
    setting later changes? Today the answer is "nothing, the total is
    stored" — the recalc only fires when a line moves. An override
    column does not change that, but it makes the stored total's
    provenance a question somebody will ask during an audit, and the
    honest answer needs the override recorded on the document rather
    than inferred.

### 3.7 G3(c): the column existed, the emitter existed, nothing filled it

The sixth verdict in this audit to turn on the difference between a
column existing and a column being written.

`einvoice_lines.product_tariff_code` has been a column since `0007`,
described there as one of the "optional product traceability fields
supported by MyInvois". `supabase/functions/_shared/ubl.ts` reads it
and emits it correctly, with `listID="PTC"`, and `ubl_test.ts` asserts
that it does — passing, for as long as both have existed.

And no INSERT anywhere named the column. All three writers of
`einvoice_lines` list their columns explicitly and this was not among
them, so the value was null on every line ever written and the
emitter's branch never ran. A test of the emitter passed while the
feature did not exist. `country_of_origin` was in the same state, and
`ubl.ts` defaults it to MYS, so nobody noticed.

**What was built.** `items.tariff_code` and `items.country_of_origin`,
carried into `einvoice_lines` by `prepare_einvoice` and
`prepare_self_billed_einvoice`. The source is the ITEM because an HS
code is a fact about a product: the same product must not reach LHDN
under two codes because two clerks typed it.

**Shape-checked, not validated.** Malaysia's tariff codes live in the
PDK — thousands of lines on a revision schedule of its own, not
published as anything this repository can seed and keep current. A
`references` to a table we could not maintain would refuse codes that
are correct, which is worse than accepting one that is wrong: the
first stops an invoice that should go, the second is caught by the
customs officer who reads it. So the check is `^[0-9]{4}[0-9.]{0,10}$`,
and it exists to catch one realistic error — a description typed into
the box under the one labelled "e-Invoice classification", the two
being adjacent on the screen and constantly confused. This document
confused them.

**The consolidated writer deliberately gets none.** A consolidated line
is one whole till receipt, classification `004`, with no single item
behind it. `0616` is left alone, and the test asserts it stays that way
by reading `prosrc` out of the catalogue.

**Nothing changes for an item with no code**, which is every item in
every existing company: `ubl.ts` omits the element when the value is
null, and already sent MYS for the country.

### 3.8 G3(b): the relaxation flag, and why it is not here

Nothing in the schema or the app mentions a relaxation period. That
part of the verdict is correct and unqualified.

It is not built here because what the flag should DO is not a settings
question. LHDN's relaxation period permits consolidated e-Invoicing for
activities normally barred from it, and the value of a flag is that
something reads it and behaves differently — which means changing what
`prepare_consolidated_einvoice` will accept. That is a validation
change on a statutory filing path, and the dates and the barred-activity
list are both facts to be looked up rather than inferred.

A `boolean` nobody reads would be the third dead settings column this
audit has found. Left out on purpose.

### A separate, small PR

The handoff permits settings-level items to go together. These are the
ones the audit found genuinely missing and genuinely small, and none of
them changes ledger behaviour:

- ~~**P5** per-company payment methods with a bank-charge account~~ — built in `0635`
- ~~**P13** decimal places per field type, rather than one company-wide~~ — the currency half built; the company setting needs a decision, see §3.4
- **P14** is NOT in this PR after verification: the company-wide
  setting is complete and live, and the only missing half — a
  per-document override — changes what a document totals to. See
  §3.6 for the two questions it needs answered first
- ~~**P22** date and user filters on `audit_trail`~~ — built in `0634`

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
