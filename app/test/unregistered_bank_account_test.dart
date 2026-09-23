import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/banking/new_bank_account_dialog.dart';

/// A bank account on the chart, and nowhere else.
///
/// From a report, 23/09/2026: "BANK ACCOUNT NOT SHOWING — under
/// Collection from customer, drop list for bank account, the added bank
/// account (sub account)".
///
/// Nothing was broken, which is why it needed fixing. A bank account
/// here is TWO records: an `accounts` row where the money sits, and a
/// `bank_accounts` row that pickers list and reconciliations run
/// against. `upsert_bank_account` makes both. Adding a sub-account
/// under Bank on the chart of accounts makes only the first — so the
/// account exists, money can be posted to it, and every bank dropdown
/// in the product is right never to mention it.
///
/// The fix OFFERS rather than decides, and that distinction is what
/// these assert. A `bank_accounts` row carries the bank, the number,
/// the kind, and whether it is a CLIENT account — which for a solicitor
/// is a statutory distinction, not a label. Creating one automatically
/// would invent all four.
void main() {
  Map<String, dynamic> waiting({
    String id = 'acct-1',
    String code = '1131',
    String name = 'Maybank Client Account',
  }) =>
      {'account_id': id, 'code': code, 'name': name, 'balance': 0};

  Widget wrap(
    List<Map<String, dynamic>> unregistered, {
    Repo? repo,
  }) =>
      ProviderScope(
        overrides: [
          unregisteredBankAccountsProvider
              .overrideWith((ref) async => unregistered),
          if (repo != null) repoProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: NewBankAccountDialog()),
        ),
      );

  Future<void> show(
    WidgetTester tester,
    List<Map<String, dynamic>> unregistered, {
    Repo? repo,
  }) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(unregistered, repo: repo));
    await tester.pumpAndSettle();
  }

  testWidgets('the account added on the chart is offered by name',
      (tester) async {
    // The report, exactly. Somebody added 1131 on the chart and could
    // not find it anywhere; now the one screen that could do something
    // about it says so.
    await show(tester, [waiting()]);

    expect(find.text('Already on your chart'), findsOneWidget);
    expect(find.text('1131 — Maybank Client Account'), findsOneWidget);
    expect(find.text('Register'), findsOneWidget);
  });

  testWidgets('and nothing is drawn when none are waiting', (tester) async {
    // The ordinary case. A heading over an empty list is a screen
    // saying something is unfinished when nothing is.
    await show(tester, const []);

    expect(find.text('Already on your chart'), findsNothing);
    expect(find.text('Register'), findsNothing);
  });

  testWidgets('registering one says so, and names which', (tester) async {
    await show(tester, [waiting()]);
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    // The sentence at the top of the form promises a chart account will
    // be opened. Once one is being adopted that promise is false, and a
    // person who left it on screen would reasonably expect a second
    // account to appear on the balance sheet.
    expect(find.textContaining('Registering 1131'), findsOneWidget);
    expect(
      find.textContaining('No new chart account is opened'),
      findsOneWidget,
    );
    expect(find.textContaining('opened for it automatically'), findsNothing);
  });

  testWidgets('and the name is taken from the chart, not retyped',
      (tester) async {
    await show(tester, [waiting()]);
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    // Retyping a name that is already on the chart is how two records
    // for one account end up called different things on two screens.
    final name = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, 'Name'),
    );
    expect(name.controller?.text, 'Maybank Client Account');
  });

  testWidgets('and it can be undone without leaving the form',
      (tester) async {
    // Somebody who pressed Register on the wrong line must not have to
    // close the dialog and lose what they typed.
    await show(tester, [waiting()]);
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chart-account-clear')));
    await tester.pumpAndSettle();

    expect(find.textContaining('opened for it automatically'), findsOneWidget);
    expect(find.text('1131 — Maybank Client Account'), findsOneWidget);
  });

  testWidgets('two waiting accounts are both offered', (tester) async {
    await show(tester, [
      waiting(),
      waiting(id: 'acct-2', code: '1132', name: 'Petty cash'),
    ]);

    expect(find.text('1131 — Maybank Client Account'), findsOneWidget);
    expect(find.text('1132 — Petty cash'), findsOneWidget);
    expect(find.text('Register'), findsNWidgets(2));
  });

  /// And that the chosen account actually reaches the save.
  ///
  /// The assertion the mutation sweep demanded, and the one whose
  /// absence would be worst: with the id dropped on the way out,
  /// pressing Register opens a SECOND chart account beside the one
  /// somebody was trying to adopt. That is a worse outcome than the
  /// bug this fixes — the original report was a missing entry, this
  /// would be a duplicated one, and nothing on screen would say so.
  testWidgets('the chosen chart account is what gets registered',
      (tester) async {
    final repo = _FakeRepo();
    await show(tester, [waiting()], repo: repo);

    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create and use'));
    await tester.pumpAndSettle();

    expect(repo.sentAccountId, 'acct-1');
    expect(repo.sentName, 'Maybank Client Account');
  });

  testWidgets('and an ordinary new account sends none, so one is opened',
      (tester) async {
    // The other direction, and the reason `accountId` cannot simply be
    // set always: a null is what makes `upsert_bank_account` open an
    // account in the bank range and number it, which is the path every
    // company that has nothing waiting still takes.
    final repo = _FakeRepo();
    await show(tester, const [], repo: repo);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'CIMB current',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create and use'));
    await tester.pumpAndSettle();

    expect(repo.sentName, 'CIMB current');
    expect(repo.sentAccountId, isNull);
  });
}

/// Only the save. `upsertBankAccount` is on the Repo CLASS rather than
/// on one of its extensions, so a double can intercept it — see
/// docs/widget-tests.md for the half of the surface where it cannot.
class _FakeRepo implements Repo {
  String? sentName;
  String? sentAccountId;
  bool called = false;

  @override
  String get orgId => 'org-1';

  @override
  Future<String> upsertBankAccount({
    required String name,
    String? bankName,
    String? bankCode,
    String? accountNumber,
    String accountType = 'current',
    String currency = 'MYR',
    String? accountId,
    String? id,
  }) async {
    called = true;
    sentName = name;
    sentAccountId = accountId;
    return 'bank-1';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'the dialog called Repo.${invocation.memberName}, which this fake '
        'does not answer',
      );
}
