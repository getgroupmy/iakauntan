// =====================================================================
// iAkauntan :: Bank statements -- the front door
//
//   flutter test test/bank_statements_screen_test.dart
//
// Importing a bank statement has worked since `0157` and nothing said
// so. It was an unlabelled `upload_file_outlined` in the app bar of the
// Reconcile screen, disabled until an account was picked, and somebody
// who had not found it had no way to know the product could take a
// statement at all.
//
// This screen is the door. It deliberately imports NOTHING: the parse,
// the balance chain, the duplicate skip and the closing balance all
// live on Reconcile and work, and a second copy of them would be a
// second set of answers to drift. So what is worth asserting here is
// not arithmetic -- it is the handoff, and the handoff is where this
// can go quietly wrong.
//
// THE ACCOUNT TRAVELS WITH THE PRESS. Somebody who pressed Upload
// beside Maybank means Maybank. If the link drops `?account=`, the
// import still opens, still parses, still succeeds -- into whichever
// account sorts first. That is a statement imported into the wrong
// bank, reported to the person as a success, and found weeks later
// when neither account reconciles.
//
// AND A STATEMENT READ IS NOT A STATEMENT IMPORTED. The list below
// shows both, and says which is which, because the one that matters is
// the photograph that was read and then never brought in -- which
// until now was invisible everywhere.
// =====================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/banking/bank_statements_screen.dart';

