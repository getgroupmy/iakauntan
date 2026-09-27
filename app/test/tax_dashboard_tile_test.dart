import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/dashboard/dashboard_screen.dart';

/// The tax tiles on the home screen.
///
/// Every figure is computed in SQL and asserted in
/// `supabase/tests/tax_dashboard_tile.sql`. What is asserted here is
/// what the tile SAYS, and the captions carry three decisions that
/// would otherwise be invisible:
///
///   * **Returns and instalments are separate tiles.** A company can
///     be entirely up to date on its returns and behind on its CP204.
///     One combined number would be true of neither.
///   * **The caption names the form.** "Form C on 31 January" is what
///     goes in the diary; "next on 31 January" is not.
///   * **Nothing overdue reads as reassurance, not as a zero.** The
///     Registrar's tile made that argument first and this follows it.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Map<String, dynamic> dashboard,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: moduleTiles(context, 'accounting', dashboard),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> tax({
    int overdue = 0,
    int soon = 0,
    int behind = 0,
    String? nextDue,
    String? nextForm,
    String? instalmentNext,
  }) => {
    'tax': {
      'overdue': overdue,
      'due_soon': soon,
      'instalments_overdue': behind,
      'next_due': nextDue,
      'next_form': nextForm,
      'instalment_next_due': instalmentNext,
    },
  };

  testWidgets('a company with nothing late is told so', (tester) async {
    await pump(tester, tax());
    expect(find.text('Returns past their deadline'), findsOneWidget);
    // Not "0 overdue" left to be read as an absence of data. The
    // Registrar's tile made this argument first.
    expect(find.text('Nothing is late'), findsOneWidget);
    expect(find.text('Nothing in the next month'), findsOneWidget);
    expect(find.text('None outstanding'), findsOneWidget);
  });

  testWidgets('a late return says to file it first', (tester) async {
    await pump(tester, tax(overdue: 2));
    expect(find.text('2'), findsWidgets);
    expect(find.text('File these first'), findsOneWidget);
    expect(find.text('Nothing is late'), findsNothing);
  });

  testWidgets('the next return names its form and date', (tester) async {
    await pump(
      tester,
      tax(soon: 1, nextDue: '2027-01-31', nextForm: 'C'),
    );
    // The form, not just the date. A tile that said "Next on
    // 31 January" leaves somebody to work out which of four returns
    // it means.
    expect(find.textContaining('C on'), findsOneWidget);
    expect(find.textContaining('31/01/2027'), findsOneWidget);
  });

  testWidgets('and falls back to the date when the form is missing',
      (tester) async {
    // The server always sends one beside a date, so this asserts the
    // intent: a missing form must not produce "Next: null on ...".
    await pump(tester, tax(soon: 1, nextDue: '2027-01-31'));
    expect(find.textContaining('null'), findsNothing);
    expect(find.textContaining('Next on 31/01/2027'), findsOneWidget);
  });

  testWidgets('instalments are their own tile with their own alarm',
      (tester) async {
    // Behind on instalments, nothing overdue on returns. One combined
    // count would be true of neither, and this is the state that
    // proves the two are separate.
    await pump(tester, tax(behind: 3));
    expect(find.text('Instalments not paid'), findsOneWidget);
    expect(find.text('Each one adds 10% of itself'), findsOneWidget);
    // The returns tile still reads as clear.
    expect(find.text('Nothing is late'), findsOneWidget);
  });

  testWidgets('with none outstanding it offers the next date',
      (tester) async {
    await pump(tester, tax(instalmentNext: '2026-11-15'));
    expect(find.textContaining('Next on 15/11/2026'), findsOneWidget);
    expect(find.text('Each one adds 10% of itself'), findsNothing);
  });

  testWidgets('a company without the key gets no tiles at all',
      (tester) async {
    // An absent key means the module is off or nothing was measured —
    // not that the figures are zero. Drawing three zeroes would be
    // stating something nobody measured.
    await pump(tester, const {});
    expect(find.text('Returns past their deadline'), findsNothing);
    expect(find.text('Instalments not paid'), findsNothing);
  });

  testWidgets('and neither does another module asking for them',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: moduleTiles(context, 'pos', tax(overdue: 2)),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Returns past their deadline'), findsNothing);
  });
}
