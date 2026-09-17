import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/sst_returns_card.dart';

/// The deadline the SST card never said out loud.
///
/// `report_sst_due` has returned the unfiled periods since 0145 and the
/// provider has been refreshed after every filing, and nothing drew it:
/// the card listed every period newest-first and left the reader to
/// work out which one was a breach.
///
/// The arithmetic — when a period ends, when its return falls due — is
/// the database's, asserted in `supabase/tests/sst_taxable_period.sql`.
/// What is asserted here is the part that only exists in Dart: which
/// sentence is chosen, that a missed date is stated in the past tense
/// rather than as a negative countdown, and that one day is not "1
/// days".
void main() {
  Map<String, dynamic> row({
    String periodEnd = '2026-06-30',
    String dueDate = '2026-07-31',
    int daysLeft = 10,
    double tax = 1200,
    bool overdue = false,
  }) => {
    'period_start': '2026-05-01',
    'period_end': periodEnd,
    'due_date': dueDate,
    'days_left': daysLeft,
    'output_tax': tax,
    'is_overdue': overdue,
  };

  group('the sentence', () {
    test('nothing unfiled inside the window says nothing at all', () {
      // Deliberately not "everything is filed": the window is 120 days
      // and a claim about periods outside it is one this row set cannot
      // support.
      expect(sstDueLine(const []), isNull);
    });

    test('a return still ahead of its date counts down', () {
      final line = sstDueLine([
        row(dueDate: '2026-07-31', daysLeft: 17, tax: 1234.50),
      ]);

      expect(line, isNotNull);
      expect(line!.overdue, isFalse);
      expect(line.text, contains('is due 31/07/2026'));
      expect(line.text, contains('17 days'));
      expect(line.text, contains('1,234.50'));
    });

    test('one day left is a day, not days', () {
      final line = sstDueLine([row(daysLeft: 1)]);
      expect(line!.text, contains('1 day.'));
      expect(line.text, isNot(contains('1 days')));
    });

    test('the last day says today rather than counting zero', () {
      final line = sstDueLine([row(daysLeft: 0, dueDate: '2026-07-31')]);
      expect(line!.text, contains('due today, 31/07/2026'));
      expect(line.text, isNot(contains('0 days')));
    });

    test('a date that has gone is past tense, never a negative count', () {
      final line = sstDueLine([
        row(dueDate: '2026-05-31', daysLeft: -12, overdue: true),
      ]);

      expect(line!.overdue, isTrue);
      expect(line.text, contains('was due 31/05/2026'));
      expect(line.text, isNot(contains('-12')));
      expect(line.text, isNot(contains('12 days')));
    });

    test('several overdue are counted and their tax totalled', () {
      final line = sstDueLine([
        row(
          periodEnd: '2026-02-28',
          dueDate: '2026-03-31',
          daysLeft: -100,
          tax: 500,
          overdue: true,
        ),
        row(
          periodEnd: '2026-04-30',
          dueDate: '2026-05-31',
          daysLeft: -40,
          tax: 250.25,
          overdue: true,
        ),
      ]);

      expect(line!.overdue, isTrue);
      expect(line.text, contains('2 returns are overdue'));
      // The earliest of the two, which is the one that has been
      // outstanding longest — not the most recent.
      expect(line.text, contains('earliest was due 31/03/2026'));
      expect(line.text, contains('750.25'));
    });

    test('an overdue one outranks a later one that is merely due', () {
      // The list comes back in due-date order and mixes both. Saying
      // "due in 20 days" while a return is already late would be the
      // worst of the possible sentences.
      final line = sstDueLine([
        row(dueDate: '2026-05-31', daysLeft: -12, tax: 300, overdue: true),
        row(dueDate: '2026-07-31', daysLeft: 20, tax: 900),
      ]);

      expect(line!.overdue, isTrue);
      expect(line.text, contains('was due'));
    });
  });

  group('the card', () {
    Widget harness(List<Map<String, dynamic>> due, {bool registered = true}) =>
        ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(null),
            currentOrgProvider.overrideWith(
              (ref) async => Organization(
                id: 'o1',
                name: 'Kabeer Holdings Sdn Bhd',
                slug: 'kabeer',
                baseCurrency: 'MYR',
                isSstRegistered: registered,
              ),
            ),
            sstTaxablePeriodsProvider.overrideWith((ref) async => const []),
            sstDueProvider.overrideWith((ref) async => due),
            canPostProvider.overrideWithValue(true),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: SingleChildScrollView(child: SstReturnsCard()),
            ),
          ),
        );

    testWidgets('draws the deadline above the list', (tester) async {
      await tester.pumpWidget(
        harness([row(dueDate: '2026-07-31', daysLeft: 17)]),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sst-due-line')), findsOneWidget);
      expect(find.textContaining('17 days'), findsOneWidget);
    });

    testWidgets('an overdue return is drawn in danger, not warning', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness([row(dueDate: '2026-05-31', daysLeft: -12, overdue: true)]),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(
        find.byKey(const ValueKey('sst-due-line')),
      );
      final context = tester.element(find.byType(SstReturnsCard));
      expect(text.style?.color, context.colors.danger);
    });

    testWidgets('and nothing due draws no line', (tester) async {
      await tester.pumpWidget(harness(const []));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sst-due-line')), findsNothing);
    });

    testWidgets('a company that is not registered sees no card at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness([row(overdue: true)], registered: false),
      );
      await tester.pumpAndSettle();

      expect(find.text('SST returns'), findsNothing);
      expect(find.byKey(const ValueKey('sst-due-line')), findsNothing);
    });
  });
}
