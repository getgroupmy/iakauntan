import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/reports/group_reports_screen.dart';
import 'package:iakauntan/src/features/reports/report_spec.dart';
import 'package:iakauntan/src/features/reports/reports_screen.dart';

/// Reporting across a company group.
///
/// The arithmetic is asserted in `supabase/tests/group_reporting.sql`,
/// where it belongs — the database is what adds the companies up. What
/// is asserted here is the half a person actually reads: that the screen
/// says it is a combination and not a consolidation, that it never
/// offers a PDF of a report it has not finished loading, and that when
/// the database refuses to add two currencies together the sentence
/// explaining why reaches the screen instead of an empty table.
void main() {
  final range = DateTimeRange(
    start: DateTime(2026, 1, 1),
    end: DateTime(2026, 8, 15),
  );

  Map<String, dynamic> tb(
    String code,
    String name, {
    int companies = 2,
    double debit = 0,
    double credit = 0,
    double closing = 0,
  }) => {
    'code': code,
    'name': name,
    'companies': companies,
    'opening_balance': 0,
    'debit': debit,
    'credit': credit,
    'closing_balance': closing,
  };

  group('combined trial balance', () {
    test('it says how many companies it added up, because the figure is '
        'meaningless without that', () {
      final spec = groupTrialBalanceSpec(
        [tb('1100', 'Trade Debtors', debit: 1060, closing: 1060)],
        range,
        companies: 3,
      );
      expect(spec.subtitle, contains('3 companies'));
    });

    test('and one company is a company, not "1 companies"', () {
      final spec = groupTrialBalanceSpec(const [], range, companies: 1);
      expect(spec.subtitle, contains('1 company'));
      expect(spec.subtitle, isNot(contains('1 companies')));
    });

    test('a balanced report says so', () {
      final spec = groupTrialBalanceSpec(
        [
          tb('1100', 'Trade Debtors', debit: 1060, closing: 1060),
          tb('4000', 'Sales', credit: 1000, closing: -1000),
          tb('2200', 'SST Payable', credit: 60, closing: -60),
        ],
        range,
        companies: 2,
      );
      expect(spec.subtitle, contains('In balance'));
    });

    test('and one that does not balance says by how much, rather than '
        'quietly showing a total nobody checks', () {
      // What a broken elimination looks like: the receivable and the
      // revenue removed, the tax line left behind.
      final spec = groupTrialBalanceSpec(
        [
          tb('1100', 'Trade Debtors', debit: 1060, closing: 1060),
          tb('4000', 'Sales', credit: 1000, closing: -1000),
        ],
        range,
        companies: 2,
      );
      expect(spec.subtitle, contains('Out of balance by'));
      expect(spec.subtitle, contains('60'));
    });

    test('the note on the report says it is not a consolidation', () {
      final spec = groupTrialBalanceSpec(const [], range, companies: 2);
      expect(spec.note, contains('not consolidated'));
    });

    test('an account nothing moved on is left off', () {
      final spec = groupTrialBalanceSpec(
        [
          tb('1100', 'Trade Debtors', debit: 1060, closing: 1060),
          tb('1300', 'Stock'),
        ],
        range,
        companies: 2,
      );
      final grid = spec.blocks.whereType<ReportGrid>().single;
      expect(grid.rows, hasLength(1));
    });

    test('how many companies hold each account is on the row', () {
      final spec = groupTrialBalanceSpec(
        [tb('1100', 'Trade Debtors', companies: 4, debit: 1060, closing: 1060)],
        range,
        companies: 4,
      );
      final grid = spec.blocks.whereType<ReportGrid>().single;
      expect(grid.headers, contains('In'));
      expect((grid.rows.single[2] as TextCell).text, '4');
    });
  });

  group('inter-company', () {
    Map<String, dynamic> ic({
      String from = 'Group A Sdn Bhd',
      String to = 'Group B Sdn Bhd',
      double receivable = 0,
      double payable = 0,
      double revenue = 0,
      double expense = 0,
    }) => {
      'from_org': from,
      'to_org': to,
      'receivable': receivable,
      'payable': payable,
      'revenue': revenue,
      'expense': expense,
    };

    test('two sides that agree need no explanation', () {
      final spec = intercompanySpec([
        ic(receivable: 1060, revenue: 1000),
        ic(
          from: 'Group B Sdn Bhd',
          to: 'Group A Sdn Bhd',
          payable: 1060,
          expense: 1000,
        ),
      ], range);
      expect(spec.note, isNull);
    });

    test('and two sides that do not are named, because that difference is '
        'a document posted in one company and not the other', () {
      final spec = intercompanySpec([
        ic(receivable: 1060, revenue: 1000),
        ic(from: 'Group B Sdn Bhd', to: 'Group A Sdn Bhd', payable: 500),
      ], range);
      expect(spec.note, isNotNull);
      expect(spec.note, contains('do not agree'));
      expect(spec.note, contains('560'));
    });

    test('both sides are listed rather than netted', () {
      final spec = intercompanySpec([
        ic(receivable: 1060, revenue: 1000),
        ic(
          from: 'Group B Sdn Bhd',
          to: 'Group A Sdn Bhd',
          payable: 1060,
          expense: 1000,
        ),
      ], range);
      final grid = spec.blocks.whereType<ReportGrid>().single;
      expect(grid.rows, hasLength(2));
    });
  });

  group('the screen', () {
    Widget harness({
      required AsyncValue<List<Map<String, dynamic>>> trialBalance,
      List<Map<String, dynamic>> intercompany = const [],
      int companies = 2,
    }) {
      return ProviderScope(
        overrides: [
          // No session, so nothing here reaches Supabase. Every provider
          // the screen reads is answered from this list.
          repoProvider.overrideWithValue(null),
          groupCompaniesProvider.overrideWith(
            (ref) async => [
              for (var i = 0; i < companies; i++)
                {'org_id': 'o$i', 'name': 'Company $i', 'is_current': i == 0},
            ],
          ),
          groupTrialBalanceProvider.overrideWith((ref, arg) {
            return trialBalance.when(
              data: (rows) => rows,
              // A future that never completes: the loading state, held
              // still so the download button can be looked at.
              loading: () => Completer<List<Map<String, dynamic>>>().future,
              error: (e, _) => Future<List<Map<String, dynamic>>>.error(e),
            );
          }),
          groupIntercompanyProvider.overrideWith((ref, arg) => intercompany),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const GroupReportsScreen(),
        ),
      );
    }

    testWidgets('says on its face that it is a combination', (tester) async {
      await tester.pumpWidget(harness(trialBalance: const AsyncData([])));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Combined, not consolidated'),
        findsOneWidget,
        reason: 'somebody who does not read the PDF still has to be told',
      );
    });

    testWidgets('offers no PDF of a report it has not finished loading', (
      tester,
    ) async {
      await tester.pumpWidget(harness(trialBalance: const AsyncLoading()));
      await tester.pump();

      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('group-download')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('and offers one once the figures are there', (tester) async {
      await tester.pumpWidget(
        harness(
          trialBalance: AsyncData([
            tb('1100', 'Trade Debtors', debit: 1060, closing: 1060),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('group-download')),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a group whose companies keep different currencies is told '
        'why, not shown an empty table', (tester) async {
      // What 0142 raises rather than adding ringgit to dollars.
      await tester.pumpWidget(
        harness(
          trialBalance: AsyncError(
            'The companies in this group keep their books in different '
            'currencies (MYR, SGD).',
            StackTrace.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('different currencies'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('group-download')))
            .onPressed,
        isNull,
        reason: 'and there is nothing to print',
      );
    });

    testWidgets('a group that does not trade with itself says that, rather '
        'than looking broken', (tester) async {
      await tester.pumpWidget(harness(trialBalance: const AsyncData([])));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Inter-company'));
      await tester.pumpAndSettle();

      expect(find.text('No trading between the companies'), findsOneWidget);
    });
  });

  group('the way in', () {
    /// The Reports screen, with nothing behind it. Every report on it
    /// fails to load, which is fine — what is being looked at is the app
    /// bar.
    Widget reports({required int companies}) => ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(null),
        groupCompaniesProvider.overrideWith(
          (ref) async => [
            for (var i = 0; i < companies; i++)
              {'org_id': 'o$i', 'name': 'Company $i', 'is_current': i == 0},
          ],
        ),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const ReportsScreen()),
    );

    /// `pumpAndSettle` cannot be used: an unreachable repository leaves
    /// `AsyncView` retrying on a periodic timer, which never settles.
    Future<void> open(WidgetTester tester, {required int companies}) async {
      await tester.pumpWidget(reports(companies: companies));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a company on its own is offered no group reports', (
      tester,
    ) async {
      await open(tester, companies: 1);
      expect(
        find.byKey(const ValueKey('open-group-reports')),
        findsNothing,
        reason:
            'a combination of one company is that company under a '
            'heading claiming otherwise',
      );
    });

    testWidgets('and a company that has another beside it is', (tester) async {
      await open(tester, companies: 2);
      expect(find.byKey(const ValueKey('open-group-reports')), findsOneWidget);
    });
  });
}
