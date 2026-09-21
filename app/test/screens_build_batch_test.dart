import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/expenses/expenses_screen.dart';
import 'package:iakauntan/src/features/financials/filings_screen.dart';

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
}
