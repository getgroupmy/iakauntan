# Graph Report - iakauntan  (2026-08-11)

## Corpus Check
- 181 files · ~178,169 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 3223 nodes · 4774 edges · 188 communities (161 shown, 27 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS · INFERRED: 3 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `fe235550`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- models.dart
- repository.dart
- corp_models.dart
- submit.ts
- document_editor.dart
- widgets.dart
- 0009_functions.sql
- hr_setup_screen.dart
- entity_screen.dart
- router.dart
- employee_editor.dart
- providers.dart
- _
- payroll_screen.dart
- matter_detail_screen.dart
- entity_editor.dart
- repoProvider
- StatelessWidget
- public.purchase_documents
- dashboard_screen.dart
- ConsumerState
- tax_year_section.dart
- contact_editor.dart
- settlement_dialog.dart
- document_pdf_test.dart
- reports_screen.dart
- corp_repository.dart
- line_editor.dart
- create_org_screen.dart
- _
- pipeline_screen.dart
- items_screen.dart
- claims_screen.dart
- public.sales_documents
- 0003_masters.sql
- taxCodesProvider
- settings_screen.dart
- 0027_hrms_time_leave_claims.sql
- einvoice_screen.dart
- app_shell.dart
- platform_console_screen.dart
- 0014_reports.sql
- public.client_account_transactions
- _TaxYearSectionState
- leave_screen.dart
- sign_in_screen.dart
- attachments_card.dart
- matters_screen.dart
- line_draft.dart
- signing_page.dart
- public.post_sales_document
- secretarial_screen.dart
- public.calculate_payroll_run
- 0036_hrms_talent.sql
- attachments_repository.dart
- 0007_einvoice.sql
- audit_trail_card.dart
- public.post_payroll_run
- expenses_screen.dart
- 0037_hrms_workflow_rpcs.sql
- public.opportunities
- 0025_hrms_core.sql
- 0028_hrms_payroll_tables.sql
- _RequestLeaveDialogState
- State
- _
- public.report_matter_summary
- public.calculate_payroll_run
- public.calculate_payroll_run
- supabaseProvider
- 0015_einvoice_prepare.sql
- 0070_signing_links.sql
- .application
- 0001_core.sql
- payslip_screen.dart
- business_pdf_test.dart
- document_list_screen.dart
- doc_types.dart
- 0002_reference.sql
- public.gl_entries
- 0018_platform_admin_modules_and_permissions.sql
- document_pdf.dart
- currentOrgProvider
- 0020_platform_admin_rpcs.sql
- public.payslip_access_requests
- manifest.json
- 0058_periodic_jobs.sql
- public.corp_entities
- public.corp_filings
- 0069_document_signatures.sql
- app.can_read_attachment
- shell_no_org_test.dart
- String?
- invoice_pdf.dart
- ConsumerWidget
- iAkauntan
- ../../data/models.dart
- Repo
- check_embeds.py
- public.corp_register_of_members
- 0029_hrms_statutory_functions.sql
- public.payslip_access_log
- _helpers.sql
- What You Must Do When Invoked
- app.claim_expense_allocation
- public.create_gl_entry
- 0056_internal_posting_path.sql
- public.audit_list_payslips
- build
- 0012_bootstrap.sql
- public.report_balance_sheet
- public.employee_directory
- 0065_corp_secretarial_documents.sql
- public.payroll_settings
- app.calc_pcb
- 0046_hrms_payslip_access_rpcs.sql
- public.payroll_payment_instruction
- 0063_corp_secretarial_deadlines.sql
- ../../core/format.dart
- reset_password_screen.dart
- git
- app.calc_pcb
- app.calc_pcb
- app.insured_wage
- app.calc_pcb
- public.reverse_gl_entry
- AppColors
- MainActivity.kt
- graphify reference: extra exports and benchmark
- graphify reference: query, path, explain
- app.seed_org_modules
- public.post_payroll_run
- app.payroll_gl_line
- download.dart
- AppColorsX
- graphify reference: add a URL and watch a folder
- 0072_corp_document_amendment.sql
- MyInvoisException
- graphify reference: commit hook and native CLAUDE.md integration
- bool?
- public.corp_filing_types
- public.corp_templates
- public.items
- public.payslips
- public.payroll_runs
- graphify reference: incremental update and cluster-only
- build
- iAkauntan
- graphify reference: GitHub clone and cross-repo merge
- graphify reference: transcribe video and audio
- LaunchImage.imageset/README.md
- app/README.md
- .claude/CLAUDE.md
- extraction-spec.md
- organizationsProvider
- build
- my_hr_screen.dart
- payslip_pdf.dart
- 0071_seed_chart_of_accounts_reentrant.sql
- payment_file_test.dart
- download_web.dart
- _CreateOrgScreenState
- package:flutter/material.dart
- ../../core/theme.dart
- package:flutter_test/flutter_test.dart
- DocKind

## God Nodes (most connected - your core abstractions)
1. `repoProvider` - 87 edges
2. `_` - 44 edges
3. `_` - 28 edges
4. `_` - 24 edges
5. `canWriteProvider` - 24 edges
6. `supabaseProvider` - 20 edges
7. `public.post_payroll_run()` - 16 edges
8. `currentOrgProvider` - 15 edges
9. `MyInvoisClient` - 15 edges
10. `public.sales_documents` - 15 edges

## Surprising Connections (you probably didn't know these)
- `public.post_payroll_run()` --reads_from--> `pcb`  [EXTRACTED]
  supabase/migrations/0050_hrms_post_payroll_split_claims.sql → app/lib/src/data/models.dart
- `public.post_payroll_run()` --reads_from--> `zakat`  [EXTRACTED]
  supabase/migrations/0050_hrms_post_payroll_split_claims.sql → app/lib/src/data/models.dart
- `_load` --references--> `repoProvider`  [EXTRACTED]
  app/lib/src/features/contacts/contact_editor.dart → app/lib/src/core/providers.dart
- `_verifyTin` --references--> `repoProvider`  [EXTRACTED]
  app/lib/src/features/contacts/contact_editor.dart → app/lib/src/core/providers.dart
- `_load` --references--> `repoProvider`  [EXTRACTED]
  app/lib/src/features/documents/document_editor.dart → app/lib/src/core/providers.dart

## Import Cycles
- None detected.

## Communities (188 total, 27 thin omitted)

### Community 0 - "models.dart"
Cohesion: 0.01
Nodes (352): Account, accountCode, accountName, accountSubtype, accountType, action, activitiesDue, activityCode (+344 more)

### Community 1 - "repository.dart"
Cohesion: 0.02
Nodes (132): acceptInvitation, accounts, activities, addDisbursement, addTimeEntry, amIPlatformAdmin, applicants, appraisals (+124 more)

### Community 2 - "corp_models.dart"
Cohesion: 0.02
Nodes (119): address, amountSecured, appointedOn, appointsDirectors, body, businessAddress, capacity, category (+111 more)

### Community 3 - "submit.ts"
Cohesion: 0.08
Nodes (43): cancel(), checkStatus(), submit(), ID_TYPES, markVerified(), validateTin(), buildContext(), Credentials (+35 more)

### Community 4 - "document_editor.dart"
Cohesion: 0.04
Nodes (54): caption, _contactId, createState, _currency, _dirty, dispose, _docDate, _docNo (+46 more)

### Community 5 - "widgets.dart"
Cohesion: 0.04
Nodes (50): accent, action, amount, bold, build, caption, child, color (+42 more)

### Community 6 - "0009_functions.sql"
Cohesion: 0.04
Nodes (38): app.apply_account_balance, app.apply_allocation, app.apply_stock_movement, app.assert_gl_balanced, app.calc_document_line, app.recalc_purchase_totals, app.recalc_sales_totals, app.track_opportunity_stage (+30 more)

### Community 7 - "hr_setup_screen.dart"
Cohesion: 0.05
Nodes (41): payrollSettingsProvider, setupRowsProvider, _blank, boolean, build, _c, _ClaimTypesTab, _ComponentsTab (+33 more)

### Community 8 - "entity_screen.dart"
Cohesion: 0.04
Nodes (44): CorpBeneficialOwner, CorpCharge, CorpDocument, CorpMember, CorpOfficer, CorpShareEvent, CorpSignature, _body (+36 more)

### Community 9 - "router.dart"
Cohesion: 0.05
Nodes (39): _documentRoutes, _rootKey, _shellKey, ../features/admin/platform_console_screen.dart, ../features/auth/reset_password_screen.dart, ../features/auth/sign_in_screen.dart, ../features/contacts/contact_editor.dart, ../features/contacts/contacts_screen.dart (+31 more)

### Community 10 - "employee_editor.dart"
Cohesion: 0.05
Nodes (41): departmentsProvider, employeeProvider, positionsProvider, _birthDate, build, _c, children, createState (+33 more)

### Community 11 - "providers.dart"
Cohesion: 0.04
Nodes (55): attendanceProvider, auditPayslip, canReadLedgerProvider, clear, corpPersonsProvider, data, DocQuery, documentProvider (+47 more)

### Community 12 - "_"
Cohesion: 0.06
Nodes (37): _, AppTheme, base, _border, _build, _clickable, colors, copyWith (+29 more)

### Community 13 - "payroll_screen.dart"
Cohesion: 0.05
Nodes (38): PaymentLine, PayrollRun, PayslipAccessRequest, _buildForm, _calculate, createState, dispose, emphasise (+30 more)

### Community 14 - "matter_detail_screen.dart"
Cohesion: 0.07
Nodes (32): clientTransactionsProvider, mattersProvider, _activity, _amount, _billable, canPost, _ClientLedgerTab, _ClientMoneyDialog (+24 more)

### Community 15 - "entity_editor.dart"
Cohesion: 0.07
Nodes (29): _auditExempt, _blank, _c, children, createState, _ctl, _DateField, dispose (+21 more)

### Community 16 - "repoProvider"
Cohesion: 0.06
Nodes (46): canAdminProvider, currentUserProvider, fiscalYearsProvider, payslipAccessLogProvider, repoProvider, requireRepo, select, teamProvider (+38 more)

### Community 17 - "StatelessWidget"
Cohesion: 0.06
Nodes (31): AsyncView, _DeltaBadge, EmptyState, ErrorState, Money, PageBody, SectionHeader, Sparkline (+23 more)

### Community 18 - "public.purchase_documents"
Cohesion: 0.17
Nodes (30): public.bank_reconciliations, public.bank_transactions, public.expenses, public.purchase_document_lines, public.purchase_documents, public.purchase_payments, public.stock_adjustment_lines, public.stock_adjustments (+22 more)

### Community 19 - "dashboard_screen.dart"
Cohesion: 0.11
Nodes (17): DashboardSummary, _activityIcon, color, data, _delta, _EinvoiceBanner, _Greeting, label (+9 more)

### Community 20 - "ConsumerState"
Cohesion: 0.07
Nodes (48): canPostProvider, canWriteProvider, contactsProvider, corpEntityProvider, disbursementsProvider, documentsProvider, matterSummaryProvider, opportunitiesProvider (+40 more)

### Community 21 - "tax_year_section.dart"
Cohesion: 0.07
Nodes (28): DeclaredRelief, _amount, _c, _code, createState, _ctl, dispose, _edit (+20 more)

### Community 22 - "contact_editor.dart"
Cohesion: 0.08
Nodes (28): _build, _c, ContactEditor, _ContactEditorState, contactId, contactType, _controllers, createState (+20 more)

### Community 23 - "settlement_dialog.dart"
Cohesion: 0.06
Nodes (35): bankAccountsProvider, outstandingProvider, _allocated, _AllocationRow, _AllocationRowState, _allocations, amount, _bankAccountId (+27 more)

### Community 24 - "document_pdf_test.dart"
Cohesion: 0.29
Nodes (6): 2026, body, main, dart:convert, Dated this 11 August, package:iakauntan/src/features/secretarial/document_pdf.dart

### Community 25 - "reports_screen.dart"
Cohesion: 0.08
Nodes (30): trialBalanceProvider, amountKey, asAt, _BalanceSheet, _balanceSheetProvider, build, createState, dispose (+22 more)

### Community 26 - "corp_repository.dart"
Cohesion: 0.07
Nodes (28): addCorpShareEvent, corpBeneficialOwners, corpCharges, corpCreateSigningLink, corpDocuments, corpEntities, corpEntity, corpGenerateDocument (+20 more)

### Community 27 - "line_editor.dart"
Cohesion: 0.07
Nodes (31): _applyItem, controller, createState, currency, _description, _discount, dispose, editable (+23 more)

### Community 28 - "create_org_screen.dart"
Cohesion: 0.07
Nodes (26): _address, _busy, _city, createState, data, dispose, _email, _emptyToNull (+18 more)

### Community 29 - "_"
Cohesion: 0.08
Nodes (26): _, _compact, _date, _dateTime, days, Fmt, _fractional, initials (+18 more)

### Community 30 - "pipeline_screen.dart"
Cohesion: 0.11
Nodes (18): Opportunity, PipelineStage, _amount, canWrite, _closeDate, _contactId, createState, deal (+10 more)

### Community 31 - "items_screen.dart"
Cohesion: 0.08
Nodes (23): Item, _classification, _code, _cost, createState, dispose, _formKey, initState (+15 more)

### Community 32 - "claims_screen.dart"
Cohesion: 0.11
Nodes (21): claimsProvider, claimTypesProvider, ExpenseClaim, _amount, build, claim, ClaimsScreen, _ClaimsScreenState (+13 more)

### Community 33 - "public.sales_documents"
Cohesion: 0.12
Nodes (24): public.contact_addresses, public.payment_allocations, public.receipts, public.sales_document_lines, public.sales_documents, set_updated_at, app.set_updated_at, auth (+16 more)

### Community 34 - "0003_masters.sql"
Cohesion: 0.20
Nodes (24): public.ref_countries, public.accounts, public.bank_accounts, public.contact_addresses, public.contact_persons, public.contacts, public.fiscal_periods, public.fiscal_years (+16 more)

### Community 35 - "taxCodesProvider"
Cohesion: 0.13
Nodes (20): accountsProvider, classificationCodesProvider, expensesProvider, itemsProvider, paymentModesProvider, taxCodesProvider, build, LineEditorCard (+12 more)

### Community 36 - "settings_screen.dart"
Cohesion: 0.06
Nodes (32): FiscalYear, _busy, canAdmin, canEdit, _ChangePasswordDialog, _ChangePasswordDialogState, _clientId, _clientSecret (+24 more)

### Community 37 - "0027_hrms_time_leave_claims.sql"
Cohesion: 0.16
Nodes (23): public.attendance_records, public.claim_types, public.employee_shifts, public.expense_claim_lines, public.expense_claims, public.leave_balances, public.leave_entitlement_bands, public.leave_requests (+15 more)

### Community 38 - "einvoice_screen.dart"
Cohesion: 0.10
Nodes (20): EinvoiceDocument, _cancel, createState, _describe, doc, _EinvoiceTile, _ErrorDetails, _filter (+12 more)

### Community 39 - "app_shell.dart"
Cohesion: 0.09
Nodes (21): Organization, _bareLayout, child, _collapsedWidth, _Dest, _destinations, extended, _extendedWidth (+13 more)

### Community 40 - "platform_console_screen.dart"
Cohesion: 0.09
Nodes (26): platformRepoProvider, PlatformOrg, _controller, createState, _dirty, dispose, _encode, initState (+18 more)

### Community 41 - "0014_reports.sql"
Cohesion: 0.13
Nodes (21): public.dashboard_summary(), public.report_balance_sheet(), public.report_profit_loss(), public.report_sst_summary(), public.report_trial_balance(), public.v_ap_aging, public.v_ar_aging, public.v_stock_valuation (+13 more)

### Community 42 - "public.client_account_transactions"
Cohesion: 0.18
Nodes (20): app.assert_client_funds, app.calc_time_entry, app.assert_client_funds(), assert_client_funds, calc_amount, public.client_account_transactions, public.disbursements, public.matters (+12 more)

### Community 43 - "_TaxYearSectionState"
Cohesion: 0.17
Nodes (13): canManageHrProvider, declaredReliefsProvider, directoryProvider, reliefTypesProvider, ytdOpeningProvider, build, PeopleScreen, _PeopleScreenState (+5 more)

### Community 44 - "leave_screen.dart"
Cohesion: 0.09
Nodes (21): LeaveRequest, createState, _DateField, _days, _decide, dispose, _end, _formKey (+13 more)

### Community 45 - "sign_in_screen.dart"
Cohesion: 0.09
Nodes (22): _Banner, _Brand, build, _busy, color, createState, dispose, _email (+14 more)

### Community 46 - "attachments_card.dart"
Cohesion: 0.10
Nodes (21): AttachmentsCard, _AttachmentsCardState, attachmentsProvider, build, _busy, canWrite, createState, file (+13 more)

### Community 47 - "matters_screen.dart"
Cohesion: 0.11
Nodes (18): Matter, MatterSummary, _clientId, _courtRef, createState, _deposit, dispose, _formKey (+10 more)

### Community 48 - "line_draft.dart"
Cohesion: 0.10
Nodes (20): classificationCode, computeLine, description, discount, discountPercent, fromLine, gross, isTaxInclusive (+12 more)

### Community 49 - "signing_page.dart"
Cohesion: 0.09
Nodes (22): body, build, _client, createState, dispose, _done, _forState, icon (+14 more)

### Community 50 - "public.post_sales_document"
Cohesion: 0.13
Nodes (17): public.expenses, public.purchase_payments, public.receipts, public.post_expense(), public.post_purchase_payment(), public.post_receipt(), public.post_sales_document(), public.void_sales_document() (+9 more)

### Community 51 - "secretarial_screen.dart"
Cohesion: 0.12
Nodes (15): CorpEntity, CorpFiling, _colour, count, _DeadlinesCard, entities, _EntitiesCard, entity (+7 more)

### Community 52 - "public.calculate_payroll_run"
Cohesion: 0.12
Nodes (16): app.manages_employee(), app.my_employee_id(), public.calculate_payroll_run(), public.attendance_records, public.departments, public.employee_salary_components, public.employees, public.leave_requests (+8 more)

### Community 53 - "0036_hrms_talent.sql"
Cohesion: 0.26
Nodes (18): public.applicant_stage_history, public.applicants, public.appraisal_cycles, public.appraisal_goals, public.appraisals, public.interviews, public.job_requisitions, public.onboarding_checklists (+10 more)

### Community 54 - "attachments_repository.dart"
Cohesion: 0.12
Nodes (16): Attachment, attachments, attachmentUrl, bucket, createdAt, deleteAttachment, fileName, fileSize (+8 more)

### Community 55 - "0007_einvoice.sql"
Cohesion: 0.21
Nodes (16): app.set_einvoice_cancel_deadline, public.ref_einvoice_types, public.einvoice_consolidation_items, public.einvoice_consolidations, public.einvoice_documents, public.einvoice_lines, public.einvoice_logs, public.einvoice_submissions (+8 more)

### Community 56 - "audit_trail_card.dart"
Cohesion: 0.12
Nodes (16): auditTrailProvider, AuditEntry, after, AuditTrailCard, before, build, _colour, entry (+8 more)

### Community 57 - "public.post_payroll_run"
Cohesion: 0.12
Nodes (16): pcb, zakat, eis_employee, eis_employer, epf_employee, epf_employer, gl_entry_id, months_paid (+8 more)

### Community 58 - "expenses_screen.dart"
Cohesion: 0.12
Nodes (15): _accountId, _amount, _bankAccountId, createState, _date, _description, dispose, _formKey (+7 more)

### Community 59 - "0037_hrms_workflow_rpcs.sql"
Cohesion: 0.12
Nodes (11): public.employee_shifts, public.public_holidays, public.work_shifts, app.shift_for(), public.clock_in(), public.decide_expense_claim(), public.attendance_records, public.expense_claims (+3 more)

### Community 60 - "public.opportunities"
Cohesion: 0.29
Nodes (16): public.activities, public.attachments, public.leads, public.notes, public.opportunities, public.opportunity_stage_history, public.pipeline_stages, public.pipelines (+8 more)

### Community 61 - "0025_hrms_core.sql"
Cohesion: 0.26
Nodes (16): public.departments, public.employee_dependants, public.employee_documents, public.employee_tax_reliefs, public.employee_ytd_opening, public.employees, public.positions, public.statutory_rates (+8 more)

### Community 62 - "0028_hrms_payroll_tables.sql"
Cohesion: 0.22
Nodes (16): public.employee_salary_components, public.pay_periods, public.payroll_runs, public.payroll_ytd, public.payslip_lines, public.payslips, public.salary_components, set_updated_at (+8 more)

### Community 63 - "_RequestLeaveDialogState"
Cohesion: 0.25
Nodes (9): leaveRequestsProvider, leaveTypesProvider, myLeaveBalancesProvider, build, LeaveScreen, _LeaveScreenState, _RequestLeaveDialog, _RequestLeaveDialogState (+1 more)

### Community 64 - "State"
Cohesion: 0.20
Nodes (14): _MonthPickerDialog, _MonthPickerDialogState, _ReliefDialog, _ReliefDialogState, _FillGaps, _FillGapsState, _SignatoryPicker, _SignatoryPickerState (+6 more)

### Community 65 - "_"
Cohesion: 0.11
Nodes (19): _, amountRow, bold, _cached, field, footer, letterhead, load (+11 more)

### Community 66 - "public.report_matter_summary"
Cohesion: 0.13
Nodes (12): public.client_account_transactions, public.disbursements, public.matters, public.profiles, public.time_entries, public.invite_member(), public.report_matter_summary(), public.setup_legal_module() (+4 more)

### Community 67 - "public.calculate_payroll_run"
Cohesion: 0.12
Nodes (15): public.calculate_payroll_run(), public.attendance_records, public.departments, public.employee_salary_components, public.employees, public.expense_claims, public.leave_requests, public.leave_types (+7 more)

### Community 68 - "public.calculate_payroll_run"
Cohesion: 0.12
Nodes (15): public.calculate_payroll_run(), public.attendance_records, public.departments, public.employee_salary_components, public.employees, public.expense_claims, public.leave_requests, public.leave_types (+7 more)

### Community 69 - "supabaseProvider"
Cohesion: 0.20
Nodes (14): currentOrgIdProvider, memberRoleProvider, supabaseProvider, _resetPassword, _submit, _create, _AboutCard, _save (+6 more)

### Community 70 - "0015_einvoice_prepare.sql"
Cohesion: 0.13
Nodes (12): app.sync_einvoice_status, public.einvoice_credentials, public.prepare_einvoice(), set_updated_at, app.set_updated_at, auth.users, public.items, public.organizations (+4 more)

### Community 71 - "0070_signing_links.sql"
Cohesion: 0.17
Nodes (12): app.write_audit_log, public.corp_signatures, audit_changes, public.corp_create_signing_link(), public.corp_open_signing_link(), public.corp_sign_with_link(), public.corp_signing_links, set_updated_at (+4 more)

### Community 72 - ".application"
Cohesion: 0.15
Nodes (10): Any, AppDelegate, Bool, RunnerTests, Flutter, FlutterAppDelegate, UIApplication, UIKit (+2 more)

### Community 73 - "0001_core.sql"
Cohesion: 0.21
Nodes (11): app.handle_new_user, on_auth_user_created, public.audit_logs, public.number_sequences, public.org_members, public.organizations, public.profiles, set_updated_at (+3 more)

### Community 74 - "payslip_screen.dart"
Cohesion: 0.12
Nodes (15): Payslip, _BasesCard, lines, _LinesCard, negative, payslipId, slip, subtitle (+7 more)

### Community 75 - "business_pdf_test.dart"
Cohesion: 0.29
Nodes (6): head, main, org, _plainInvoice, package:iakauntan/src/features/documents/invoice_pdf.dart, package:iakauntan/src/features/hr/payslip_pdf.dart

### Community 76 - "document_list_screen.dart"
Cohesion: 0.15
Nodes (12): BusinessDocument, createState, doc, docType, _DocumentTile, _einvoiceColor, _einvoiceIcon, kind (+4 more)

### Community 77 - "doc_types.dart"
Cohesion: 0.15
Nodes (12): DocTypeMeta, docTypes, docTypesFor, einvoice, icon, kind, metaFor, plural (+4 more)

### Community 78 - "0002_reference.sql"
Cohesion: 0.18
Nodes (12): public.exchange_rates, public.ref_classification_codes, public.ref_countries, public.ref_currencies, public.ref_einvoice_types, public.ref_exemption_reasons, public.ref_msic_codes, public.ref_payment_modes (+4 more)

### Community 79 - "public.gl_entries"
Cohesion: 0.22
Nodes (12): public.gl_entries, public.gl_lines, public.recurring_journals, set_updated_at, app.set_updated_at, auth.users, public.accounts, public.contacts (+4 more)

### Community 80 - "0018_platform_admin_modules_and_permissions.sql"
Cohesion: 0.23
Nodes (8): app.has_module(), app.is_platform_admin(), public.org_modules, public.platform_admins, public.platform_modules, public.platform_settings, auth.users, public.organizations

### Community 81 - "document_pdf.dart"
Cohesion: 0.17
Nodes (11): bold, buildDocumentPdf, doc, _inline, kit, _paragraphs, parts, regular (+3 more)

### Community 82 - "currentOrgProvider"
Cohesion: 0.09
Nodes (26): activitiesProvider, arAgingProvider, currentOrgProvider, dashboardProvider, einvoicesProvider, orgLogoProvider, payslipProvider, _ActivitiesCard (+18 more)

### Community 83 - "0020_platform_admin_rpcs.sql"
Cohesion: 0.17
Nodes (5): app.seed_modules_on_org, public.org_modules, public.platform_stats(), seed_modules, public.sales_documents

### Community 84 - "public.payslip_access_requests"
Cohesion: 0.21
Nodes (11): app.set_payslip_pay_date, app.payslip_access_granted(), app.set_payslip_pay_date(), public.my_payslip_access(), public.payslip_access_requests, set_pay_date, auth.users, public.employees (+3 more)

### Community 85 - "manifest.json"
Cohesion: 0.20
Nodes (9): background_color, description, display, icons, name, prefer_related_applications, short_name, start_url (+1 more)

### Community 86 - "0058_periodic_jobs.sql"
Cohesion: 0.18
Nodes (7): public.leave_entitlement_bands, public.recurring_journals, app.leave_entitlement(), app.roll_leave_year(), app.run_recurring_journals(), public.leave_balances, public.leave_types

### Community 87 - "public.corp_entities"
Cohesion: 0.45
Nodes (10): public.corp_entities, public.corp_officers, public.corp_persons, public.corp_share_classes, public.corp_share_events, auth, auth.users, public (+2 more)

### Community 88 - "public.corp_filings"
Cohesion: 0.40
Nodes (10): public.corp_documents, public.corp_filing_types, public.corp_filings, public.corp_resolutions, public.corp_templates, auth.users, public.corp_entities, public.corp_persons (+2 more)

### Community 89 - "0069_document_signatures.sql"
Cohesion: 0.29
Nodes (8): public.corp_request_signatures(), public.corp_signature_requests, public.corp_signature_state(), public.corp_signatures, auth.users, public.corp_documents, public.corp_persons, public.organizations

### Community 90 - "app.can_read_attachment"
Cohesion: 0.20
Nodes (7): app.attachment_path_ok, public.employee_documents, app.can_read_attachment(), attachment_path_ok, public.expense_claims, public.leave_requests, public.payslips

### Community 91 - "shell_no_org_test.dart"
Cohesion: 0.21
Nodes (10): harness, main, sizeTo, everything, harness, main, package:iakauntan/src/core/providers.dart, package:iakauntan/src/core/theme.dart (+2 more)

### Community 92 - "String?"
Cohesion: 0.33
Nodes (6): authStateProvider, build, CurrentOrgNotifier, PasswordRecoveryNotifier, Notifier, String?

### Community 93 - "invoice_pdf.dart"
Cohesion: 0.17
Nodes (11): anyDiscount, anyTax, bits, buildInvoicePdf, join, kit, pdf, _present (+3 more)

### Community 94 - "ConsumerWidget"
Cohesion: 0.07
Nodes (36): applicantsProvider, appraisalsProvider, corpBeneficialOwnersProvider, corpChargesProvider, corpDocumentsProvider, corpMembersProvider, corpOfficersProvider, corpShareEventsProvider (+28 more)

### Community 95 - "iAkauntan"
Cohesion: 0.04
Nodes (47): A guard that failed open, Access and administration, Access types, Accounting model, An auditor asking to see payslips, And every change is recorded too, Attachments, Backend changes (+39 more)

### Community 96 - "../../data/models.dart"
Cohesion: 0.13
Nodes (15): _, appName, Env, supabaseAnonKey, supabaseUrl, supportEmail, csv, _escape (+7 more)

### Community 97 - "Repo"
Cohesion: 0.20
Nodes (10): RepoAttachments, RepoCorp, RepoCorpSignatures, RepoCorpSigningLinks, Repo, RepoExtras, RepoHr, RepoHrSetup (+2 more)

### Community 98 - "check_embeds.py"
Cohesion: 0.60
Nodes (4): Path, ambiguous_pairs(), main(), scan()

### Community 99 - "public.corp_register_of_members"
Cohesion: 0.36
Nodes (6): public.corp_share_classes, app.corp_check_share_event(), public.corp_register_of_members(), public.corp_entities, public.corp_persons, public.corp_share_events

### Community 101 - "public.payslip_access_log"
Cohesion: 0.29
Nodes (6): app.covering_grant(), public.payslip_access_log, auth.users, public.organizations, public.payslip_access_requests, public.payslips

### Community 103 - "What You Must Do When Invoked"
Cohesion: 0.08
Nodes (24): For /graphify add and --watch, For /graphify query, For the commit hook and native CLAUDE.md integration, For --update and --cluster-only, /graphify, Honesty Rules, Interpreter guard for subcommands, Part A - Structural extraction for code files (+16 more)

### Community 104 - "app.claim_expense_allocation"
Cohesion: 0.33
Nodes (6): public.claim_types, public.expense_claim_lines, app.claim_expense_allocation(), public.post_expense_claim(), public.accounts, public.expense_claims

### Community 105 - "public.create_gl_entry"
Cohesion: 0.29
Nodes (4): public.fiscal_years, public.create_gl_entry(), public.fiscal_periods, public.organizations

### Community 106 - "0056_internal_posting_path.sql"
Cohesion: 0.29
Nodes (4): public.number_sequences, app.create_gl_entry_internal(), app.next_document_number_internal(), public.fiscal_periods

### Community 107 - "public.audit_list_payslips"
Cohesion: 0.29
Nodes (5): public.audit_list_payslips(), public.pay_periods, public.payroll_runs, public.payslip_lines, public.payslips

### Community 108 - "build"
Cohesion: 0.24
Nodes (12): canRequestPayslipAccessProvider, canRunPayrollProvider, myPayslipAccessProvider, paymentInstructionProvider, payrollRunsProvider, payslipsForRunProvider, build, _PaymentCard (+4 more)

### Community 109 - "0012_bootstrap.sql"
Cohesion: 0.40
Nodes (3): _coa, public.create_fiscal_year(), public.organizations

### Community 110 - "public.report_balance_sheet"
Cohesion: 0.53
Nodes (5): public.report_balance_sheet(), public.report_trial_balance(), public.accounts, public.gl_entries, public.gl_lines

### Community 111 - "public.employee_directory"
Cohesion: 0.33
Nodes (4): public.employee_directory(), public.departments, public.employees, public.positions

### Community 112 - "0065_corp_secretarial_documents.sql"
Cohesion: 0.40
Nodes (3): app.corp_merge_context(), public.corp_template_placeholders(), public.corp_entities

### Community 113 - "public.payroll_settings"
Cohesion: 0.40
Nodes (4): public.payroll_settings, public, public.accounts, public.organizations

### Community 114 - "app.calc_pcb"
Cohesion: 0.40
Nodes (3): app.calc_pcb(), public.employees, public.statutory_rates

### Community 115 - "0046_hrms_payslip_access_rpcs.sql"
Cohesion: 0.50
Nodes (3): public.request_payslip_access(), public.revoke_payslip_access(), public.payslip_access_requests

### Community 116 - "public.payroll_payment_instruction"
Cohesion: 0.50
Nodes (4): public.mark_payroll_paid(), public.payroll_payment_instruction(), public.payroll_runs, public.payslips

### Community 118 - "../../core/format.dart"
Cohesion: 0.09
Nodes (25): Contact, Employee, JournalEntry, contact, _ContactTile, createState, dispose, _query (+17 more)

### Community 119 - "reset_password_screen.dart"
Cohesion: 0.12
Nodes (18): passwordRecoveryProvider, _abandon, _busy, _confirm, createState, dispose, _error, _formKey (+10 more)

### Community 121 - "app.calc_pcb"
Cohesion: 0.50
Nodes (3): app.calc_pcb(), public.employees, public.statutory_rates

### Community 122 - "app.calc_pcb"
Cohesion: 0.50
Nodes (3): app.calc_pcb(), public.employees, public.statutory_rates

### Community 123 - "app.insured_wage"
Cohesion: 0.50
Nodes (3): app.insured_wage(), public.statutory_rates, public.statutory_schedules

### Community 124 - "app.calc_pcb"
Cohesion: 0.50
Nodes (3): app.calc_pcb(), public.employees, public.statutory_rates

### Community 126 - "public.reverse_gl_entry"
Cohesion: 0.50
Nodes (3): public.reverse_gl_entry(), public.gl_entries, public.gl_lines

### Community 127 - "AppColors"
Cohesion: 1.00
Nodes (3): @immutable, AppColors, ThemeExtension

### Community 129 - "graphify reference: extra exports and benchmark"
Cohesion: 0.22
Nodes (8): graphify reference: extra exports and benchmark, Step 6b - Wiki (only if --wiki flag), Step 7 - Neo4j export (only if --neo4j or --neo4j-push flag), Step 7a - FalkorDB export (only if --falkordb or --falkordb-push flag), Step 7b - SVG export (only if --svg flag), Step 7c - GraphML export (only if --graphml flag), Step 7d - MCP server (only if --mcp flag), Step 8 - Token reduction benchmark (only if total_words > 5000)

### Community 130 - "graphify reference: query, path, explain"
Cohesion: 0.33
Nodes (5): For /graphify explain, For /graphify path, graphify reference: query, path, explain, Step 0 — Constrained query expansion (REQUIRED before traversal), Step 1 — Traversal

### Community 137 - "graphify reference: add a URL and watch a folder"
Cohesion: 0.50
Nodes (3): For /graphify add, For --watch, graphify reference: add a URL and watch a folder

### Community 140 - "graphify reference: commit hook and native CLAUDE.md integration"
Cohesion: 0.50
Nodes (3): For git commit hook, For native CLAUDE.md integration, graphify reference: commit hook and native CLAUDE.md integration

### Community 166 - "graphify reference: incremental update and cluster-only"
Cohesion: 0.50
Nodes (3): For --cluster-only, For --update (incremental re-extraction), graphify reference: incremental update and cluster-only

### Community 167 - "build"
Cohesion: 0.67
Nodes (3): build, _save, Route /secretarial

### Community 175 - "organizationsProvider"
Cohesion: 0.47
Nodes (6): isPlatformAdminProvider, organizationsProvider, _AuthRefresh, AppShell, _visible, ChangeNotifier

### Community 176 - "build"
Cohesion: 0.50
Nodes (5): corpEntitiesProvider, corpFilingsProvider, build, SecretarialScreen, Route /secretarial/new

### Community 177 - "my_hr_screen.dart"
Cohesion: 0.15
Nodes (14): myEmployeeProvider, myPayslipsProvider, LeaveBalance, _submit, balance, _BalancePill, build, employee (+6 more)

### Community 178 - "payslip_pdf.dart"
Cohesion: 0.18
Nodes (10): _block, buildPayslipPdf, deductions, earnings, employer, kit, pdf, period (+2 more)

### Community 180 - "payment_file_test.dart"
Cohesion: 0.33
Nodes (5): _line, main, package:iakauntan/src/core/download.dart, package:iakauntan/src/data/models.dart, package:iakauntan/src/features/hr/payment_file.dart

### Community 181 - "download_web.dart"
Cohesion: 0.14
Nodes (13): false, saveBytesFile, saveTextFile, anchor, blob, saveBytesFile, saveTextFile, true (+5 more)

### Community 182 - "_CreateOrgScreenState"
Cohesion: 0.50
Nodes (4): build, CreateOrgScreen, _CreateOrgScreenState, _statesProvider

### Community 183 - "package:flutter/material.dart"
Cohesion: 0.17
Nodes (11): build, error, main, _StartupFailure, main, package:flutter/material.dart, package:flutter_riverpod/flutter_riverpod.dart, package:iakauntan/src/features/auth/reset_password_screen.dart (+3 more)

### Community 184 - "../../core/theme.dart"
Cohesion: 0.33
Nodes (6): build, IAkauntanApp, routerProvider, ../../core/env.dart, core/router.dart, ../../core/theme.dart

### Community 185 - "package:flutter_test/flutter_test.dart"
Cohesion: 0.50
Nodes (3): main, package:flutter_test/flutter_test.dart, package:iakauntan/src/core/format.dart

## Knowledge Gaps
- **1610 isolated node(s):** `XCTest`, `error`, `main`, `build`, `false` (+1605 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **27 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `_` connect `_` to `../../data/models.dart`, `AppColorsX`, `dashboard_screen.dart`, `package:flutter/material.dart`, `_`, `AppColors`?**
  _High betweenness centrality (0.023) - this node is a cross-community bridge._
- **Why does `_` connect `_` to `../../data/models.dart`, `payslip_pdf.dart`, `invoice_pdf.dart`, `download_web.dart`?**
  _High betweenness centrality (0.012) - this node is a cross-community bridge._
- **Why does `DashboardSummary` connect `dashboard_screen.dart` to `models.dart`, `providers.dart`?**
  _High betweenness centrality (0.007) - this node is a cross-community bridge._
- **What connects `XCTest`, `error`, `main` to the rest of the system?**
  _1610 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `models.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.0056657223796034 - nodes in this community are weakly interconnected._
- **Should `repository.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.015037593984962405 - nodes in this community are weakly interconnected._
- **Should `corp_models.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.016666666666666666 - nodes in this community are weakly interconnected._