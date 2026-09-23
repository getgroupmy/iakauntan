import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/crm/leads_screen.dart';
import 'package:iakauntan/src/features/crm/pipeline_screen.dart';
import 'package:iakauntan/src/features/documents/cheques_screen.dart';
import 'package:iakauntan/src/features/documents/contra_screen.dart';
import 'package:iakauntan/src/features/documents/deposits_screen.dart';
import 'package:iakauntan/src/features/documents/knock_off_screen.dart';
import 'package:iakauntan/src/features/expenses/expenses_screen.dart';
import 'package:iakauntan/src/features/financials/filing_screen.dart';
import 'package:iakauntan/src/features/financials/filings_screen.dart';
import 'package:iakauntan/src/features/hr/hr_setup_screen.dart';
import 'package:iakauntan/src/features/hr/onboarding_screen.dart';
import 'package:iakauntan/src/features/hr/payroll_screen.dart';
import 'package:iakauntan/src/features/legal/matters_screen.dart';
import 'package:iakauntan/src/features/profile/profile_screen.dart';
import 'package:iakauntan/src/features/property/property_screen.dart';
import 'package:iakauntan/src/features/secretarial/people_screen.dart';
import 'package:iakauntan/src/features/settings/email_screen.dart';
import 'package:iakauntan/src/features/reports/budgets_screen.dart';
import 'package:iakauntan/src/features/reports/cash_forecast_screen.dart';
import 'package:iakauntan/src/features/landing/no_access_screen.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/shared/receipt_capture.dart';
import 'package:iakauntan/src/features/ledger/recurring_screen.dart';
import 'package:iakauntan/src/data/my_profile_repository.dart';
import 'package:iakauntan/src/features/pos/delivery_setup_screen.dart';
import 'package:iakauntan/src/features/pos/menu_links_screen.dart';
import 'package:iakauntan/src/features/pos/menu_times_screen.dart';
import 'package:iakauntan/src/features/pos/promotions_screen.dart';
import 'package:iakauntan/src/features/pos/recipes_screen.dart';
import 'package:iakauntan/src/features/pos/scales_screen.dart';
import 'package:iakauntan/src/features/pos/stalls_screen.dart';
import 'package:iakauntan/src/features/stock/bundles_screen.dart';
import 'package:iakauntan/src/features/stock/landed_cost_screen.dart';
import 'package:iakauntan/src/features/stock/transfers_screen.dart';
import 'package:iakauntan/src/features/stock/stock_take_screen.dart';
import 'package:iakauntan/src/features/ticketing/teams_screen.dart';
import 'package:iakauntan/src/features/ticketing/ticket_screen.dart';
import 'package:iakauntan/src/features/ticketing/tickets_screen.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';

