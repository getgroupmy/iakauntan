# Graph Report - app  (2026-08-12)

## Corpus Check
- 119 files · ~120,167 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 3126 nodes · 4829 edges · 124 communities (116 shown, 8 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `f2848e23`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- models.dart
- repository.dart
- corp_models.dart
- document_editor.dart
- settings_screen.dart
- entity_screen.dart
- widgets.dart
- providers.dart
- hr_setup_screen.dart
- router.dart
- employee_editor.dart
- statutory_rates_admin.dart
- statement_import.dart
- report_spec.dart
- tax_year_section.dart
- _
- repoProvider
- entity_editor.dart
- settlement_dialog.dart
- items_screen.dart
- journal_editor.dart
- reconciliation_screen.dart
- team_screen.dart
- platform_console_screen.dart
- payroll_screen.dart
- reports_screen.dart
- dashboard_screen.dart
- leave_screen.dart
- line_editor.dart
- contact_editor.dart
- corp_repository.dart
- _
- matter_detail_screen.dart
- item_prices_dialog.dart
- create_org_screen.dart
- claims_screen.dart
- recurring_screen.dart
- leave_bands_dialog.dart
- pipeline_screen.dart
- asset_editor.dart
- contact_extras.dart
- sign_in_screen.dart
- einvoice_screen.dart
- stock_take_screen.dart
- line_draft.dart
- signing_page.dart
- StatelessWidget
- app_shell.dart
- attachments_card.dart
- _
- transfer_dialog.dart
- secretarial_screen.dart
- matters_screen.dart
- package:flutter_test/flutter_test.dart
- assets_screen.dart
- supabaseProvider
- dart:typed_data
- State
- demo_accounts.dart
- holidays_tab.dart
- package:flutter_riverpod/flutter_riverpod.dart
- reset_password_screen.dart
- audit_trail_card.dart
- my_hr_screen.dart
- expenses_screen.dart
- payslip_screen.dart
- attachments_repository.dart
- package:flutter/material.dart
- .application
- fx.dart
- ../../core/providers.dart
- business_pdf_test.dart
- build
- build
- statutory_rates_tab.dart
- transfer.dart
- report_pdf_test.dart
- DateTime
- document_list_screen.dart
- doc_types.dart
- people_screen.dart
- invoice_pdf.dart
- document_pdf.dart
- ../../core/widgets.dart
- ../../data/repository.dart
- build
- canWriteProvider
- currentOrgProvider
- statement_pdf.dart
- payslip_pdf.dart
- report_pdf.dart
- ../../core/format.dart
- package:iakauntan/src/data/models.dart
- double get
- Repo
- manifest.json
- ../../data/models.dart
- _ContactEditorState
- main.dart
- _MatterDetailScreenState
- _statesProvider
- report_spec_test.dart
- ../../core/theme.dart
- static const
- _SettlementDialogState
- statement_test.dart
- build
- transfer_test.dart
- ContactExtras
- _AssetsScreenState
- MainActivity.kt
- AppColors
- AppColorsX
- download_stub.dart
- MyInvoisException
- LaunchImage.imageset/README.md
- DocKind
- README.md
- bool?

## God Nodes (most connected - your core abstractions)
1. `repoProvider` - 135 edges
2. `_` - 44 edges
3. `_` - 31 edges
4. `_` - 27 edges
5. `canWriteProvider` - 26 edges
6. `canPostProvider` - 24 edges
7. `supabaseProvider` - 21 edges
8. `currentOrgProvider` - 20 edges
9. `build` - 16 edges
10. `currentUserProvider` - 13 edges

## Surprising Connections (you probably didn't know these)
- `_save` --references--> `repoProvider`  [EXTRACTED]
  lib/src/features/admin/statutory_rates_admin.dart → lib/src/core/providers.dart
- `_save` --references--> `repoProvider`  [EXTRACTED]
  lib/src/features/assets/asset_editor.dart → lib/src/core/providers.dart
- `_post` --references--> `repoProvider`  [EXTRACTED]
  lib/src/features/assets/depreciation_dialog.dart → lib/src/core/providers.dart
- `dispose` --references--> `repoProvider`  [EXTRACTED]
  lib/src/features/assets/disposal_dialog.dart → lib/src/core/providers.dart
- `_complete` --references--> `repoProvider`  [EXTRACTED]
  lib/src/features/banking/reconciliation_screen.dart → lib/src/core/providers.dart

## Import Cycles
- None detected.

## Communities (124 total, 8 thin omitted)

### Community 0 - "models.dart"
Cohesion: 0.01
Nodes (391): Duration? get, Account, accountCode, accountName, accountSubtype, accountType, accumulated, accumulatedDepreciation (+383 more)

### Community 1 - "repository.dart"
Cohesion: 0.01
Nodes (188): ../features/documents/transfer.dart, acceptInvitation, accounts, activities, addDisbursement, addFixedHolidays, addTimeEntry, amIPlatformAdmin (+180 more)

### Community 2 - "corp_models.dart"
Cohesion: 0.02
Nodes (119): DateTime get, address, amountSecured, appointedOn, appointsDirectors, body, businessAddress, capacity (+111 more)

### Community 3 - "document_editor.dart"
Cohesion: 0.02
Nodes (87): ../../core/layout.dart, DocKind get, DocTypeMeta get, invoice_pdf.dart, _actions, _base, baseCurrency, caption (+79 more)

### Community 4 - "settings_screen.dart"
Cohesion: 0.05
Nodes (55): ../auth/reset_password_screen.dart, ConsumerState, ConsumerStatefulWidget, _DocumentEditor, fxRevaluationPreviewProvider, FiscalYear, FxRevaluation, DocumentEditor (+47 more)

### Community 5 - "entity_screen.dart"
Cohesion: 0.04
Nodes (54): document_pdf.dart, CorpBeneficialOwner, CorpCharge, CorpDocument, CorpMember, CorpOfficer, CorpShareEvent, CorpSignature (+46 more)

### Community 6 - "widgets.dart"
Cohesion: 0.04
Nodes (50): CustomPainter, EdgeInsets, EdgeInsetsGeometry, accent, action, amount, bold, build (+42 more)

### Community 7 - "providers.dart"
Cohesion: 0.04
Nodes (48): AuthState, attendanceProvider, auditPayslip, authStateProvider, build, canReadLedgerProvider, clear, corpPersonsProvider (+40 more)

### Community 8 - "hr_setup_screen.dart"
Cohesion: 0.05
Nodes (46): holidays_tab.dart, leave_bands_dialog.dart, payrollSettingsProvider, setupRowsProvider, _blank, boolean, build, _c (+38 more)

### Community 9 - "router.dart"
Cohesion: 0.05
Nodes (43): ../features/admin/platform_console_screen.dart, ../features/assets/assets_screen.dart, ../features/auth/reset_password_screen.dart, ../features/auth/sign_in_screen.dart, ../features/banking/reconciliation_screen.dart, ../features/contacts/contact_editor.dart, ../features/contacts/contacts_screen.dart, ../features/crm/pipeline_screen.dart (+35 more)

### Community 10 - "employee_editor.dart"
Cohesion: 0.05
Nodes (41): departmentsProvider, employeeProvider, positionsProvider, _birthDate, build, _c, children, createState (+33 more)

### Community 11 - "statutory_rates_admin.dart"
Cohesion: 0.05
Nodes (39): double?, ../hr/statutory_rates_tab.dart, _AdminScheduleTile, _body, byCategory, category, createState, dispose (+31 more)

### Community 12 - "statement_import.dart"
Cohesion: 0.05
Nodes (39): amount, amountAt, _amountNames, buffer, creditAt, _creditNames, d, date (+31 more)

### Community 13 - "report_spec.dart"
Cohesion: 0.05
Nodes (39): active, amount, assets, balanceSheetSpec, blocks, Cell, code, cogs (+31 more)

### Community 14 - "tax_year_section.dart"
Cohesion: 0.06
Nodes (37): int get, declaredReliefsProvider, reliefTypesProvider, ytdOpeningProvider, DeclaredRelief, _amount, build, _c (+29 more)

### Community 15 - "_"
Cohesion: 0.06
Nodes (37): AppColors get, ColorScheme get, _, AppTheme, base, _border, _build, _clickable (+29 more)

### Community 16 - "repoProvider"
Cohesion: 0.08
Nodes (37): ConsumerWidget, accountsProvider, bankAccountsProvider, canPostProvider, corpOfficersProvider, expensesProvider, fiscalYearsProvider, recurringJournalsProvider (+29 more)

### Community 17 - "entity_editor.dart"
Cohesion: 0.06
Nodes (36): ../../data/corp_repository.dart, corpEntityProvider, _auditExempt, _blank, build, _c, children, CorpEntityEditor (+28 more)

### Community 18 - "settlement_dialog.dart"
Cohesion: 0.06
Nodes (36): fx.dart, _allocated, _allocatedDocs, _AllocationRow, _AllocationRowState, _allocations, amount, _bankAccountId (+28 more)

### Community 19 - "items_screen.dart"
Cohesion: 0.07
Nodes (36): item_prices_dialog.dart, classificationCodesProvider, itemsProvider, taxCodesProvider, Item, build, LineEditorCard, build (+28 more)

### Community 20 - "journal_editor.dart"
Cohesion: 0.06
Nodes (36): projectsProvider, _HeaderCard, accountId, accounts, build, createState, credit, credits (+28 more)

### Community 21 - "reconciliation_screen.dart"
Cohesion: 0.06
Nodes (35): _asAt, _balance, _bankAccountId, banks, canPost, caption, _complete, _Controls (+27 more)

### Community 22 - "team_screen.dart"
Cohesion: 0.07
Nodes (33): audit_trail_card.dart, canAdminProvider, payslipAccessLogProvider, payslipAccessRequestsProvider, teamProvider, TeamMember, _GrantedBadge, _AccessLog (+25 more)

### Community 23 - "platform_console_screen.dart"
Cohesion: 0.07
Nodes (33): platformOrgsProvider, platformRepoProvider, platformSettingsProvider, platformStatsProvider, PlatformOrg, build, _controller, createState (+25 more)

### Community 24 - "payroll_screen.dart"
Cohesion: 0.06
Nodes (33): PaymentLine, PayrollRun, PayslipAccessRequest, _buildForm, _calculate, createState, dispose, emphasise (+25 more)

### Community 25 - "reports_screen.dart"
Cohesion: 0.08
Nodes (31): AutoDisposeFutureProvider, DateTimeRange, trialBalanceProvider, ReportSpec, _balanceSheetProvider, _Block, build, _cell (+23 more)

### Community 26 - "dashboard_screen.dart"
Cohesion: 0.08
Nodes (30): Color, activitiesProvider, arAgingProvider, dashboardProvider, revenueTrendProvider, DashboardSummary, _ActivitiesCard, _activityIcon (+22 more)

### Community 27 - "leave_screen.dart"
Cohesion: 0.08
Nodes (29): leaveRequestsProvider, leaveTypesProvider, myLeaveBalancesProvider, LeaveRequest, build, createState, _DateField, _days (+21 more)

### Community 28 - "line_editor.dart"
Cohesion: 0.07
Nodes (29): _applyItem, controller, createState, currency, _description, _discount, dispose, editable (+21 more)

### Community 29 - "contact_editor.dart"
Cohesion: 0.07
Nodes (28): contact_extras.dart, _c, contactId, contactType, _controllers, createState, dispose, _entityType (+20 more)

### Community 30 - "corp_repository.dart"
Cohesion: 0.07
Nodes (28): corp_models.dart, addCorpShareEvent, corpBeneficialOwners, corpCharges, corpCreateSigningLink, corpDocuments, corpEntities, corpEntity (+20 more)

### Community 31 - "_"
Cohesion: 0.07
Nodes (29): _, _compact, _date, _dateTime, days, Fmt, _fractional, initials (+21 more)

### Community 32 - "matter_detail_screen.dart"
Cohesion: 0.08
Nodes (28): _activity, _amount, _billable, canPost, _ClientMoneyDialog, _ClientMoneyDialogState, createState, _date (+20 more)

### Community 33 - "item_prices_dialog.dart"
Cohesion: 0.08
Nodes (27): _active, _code, createState, _delete, dispose, _edit, item, itemId (+19 more)

### Community 34 - "create_org_screen.dart"
Cohesion: 0.07
Nodes (27): _address, _busy, _city, createState, data, dispose, _email, _emptyToNull (+19 more)

### Community 35 - "claims_screen.dart"
Cohesion: 0.09
Nodes (26): claimsProvider, claimTypesProvider, ExpenseClaim, _amount, _bankAccountId, build, claim, ClaimsScreen (+18 more)

### Community 36 - "recurring_screen.dart"
Cohesion: 0.08
Nodes (26): accounts, _active, _autoPost, _balances, createState, _credits, _debits, dispose (+18 more)

### Community 37 - "leave_bands_dialog.dart"
Cohesion: 0.09
Nodes (25): leaveBandsProvider, _applyPreset, band, _BandDialog, _BandDialogState, _BandRow, build, _busy (+17 more)

### Community 38 - "pipeline_screen.dart"
Cohesion: 0.09
Nodes (25): opportunitiesProvider, pipelineStagesProvider, Opportunity, PipelineStage, _amount, build, canWrite, _closeDate (+17 more)

### Community 39 - "asset_editor.dart"
Cohesion: 0.08
Nodes (25): _acquired, asset, _AssetEditor, _AssetEditorState, _assetNo, build, _category, _cost (+17 more)

### Community 40 - "contact_extras.dart"
Cohesion: 0.08
Nodes (25): _AddressTile, _c, contactId, createState, _default, _delete, dispose, _editAddress (+17 more)

### Community 41 - "sign_in_screen.dart"
Cohesion: 0.08
Nodes (24): demo_accounts.dart, _Banner, _Brand, build, _busy, color, createState, _demoBusy (+16 more)

### Community 42 - "einvoice_screen.dart"
Cohesion: 0.09
Nodes (23): einvoicesProvider, EinvoiceDocument, build, _cancel, createState, _describe, doc, EinvoiceScreen (+15 more)

### Community 43 - "stock_take_screen.dart"
Cohesion: 0.10
Nodes (23): stockOnHandProvider, warehousesProvider, build, _controller, _counted, createState, _date, dispose (+15 more)

### Community 44 - "line_draft.dart"
Cohesion: 0.08
Nodes (23): applyItemToLine, classificationCode, computeLine, description, discount, discountPercent, fromLine, gross (+15 more)

### Community 45 - "signing_page.dart"
Cohesion: 0.09
Nodes (22): Future, body, build, _client, createState, dispose, _done, _forState (+14 more)

### Community 46 - "StatelessWidget"
Cohesion: 0.09
Nodes (23): AsyncView, _DeltaBadge, EmptyState, ErrorState, FilterBar, Money, PageBody, SectionHeader (+15 more)

### Community 47 - "app_shell.dart"
Cohesion: 0.09
Nodes (22): Organization, _bareLayout, child, _collapsedWidth, _Dest, _destinations, extended, _extendedWidth (+14 more)

### Community 48 - "attachments_card.dart"
Cohesion: 0.10
Nodes (21): ../../data/attachments_repository.dart, AttachmentsCard, _AttachmentsCardState, attachmentsProvider, build, _busy, canWrite, createState (+13 more)

### Community 49 - "_"
Cohesion: 0.10
Nodes (22): Font, format.dart, _, amountRow, bold, _cached, field, footer (+14 more)

### Community 50 - "transfer_dialog.dart"
Cohesion: 0.10
Nodes (21): build, _controller, createState, dispose, initState, line, _lines, _load (+13 more)

### Community 51 - "secretarial_screen.dart"
Cohesion: 0.10
Nodes (20): AsyncValue, ../../data/corp_models.dart, corpEntitiesProvider, corpFilingsProvider, CorpEntity, CorpFiling, build, _colour (+12 more)

### Community 52 - "matters_screen.dart"
Cohesion: 0.10
Nodes (20): Matter, MatterSummary, _clientId, _courtRef, createState, _deposit, dispose, _formKey (+12 more)

### Community 53 - "package:flutter_test/flutter_test.dart"
Cohesion: 0.10
Nodes (15): Amount,Particulars,Posting, dart:io, package:flutter_test/flutter_test.dart, package:iakauntan/src/core/format.dart, package:iakauntan/src/features/admin/statutory_rates_admin.dart, package:iakauntan/src/features/banking/statement_import.dart, package:iakauntan/src/features/ledger/journal_editor.dart, main (+7 more)

### Community 54 - "assets_screen.dart"
Cohesion: 0.10
Nodes (19): asset_editor.dart, depreciation_dialog.dart, disposal_dialog.dart, FixedAsset, asset, assets, _AssetTile, createState (+11 more)

### Community 55 - "supabaseProvider"
Cohesion: 0.15
Nodes (20): ChangeNotifier, currentOrgIdProvider, isPlatformAdminProvider, organizationsProvider, supabaseProvider, _AuthRefresh, _resetPassword, _signInAsDemo (+12 more)

### Community 56 - "dart:typed_data"
Cohesion: 0.11
Nodes (17): dart:js_interop, dart:typed_data, false, saveBytesFile, saveTextFile, anchor, blob, saveBytesFile (+9 more)

### Community 57 - "State"
Cohesion: 0.14
Nodes (20): _RateRow, _RateRowState, _WideLine, _WideLineState, _LineRow, _LineRowState, _MonthPickerDialog, _MonthPickerDialogState (+12 more)

### Community 58 - "demo_accounts.dart"
Cohesion: 0.10
Nodes (19): account, accounts, _AccountTile, build, busy, busyEmail, DemoAccount, DemoAccountPicker (+11 more)

### Community 59 - "holidays_tab.dart"
Cohesion: 0.11
Nodes (19): _addFixed, _busy, createState, _date, _delete, dispose, _edit, HolidaysTab (+11 more)

### Community 60 - "package:flutter_riverpod/flutter_riverpod.dart"
Cohesion: 0.14
Nodes (16): package:flutter_riverpod/flutter_riverpod.dart, package:iakauntan/src/core/providers.dart, package:iakauntan/src/features/auth/reset_password_screen.dart, package:iakauntan/src/features/shell/app_shell.dart, package:supabase_flutter/supabase_flutter.dart, main, everything, harness (+8 more)

### Community 61 - "reset_password_screen.dart"
Cohesion: 0.12
Nodes (18): FormState, passwordRecoveryProvider, _abandon, _busy, _confirm, createState, dispose, _error (+10 more)

### Community 62 - "audit_trail_card.dart"
Cohesion: 0.12
Nodes (16): auditTrailProvider, AuditEntry, after, AuditTrailCard, before, build, _colour, entry (+8 more)

### Community 63 - "my_hr_screen.dart"
Cohesion: 0.14
Nodes (16): myAttendanceTodayProvider, myEmployeeProvider, myPayslipsProvider, Employee, LeaveBalance, _submit, balance, _BalancePill (+8 more)

### Community 64 - "expenses_screen.dart"
Cohesion: 0.12
Nodes (16): _accountId, _amount, _bankAccountId, createState, _date, _description, dispose, _ExpenseDialog (+8 more)

### Community 65 - "payslip_screen.dart"
Cohesion: 0.12
Nodes (15): ../../core/download.dart, Payslip, _BasesCard, lines, _LinesCard, negative, payslipId, slip (+7 more)

### Community 66 - "attachments_repository.dart"
Cohesion: 0.12
Nodes (15): int?, Attachment, attachments, attachmentUrl, bucket, createdAt, deleteAttachment, fileName (+7 more)

### Community 67 - "package:flutter/material.dart"
Cohesion: 0.15
Nodes (12): package:flutter/material.dart, package:iakauntan/src/core/theme.dart, package:iakauntan/src/core/widgets.dart, package:iakauntan/src/features/auth/demo_accounts.dart, asset, main, main, pump (+4 more)

### Community 68 - ".application"
Cohesion: 0.15
Nodes (10): Any, Flutter, FlutterAppDelegate, AppDelegate, Bool, RunnerTests, UIApplication, UIKit (+2 more)

### Community 69 - "fx.dart"
Cohesion: 0.14
Nodes (13): bool get, byCurrency, code, conflict, described, isConflicting, parseRate, rateCaption (+5 more)

### Community 70 - "../../core/providers.dart"
Cohesion: 0.16
Nodes (13): ../../core/providers.dart, contactsProvider, Contact, build, contact, ContactsScreen, _ContactsScreenState, _ContactTile (+5 more)

### Community 71 - "business_pdf_test.dart"
Cohesion: 0.14
Nodes (12): dart:convert, Dated this 11 August, package:iakauntan/src/features/documents/invoice_pdf.dart, package:iakauntan/src/features/hr/payslip_pdf.dart, package:iakauntan/src/features/secretarial/document_pdf.dart, head, main, org (+4 more)

### Community 72 - "build"
Cohesion: 0.15
Nodes (14): corpBeneficialOwnersProvider, corpChargesProvider, corpDocumentsProvider, corpMembersProvider, corpShareEventsProvider, corpSignaturesProvider, corpTemplatesProvider, _BeneficialOwners (+6 more)

### Community 73 - "build"
Cohesion: 0.18
Nodes (14): currentUserProvider, enabledModulesProvider, isDemoAccountProvider, memberRoleProvider, moduleEnabled, platformModulesProvider, select, build (+6 more)

### Community 74 - "statutory_rates_tab.dart"
Cohesion: 0.15
Nodes (13): statutorySchedulesProvider, build, StatutoryRatesAdminTab, _bodies, bodyName, build, schedule, _ScheduleCard (+5 more)

### Community 75 - "transfer.dart"
Cohesion: 0.14
Nodes (13): canTransfer, description, fromJson, lineId, lineNo, null, outstanding, quantity (+5 more)

### Community 76 - "report_pdf_test.dart"
Cohesion: 0.14
Nodes (12): package:iakauntan/src/features/reports/report_pdf.dart, package:iakauntan/src/features/reports/report_spec.dart, package:iakauntan/src/features/reports/reports_screen.dart, generatedAt, main, org, pl, png (+4 more)

### Community 77 - "DateTime"
Cohesion: 0.17
Nodes (12): DateTime, asset, _bankAccountId, createState, _DisposalDialog, _DisposalDialogState, dispose, _on (+4 more)

### Community 78 - "document_list_screen.dart"
Cohesion: 0.15
Nodes (12): doc_types.dart, BusinessDocument, createState, doc, docType, _DocumentTile, _einvoiceColor, _einvoiceIcon (+4 more)

### Community 79 - "doc_types.dart"
Cohesion: 0.15
Nodes (12): IconData, DocTypeMeta, docTypes, docTypesFor, einvoice, icon, kind, metaFor (+4 more)

### Community 80 - "people_screen.dart"
Cohesion: 0.19
Nodes (12): canManageHrProvider, directoryProvider, build, canManageHr, createState, employee, PeopleScreen, _PeopleScreenState (+4 more)

### Community 81 - "invoice_pdf.dart"
Cohesion: 0.15
Nodes (12): anyDiscount, anyTax, bits, buildInvoicePdf, join, kit, mode, pdf (+4 more)

### Community 82 - "document_pdf.dart"
Cohesion: 0.17
Nodes (11): ../../core/pdf_kit.dart, bold, buildDocumentPdf, doc, _inline, kit, _paragraphs, parts (+3 more)

### Community 83 - "../../core/widgets.dart"
Cohesion: 0.20
Nodes (11): ../../core/widgets.dart, journal_editor.dart, journalSourceFilterProvider, journalsProvider, JournalEntry, build, entry, JournalsScreen (+3 more)

### Community 84 - "../../data/repository.dart"
Cohesion: 0.21
Nodes (11): ../../data/repository.dart, applicantsProvider, appraisalsProvider, requisitionsProvider, _advance, _AppraisalsTab, build, _CandidatesTab (+3 more)

### Community 85 - "build"
Cohesion: 0.24
Nodes (12): canRequestPayslipAccessProvider, canRunPayrollProvider, myPayslipAccessProvider, paymentInstructionProvider, payrollRunsProvider, payslipsForRunProvider, build, _PaymentCard (+4 more)

### Community 86 - "canWriteProvider"
Cohesion: 0.21
Nodes (12): canWriteProvider, clientTransactionsProvider, disbursementsProvider, documentsProvider, timeEntriesProvider, build, DocumentListScreen, _DocumentListScreenState (+4 more)

### Community 87 - "currentOrgProvider"
Cohesion: 0.24
Nodes (12): currentOrgProvider, orgLogoProvider, payslipProvider, _downloadStatement, _downloadPdf, _submitEinvoice, build, _downloadPdf (+4 more)

### Community 88 - "statement_pdf.dart"
Cohesion: 0.17
Nodes (11): address, aged, buildStatementPdf, kit, mode, open, pdf, _present (+3 more)

### Community 89 - "payslip_pdf.dart"
Cohesion: 0.17
Nodes (11): _block, buildPayslipPdf, deductions, earnings, employer, kit, mode, pdf (+3 more)

### Community 90 - "report_pdf.dart"
Cohesion: 0.17
Nodes (11): _block, buildReportPdf, _cell, _grid, _highlight, kit, mode, pdf (+3 more)

### Community 91 - "../../core/format.dart"
Cohesion: 0.22
Nodes (10): ../../core/format.dart, depreciationPreviewProvider, _asAt, build, createState, _DepreciationDialog, _DepreciationDialogState, _post (+2 more)

### Community 92 - "package:iakauntan/src/data/models.dart"
Cohesion: 0.18
Nodes (9): package:iakauntan/src/core/download.dart, package:iakauntan/src/core/layout.dart, package:iakauntan/src/data/models.dart, package:iakauntan/src/features/documents/fx.dart, package:iakauntan/src/features/hr/payment_file.dart, doc, main, _line (+1 more)

### Community 93 - "double get"
Cohesion: 0.20
Nodes (9): double get, Ageing, current, over90, today, total, upTo30, upTo60 (+1 more)

### Community 94 - "Repo"
Cohesion: 0.20
Nodes (10): RepoAttachments, RepoCorp, RepoCorpSignatures, RepoCorpSigningLinks, Repo, RepoExtras, RepoHr, RepoHrSetup (+2 more)

### Community 95 - "manifest.json"
Cohesion: 0.20
Nodes (9): background_color, description, display, icons, name, prefer_related_applications, short_name, start_url (+1 more)

### Community 96 - "../../data/models.dart"
Cohesion: 0.22
Nodes (8): ../../data/models.dart, csv, _escape, filename, header, PaymentFile, _row, total

### Community 97 - "_ContactEditorState"
Cohesion: 0.28
Nodes (9): itemPricesProvider, priceLevelsProvider, _build, ContactEditor, _ContactEditorState, _statesRefProvider, build, _ItemPricesDialog (+1 more)

### Community 98 - "main.dart"
Cohesion: 0.25
Nodes (7): build, error, main, _StartupFailure, src/app.dart, src/core/env.dart, src/core/theme.dart

### Community 99 - "_MatterDetailScreenState"
Cohesion: 0.29
Nodes (8): mattersProvider, matterSummaryProvider, initState, MatterDetailScreen, _MatterDetailScreenState, build, MattersScreen, _MattersScreenState

### Community 100 - "_statesProvider"
Cohesion: 0.25
Nodes (8): publicHolidaysProvider, _AddressDialog, _AddressDialogState, build, _HolidayDialog, _HolidayDialogState, build, _statesProvider

### Community 101 - "report_spec_test.dart"
Cohesion: 0.32
Nodes (7): ReportBlock, ReportGrid, ReportHighlight, ReportSection, main, pl, range

### Community 102 - "../../core/theme.dart"
Cohesion: 0.33
Nodes (6): ../../core/env.dart, core/router.dart, ../../core/theme.dart, build, IAkauntanApp, routerProvider

### Community 103 - "static const"
Cohesion: 0.33
Nodes (7): _, appName, Env, supabaseAnonKey, supabaseUrl, supportEmail, static const

### Community 104 - "_SettlementDialogState"
Cohesion: 0.29
Nodes (7): outstandingProvider, paymentModesProvider, build, _OpenDocuments, _OpenDocumentsState, _SettlementDialog, _SettlementDialogState

### Community 105 - "statement_test.dart"
Cohesion: 0.29
Nodes (6): package:iakauntan/src/core/pdf_kit.dart, package:iakauntan/src/features/contacts/statement.dart, package:iakauntan/src/features/contacts/statement_pdf.dart, asAt, doc, main

### Community 106 - "build"
Cohesion: 0.40
Nodes (5): currenciesProvider, customerCreditProvider, build, _CreditBanner, _CurrencyField

### Community 107 - "transfer_test.dart"
Cohesion: 0.40
Nodes (4): package:iakauntan/src/features/documents/doc_types.dart, package:iakauntan/src/features/documents/transfer.dart, line, main

### Community 108 - "ContactExtras"
Cohesion: 0.67
Nodes (4): contactAddressesProvider, contactPersonsProvider, build, ContactExtras

### Community 109 - "_AssetsScreenState"
Cohesion: 0.50
Nodes (4): fixedAssetsProvider, AssetsScreen, _AssetsScreenState, build

### Community 111 - "AppColors"
Cohesion: 1.00
Nodes (3): @immutable, AppColors, ThemeExtension

## Knowledge Gaps
- **2104 isolated node(s):** `XCTest`, `error`, `main`, `build`, `false` (+2099 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `_` connect `_` to `dart:typed_data`, `payslip_pdf.dart`, `statement_pdf.dart`, `../../data/models.dart`?**
  _High betweenness centrality (0.028) - this node is a cross-community bridge._
- **Why does `_` connect `_` to `package:flutter/material.dart`, `static const`, `AppColors`, `AppColorsX`, `dashboard_screen.dart`, `_`?**
  _High betweenness centrality (0.023) - this node is a cross-community bridge._
- **Why does `repoProvider` connect `repoProvider` to `document_editor.dart`, `settings_screen.dart`, `entity_screen.dart`, `providers.dart`, `hr_setup_screen.dart`, `statutory_rates_admin.dart`, `tax_year_section.dart`, `settlement_dialog.dart`, `items_screen.dart`, `journal_editor.dart`, `reconciliation_screen.dart`, `team_screen.dart`, `payroll_screen.dart`, `leave_screen.dart`, `contact_editor.dart`, `matter_detail_screen.dart`, `item_prices_dialog.dart`, `claims_screen.dart`, `recurring_screen.dart`, `leave_bands_dialog.dart`, `pipeline_screen.dart`, `asset_editor.dart`, `contact_extras.dart`, `einvoice_screen.dart`, `stock_take_screen.dart`, `attachments_card.dart`, `transfer_dialog.dart`, `matters_screen.dart`, `holidays_tab.dart`, `my_hr_screen.dart`, `expenses_screen.dart`, `build`, `build`, `DateTime`, `../../core/widgets.dart`, `../../data/repository.dart`, `build`, `currentOrgProvider`, `../../core/format.dart`, `_ContactEditorState`, `_statesProvider`, `_SettlementDialogState`, `ContactExtras`?**
  _High betweenness centrality (0.014) - this node is a cross-community bridge._
- **What connects `XCTest`, `error`, `main` to the rest of the system?**
  _2104 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `models.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.00510204081632653 - nodes in this community are weakly interconnected._
- **Should `repository.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.010582010582010581 - nodes in this community are weakly interconnected._
- **Should `corp_models.dart` be split into smaller, more focused modules?**
  _Cohesion score 0.016666666666666666 - nodes in this community are weakly interconnected._