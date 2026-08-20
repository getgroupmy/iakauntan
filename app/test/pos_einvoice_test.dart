import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/einvoice/einvoice_screen.dart';

/// The consolidated e-Invoice a shop owes LHDN.
///
/// 0210 built the roll-up, the deadline and the outstanding query, and
/// nothing called any of it — so a shop selling through the till has
/// been accruing a statutory obligation with nowhere to see it. What is
/// asserted here is the part that makes it an obligation somebody can
/// act on.
///
/// The dates are not recomputed. `due_date` and `days_left` come back
/// from `pos_einvoice_outstanding`, so these tests feed the figures the
/// server would send and check what a person is told about them — in
/// particular that a missed deadline reads as missed, since that is the
/// one thing this section exists to say.
void main() {
  Widget screen({
    List<Map<String, dynamic>> outstanding = const [],
    bool einvoiceEnabled = true,
  }) => ProviderScope(
    overrides: [
      currentUserProvider.overrideWithValue(null),
      authStateProvider.overrideWith((_) => const Stream<AuthState>.empty()),
      currentOrgProvider.overrideWith(
        (_) async => Organization(
          id: 'o1',
          name: 'Kedai Runcit Sdn Bhd',
          slug: 'runcit',
          baseCurrency: 'MYR',
          einvoiceEnabled: einvoiceEnabled,
        ),
      ),
      enabledModulesProvider.overrideWith((_) async => {'einvoice', 'pos'}),
      einvoicesProvider.overrideWith((_, __) async => const []),
      posEinvoiceOutstandingProvider.overrideWith((_) async => outstanding),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const EinvoiceScreen(),
    ),
  );

  Future<void> show(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  testWidgets('a period still in hand says how long is left', (tester) async {
    await show(
      tester,
      screen(
        outstanding: const [
          {
            'period_start': '2026-07-01',
            'period_end': '2026-07-31',
            'due_date': '2026-08-07',
            'sales_waiting': 412,
            'total_amount': 8340.50,
            'consolidation_status': 'not started',
            'days_left': 5,
          },
        ],
      ),
    );

    expect(find.textContaining('412 till sales to consolidate'), findsOneWidget);
    expect(find.textContaining('5 days left'), findsOneWidget);
    expect(find.text('Consolidate'), findsOneWidget);
    expect(find.textContaining('late'), findsNothing);
  });

  testWidgets('a deadline already missed says so, and by how much', (
    tester,
  ) async {
    // The reason this widget exists. `days_left` comes back negative and
    // is shown as it is — clamping it to zero would turn "you are three
    // days late filing with LHDN" into "due today".
    await show(
      tester,
      screen(
        outstanding: const [
          {
            'period_start': '2026-06-01',
            'period_end': '2026-06-30',
            'due_date': '2026-07-07',
            'sales_waiting': 389,
            'total_amount': 7120.00,
            'consolidation_status': 'not started',
            'days_left': -3,
          },
        ],
      ),
    );

    expect(find.textContaining('3 days late'), findsOneWidget);
    expect(find.textContaining('Was due'), findsOneWidget);
    expect(find.textContaining('days left'), findsNothing);
  });

  testWidgets('one day is a day, not 1 days', (tester) async {
    await show(
      tester,
      screen(
        outstanding: const [
          {
            'period_start': '2026-07-01',
            'period_end': '2026-07-31',
            'due_date': '2026-08-07',
            'sales_waiting': 12,
            'total_amount': 240.00,
            'consolidation_status': 'not started',
            'days_left': 1,
          },
        ],
      ),
    );

    expect(find.textContaining('1 day left'), findsOneWidget);
    expect(find.textContaining('1 days left'), findsNothing);
  });

  testWidgets('a shop with nothing outstanding is shown nothing', (
    tester,
  ) async {
    // The other half. An assertion that only checks the banner appears
    // is satisfied by a banner that is always there — and a company with
    // no till at all should never see a word about consolidation.
    await show(tester, screen());

    expect(find.text('Consolidate'), findsNothing);
    expect(find.textContaining('to consolidate'), findsNothing);
    // The positive control: the screen itself rendered.
    expect(find.text('No e-Invoices yet'), findsOneWidget);
  });

  testWidgets('every period owed gets its own row and its own button', (
    tester,
  ) async {
    // Two months unfiled is the state a shop discovers late, and one
    // row summarising both would hide which is overdue.
    await show(
      tester,
      screen(
        outstanding: const [
          {
            'period_start': '2026-06-01',
            'period_end': '2026-06-30',
            'due_date': '2026-07-07',
            'sales_waiting': 389,
            'total_amount': 7120.00,
            'consolidation_status': 'not started',
            'days_left': -34,
          },
          {
            'period_start': '2026-07-01',
            'period_end': '2026-07-31',
            'due_date': '2026-08-07',
            'sales_waiting': 412,
            'total_amount': 8340.50,
            'consolidation_status': 'not started',
            'days_left': -3,
          },
        ],
      ),
    );

    expect(find.text('Consolidate'), findsNWidgets(2));
    expect(find.textContaining('34 days late'), findsOneWidget);
    expect(find.textContaining('3 days late'), findsOneWidget);
  });
}
