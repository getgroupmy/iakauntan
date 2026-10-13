import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/reports/budgets_screen.dart';

/// `0857`. A budget is the module's: anybody the accounting module admits
/// keeps one. The actual beside it is the ledger's, and the database
/// refuses it -- the variance, and filling a budget from last year's
/// actuals -- to a role that does not read the ledger. So for such a
/// role the panel says why rather than showing the refusal as an error,
/// the fill is not offered, and neither is asked of the database.
void main() {
  Future<_RecordingRepo> open(WidgetTester tester, String role) async {
    final repo = _RecordingRepo();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(repo),
          memberRoleProvider.overrideWith((ref) async => role),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const BudgetsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Board plan'));
    await tester.pumpAndSettle();
    return repo;
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
  }

  testWidgets('a salesman is told why, and the actuals are not asked for', (
    tester,
  ) async {
    final repo = await open(tester, 'sales');
    expect(
      find.byKey(const ValueKey('budget-actuals-withheld')),
      findsOneWidget,
    );
    expect(find.textContaining('your role in this company'), findsOneWidget);
    expect(repo.asked, isNot(contains('report_budget_vs_actual')));

    await openMenu(tester);
    expect(find.text('Change the numbers'), findsOneWidget);
    expect(find.text('Fill it from last year'), findsNothing);
  });

  testWidgets('a clerk is shown the actuals and offered the fill', (
    tester,
  ) async {
    // The control. Without it, both assertions above pass against a
    // screen that had stopped offering either to anybody.
    final repo = await open(tester, 'accounts_clerk');
    expect(find.byKey(const ValueKey('budget-actuals-withheld')), findsNothing);
    expect(repo.asked, contains('report_budget_vs_actual'));
    expect(find.text('Nothing budgeted and nothing spent.'), findsOneWidget);

    await openMenu(tester);
    expect(find.text('Fill it from last year'), findsOneWidget);
  });
}

/// One draft budget, nothing in any report, and a note of what was asked.
class _RecordingRepo implements Repo {
  final asked = <String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    final member = name.substring('Symbol("'.length, name.length - 2);
    if (member == 'orgId') return 'o1';
    // The budget reads are extensions that go through `callRpc`, so
    // they are remembered, and answered, by the function's name.
    final fn = member == 'callRpc'
        ? invocation.positionalArguments.first as String
        : member;
    asked.add(fn);
    if (fn == 'budgets_list') {
      return Future.value(<Map<String, dynamic>>[
        {
          'id': 'b1',
          'name': 'Board plan',
          'status': 'draft',
          'year_name': 'FY2026',
          'lines': 0,
        },
      ]);
    }
    return Future.value(const <Map<String, dynamic>>[]);
  }
}