void main() {
  const accounts = [
    {
      'id': 'b1',
      'name': 'Maybank Current',
      'bank_name': 'Maybank',
      'account_number': '5140 1234',
      'current_balance': 12500.0,
    },
    {
      'id': 'b2',
      'name': 'CIMB Savings',
      'bank_name': 'CIMB Bank',
      'account_number': '7011 9987',
      'current_balance': 840.5,
    },
  ];

  ScanInboxEntry scan({
    required String id,
    String? kind,
    String? table,
    String? postedId,
    String? file,
  }) => ScanInboxEntry(
    scanId: id,
    scannedAt: DateTime(2026, 3, 4, 9, 30),
    fileName: file,
    provider: 'gemini',
    documentKind: kind,
    postedTable: table,
    postedId: postedId,
  );

  // Where the Upload button actually sent the person, in order.
  late List<String> went;

  // Which filter the list asked the inbox for. `all`, because a
  // statement read and never imported is the whole point of showing
  // the list, and `posted` would hide exactly that one.
  late List<String> asked;

  Widget wrap({
    List<Map<String, dynamic>> banks = accounts,
    List<ScanInboxEntry> inbox = const [],
    String role = 'owner',
  }) {
    went = [];
    asked = [];
    final router = GoRouter(
      initialLocation: '/bank-statements',
      routes: [
        GoRoute(
          path: '/bank-statements',
          builder: (_, _) => const BankStatementsScreen(),
        ),
        // Stands in for the Reconcile screen, so the test reads the
        // address rather than the screen behind it. What Reconcile
        // then DOES with those parameters is asserted in
        // reconciliation_screen_test.dart.
        GoRoute(
          path: '/reconcile',
          builder: (_, state) {
            went.add(state.uri.toString());
            return const Scaffold(body: Text('the reconcile screen'));
          },
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        bankAccountsProvider.overrideWith((ref) async => banks),
        scanInboxProvider.overrideWith((ref, only) async {
          asked.add(only);
          return inbox;
        }),
        memberRoleProvider.overrideWith((ref) async => role),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> show(
    WidgetTester tester, {
    List<Map<String, dynamic>> banks = accounts,
    List<ScanInboxEntry> inbox = const [],
    String role = 'owner',
  }) async {
    // Two accounts and a list beneath them do not fit 800x600, and a
    // `RenderFlex` overflow is a failure here while a release build
    // simply clips it. See docs/widget-tests.md.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(banks: banks, inbox: inbox, role: role));
    await tester.pumpAndSettle();
  }

  group('the account travels with the press', () {
    testWidgets('Upload opens the import on the account it sits beside',
        (tester) async {
      await show(tester);

      await tester.tap(find.byKey(const ValueKey('bank-statement-upload-b2')));
      await tester.pumpAndSettle();

      // Both halves. The account, or the statement lands in the wrong
      // bank; the import, or the person arrives at a reconciliation
      // screen and has to find the unlabelled icon after all.
      expect(went, ['/reconcile?account=b2&import=1']);
    });

    testWidgets('the other account is the other account', (tester) async {
      await show(tester);

      await tester.tap(find.byKey(const ValueKey('bank-statement-upload-b1')));
      await tester.pumpAndSettle();

      expect(went, ['/reconcile?account=b1&import=1']);
    });

    testWidgets('the row itself opens the account without the import',
        (tester) async {
      // Somebody who wants to LOOK at an account gets the account, not
      // a file picker over the top of it.
      await show(tester);

      await tester.tap(find.text('CIMB Savings'));
      await tester.pumpAndSettle();

      expect(went, ['/reconcile?account=b2']);
    });
  });

  group('who is offered it', () {
    testWidgets('a clerk who cannot post is not offered Upload',
        (tester) async {
      // Hidden rather than greyed. A disabled button is a question the
      // screen will not answer; the row still opens, because reading a
      // reconciliation is not posting to it.
      await show(tester, role: 'clerk');

      expect(
        find.byKey(const ValueKey('bank-statement-upload-b1')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('bank-statement-account-b1')),
          findsOneWidget);
    });

    testWidgets('an owner is', (tester) async {
      await show(tester);

      expect(
        find.byKey(const ValueKey('bank-statement-upload-b1')),
        findsOneWidget,
      );
    });
  });

  group('what the screen says when there is nothing', () {
    testWidgets('no bank account says where one comes from', (tester) async {
      await show(tester, banks: const []);

      expect(find.text('No bank account yet'), findsOneWidget);
      // And not the "nothing read" message, which would be answering a
      // question nobody can reach yet.
      expect(find.byKey(const ValueKey('bank-statement-upload-b1')),
          findsNothing);
    });

    testWidgets('nothing read yet says so', (tester) async {
      await show(tester);

      expect(find.text('Nothing read yet'), findsOneWidget);
    });
  });

  group('a statement read is not a statement imported', () {
    testWidgets('one that was brought in, and one that was not',
        (tester) async {
      await show(
        tester,
        inbox: [
          scan(
            id: 's1',
            file: 'cimb-jan.pdf',
            kind: 'bank_statement',
            table: 'bank_transactions',
            postedId: 'x1',
          ),
          scan(id: 's2', file: 'maybank-feb.jpg', kind: 'bank_statement'),
        ],
      );

      expect(find.text('cimb-jan.pdf'), findsOneWidget);
      expect(find.text('maybank-feb.jpg'), findsOneWidget);

      // Inside the row each belongs to, not anywhere on the screen.
      // Both labels appear exactly once whichever way round they are,
      // so counting them proves nothing -- swapping them was a mutant
      // that survived being counted.
      Finder inRow(String id, String text) => find.descendant(
            of: find.byKey(ValueKey('bank-statement-scan-$id')),
            matching: find.textContaining(text),
          );

      expect(inRow('s1', '· brought in'), findsOneWidget);
      // The second is the one this screen exists to surface: read,
      // sitting there, never imported, and until now shown nowhere.
      expect(inRow('s2', '· not brought in yet'), findsOneWidget);
    });

    testWidgets('a scan that is not a statement stays out of the list',
        (tester) async {
      await show(
        tester,
        inbox: [
          scan(
            id: 's3',
            file: 'tnb-bill.jpg',
            kind: 'purchase_invoice',
            table: 'purchase_documents',
            postedId: 'p1',
          ),
        ],
      );

      expect(find.text('tnb-bill.jpg'), findsNothing);
      expect(find.text('Nothing read yet'), findsOneWidget);
    });

    testWidgets('the list asks for everything, not just what was posted',
        (tester) async {
      await show(tester);

      // `posted` would hide the unimported statement, which is the one
      // worth seeing.
      expect(asked, contains('all'));
      expect(asked, isNot(contains('posted')));
    });
  });

  group('whether a scan is a statement', () {
    ScanInboxEntry e({String? kind, String? table}) =>
        scan(id: 'x', kind: kind, table: table);

    test('filed into bank_transactions, whatever it was called', () {
      expect(isBankStatementScan(e(table: 'bank_transactions')), isTrue);
    });

    test('or named as one and not yet filed anywhere', () {
      expect(isBankStatementScan(e(kind: 'bank_statement')), isTrue);
    });

    test('a purchase invoice is neither', () {
      expect(
        isBankStatementScan(
          e(kind: 'purchase_invoice', table: 'purchase_documents'),
        ),
        isFalse,
      );
    });

    test('and a scan that became nothing and was never named is neither', () {
      expect(isBankStatementScan(e()), isFalse);
    });
  });
}
