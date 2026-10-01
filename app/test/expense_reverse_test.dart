import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/shared/attachments_card.dart';
import 'package:iakauntan/src/features/expenses/expenses_screen.dart';

/// Correcting a posted expense, from the expense.
///
/// `EXP-2026-00001` is why this exists: RM22.50 posted against the
/// `1120` control account, which put it on no bank reconciliation at
/// all. The fix is a reversal and a re-entry — and there was no way to
/// start one from the expense. The detail dialog said "correcting one
/// means reversing it, which is a different verb and a different
/// screen", and that screen only existed for journals, so somebody had
/// to go and find `JV-2026-00001` by its number.
///
/// What is asserted here is the WIRING, because the rule itself
/// (`reEntryFields`) has its own unit tests and a rule that reaches
/// nothing is the mutant that survived the last time this file's
/// sibling was written.
void main() {
  Map<String, dynamic> expense({
    String status = 'posted',
    String? entry = 'jv-1',
  }) => {
    'id': 'e1',
    'expense_no': 'EXP-2026-00001',
    'expense_date': '2026-09-03',
    'description': 'Lalamove',
    'amount': '22.50',
    'total_amount': '22.50',
    'status': status,
    'gl_entry_id': entry,
    'accounts': {'code': '6250', 'name': 'Transport and Travelling'},
  };

  Widget wrap(_FakeRepo repo, List<Map<String, dynamic>> rows) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      expensesProvider.overrideWith((ref) async => rows),
      canPostProvider.overrideWithValue(true),
      canWriteProvider.overrideWithValue(true),
      attachmentsProvider.overrideWith((ref, arg) async => []),
      expenseSplitProvider.overrideWith((ref, arg) async => []),
      paymentModesProvider.overrideWith((ref) async => []),
      ocrStatusProvider.overrideWith((ref) async => OcrSettings.off),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ExpensesScreen(),
    ),
  );

  Future<void> openDetail(
    WidgetTester tester,
    _FakeRepo repo, {
    String status = 'posted',
    String? entry = 'jv-1',
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(repo, [expense(status: status, entry: entry)]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lalamove').first);
    await tester.pumpAndSettle();
  }

  testWidgets('a posted expense offers to reverse itself', (tester) async {
    await openDetail(tester, _FakeRepo());
    expect(find.byKey(const ValueKey('reverse-expense')), findsOneWidget);
  });

  testWidgets('a draft does not, because it has no journal to contra',
      (tester) async {
    // Offering to reverse nothing is offering a refusal — the same rule
    // the group headings are dropped from the account picker under.
    await openDetail(tester, _FakeRepo(), status: 'draft', entry: null);
    expect(find.byKey(const ValueKey('reverse-expense')), findsNothing);
  });

  testWidgets('and reversing contras the expense own journal, on the day it '
      'was spent', (tester) async {
    final repo = _FakeRepo();
    await openDetail(tester, repo);

    await tester.tap(find.byKey(const ValueKey('reverse-expense')));
    await tester.pumpAndSettle();

    // Accept whatever day the picker opened on. Which day that was is
    // asserted at the bottom, off the call the repository actually
    // received — `find.text('3')` would have matched the cell labelled
    // 3 in any month, and proved nothing while looking like proof.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // And says what will happen before it happens. NOT "marks the
    // original void", which is what the journal screen said and what
    // `0102` stopped doing: the original stands, and an accountant
    // deciding whether to press this needs to know that.
    expect(find.textContaining('come to nothing'), findsOneWidget);
    expect(find.textContaining('stays on the list'), findsOneWidget);
    expect(find.textContaining('void'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Reverse'));
    await tester.pumpAndSettle();

    expect(repo.reversed, isNotNull,
        reason: 'nothing was reversed, so nothing was asserted');
    expect(repo.reversed!.entryId, 'jv-1');
    expect(repo.reversed!.on, DateTime(2026, 9, 3));
  });
}

class _FakeRepo implements Repo {
  ({String entryId, DateTime on})? reversed;

  @override
  String get orgId => 'org-1';

  @override
  Future<void> reverseJournal(String entryId, DateTime on) async {
    reversed = (entryId: entryId, on: on);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}
