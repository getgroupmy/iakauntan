import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/crm/leads_screen.dart';
import 'package:iakauntan/src/features/crm/pipeline_screen.dart';
import 'package:iakauntan/src/features/expenses/expenses_screen.dart';
import 'package:iakauntan/src/features/financials/filings_screen.dart';
import 'package:iakauntan/src/features/landing/no_access_screen.dart';
import 'package:iakauntan/src/features/ledger/recurring_screen.dart';
import 'package:iakauntan/src/features/stock/stock_take_screen.dart';
import 'package:iakauntan/src/features/ticketing/teams_screen.dart';
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
}
