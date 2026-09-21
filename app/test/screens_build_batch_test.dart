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
import 'package:iakauntan/src/features/documents/cheques_screen.dart';
import 'package:iakauntan/src/features/documents/contra_screen.dart';
import 'package:iakauntan/src/features/documents/deposits_screen.dart';
import 'package:iakauntan/src/features/expenses/expenses_screen.dart';
import 'package:iakauntan/src/features/financials/filings_screen.dart';
import 'package:iakauntan/src/features/legal/matters_screen.dart';
import 'package:iakauntan/src/features/reports/budgets_screen.dart';
import 'package:iakauntan/src/features/landing/no_access_screen.dart';
import 'package:iakauntan/src/features/ledger/recurring_screen.dart';
import 'package:iakauntan/src/features/stock/bundles_screen.dart';
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
        GoRoute(
          path: '/legal/:id',
          builder: (_, __) => const Scaffold(body: Text('one matter')),
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
}