/// Screens that nothing had ever constructed.
///
/// `scripts/check_screens_built.py` lists thirty-eight of these as a
/// backlog rather than a decision, and says the number should go down.
/// This takes some off it.
///
/// `FilingsScreen` is first for a reason: three actions were added to
/// it in the same stretch that built the tax stack, and nothing
/// anywhere put it on screen. The gate exists because of exactly that,
/// so leaving its own instigator on the exemption list would be
/// leaving the point unmade.
///
/// These are shallow on purpose — one realistic answer per provider,
/// and an assertion that something the screen was given appears. What
/// they catch is the class of fault that makes a screen useless rather
/// than wrong: a throw in `build`, a field nobody set, a layout that
/// cannot lay out.
void main() {
  Widget wrap(Widget screen, List<Override> overrides) {
    final router = GoRouter(
      initialLocation: '/x',
      routes: [
        GoRoute(path: '/x', builder: (_, __) => screen),
        GoRoute(
          path: '/tax-calendar',
          builder: (_, __) => const Scaffold(body: Text('the calendar')),
        ),
        GoRoute(
          path: '/legal/:id',
          builder: (_, __) => const Scaffold(body: Text('one matter')),
        ),
        GoRoute(
          path: '/property/:id',
          builder: (_, __) => const Scaffold(body: Text('one site')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, __) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/hr/payroll/:id',
          builder: (_, __) => const Scaffold(body: Text('one run')),
        ),
        GoRoute(
          path: '/hr/payslip/:id',
          builder: (_, __) => const Scaffold(body: Text('one payslip')),
        ),
        GoRoute(
          path: '/hr/remittances',
          builder: (_, __) => const Scaffold(body: Text('remittances')),
        ),
        GoRoute(
          path: '/hr/ea-forms',
          builder: (_, __) => const Scaffold(body: Text('ea forms')),
        ),
      ],
    );
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> onAPhone(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  group('the financial statements screen', () {
    testWidgets('builds and lists a year', (tester) async {
      await onAPhone(
        tester,
        wrap(const FilingsScreen(), [
          fsFilingsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'f1',
                'status': 'draft',
                'fy_end': '2026-06-30',
                'framework': 'mpers',
                'audit_status': 'audited',
              },
            ],
          ),
          fsDeadlinesDueProvider.overrideWith((ref) async => {}),
          canWriteProvider.overrideWithValue(true),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('Financial statements'), findsOneWidget);
      // The title is BUILT from the date rather than sent as a name,
      // which is the kind of thing only constructing the screen shows.
      expect(find.text('Year ended 30/06/2026'), findsOneWidget);
    });

    testWidgets('and offers the three tax actions to somebody who may post',
        (tester) async {
      // The actions added in the tax stretch. Nothing had ever checked
      // they render, which is what put this screen at the top of the
      // list.
      await onAPhone(
        tester,
        wrap(const FilingsScreen(), [
          fsFilingsProvider.overrideWith((ref) async => []),
          fsDeadlinesDueProvider.overrideWith((ref) async => {}),
          canWriteProvider.overrideWithValue(true),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.byKey(const ValueKey('open-tax-computation')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('open-tax-estimate')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-tax-calendar')), findsOneWidget);
    });

    testWidgets('but the calendar alone to somebody who may not',
        (tester) async {
      // Reading a deadline needs no posting right: the person who most
      // needs to see one is often not the one who keys the return.
      await onAPhone(
        tester,
        wrap(const FilingsScreen(), [
          fsFilingsProvider.overrideWith((ref) async => []),
          fsDeadlinesDueProvider.overrideWith((ref) async => {}),
          canWriteProvider.overrideWithValue(false),
          canPostProvider.overrideWithValue(false),
        ]),
      );
      expect(find.byKey(const ValueKey('open-tax-calendar')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-tax-computation')), findsNothing);
      expect(find.byKey(const ValueKey('open-tax-estimate')), findsNothing);
    });

    testWidgets('an empty list says what to do rather than nothing',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const FilingsScreen(), [
          fsFilingsProvider.overrideWith((ref) async => []),
          fsDeadlinesDueProvider.overrideWith((ref) async => {}),
          canWriteProvider.overrideWithValue(true),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('No accounts prepared yet'), findsOneWidget);
    });
  });

  group('the expenses screen', () {
    testWidgets('builds and lists a claim', (tester) async {
      await onAPhone(
        tester,
        wrap(const ExpensesScreen(), [
          expensesProvider.overrideWith(
            (ref) async => [
              {
                'id': 'e1',
                'expense_no': 'EXP-001',
                'expense_date': '2026-09-01',
                'total_amount': 250.00,
                'status': 'draft',
                'description': 'Parking at the client',
              },
            ],
          ),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.textContaining('Parking at the client'), findsOneWidget);
    });

    /// The expense form, opened on a capture made somewhere else.
    ///
    /// `0686`. A payment voucher photographed into Bills has no
    /// supplier on it — the only company named is the firm's own — so
    /// Bills offers to record it as an expense instead, on the capture
    /// already taken. `showExpenseFromScan` is that door, and nothing
    /// opened it, so nothing knew it built.
    testWidgets('opens on a capture that was made on another screen',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const ExpensesScreen(), [
          expensesProvider.overrideWith((ref) async => []),
          canPostProvider.overrideWithValue(true),
          // The form reads six lists off the company. Each is stubbed
          // empty rather than left to throw OrgNotReady — which is what
          // it does in a test, because no organization was ever
          // resolved.
          accountsProvider.overrideWith((ref) async => <Account>[]),
          bankAccountsProvider.overrideWith((ref) async => []),
          paymentModesProvider.overrideWith((ref) async => []),
          projectsProvider.overrideWith((ref) async => []),
          departmentsProvider.overrideWith((ref) async => []),
          taxCodesProvider.overrideWith((ref) async => []),
        ]),
      );

      final context = tester.element(find.byType(ExpensesScreen));
      // The reading off the voucher: no supplier, but a number, a date
      // and an amount — which is exactly what an expense wants.
      unawaited(showExpenseFromScan(
        context,
        StagedReceipt(
          attachmentId: 'att-1',
          placeholderId: 'ph-1',
          read: OcrExtraction(
            documentNo: '16851',
            documentDate: DateTime(2026, 1, 22),
            totalAmount: 1320.00,
            documentKind: 'payment_voucher',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Built, and carrying what the paper said. A dialog that opened
      // empty would satisfy "it builds" and be useless.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('1320.00'), findsWidgets);
    });
  });

  group('the pipeline board', () {
    testWidgets('builds with a stage and an opportunity', (tester) async {
      await onAPhone(
        tester,
        wrap(const PipelineScreen(), [
          pipelineStagesProvider.overrideWith(
            (ref) async => [
              PipelineStage(
                id: 's1',
                pipelineId: 'p1',
                name: 'Qualifying',
                probability: 30,
                stageType: 'open',
                sortOrder: 1,
              ),
            ],
          ),
          opportunitiesProvider.overrideWith(
            (ref) async => [
              Opportunity(
                id: 'o1',
                opportunityNo: 'OPP-001',
                name: 'Kedai Kopi fit-out',
                stageId: 's1',
                pipelineId: 'p1',
                amount: 45000,
              ),
            ],
          ),
          canWriteProvider.overrideWithValue(true),
        ]),
      );
      expect(find.textContaining('Qualifying'), findsOneWidget);
      expect(find.textContaining('Kedai Kopi'), findsOneWidget);
    });
  });

  group('the recurring journals screen', () {
    testWidgets('builds and lists one', (tester) async {
      await onAPhone(
        tester,
        wrap(const RecurringScreen(), [
          recurringJournalsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'r1',
                'name': 'Monthly rent accrual',
                'frequency': 'monthly',
                'next_run_on': '2026-10-01',
                'is_active': true,
              },
            ],
          ),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.textContaining('Monthly rent accrual'), findsOneWidget);
    });

    testWidgets('and says so when there are none', (tester) async {
      await onAPhone(
        tester,
        wrap(const RecurringScreen(), [
          recurringJournalsProvider.overrideWith((ref) async => []),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.byType(EmptyState), findsOneWidget);
    });
  });

  group('the stock take screen', () {
    testWidgets('builds and lists an adjustment', (tester) async {
      await onAPhone(
        tester,
        wrap(const StockTakeScreen(), [
          stockAdjustmentsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'a1',
                'adjustment_no': 'ADJ-001',
                'adjustment_date': '2026-09-01',
                'reason': 'stock_take',
                'status': 'draft',
              },
            ],
          ),
          // The screen also asks for warehouses and what is on hand.
          // Without them it renders an error rather than the list —
          // which is exactly the sort of thing only constructing it
          // shows, and the reason the fixture names every provider the
          // screen watches rather than only the obvious one.
          //
          // The on-hand list has to have something IN it. An empty one
          // short-circuits to "Nothing to count" and the whole body —
          // count rows, recent counts, all of it — is never built, so
          // a fixture that returns `[]` asserts nothing about the
          // screen it names. Cost half an hour to notice.
          //
          // No warehouses, deliberately: the screen picks the first
          // one into `_warehouseId` without a setState, so a non-empty
          // list leaves the family key the on-hand override is written
          // against depending on how many times the widget happens to
          // rebuild. With none, it stays null and the fixture is the
          // one the screen reads.
          warehousesProvider.overrideWith((ref) async => []),
          stockOnHandProvider(null).overrideWith(
            (ref) async => [
              {
                'item_id': 'i1',
                'code': 'KOPI-01',
                'name': 'Kopi beans 1kg',
                'quantity': 12,
                'average_cost': 38.50,
              },
            ],
          ),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      // The item it was given, and the system figure it derived from
      // the row rather than was handed.
      expect(find.textContaining('Kopi beans 1kg'), findsOneWidget);
      expect(find.textContaining('system 12'), findsOneWidget);
      // The history sits below the count form, so it is off-screen on
      // a phone — `find.text` does not scroll. The key is enough: the
      // list was BUILT, which is what this file is for.
      expect(find.byKey(const ValueKey('stock-adjustment-history')),
          findsOneWidget);
    });

    testWidgets('and says there is nothing to count when there is not',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const StockTakeScreen(), [
          stockAdjustmentsProvider.overrideWith((ref) async => []),
          warehousesProvider.overrideWith((ref) async => []),
          stockOnHandProvider(null).overrideWith((ref) async => []),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('Nothing to count'), findsOneWidget);
      expect(find.byKey(const ValueKey('stock-adjustment-history')),
          findsNothing);
    });
  });

  group('the leads list', () {
    testWidgets('builds and shows a lead under the open filter',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const LeadsScreen(), [
          // The screen opens on 'open' and asks the family for exactly
          // that. Overriding a different key leaves the real provider
          // in place and the test reaches for the network.
          leadsProvider('open').overrideWith(
            (ref) async => [
              {
                'id': 'l1',
                'lead_no': 'LEAD-001',
                'company_name': 'Restoran Seri Malaya',
                'status': 'contacted',
                'source': 'walk-in',
                'estimated_value': 12000,
              },
            ],
          ),
          canWriteProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('Restoran Seri Malaya'), findsOneWidget);
      // Built from the row's parts rather than handed over whole.
      expect(find.textContaining('via walk-in'), findsOneWidget);
    });

    testWidgets('and says what a lead is for when there are none',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const LeadsScreen(), [
          leadsProvider('open').overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(false),
        ]),
      );
      expect(find.text('No leads here'), findsOneWidget);
      // No write right, so no way to add one from the empty state.
      expect(find.text('Add lead'), findsNothing);
    });
  });

  group('the no-access screen', () {
    testWidgets('names the module the address was pointed at',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const NoAccessScreen(), [
          workspaceLookupProvider.overrideWith(
            (ref) async => (
              host: WorkspaceHost.found,
              workspace: <String, dynamic>{
                'module_code': 'pos',
                'landing_path': '/pos',
              },
            ),
          ),
          platformModulesProvider.overrideWith(
            (ref) async => [
              ModuleInfo(
                code: 'pos',
                name: 'Point of sale',
                isCore: false,
                monthlyPrice: 49,
              ),
            ],
          ),
        ]),
      );
      expect(
        find.text('Point of sale is not part of your subscription'),
        findsOneWidget,
      );
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('and falls back to a sentence naming nothing when the '
        'catalogue does not know the code', (tester) async {
      // The fallback the screen's own comment promises: better a vague
      // sentence than `property_strata` printed at a shopkeeper.
      await onAPhone(
        tester,
        wrap(const NoAccessScreen(), [
          workspaceLookupProvider.overrideWith(
            (ref) async => (
              host: WorkspaceHost.found,
              workspace: <String, dynamic>{
                'module_code': 'property_strata',
                'landing_path': '/property',
              },
            ),
          ),
          platformModulesProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('This address is not open to you'), findsOneWidget);
      expect(find.textContaining('property_strata'), findsNothing);
    });
  });

  group('the service desk', () {
    testWidgets('builds, and its filter bar draws at all', (tester) async {
      // Written expecting to catch the same fault as the leads bar,
      // and it did not: this screen's inner scroll view was a
      // `SingleChildScrollView`, which sizes to its child instead of
      // expanding, so the bar drew and dragged perfectly well. The
      // test passed against the unfixed version, which is how the
      // claim got checked rather than believed. Kept anyway -- the
      // screen still had nothing building it.
      await onAPhone(
        tester,
        wrap(const TicketsScreen(), [
          ticketsProvider(const TicketQuery()).overrideWith(
            (ref) async => [
              {
                'id': 't1',
                'ticket_no': 'TKT-001',
                'subject': 'Printer will not print the receipt',
                'status': 'open',
                'priority': 'p1',
                'team_id': 'team-1',
                'category_id': 'cat-1',
                'response_breached': false,
                'resolution_breached': true,
              },
            ],
          ),
          ticketTeamsProvider.overrideWith(
            (ref) async => [
              {'id': 'team-1', 'name': 'Front counter'},
            ],
          ),
          ticketCategoriesProvider.overrideWith(
            (ref) async => [
              {'id': 'cat-1', 'name': 'Hardware'},
            ],
          ),
        ]),
      );
      // 'Resolved' and 'Breached', not 'Open': the row's own status
      // chip reads "Open" too, so that one would pass whether the bar
      // drew or not.
      expect(find.text('Resolved'), findsOneWidget);
      expect(find.text('Breached'), findsOneWidget);
      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('Printer will not print the receipt'), findsOneWidget);
      // The id on the row resolved through two other providers, which
      // is the screen doing work rather than printing what it was
      // handed.
      expect(find.textContaining('Hardware · Front counter'), findsOneWidget);
      // A breached ticket says so instead of showing a due time.
      expect(find.text('SLA breached'), findsOneWidget);
    });

    testWidgets('and an empty queue blames the filters, not the desk',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const TicketsScreen(), [
          ticketsProvider(const TicketQuery()).overrideWith((ref) async => []),
          ticketTeamsProvider.overrideWith((ref) async => []),
          ticketCategoriesProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Nothing in this queue'), findsOneWidget);
    });
  });

  group('the support teams screen', () {
    testWidgets('builds and summarises a roster', (tester) async {
      await onAPhone(
        tester,
        wrap(const TicketTeamsScreen(), [
          ticketTeamsAllProvider.overrideWith(
            (ref) async => [
              {'id': 'team-1', 'name': 'Front counter', 'is_active': true},
              {'id': 'team-2', 'name': 'Night shift', 'is_active': false},
            ],
          ),
          ticketTeamRosterProvider('team-1').overrideWith(
            (ref) async => [
              {'user_id': 'u1', 'full_name': 'Siti', 'is_lead': true},
              {'user_id': 'u2', 'full_name': 'Ravi', 'is_lead': false},
            ],
          ),
          ticketTeamRosterProvider('team-2').overrideWith((ref) async => []),
          canAdminProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('Front counter'), findsOneWidget);
      // Counted and phrased by the screen, not sent as a sentence.
      expect(find.text('2 people, led by Siti'), findsOneWidget);
      // A retired team is still listed, and says which it is.
      expect(find.text('Night shift'), findsOneWidget);
      expect(
        find.text('Anybody can be given these — nobody is on it'),
        findsOneWidget,
      );
    });

    testWidgets('and offers no way to add one to somebody who may not',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const TicketTeamsScreen(), [
          ticketTeamsAllProvider.overrideWith((ref) async => []),
          canAdminProvider.overrideWithValue(false),
        ]),
      );
      expect(find.text('No teams yet'), findsOneWidget);
      expect(find.text('Add a team'), findsNothing);
    });
  });

  group('the matters list', () {
    testWidgets('builds, and adds up the client account itself',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const MattersScreen(), [
          mattersProvider((status: 'open', search: '')).overrideWith(
            (ref) async => [
              Matter(
                id: 'm1',
                matterNo: 'MAT-001',
                name: 'Sale of shophouse',
                clientId: 'c1',
                clientName: 'Tan Sri Lim',
                status: 'open',
              ),
              Matter(
                id: 'm2',
                matterNo: 'MAT-002',
                name: 'Tenancy dispute',
                clientId: 'c2',
                clientName: 'Kedai Runcit Aman',
                status: 'open',
              ),
            ],
          ),
          matterSummaryProvider.overrideWith(
            (ref) async => [
              MatterSummary(
                matterId: 'm1',
                matterNo: 'MAT-001',
                matterName: 'Sale of shophouse',
                clientName: 'Tan Sri Lim',
                status: 'open',
                clientFunds: 15000,
                unbilledTime: 2400,
                unbilledDisbursements: 100,
                billed: 0,
                outstanding: 0,
              ),
              MatterSummary(
                matterId: 'm2',
                matterNo: 'MAT-002',
                matterName: 'Tenancy dispute',
                clientName: 'Kedai Runcit Aman',
                status: 'open',
                clientFunds: 3500,
                unbilledTime: 0,
                unbilledDisbursements: 0,
                billed: 0,
                outstanding: 0,
              ),
            ],
          ),
          canWriteProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('MAT-001'), findsOneWidget);
      // The banner is a sum over a SECOND provider, joined to the list
      // by id. Nothing hands the screen this number.
      expect(
        find.textContaining('2 matters · RM 18,500.00 held'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('matters-over-fee')), findsOneWidget);
    });

    testWidgets('and a matter with no unbilled time says client funds',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const MattersScreen(), [
          mattersProvider((status: 'open', search: '')).overrideWith(
            (ref) async => [
              Matter(
                id: 'm1',
                matterNo: 'MAT-001',
                name: 'Sale of shophouse',
                clientId: 'c1',
                status: 'open',
              ),
            ],
          ),
          matterSummaryProvider.overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(false),
        ]),
      );
      // No summary at all for this matter, which is the state a file
      // opened five minutes ago is in.
      expect(find.text('client funds'), findsOneWidget);
      expect(find.text('New matter'), findsNothing);
    });
  });

  group('the budgets screen', () {
    testWidgets('builds and phrases what is in each budget', (tester) async {
      await onAPhone(
        tester,
        wrap(const BudgetsScreen(), [
          budgetsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'b1',
                'name': 'FY2027 plan',
                'status': 'draft',
                'year_name': 'FY2027',
                'department_code': 'KL',
                'lines': 24,
              },
              {
                'id': 'b2',
                'name': 'FY2026 plan',
                'status': 'approved',
                'year_name': 'FY2026',
                'lines': 0,
              },
            ],
          ),
        ]),
      );
      expect(find.text('FY2027 plan'), findsOneWidget);
      // Pluralised and joined by the screen from three columns.
      expect(find.text('FY2027 · KL · 24 lines'), findsOneWidget);
      // And the empty one says so rather than printing a zero.
      expect(find.text('FY2026 · nothing in it yet'), findsOneWidget);
    });

    testWidgets('and an empty list argues for the third column',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const BudgetsScreen(), [
          budgetsProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('No budget yet'), findsOneWidget);
    });
  });

  group('the contra screen', () {
    testWidgets('builds and says what was offset against what',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const ContraScreen(), [
          contraNotesProvider(null).overrideWith(
            (ref) async => [
              {
                'id': 'c1',
                'contra_no': 'CTR-001',
                'status': 'posted',
                'party': 'Syarikat Maju Jaya',
                'amount': 4200,
                'invoices': 2,
                'bills': 1,
              },
            ],
          ),
        ]),
      );
      expect(find.text('CTR-001'), findsOneWidget);
      // Both counts pluralised independently, which is the one thing a
      // summary like this gets wrong.
      expect(
        find.text(
          'Syarikat Maju Jaya · RM 4,200.00 · 2 invoices against 1 bill',
        ),
        findsOneWidget,
      );
    });

    testWidgets('and an empty list explains what a contra is for',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const ContraScreen(), [
          contraNotesProvider(null).overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Nothing offset'), findsOneWidget);
    });
  });

  group('the bundles screen', () {
    testWidgets('builds and prices a bundle against its parts',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const BundlesScreen(), [
          itemBundlesProvider.overrideWith(
            (ref) async => [
              {
                'item_id': 'i1',
                'code': 'GIFT-01',
                'name': 'Raya hamper',
                'parts': 6,
                'price': 120,
                'cost': 74.5,
              },
              {
                'item_id': 'i2',
                'code': 'GIFT-02',
                'name': 'Single tin',
                'parts': 1,
                'price': 25,
                'cost': 18,
              },
            ],
          ),
        ]),
      );
      expect(find.text('GIFT-01 Raya hamper'), findsOneWidget);
      expect(
        find.text('6 parts · RM 120.00 for RM 74.50 of stock'),
        findsOneWidget,
      );
      // One part, singular -- the off-by-one every pluraliser has.
      expect(
        find.text('1 part · RM 25.00 for RM 18.00 of stock'),
        findsOneWidget,
      );
    });

    testWidgets('and an empty list says what a bundle is', (tester) async {
      await onAPhone(
        tester,
        wrap(const BundlesScreen(), [
          itemBundlesProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('No bundles'), findsOneWidget);
    });
  });

  group('the post-dated cheque register', () {
    testWidgets('builds, and the strip above it warns about a late one',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const ChequesScreen(), [
          postDatedChequesProvider((direction: null, status: null))
              .overrideWith(
            (ref) async => [
              {
                'id': 'p1',
                'pdc_no': 'PDC-001',
                'direction': 'incoming',
                'status': 'held',
                'party': 'Kedai Kek Ros',
                'cheque_no': '445512',
                'bank_name': 'Maybank',
                'cheque_date': '2026-09-01',
                'days_to_go': -20,
                'amount': 1800,
              },
            ],
          ),
          pdcMaturingProvider.overrideWith(
            (ref) async => [
              {
                'id': 'p1',
                'direction': 'incoming',
                'amount': 1800,
                'overdue': true,
                'cheque_date': '2026-09-01',
              },
            ],
          ),
        ]),
      );
      // The banner: counted, pluralised with its verb, and totalled by
      // direction, all by the screen.
      expect(
        find.text(
          'One cheque is past its date and not cleared. '
          'RM 1,800.00 to bank.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('PDC-001 · We were given it'),
        findsOneWidget,
      );
      // Negative days become words, not "in -20 days".
      expect(
        find.textContaining('Was due 20 days ago — not banked'),
        findsOneWidget,
      );
    });

    testWidgets('and the strip stays away when nothing is maturing',
        (tester) async {
      // Silent while it loads and silent when there is nothing: the
      // register below carries its own message.
      await onAPhone(
        tester,
        wrap(const ChequesScreen(), [
          postDatedChequesProvider((direction: null, status: null))
              .overrideWith((ref) async => []),
          pdcMaturingProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.byKey(const ValueKey('pdc-to-bank')), findsNothing);
      expect(find.text('No cheques on hand'), findsOneWidget);
    });
  });

  group('the deposits screen', () {
    testWidgets('builds, and a part-used deposit says what is left',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const DepositsScreen(), [
          depositNotesProvider((kind: null, status: null)).overrideWith(
            (ref) async => [
              {
                'id': 'd1',
                'deposit_no': 'DEP-001',
                'kind': 'customer',
                'status': 'open',
                'party': 'Puan Aminah',
                'amount': 5000,
                'balance': 2000,
                'applied': 3000,
                'refunded': 0,
                'forfeited': 0,
              },
              {
                'id': 'd2',
                'deposit_no': 'DEP-002',
                'kind': 'supplier',
                'status': 'open',
                'party': 'Pembekal Bahan',
                'amount': 800,
                'balance': 800,
              },
            ],
          ),
        ]),
      );
      expect(find.text('DEP-001 · Held for a customer'), findsOneWidget);
      expect(find.text('DEP-002 · Paid to a supplier'), findsOneWidget);
      expect(
        find.text('Puan Aminah · RM 5,000.00 · RM 2,000.00 left'),
        findsOneWidget,
      );
      // The sentence somebody looks for a year later.
      expect(find.text('RM 3,000.00 against documents'), findsOneWidget);
      // An untouched one says so instead of "RM 800.00 left".
      expect(
        find.text('Pembekal Bahan · RM 800.00 · untouched'),
        findsOneWidget,
      );
    });

    testWidgets('and an empty list argues for the balance sheet',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const DepositsScreen(), [
          depositNotesProvider((kind: null, status: null))
              .overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Nothing on deposit'), findsOneWidget);
    });
  });

  group('the promotions screen', () {
    testWidgets('builds, and says what each rule actually does',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const PromotionsScreen(), [
          enabledModulesProvider.overrideWith((ref) async => {'pos'}),
          myModuleAccessProvider.overrideWith((ref) async => {'pos': 'write'}),
          posPromotionsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'pr1',
                'name': 'Morning teh',
                'kind': 'buy_x_get_y',
                'buy_quantity': 2,
                'get_quantity': 1,
                'percent': 100,
                'is_active': true,
                'times_used': 1,
                'weekdays': [1, 2, 3, 4, 5],
                'starts_at': '07:00:00',
                'ends_at': '11:00:00',
              },
              {
                'id': 'pr2',
                'name': 'Half-price Tuesday',
                'kind': 'buy_x_get_y',
                'buy_quantity': 1,
                'get_quantity': 1,
                'percent': 50,
                'is_active': false,
                'times_used': 12,
              },
            ],
          ),
        ]),
      );
      // "Three for two" is what a shop SAYS; buy 2 get 1 free is what
      // it means, and the screen says the second.
      expect(
        find.textContaining('Buy 2, get 1 free'),
        findsOneWidget,
      );
      // Under a hundred per cent it is not free, and the sentence has
      // to change. This is the branch a wrong answer ships in.
      expect(
        find.textContaining('Buy 1, get 1 at 50% off'),
        findsOneWidget,
      );
      // Weekday numbers into names, and a Postgres time truncated to
      // the minute -- nobody writes a happy hour to the second.
      expect(
        find.textContaining('Mon Tue Wed Thu Fri · 07:00–11:00'),
        findsOneWidget,
      );
      // Singular and plural of the same count, on two rows.
      expect(find.textContaining('1 bill ·'), findsNothing);
      expect(find.textContaining('· 1 bill'), findsOneWidget);
      expect(find.textContaining('12 bills'), findsOneWidget);
      expect(find.textContaining('retired'), findsOneWidget);
    });

    testWidgets('and says so plainly when the company has no till',
        (tester) async {
      // Entitlement, not permission: the module was never bought.
      await onAPhone(
        tester,
        wrap(const PromotionsScreen(), [
          enabledModulesProvider.overrideWith((ref) async => {'accounting'}),
          myModuleAccessProvider.overrideWith((ref) async => const {}),
        ]),
      );
      expect(find.text('The till is not switched on'), findsOneWidget);
      // And no button to make one, which would be a dead end.
      expect(find.text('New promotion'), findsNothing);
    });
  });

  group('the published menus screen', () {
    testWidgets('builds, and says which of the three ways a link is dead',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const MenuLinksScreen(), [
          posMenuLinksProvider.overrideWith(
            (ref) async => [
              {
                'id': 'l1',
                'kind': 'table',
                'table_code': '12',
                'label': 'By the window',
                'token': 'abc123',
                'outlet_name': 'Jalan Ipoh',
                'orders': 4,
                'is_active': true,
              },
              {
                'id': 'l2',
                'kind': 'takeaway',
                'token': 'def456',
                'outlet_name': 'Jalan Ipoh',
                'orders': 0,
                'is_active': false,
              },
              {
                'id': 'l3',
                'kind': 'delivery',
                'token': 'ghi789',
                'outlet_name': 'Jalan Ipoh',
                'orders': 0,
                'is_active': true,
                'single_use': true,
                'used_at': '2026-09-01T10:00:00Z',
              },
            ],
          ),
        ]),
      );
      expect(find.text('Table 12 · By the window'), findsOneWidget);
      expect(find.text('Takeaway'), findsOneWidget);
      // A sticker that quietly stopped working is found by a customer
      // holding a phone, so the list names the reason.
      expect(find.textContaining('Switched off'), findsOneWidget);
      expect(find.textContaining('Used'), findsOneWidget);
      // The URL is assembled here, token-encoded, not sent by the
      // server.
      expect(find.textContaining('/#/menu/abc123'), findsOneWidget);
    });

    testWidgets('and an empty list says what publishing one is for',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const MenuLinksScreen(), [
          posMenuLinksProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Nothing published'), findsOneWidget);
    });
  });

  group('the menu times screen', () {
    testWidgets('builds, and says which schedule is on right now',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const MenuTimesScreen(), [
          enabledModulesProvider.overrideWith((ref) async => {'pos'}),
          myModuleAccessProvider.overrideWith((ref) async => {'pos': 'write'}),
          posMenuSchedulesProvider.overrideWith(
            (ref) async => [
              {
                'id': 's1',
                'name': 'Breakfast',
                'is_active': true,
                'open_now': true,
                'dishes': 9,
                'weekdays': [1, 2, 3, 4, 5],
                'starts_at': '07:00:00',
                'ends_at': '11:00:00',
              },
              {
                'id': 's2',
                'name': 'Weekend special',
                'is_active': true,
                'open_now': false,
                // A schedule governing nothing: saved without its
                // dishes, quietly doing nothing. The row is meant to
                // show that rather than look normal.
                'dishes': 0,
              },
            ],
          ),
        ]),
      );
      // The question somebody opens this screen to answer, said on the
      // row rather than worked out from two times and a clock.
      expect(find.text('on now'), findsOneWidget);
      expect(
        find.text('Mon Tue Wed Thu Fri · 07:00–11:00 · 9 dishes'),
        findsOneWidget,
      );
      // No days and no times means always, said in words, and one dish
      // would be singular.
      expect(find.text('all day, every day · 0 dishes'), findsOneWidget);
    });

    testWidgets('and says so plainly when the company has no till',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const MenuTimesScreen(), [
          enabledModulesProvider.overrideWith((ref) async => {'accounting'}),
          myModuleAccessProvider.overrideWith((ref) async => const {}),
        ]),
      );
      expect(find.text('The till is not switched on'), findsOneWidget);
    });
  });

  group('the property screen', () {
    testWidgets('builds, and counts the quit rent across the portfolio',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const PropertyScreen(), [
          enabledModulesProvider
              .overrideWith((ref) async => {'property_strata'}),
          myModuleAccessProvider
              .overrideWith((ref) async => {'property_strata': 'write'}),
          // Holding the strata module alone narrows the list to strata
          // WITHOUT the filter being shown, so the family key is
          // 'strata' rather than null. Override the wrong one and the
          // real provider is left in place.
          propertySitesProvider('strata').overrideWith(
            (ref) async => [
              {
                'id': 'p1',
                'code': 'SRI-01',
                'name': 'Sri Puteri Condominium',
                'tenure': 'strata',
                'city': 'Kajang',
                'property_units': [
                  {'count': 240},
                ],
              },
            ],
          ),
          propertyStatutoryDueProvider.overrideWith(
            (ref) async => [
              {'id': 'b1', 'amount': 1200, 'is_overdue': true},
              {'id': 'b2', 'amount': 800, 'is_overdue': false},
            ],
          ),
        ]),
      );
      // A bill is missed by not opening the site it belongs to, so the
      // banner counts across every site and never asks anyone to.
      expect(
        find.textContaining(
          '1 quit rent or assessment bill(s) overdue, 2 outstanding, '
          'RM 2,000.00 in all.',
        ),
        findsOneWidget,
      );
      // PostgREST returns an aggregate embed as a ONE-ELEMENT LIST,
      // which is the shape this tile has to unwrap.
      expect(
        find.text('SRI-01 · Strata · 240 units · Kajang'),
        findsOneWidget,
      );
      // One module held, so nothing to choose between and no filter.
      expect(find.text('Non-strata'), findsNothing);
    });

    testWidgets('and the filter appears only when both are held',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const PropertyScreen(), [
          enabledModulesProvider.overrideWith(
            (ref) async => {'property_strata', 'property_nonstrata'},
          ),
          myModuleAccessProvider.overrideWith(
            (ref) async => {
              'property_strata': 'write',
              'property_nonstrata': 'write',
            },
          ),
          propertySitesProvider(null).overrideWith((ref) async => []),
          propertyStatutoryDueProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Non-strata'), findsOneWidget);
      expect(find.text('No properties yet'), findsOneWidget);
      // Nothing outstanding, so no banner rather than a banner saying
      // zero.
      expect(find.textContaining('quit rent'), findsNothing);
    });
  });

  group('the landed cost screen', () {
    testWidgets('builds, and a posted run says how much reached the stock',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const LandedCostScreen(), [
          landedCostRunsProvider(null).overrideWith(
            (ref) async => [
              {
                'id': 'r1',
                'run_no': 'LC-001',
                'status': 'posted',
                'bills': 3,
                'total': 4500,
                'capitalised': 4500,
              },
              {
                'id': 'r2',
                'run_no': 'LC-002',
                'status': 'posted',
                'bills': 1,
                'total': 900,
                // Some of it could not reach the stock -- the goods
                // were already sold -- so the figure is named rather
                // than implied.
                'capitalised': 640,
              },
              {
                'id': 'r3',
                'run_no': 'LC-003',
                'status': 'draft',
                'bills': 2,
                'total': 1500,
                'capitalised': 0,
              },
            ],
          ),
        ]),
      );
      expect(find.text('3 bills · RM 4,500.00 · all of it onto stock'),
          findsOneWidget);
      expect(find.text('1 bill · RM 900.00 · RM 640.00 onto stock'),
          findsOneWidget);
      // A draft has capitalised nothing yet, so the sentence stops --
      // saying "RM 0.00 onto stock" about a run nobody has posted
      // would read as a failure.
      expect(find.text('2 bills · RM 1,500.00'), findsOneWidget);
    });

    testWidgets('and an empty list says what landed cost is for',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const LandedCostScreen(), [
          landedCostRunsProvider(null).overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Nothing landed yet'), findsOneWidget);
    });
  });

  group('the knock-off screen', () {
    testWidgets('builds, and asks for a customer before anything else',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const KnockOffScreen(), [
          contactsProvider((type: 'customer', search: '')).overrideWith(
            (ref) async => [
              Contact(
                id: 'c1',
                code: 'CUST-001',
                name: 'Kedai Runcit Aman',
                contactType: 'customer',
              ),
            ],
          ),
          canPostProvider.overrideWithValue(true),
        ]),
      );
      expect(find.byKey(const ValueKey('knock-off-contact')), findsOneWidget);
      // Nothing is read until somebody is chosen, and the screen says
      // that rather than showing an empty account.
      expect(
        find.text('Pick a customer to see their account.'),
        findsOneWidget,
      );
    });
  });

  group('the people and bodies corporate screen', () {
    testWidgets('builds, and puts the two AMLA facts on the row',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const CorpPeopleScreen(), [
          corpPersonsProvider.overrideWith(
            (ref) async => [
              CorpPerson(
                id: 'p1',
                kind: 'individual',
                fullName: 'Dato Sri Azman bin Hassan',
                nric: '650412-10-5533',
                // A politically exposed person carries enhanced due
                // diligence for as long as they are on the file, so it
                // belongs on the row rather than two clicks inside it.
                isPep: true,
                idVerifiedOn: DateTime(2026, 3, 14),
              ),
              CorpPerson(
                id: 'p2',
                kind: 'corporate',
                fullName: 'Amanah Holdings Sdn Bhd',
                registrationNo: '202101001234',
              ),
              CorpPerson(
                id: 'p3',
                kind: 'individual',
                fullName: 'Nurul Huda',
              ),
            ],
          ),
          canWriteProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('PEP'), findsOneWidget);
      // `identifier` picks a different column depending on what the
      // person IS: the registration number for a body corporate, the
      // NRIC or passport for a human.
      expect(find.text('650412-10-5533'), findsOneWidget);
      expect(find.text('202101001234'), findsOneWidget);
      // And says so rather than leaving a blank line, which is how a
      // person with nothing on file looks complete.
      expect(find.text('no identifier on file'), findsOneWidget);
      // The question an AMLA inspection asks first: has a document
      // actually been sighted. Two of the three, so two warnings.
      expect(
        find.byTooltip('No identity document sighted'),
        findsNWidgets(2),
      );
      expect(
        find.byTooltip('Identity verified 14/03/2026'),
        findsOneWidget,
      );
    });

    testWidgets('and offers no Add to somebody who may not write',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const CorpPeopleScreen(), [
          corpPersonsProvider.overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(false),
        ]),
      );
      expect(find.text('Nobody on file'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-person')), findsNothing);
    });
  });

  group('the profile screen', () {
    testWidgets('builds, and Save is dead until something changes',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const ProfileScreen(), [
          myProfileProvider.overrideWith(
            (ref) async => {
              'full_name': 'Nurul Huda binti Rahman',
              'salutation': 'Puan',
              'phone': '012-3456789',
            },
          ),
          // A plain Provider reading the Supabase client. Null is a
          // real state -- the screen has a fallback for it -- and it
          // keeps the client out of the test.
          currentUserProvider.overrideWithValue(null),
          memberRoleProvider.overrideWith((ref) async => 'account_manager'),
        ]),
      );
      expect(find.text('Nurul Huda binti Rahman'), findsOneWidget);
      // A form whose Save is always live teaches people to press it
      // and hope, so it starts disabled.
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('profile-save')),
      );
      expect(save.onPressed, isNull);

      await tester.enterText(
        find.byKey(const ValueKey('profile-full-name')),
        'Nurul Huda Rahman',
      );
      await tester.pumpAndSettle();
      final after = tester.widget<FilledButton>(
        find.byKey(const ValueKey('profile-save')),
      );
      expect(after.onPressed, isNotNull);
    });

    testWidgets('and the address is shown, not edited', (tester) async {
      // `profiles.email` is a COPY of the auth address and 0649
      // refuses to write it: changing it here would move what the row
      // says and leave the address that actually signs you in exactly
      // as it was.
      await onAPhone(
        tester,
        wrap(const ProfileScreen(), [
          myProfileProvider.overrideWith((ref) async => {'full_name': 'A'}),
          currentUserProvider.overrideWithValue(null),
          memberRoleProvider.overrideWith((ref) async => 'account_manager'),
        ]),
      );
      expect(find.text('Signed in as'), findsOneWidget);
      // No user, so the em dash rather than a blank -- and there is no
      // box to type an address into.
      expect(find.text('—'), findsOneWidget);
      // The role is a column value turned into words by the screen.
      expect(find.text('Account Manager'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-to-settings')),
        findsOneWidget,
      );
    });
  });

  group('the transfers screen', () {
    testWidgets('builds both tabs, and only mentions a shortfall when '
        'there is one', (tester) async {
      await onAPhone(
        tester,
        wrap(const TransfersScreen(), [
          stockTransfersProvider(null).overrideWith(
            (ref) async => [
              {
                'id': 't1',
                'transfer_no': 'TRF-001',
                'status': 'sent',
                'from_warehouse': 'Jalan Ipoh',
                'to_warehouse': 'Kajang',
                'line_count': 4,
                'value': 3200,
                'shortfall': 150,
              },
              {
                'id': 't2',
                'transfer_no': 'TRF-002',
                'status': 'received',
                'from_warehouse': 'Kajang',
                'to_warehouse': 'Jalan Ipoh',
                'line_count': 1,
                'value': 90,
                'shortfall': 0,
              },
            ],
          ),
          itemConversionsProvider.overrideWith((ref) async => []),
        ]),
      );
      // The state machine said in words rather than as a column value.
      expect(find.text('On its way'), findsOneWidget);
      expect(find.text('Arrived'), findsOneWidget);
      expect(
        find.text('Jalan Ipoh → Kajang · 4 lines · RM 3,200.00 · '
            'short by RM 150.00'),
        findsOneWidget,
      );
      // Every arrived transfer saying "short by RM 0.00" is noise that
      // trains people to stop reading the line that matters.
      expect(find.text('Kajang → Jalan Ipoh · 1 line · RM 90.00'),
          findsOneWidget);
      // Neither is a draft, so nothing here can be called off.
      expect(find.byKey(const ValueKey('cancel-transfer')), findsNothing);
    });

    testWidgets('and the conversions tab is its own list', (tester) async {
      await onAPhone(
        tester,
        wrap(const TransfersScreen(), [
          stockTransfersProvider(null).overrideWith((ref) async => []),
          itemConversionsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'c1',
                'name': 'Whole chicken into pieces',
                'from_quantity': 1,
                'from_uom_code': 'ea',
                'from_item': 'Ayam sejuk beku',
                'output_count': 4,
                'on_hand': 18,
                'is_active': true,
              },
            ],
          ),
        ]),
      );
      expect(find.text('Nothing has moved between stores'), findsOneWidget);
      // A TabBarView keeps the second page off screen until it is
      // asked for, so the tap is the test.
      await tester.tap(find.text('Conversions'));
      await tester.pumpAndSettle();
      expect(find.text('Whole chicken into pieces'), findsOneWidget);
      expect(
        find.textContaining('1 ea Ayam sejuk beku → 4 things · 18 on hand'),
        findsOneWidget,
      );
    });
  });

  group('the onboarding screen', () {
    testWidgets('builds, and counts the tasks off the embed', (tester) async {
      await onAPhone(
        tester,
        wrap(const OnboardingScreen(), [
          // Opens on 'in progress', so `true` is the family key.
          onboardingChecklistsProvider(true).overrideWith(
            (ref) async => [
              {
                'id': 'ch1',
                'kind': 'onboarding',
                'start_date': '2026-10-01',
                'employees': {
                  'full_name': 'Lim Wei Ling',
                  'employee_no': 'EMP-014',
                },
                'onboarding_tasks': [
                  {'id': 'a', 'is_done': true},
                  {'id': 'b', 'is_done': true},
                  {'id': 'c', 'is_done': false},
                ],
              },
              {
                'id': 'ch2',
                'kind': 'offboarding',
                'completed_at': '2026-09-15T00:00:00Z',
                'employees': {'full_name': 'Ahmad Faiz'},
                'onboarding_tasks': [
                  {'id': 'd', 'is_done': true},
                ],
              },
            ],
          ),
          // The HR roles, through the role provider the gate reads.
          memberRoleProvider.overrideWith((ref) async => 'hr_manager'),
        ]),
      );
      expect(find.text('Lim Wei Ling'), findsOneWidget);
      // Counted off a PostgREST embed and joined with a start date the
      // screen parses and reformats.
      expect(
        find.text('EMP-014 · from 01/10/2026 · 2 of 3 done'),
        findsOneWidget,
      );
      // No employee number and no start date, so the line is just the
      // count rather than two empty separators.
      expect(find.text('1 of 1 done'), findsOneWidget);
      expect(find.text('Start a checklist'), findsOneWidget);
    });

    testWidgets('and somebody without an HR role cannot start one',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const OnboardingScreen(), [
          onboardingChecklistsProvider(true).overrideWith((ref) async => []),
          memberRoleProvider.overrideWith((ref) async => 'viewer'),
        ]),
      );
      expect(find.text('Nothing in progress'), findsOneWidget);
      expect(find.text('Start a checklist'), findsNothing);
    });
  });

  group('the recipes screen', () {
    testWidgets('builds, and the countdown says the three things it can',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const RecipesScreen(), [
          posRecipesProvider.overrideWith(
            (ref) async => [
              {
                'id': 'r1',
                'item_id': 'i1',
                'item_name': 'Nasi lemak ayam',
                'line_count': 6,
                'cost_per_unit': 4.25,
              },
              {
                'id': 'r2',
                'item_id': 'i2',
                'item_name': 'Teh tarik',
                'line_count': 1,
                'cost_per_unit': 0.85,
              },
              {
                'id': 'r3',
                'item_id': 'i3',
                'item_name': 'Roti canai',
                'line_count': 3,
                'cost_per_unit': 0.60,
              },
            ],
          ),
          posOutletsProvider.overrideWith(
            (ref) async => [
              {'id': 'o1', 'name': 'Jalan Ipoh'},
            ],
          ),
          // The countdown is a question about ONE kitchen's shelves,
          // so it is keyed on the outlet the screen picks: the first
          // one, since nothing has been chosen.
          posItemAvailabilityProvider('o1').overrideWith(
            (ref) async => [
              {'item_id': 'i1', 'portions': 4, 'available': true},
              {
                'item_id': 'i2',
                'portions': 0,
                'available': false,
                'limiting_item_name': 'Susu pekat',
              },
              // No portions at all: nothing counted limits this dish.
              // Saying "unlimited" would be a promise nobody made, so
              // the chip is absent rather than reassuring.
              {'item_id': 'i3', 'portions': null, 'available': true},
            ],
          ),
        ]),
      );
      expect(find.text('6 ingredients · costs RM 4.25'), findsOneWidget);
      expect(find.text('1 ingredient · costs RM 0.85'), findsOneWidget);
      expect(find.text('4 left'), findsOneWidget);
      // Out, and WHAT of -- a kitchen can act on the second.
      expect(find.text('Out of susu pekat'), findsOneWidget);
      // The "why" button appears exactly where there is a number to
      // explain. It was described in the repository as the list that
      // explains why the countdown says four, and nothing called it.
      expect(find.byKey(const ValueKey('why-i1')), findsOneWidget);
      expect(find.byKey(const ValueKey('why-i3')), findsNothing);
    });

    testWidgets('and an empty list says what a recipe buys you',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const RecipesScreen(), [
          posRecipesProvider.overrideWith((ref) async => []),
          posOutletsProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('No recipes yet'), findsOneWidget);
    });
  });

  group('the cash flow screen', () {
    testWidgets('builds, and the banner is the one thing it cannot miss',
        (tester) async {
      // Twelve weeks out. The banner turns days into weeks and says
      // the date, which is the sentence somebody reads first.
      final runsOut = DateTime.now().add(const Duration(days: 84));
      await onAPhone(
        tester,
        wrap(const CashFlowScreen(), [
          // Opens on thirteen weeks with history on, so that is the
          // family key -- the record is compared by value.
          cashForecastProvider((weeks: 13, useHistory: true)).overrideWith(
            (ref) async => [
              {
                'week_no': 1,
                'week_start': '2026-09-21',
                'week_end': '2026-09-27',
                'money_in': 12000,
                'money_out': 8000,
                'closing': 4000,
                'overdrawn': false,
              },
              {
                'week_no': 2,
                'week_start': '2026-09-28',
                'week_end': '2026-10-04',
                'money_in': 1000,
                'money_out': 9000,
                'closing': -4000,
                'overdrawn': true,
              },
            ],
          ),
          cashRunsOutProvider(13).overrideWith((ref) async => runsOut),
        ]),
      );
      expect(
        find.textContaining('The bank runs short in 12 weeks'),
        findsOneWidget,
      );
      // The label is built from a week number and a parsed date.
      expect(find.text('Week 1 · 21/09/2026'), findsOneWidget);
      expect(find.text('in RM 12,000.00 · out RM 8,000.00'), findsOneWidget);
      // The button that shows the figures behind the toggle -- the
      // tooltip had been claiming the forecast uses how late each
      // customer actually pays, with no way to see or dispute one.
      expect(find.byKey(const ValueKey('payment-lags')), findsOneWidget);
    });

    testWidgets('and says so plainly when it never runs short',
        (tester) async {
      // `overdrawn` is the SERVER's answer and is read as one.
      // Recomputing it here from the figures on the row would be a
      // second opinion that could disagree with the first.
      await onAPhone(
        tester,
        wrap(const CashFlowScreen(), [
          cashForecastProvider((weeks: 13, useHistory: true)).overrideWith(
            (ref) async => [
              {
                'week_no': 1,
                'week_start': '2026-09-21',
                'week_end': '2026-09-27',
                'money_in': 5000,
                'money_out': 1000,
                'closing': 4000,
                'overdrawn': false,
              },
            ],
          ),
          cashRunsOutProvider(13).overrideWith((ref) async => null),
        ]),
      );
      expect(
        find.text('The bank stays in credit the whole way'),
        findsOneWidget,
      );
    });
  });

  group('the email screen', () {
    testWidgets('builds its settings tab, off until somebody turns it on',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const EmailScreen(), [
          emailSettingsProvider.overrideWith(
            (ref) async => {
              'is_enabled': false,
              'from_name': 'Kedai Kek Ros',
              'reply_to': 'hello@kedaikekros.my',
              'reminder_min_amount': 50,
              'reminder_days': [7, 14, 30],
              'sales_digest_to': '',
            },
          ),
          emailOutboxProvider('all').overrideWith((ref) async => []),
          canAdminProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('Sending'), findsOneWidget);
      expect(find.text('Kedai Kek Ros'), findsOneWidget);
      // A postgres array joined into the box somebody types into.
      expect(find.text('7, 14, 30'), findsOneWidget);
    });

    testWidgets('and the outbox says why a message failed', (tester) async {
      await onAPhone(
        tester,
        wrap(const EmailScreen(), [
          emailSettingsProvider.overrideWith((ref) async => null),
          emailOutboxProvider('all').overrideWith(
            (ref) async => [
              {
                'id': 'm1',
                'status': 'failed',
                'subject': 'Invoice INV-0042',
                'to_email': 'akaun@pelanggan.my',
                'queued_at': '2026-09-20T09:15:00Z',
                'attempts': 3,
                'last_error': 'No provider key is configured.',
                'sales_documents': {'doc_no': 'INV-0042'},
              },
              {
                'id': 'm2',
                'status': 'sent',
                'subject': 'Statement, August',
                'to_email': 'akaun@pelanggan.my',
                'queued_at': '2026-09-19T09:15:00Z',
                'attempts': 1,
              },
            ],
          ),
          canAdminProvider.overrideWithValue(true),
        ]),
      );
      // The second tab is not built until it is asked for.
      await tester.tap(find.text('Outbox'));
      await tester.pumpAndSettle();

      expect(find.text('Invoice INV-0042'), findsOneWidget);
      // The reason, in red, rather than a status nobody can act on.
      expect(find.text('No provider key is configured.'), findsOneWidget);
      // Three attempts is worth saying; one is not, so that row's line
      // stops at the date.
      expect(find.textContaining('3 attempts'), findsOneWidget);
      expect(find.textContaining('1 attempts'), findsNothing);
      // Only a failed or queued message offers a Send.
      expect(find.text('Send'), findsOneWidget);
    });
  });

  group('the zones and drivers screen', () {
    testWidgets('builds, and a zone with no postcodes is the catch-all',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const DeliverySetupScreen(), [
          posDeliveryZonesProvider.overrideWith(
            (ref) async => [
              {
                'id': 'z1',
                'name': 'Kajang town',
                'is_active': true,
                'fee': 6,
                'min_order': 20,
                'free_above': 80,
                'postcodes': ['43000', '43300'],
              },
              {
                'id': 'z2',
                'name': 'Everywhere else',
                'is_active': true,
                'fee': 0,
                'min_order': 0,
                'postcodes': [],
              },
            ],
          ),
          posDriversProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(
        find.text('RM 6.00 · over RM 20.00 · free above RM 80.00'),
        findsOneWidget,
      );
      expect(find.text('43000, 43300'), findsOneWidget);
      // No fee at all is "Free", not "RM 0.00", and no postcodes means
      // the zone the shop falls back to — said in words, because an
      // empty line reads as an unfinished zone.
      expect(find.text('Free'), findsOneWidget);
      expect(
        find.text('Anywhere not named by another zone'),
        findsOneWidget,
      );
    });

    testWidgets('and a driver says which outlet, always', (tester) async {
      await onAPhone(
        tester,
        wrap(const DeliverySetupScreen(), [
          posDeliveryZonesProvider.overrideWith((ref) async => []),
          posDriversProvider.overrideWith(
            (ref) async => [
              {
                'id': 'd1',
                'name': 'Hafiz',
                'is_active': true,
                'phone': '012-9876543',
                'vehicle': 'Motorcycle',
                'plate_no': 'WXY 1234',
                'outlet_name': 'Jalan Ipoh',
                'out_now': 2,
              },
              {
                'id': 'd2',
                'name': 'Suresh',
                'is_active': false,
                'out_now': 0,
              },
            ],
          ),
        ]),
      );
      expect(find.text('No zones yet'), findsOneWidget);
      await tester.tap(find.text('Drivers'));
      await tester.pumpAndSettle();

      expect(find.text('Hafiz'), findsOneWidget);
      expect(
        find.text('012-9876543 · Motorcycle · WXY 1234 · '
            'Jalan Ipoh only · 2 out now'),
        findsOneWidget,
      );
      // Everything else about this one is missing, but the outlet
      // question is answered either way -- "every outlet" is a real
      // setting, not an absence.
      expect(find.text('every outlet'), findsOneWidget);
    });
  });

  group('the stalls screen', () {
    testWidgets('builds, and a stall with no dishes says so', (tester) async {
      await onAPhone(
        tester,
        wrap(const StallsScreen(), [
          posOutletsProvider.overrideWith(
            (ref) async => [
              {'id': 'o1', 'name': 'Medan Selera Kajang'},
            ],
          ),
          posStallsProvider('o1').overrideWith(
            (ref) async => [
              {
                'id': 's1',
                'code': 'A1',
                'name': 'Nasi kandar',
                'operator': 'Encik Rahim',
                'commission_percent': 12.5000,
                'item_count': 8,
                'is_active': true,
              },
              {
                'id': 's2',
                'code': 'A2',
                'name': 'Air tebu',
                'operator': 'Puan Siti',
                'commission_percent': 10.0000,
                'item_count': 0,
                'is_active': false,
              },
            ],
          ),
        ]),
      );
      // 12.5000 is what a numeric column holds and 12.5 is what a
      // court agreed to.
      expect(
        find.text('Encik Rahim · 12.5% commission · 8 dishes'),
        findsOneWidget,
      );
      // A stall that owns no dish settles for nothing however much the
      // court takes, so the list says it outright rather than "0
      // dishes".
      expect(
        find.text('Puan Siti · 10% commission · nothing on the menu yet'),
        findsOneWidget,
      );
      expect(find.text('Closed'), findsOneWidget);
      expect(find.byKey(const ValueKey('stall-items-s1')), findsOneWidget);
      // One court, so no picker to choose between.
      expect(find.text('Court'), findsNothing);
    });

    testWidgets('and says a food court is an outlet with stalls in it',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const StallsScreen(), [
          posOutletsProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('No outlet yet'), findsOneWidget);
    });
  });

  group('the scales screen', () {
    testWidgets('builds, and an item with no scale number says so',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const ScalesScreen(), [
          weighedItemsProvider.overrideWith(
            (ref) async => [
              {
                'item_id': 'i1',
                'name': 'Ayam bersih',
                'unit_price': 12.90,
                'uom_code': 'kg',
                'scale_plu': '0042',
              },
              {
                'item_id': 'i2',
                'name': 'Udang sederhana',
                'unit_price': 38,
                'uom_code': 'kg',
              },
            ],
          ),
          scaleFormatsProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('RM 12.90 per kg · scale 0042'), findsOneWidget);
      // The scale cannot ring up an item it has no number for, so the
      // row says that outright rather than leaving the line short.
      expect(
        find.text('RM 38.00 per kg · no number on the scale'),
        findsOneWidget,
      );
    });

    testWidgets('and a label layout is read back in words', (tester) async {
      await onAPhone(
        tester,
        wrap(const ScalesScreen(), [
          weighedItemsProvider.overrideWith((ref) async => []),
          scaleFormatsProvider.overrideWith(
            (ref) async => [
              {
                'id': 'f1',
                'name': 'Avery Berkel',
                'prefix': '02',
                'code_digits': 5,
                'value_digits': 5,
                'total_digits': 13,
                'value_kind': 'weight_grams',
                'is_active': true,
              },
              {
                'id': 'f2',
                'name': 'Old Digi',
                'prefix': '21',
                'code_digits': 4,
                'value_digits': 5,
                'total_digits': 12,
                'value_kind': 'price',
                'is_active': false,
              },
            ],
          ),
        ]),
      );
      expect(find.text('Everything here is counted'), findsOneWidget);
      await tester.tap(find.text('Labels'));
      await tester.pumpAndSettle();

      // Every make of scale lays the digits out differently, so the
      // list reads the stored layout back as a sentence somebody can
      // check against the label in their hand.
      expect(
        find.text('Starts 02 · 5 digits of item · 5 of grams · 13 in all'),
        findsOneWidget,
      );
      // A value that is money rather than weight is a different label
      // entirely, and the same row shape has to say which.
      expect(
        find.text('Starts 21 · 4 digits of item · 5 of ringgit · 12 in all'),
        findsOneWidget,
      );
      expect(find.text('Off'), findsOneWidget);
    });
  });

  group('the payroll screen', () {
    testWidgets('builds, and the remittance badge counts what is overdue',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const PayrollScreen(), [
          // `canRunPayrollProvider` is derived from the role, so the
          // role is what the fixture sets.
          memberRoleProvider.overrideWith((ref) async => 'hr_manager'),
          myPayslipAccessProvider.overrideWith((ref) async => false),
          payrollRunsProvider.overrideWith(
            (ref) async => [
              PayrollRun(
                id: 'pr1',
                runNo: 'PAY-2026-09',
                status: 'posted',
                periodCode: '2026-09',
                payDate: DateTime(2026, 9, 25),
                employeeCount: 14,
                totalNet: 48250.75,
              ),
            ],
          ),
          // The contribution nobody was reminded of is the one that
          // goes late, so the badge is the point of this action.
          statutoryDueProvider.overrideWith(
            (ref) async => [
              {'id': 'd1', 'is_overdue': true},
              {'id': 'd2', 'is_overdue': false},
              {'id': 'd3', 'is_overdue': false},
            ],
          ),
        ]),
      );
      expect(find.text('PAY-2026-09'), findsOneWidget);
      expect(
        find.text('2026-09 · 14 employees · paid 25/09/2026'),
        findsOneWidget,
      );
      // Three due, one of them late, and the tooltip says WHICH number
      // it is rather than just showing a badge.
      expect(
        find.byTooltip('1 statutory contribution overdue'),
        findsOneWidget,
      );
      expect(find.byTooltip('EA forms'), findsOneWidget);
      expect(find.text('New run'), findsOneWidget);
    });

    testWidgets('and an auditor with no grant gets the request form',
        (tester) async {
      // Not an empty list they cannot explain. This is a whole
      // different screen behind the same route.
      await onAPhone(
        tester,
        wrap(const PayrollScreen(), [
          memberRoleProvider.overrideWith((ref) async => 'auditor'),
          myPayslipAccessProvider.overrideWith((ref) async => false),
          payrollRunsProvider.overrideWith((ref) async => []),
          payslipAccessRequestsProvider.overrideWith((ref) async => []),
          statutoryDueProvider.overrideWith((ref) async => []),
        ]),
      );
      // The request screen keeps the same app bar title, so the list
      // is what distinguishes them -- and what replaced it.
      expect(find.text('Payslips are closed by default'), findsOneWidget);
      // No New run button, and no remittance or EA action either --
      // none of them is this person's to press.
      expect(find.text('New run'), findsNothing);
      expect(find.byTooltip('EA forms'), findsNothing);
    });
  });

  group('one payroll run', () {
    testWidgets('builds, and splits every contribution two ways',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const PayrollRunScreen(runId: 'pr1'), [
          memberRoleProvider.overrideWith((ref) async => 'hr_manager'),
          payrollRunsProvider.overrideWith(
            (ref) async => [
              PayrollRun(
                id: 'pr1',
                runNo: 'PAY-2026-09',
                status: 'draft',
                periodCode: '2026-09',
                payDate: DateTime(2026, 9, 25),
                employeeCount: 2,
                totalGross: 9000,
                totalNet: 7605,
                totalEpfEmployee: 990,
                totalEpfEmployer: 1170,
                totalSocsoEmployee: 22.25,
                totalSocsoEmployer: 77.85,
                totalEisEmployee: 8.90,
                totalEisEmployer: 8.90,
                totalPcb: 373.85,
                totalHrdf: 90,
              ),
            ],
          ),
          payslipsForRunProvider('pr1').overrideWith(
            (ref) async => [
              Payslip(
                id: 'ps1',
                employeeName: 'Lim Wei Ling',
                employeeNo: 'EMP-014',
                grossPay: 5000,
                epfEmployee: 550,
                pcb: 280.15,
                netPay: 4157.60,
              ),
            ],
          ),
        ]),
      );
      // The title is looked up out of the RUNS list by id -- the
      // screen is given an id and nothing else.
      expect(find.text('PAY-2026-09'), findsOneWidget);
      // Five statutory lines, each split employee/employer, and two of
      // them are one-sided: PCB is the employee's alone and the HRD
      // Corp levy is the employer's alone. Those two zeroes are the
      // ones a table like this gets backwards.
      expect(find.text('EPF / KWSP'), findsOneWidget);
      expect(find.text('HRD Corp levy'), findsOneWidget);
      expect(find.text('Employee'), findsOneWidget);
      expect(find.text('Employer'), findsOneWidget);
      expect(find.text('Lim Wei Ling'), findsOneWidget);
      expect(
        find.text('EMP-014 · gross RM 5,000.00 · EPF RM 550.00 · '
            'PCB RM 280.15'),
        findsOneWidget,
      );
    });

    testWidgets('and an id nothing matches says so rather than throwing',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const PayrollRunScreen(runId: 'gone'), [
          memberRoleProvider.overrideWith((ref) async => 'hr_manager'),
          payrollRunsProvider.overrideWith((ref) async => []),
          payslipsForRunProvider('gone').overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('Run not found'), findsOneWidget);
      // And the app bar falls back to a name rather than showing an
      // empty title.
      expect(find.text('Payroll run'), findsOneWidget);
    });
  });

  group('one ticket', () {
    testWidgets('builds, and resolves three ids through three providers',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const TicketScreen(id: 't1'), [
          ticketProvider('t1').overrideWith(
            (ref) async => {
              'id': 't1',
              'ticket_no': 'TKT-001',
              'subject': 'Printer will not print the receipt',
              'description': 'It feeds the paper and prints nothing.',
              'status': 'open',
              'priority': 'p1',
              'ticket_type': 'problem',
              'channel': 'phone',
              'team_id': 'team-1',
              'category_id': 'cat-1',
              'assignee_id': 'u1',
              'opened_at': '2026-09-20T02:00:00Z',
              'escalation_level': 2,
              'response_breached': false,
              'resolution_breached': true,
            },
          ),
          ticketTeamsProvider.overrideWith(
            (ref) async => [
              {'id': 'team-1', 'name': 'Front counter'},
            ],
          ),
          ticketCategoriesProvider.overrideWith(
            (ref) async => [
              {'id': 'cat-1', 'name': 'Hardware'},
            ],
          ),
          teamProvider.overrideWith(
            (ref) async => [
              TeamMember(
                memberId: 'm1',
                userId: 'u1',
                fullName: 'Siti Nurhaliza',
                role: 'admin',
                status: 'active',
              ),
            ],
          ),
          ticketCommentsProvider('t1').overrideWith((ref) async => []),
          ticketEventsProvider('t1').overrideWith((ref) async => []),
          cannedResponsesProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(find.text('TKT-001'), findsOneWidget);
      expect(find.text('Printer will not print the receipt'), findsOneWidget);
      // Three ids, three separate providers, three names on the page.
      expect(find.text('Front counter'), findsOneWidget);
      expect(find.text('Hardware'), findsOneWidget);
      expect(find.text('Siti Nurhaliza'), findsOneWidget);
      // A code turned into a word, and the escalation count, which is
      // only shown when there has been one.
      expect(find.text('Problem'), findsOneWidget);
      expect(find.text('2 time(s)'), findsOneWidget);
      // The requester's own door. 0192 built the half of the
      // conversation they write and nothing could reach it, so a
      // customer could not answer a question about their own ticket.
      expect(find.byKey(const ValueKey('ticket-share')), findsOneWidget);
      // Send is ON the screen. It used to be 252 pixels off the right
      // edge, so a ticket could not be replied to from a phone at all
      // -- and a release build clips that silently, so the button was
      // simply missing rather than obviously broken.
      final send = tester.getRect(find.byKey(const ValueKey('ticket-send')));
      expect(send.right, lessThanOrEqualTo(412));
    });

    testWidgets('and an assignee who has left the team is named as that',
        (tester) async {
      // Not a blank and not a raw uuid: the ticket is assigned, and to
      // somebody the roster no longer holds, which is a different
      // thing from being unassigned.
      await onAPhone(
        tester,
        wrap(const TicketScreen(id: 't1'), [
          ticketProvider('t1').overrideWith(
            (ref) async => {
              'id': 't1',
              'ticket_no': 'TKT-002',
              'subject': 'Old ticket',
              'status': 'open',
              'priority': 'p3',
              'channel': 'email',
              'assignee_id': 'gone',
              'opened_at': '2026-09-20T02:00:00Z',
            },
          ),
          ticketTeamsProvider.overrideWith((ref) async => []),
          ticketCategoriesProvider.overrideWith((ref) async => []),
          teamProvider.overrideWith((ref) async => []),
          ticketCommentsProvider('t1').overrideWith((ref) async => []),
          ticketEventsProvider('t1').overrideWith((ref) async => []),
          cannedResponsesProvider.overrideWith((ref) async => []),
        ]),
      );
      expect(
        find.text('Somebody no longer on the team'),
        findsOneWidget,
      );
      // No escalations and no reopenings, so neither row appears --
      // "0 time(s)" on every ticket is noise.
      expect(find.textContaining('time(s)'), findsNothing);
    });
  });

  group('one financial statement', () {
    List<Override> filing({
      required bool balances,
      required bool exemptionClaimed,
      required bool groundApplies,
      bool late = false,
    }) =>
        [
          fsFilingProvider('f1').overrideWith(
            (ref) async => {
              'id': 'f1',
              'status': 'draft',
              'fy_end': '2026-06-30',
              'corp_entity_id': 'e1',
              'audit_status': exemptionClaimed ? 'audit_exempt' : 'audited',
            },
          ),
          corpEntitiesProvider.overrideWith(
            (ref) async => [
              CorpEntity(
                id: 'e1',
                name: 'Maju Jaya Sdn Bhd',
                entityType: 'sdn_bhd',
                status: 'active',
                registrationNo: '202101001234',
              ),
            ],
          ),
          fsBalanceCheckProvider('f1').overrideWith(
            (ref) async => {
              'balances': balances,
              'difference': balances ? 0 : 1250.40,
              'assets': 500000,
              'liabilities': 200000,
              'equity': balances ? 300000 : 298749.60,
            },
          ),
          fsDeadlinesProvider('f1').overrideWith(
            (ref) async => {
              'is_late': late,
              'days_left': 45,
              'circulate_by': '2026-12-30',
              'lodge_by': '2027-01-29',
              'basis': 'Six months after the year end, lodged within 30 days.',
            },
          ),
          fsExemptionProvider('f1').overrideWith(
            (ref) async => [
              {'ground': 'zero_revenue', 'qualifies': groundApplies},
              {'ground': 'threshold_qualified', 'qualifies': false},
              {'ground': 'dormant', 'qualifies': false},
            ],
          ),
          fsExportProvider('f1').overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(true),
          canAdminProvider.overrideWithValue(true),
        ];

    testWidgets('builds, and names the company these accounts are for',
        (tester) async {
      await onAPhone(
        tester,
        wrap(
          const FilingScreen(filingId: 'f1'),
          filing(
            balances: true,
            exemptionClaimed: false,
            groundApplies: false,
          ),
        ),
      );
      // `fs_set_entity` was granted and called by nothing, so
      // `corp_entity_id` was null on every filing and the deadline
      // list named the practice rather than the client.
      expect(find.text('Maju Jaya Sdn Bhd (202101001234)'), findsOneWidget);
      expect(
        find.text('The statement of financial position balances'),
        findsOneWidget,
      );
      expect(find.text('Due in 45 days'), findsOneWidget);
      expect(find.byKey(const ValueKey('fs-mapping')), findsOneWidget);
      // All three grounds, including the ones that do not apply:
      // showing only the one that succeeds answers "am I exempt" and
      // leaves "why not" to guesswork.
      expect(find.text('An audit is required'), findsOneWidget);
      expect(find.text('Zero Revenue'), findsOneWidget);
      expect(find.text('Dormant'), findsOneWidget);
    });

    testWidgets('and says outright when the position does not balance',
        (tester) async {
      await onAPhone(
        tester,
        wrap(
          const FilingScreen(filingId: 'f1'),
          filing(
            balances: false,
            exemptionClaimed: false,
            groundApplies: false,
          ),
        ),
      );
      expect(find.text('Out by RM 1,250.40'), findsOneWidget);
    });

    testWidgets('and flags exemption claimed with no ground for it',
        (tester) async {
      // The dangerous combination: filing unaudited accounts that
      // needed an audit. Neither half is wrong on its own.
      await onAPhone(
        tester,
        wrap(
          const FilingScreen(filingId: 'f1'),
          filing(
            balances: true,
            exemptionClaimed: true,
            groundApplies: false,
          ),
        ),
      );
      expect(
        find.text('Exemption claimed, but no ground applies'),
        findsOneWidget,
      );
    });

    testWidgets('but not when a ground does apply', (tester) async {
      await onAPhone(
        tester,
        wrap(
          const FilingScreen(filingId: 'f1'),
          filing(
            balances: true,
            exemptionClaimed: true,
            groundApplies: true,
          ),
        ),
      );
      expect(find.text('Audit exemption available'), findsOneWidget);
      expect(
        find.text('Exemption claimed, but no ground applies'),
        findsNothing,
      );
    });

    testWidgets('and a filing that is gone says so', (tester) async {
      await onAPhone(
        tester,
        wrap(const FilingScreen(filingId: 'f1'), [
          fsFilingProvider('f1').overrideWith((ref) async => null),
          corpEntitiesProvider.overrideWith((ref) async => []),
          fsBalanceCheckProvider('f1').overrideWith((ref) async => null),
          fsDeadlinesProvider('f1').overrideWith((ref) async => null),
          fsExemptionProvider('f1').overrideWith((ref) async => []),
          fsExportProvider('f1').overrideWith((ref) async => []),
          canWriteProvider.overrideWithValue(true),
          canAdminProvider.overrideWithValue(true),
        ]),
      );
      expect(find.text('Not found'), findsOneWidget);
    });
  });

  group('the HR setup screen', () {
    testWidgets('builds its payroll tab out of the settings row',
        (tester) async {
      await onAPhone(
        tester,
        wrap(const HrSetupScreen(), [
          payrollSettingsProvider.overrideWith(
            (ref) async => {
              'employer_epf_no': 'E1234567890',
              'employer_socso_no': 'A1234567890',
              'employer_tax_no': 'E 1234567890',
              'hrdf_registration_no': '',
              'hrdf_category': null,
              // 0 is a real setting, not a missing one, and the screen
              // has to say which.
              'pay_day': 0,
            },
          ),
        ]),
      );
      expect(find.text('Employer registrations'), findsOneWidget);
      // These appear on the statutory submissions, so they are read
      // back into the boxes rather than left for somebody to retype.
      expect(find.text('E1234567890'), findsOneWidget);
      expect(find.text('A1234567890'), findsOneWidget);
      // Pay day 0 is the last day of the month, not "unset".
      expect(find.text('Last day of the month'), findsOneWidget);
      expect(find.text('Save settings'), findsOneWidget);
      // Ten tabs, scrollable, and the last one is reachable.
      expect(find.text('Statutory rates'), findsOneWidget);
    });

    testWidgets('and a second tab is a list keyed on its own table',
        (tester) async {
      // Every simple configuration list goes through ONE provider
      // keyed by table name, so the fixture has to name the table --
      // and a tab whose table is not overridden reaches the network.
      await onAPhone(
        tester,
        wrap(const HrSetupScreen(), [
          payrollSettingsProvider.overrideWith((ref) async => null),
          setupRowsProvider((table: 'departments', orderBy: 'name'))
              .overrideWith(
            (ref) async => [
              {
                'id': 'd1',
                'name': 'Kitchen',
                'code': 'KIT',
                'cost_centre': 'CC-01',
              },
              {'id': 'd2', 'name': 'Front of house', 'code': 'FOH'},
            ],
          ),
          setupRowsProvider((table: 'positions', orderBy: 'name'))
              .overrideWith((ref) async => []),
        ]),
      );
      await tester.tap(find.text('Structure'));
      await tester.pumpAndSettle();

      expect(find.text('Kitchen'), findsOneWidget);
      // Code and cost centre joined, and the cost centre dropped when
      // there is not one rather than leaving a trailing separator.
      expect(find.text('KIT · CC-01'), findsOneWidget);
      expect(find.text('FOH'), findsOneWidget);
    });
  });
}
