import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/legal/client_transfer_screen.dart';

/// Moving a client's balance to their other matter, with a page of its
/// own.
///
/// `0358` built the movement and left the matter screen as the only way
/// in — behind the matter you had already navigated to. The balance
/// belongs to a CLIENT, and the person moving it is working from the
/// client's name.
///
/// The decision this screen has to get right is the statutory one, and
/// it is silent when wrong: money held for one client may not be
/// applied for another. `0358` refuses it at the server and names both
/// clients doing so — but a list that cannot contain the wrong answer
/// is better than a refusal after the fact, and a destination picker
/// that quietly offered every open matter would make the breach one
/// mistyped number away, in a list where both are open.
void main() {
  Matter matter({
    required String id,
    required String no,
    required String client,
    String name = 'Sale of a house',
  }) =>
      Matter(
        id: id,
        matterNo: no,
        name: name,
        clientId: client,
        status: 'open',
        clientName: 'Client $client',
      );

  final hers = [
    matter(id: 'm-1', no: 'M-1', client: 'c-1', name: 'A conveyance'),
    matter(id: 'm-2', no: 'M-2', client: 'c-1', name: 'A tenancy'),
    // Somebody else's, and the one that must never be offered.
    matter(id: 'm-9', no: 'M-9', client: 'c-9', name: 'Another client'),
  ];

  Widget wrap({
    List<Map<String, dynamic>> rows = const [],
    Map<String, double> held = const {'m-1': 5000, 'm-2': 3000},
    bool canPost = true,
  }) =>
      ProviderScope(
        overrides: [
          canPostProvider.overrideWithValue(canPost),
          clientTransfersProvider.overrideWith((ref) async => rows),
          matterClientBalancesProvider.overrideWith((ref) async => held),
          mattersProvider.overrideWith(
            (ref, arg) async => arg.status == 'open' ? hers : <Matter>[],
          ),
          matterSummaryProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ClientTransferScreen(),
        ),
      );

  Future<void> onAPhone(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(412, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('client-transfer-new')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key, String option) async {
    await tester.tap(find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(TextFormField),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('the page says nothing has moved yet', (tester) async {
    await onAPhone(tester, wrap());
    expect(find.text('Moved between matters'), findsOneWidget);
    expect(find.text('Nothing moved between matters yet'), findsOneWidget);
  });

  testWidgets('and lists both legs of one that has', (tester) async {
    // Both, rather than one row per pair. That is what the client
    // ledger holds, and folding them would show something the ledger
    // does not say.
    await onAPhone(
      tester,
      wrap(rows: [
        {
          'id': 't-1',
          'amount': -2000,
          'description': 'Balance follows the client',
          'matters': {
            'matter_no': 'M-1',
            'name': 'A conveyance',
            'contacts': {'name': 'Puan Aminah'},
          },
        },
        {
          'id': 't-2',
          'amount': 2000,
          'description': 'Balance follows the client',
          'matters': {
            'matter_no': 'M-2',
            'name': 'A tenancy',
            'contacts': {'name': 'Puan Aminah'},
          },
        },
      ]),
    );
    expect(find.textContaining('M-1'), findsOneWidget);
    expect(find.textContaining('M-2'), findsOneWidget);
  });

  testWidgets('somebody who may not post is not offered the button',
      (tester) async {
    await onAPhone(tester, wrap(canPost: false));
    expect(find.byKey(const ValueKey('client-transfer-new')), findsNothing);
  });

  // The assertion this file exists for.
  testWidgets('the destination is the same client’s matters only',
      (tester) async {
    await onAPhone(tester, wrap());
    await openDialog(tester);
    await choose(tester, 'transfer-from', 'M-1 · A conveyance');

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('transfer-to')),
      matching: find.byType(TextFormField),
    ));
    await tester.pumpAndSettle();

    // Her other matter is there.
    expect(find.text('M-2 · A tenancy'), findsOneWidget);
    // Another client's is NOT, and this is the breach the Legal
    // Profession (Accounts) Rules are about rather than a tidy list.
    expect(find.text('M-9 · Another client'), findsNothing);
  });

  // An equivalent mutant lives here, and it is worth naming so the next
  // sweep does not spend an afternoon on it: deleting `_toId = null`
  // from the source picker survives these assertions, because the
  // cross-client check added beside it refuses the same pair. The two
  // are belt and braces and either alone keeps the money right.
  //
  // What differs is only what the person sees — a To field cleared and
  // waiting, versus one still showing a matter with a red line under
  // it — and a widget test cannot read a `SearchablePicker`'s displayed
  // value to tell them apart. The behaviour that MATTERS is asserted
  // twice over.
  testWidgets('and changing the source clears a destination', (tester) async {
    // Otherwise a source picked second keeps a destination chosen
    // against the first — which is the one arrangement this screen
    // exists to make impossible.
    await onAPhone(tester, wrap());
    await openDialog(tester);
    await choose(tester, 'transfer-from', 'M-1 · A conveyance');
    await choose(tester, 'transfer-to', 'M-2 · A tenancy');
    expect(find.byKey(const ValueKey('transfer-blurb')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('transfer-amount')),
      '1000',
    );
    await tester.pumpAndSettle();
    await choose(tester, 'transfer-from', 'M-9 · Another client');

    // With an amount already typed, "enter an amount" cannot be what
    // stops it — so if the destination were kept, the only thing left
    // between this and a cross-client transfer is the client check.
    // Both have to hold, and the message has to name the clients.
    final blocked = find.byKey(const ValueKey('transfer-blocked'));
    expect(blocked, findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('transfer-save')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('what the matter holds is shown against the source',
      (tester) async {
    await onAPhone(tester, wrap());
    await openDialog(tester);
    await choose(tester, 'transfer-from', 'M-1 · A conveyance');
    expect(find.byKey(const ValueKey('transfer-held')), findsOneWidget);
    expect(find.textContaining('5,000'), findsWidgets);
  });

  testWidgets('more than is held cannot be moved', (tester) async {
    // `app.assert_client_funds` refuses this and is the real defence.
    // The point here is that the refusal arrives while the field is
    // still in front of them, naming which of the two numbers is the
    // problem.
    await onAPhone(tester, wrap());
    await openDialog(tester);
    await choose(tester, 'transfer-from', 'M-1 · A conveyance');
    await choose(tester, 'transfer-to', 'M-2 · A tenancy');

    // More than M-1 holds, and LESS than every matter holds together:
    // 5,000 here against 8,000 across both. A check reading the total
    // would wave this through, which is one client's money funding
    // another's payment — the breach itself.
    await tester.enterText(
      find.byKey(const ValueKey('transfer-amount')),
      '6000',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('transfer-blocked')), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('transfer-save')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('and an amount within it can', (tester) async {
    await onAPhone(tester, wrap());
    await openDialog(tester);
    await choose(tester, 'transfer-from', 'M-1 · A conveyance');
    await choose(tester, 'transfer-to', 'M-2 · A tenancy');
    await tester.enterText(
      find.byKey(const ValueKey('transfer-amount')),
      '2000',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('transfer-blocked')), findsNothing);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('transfer-save')),
    );
    expect(button.onPressed, isNotNull);
  });
}
