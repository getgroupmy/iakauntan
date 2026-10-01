import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/cheques_screen.dart';
import 'package:iakauntan/src/features/documents/deposits_screen.dart';

/// The two forms that could not be saved before `0728` and now cannot
/// be saved without saying which account the money moved through.
///
/// `named_account_test.dart` asserts the sentences. This file asserts
/// the forms: that the box carries a star, that the button is dead
/// until an account is chosen, and that choosing one is the only thing
/// that was missing. Each case ends by ENABLING the button, because a
/// form that refuses everything satisfies "it refuses without an
/// account" and is useless — the same bargain `bank_accounts.sql`
/// makes in SQL by pairing every refusal with the write that must
/// still succeed.
///
/// The cheque dialog is the interesting one. `clear_pdc` takes the
/// account from the cheque when its caller names none, and the cheque
/// list calls it exactly that way — so recording is the ONLY place the
/// account can be asked for, and a cheque recorded without one could
/// never be cleared at all.
void main() {
  final banks = [
    {
      'id': 'bank-1',
      'name': 'Maybank current',
      'bank_name': 'Maybank',
      'account_number': '512345678901',
    },
  ];

  Contact customer() => Contact(
    id: 'c1',
    code: 'C-0001',
    name: 'Kedai Runcit Aminah',
    contactType: 'customer',
  );

  Contact supplier() => Contact(
    id: 's1',
    code: 'S-0001',
    name: 'Pembekal Jaya',
    contactType: 'supplier',
  );

  Widget wrap(Widget screen, List<Override> overrides) => ProviderScope(
    overrides: [
      bankAccountsProvider.overrideWith((ref) async => banks),
      contactsProvider((type: 'customer', search: '')).overrideWith(
        (ref) async => [customer()],
      ),
      contactsProvider((type: 'supplier', search: '')).overrideWith(
        (ref) async => [supplier()],
      ),
      ...overrides,
    ],
    child: MaterialApp(theme: AppTheme.light(), home: screen),
  );

  Future<void> onAPhone(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  /// Opens a `SearchablePicker` by its label and takes the named row.
  Future<void> pick(WidgetTester tester, String label, String row) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(row).last);
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, String label) =>
      tester
          .widget<ButtonStyleButton>(find.widgetWithText(FilledButton, label))
          .onPressed !=
      null;

  group('the deposit form', () {
    Future<void> openIt(WidgetTester tester) async {
      await onAPhone(
        tester,
        wrap(const DepositsScreen(), [
          depositNotesProvider((kind: null, status: null))
              .overrideWith((ref) async => []),
        ]),
      );
      await tester.tap(find.text('New deposit'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks for the account, with a star', (tester) async {
      await openIt(tester);
      expect(find.text('In or out of *'), findsOneWidget);
    });

    testWidgets('and will not record one without it', (tester) async {
      await openIt(tester);
      await pick(tester, 'From whom', 'Kedai Runcit Aminah');
      await tester.enterText(
        find.widgetWithText(TextField, 'How much'),
        '500',
      );
      await tester.pumpAndSettle();

      // Everything else about this deposit is complete: a party and an
      // amount are the whole of what the old form asked for.
      expect(enabled(tester, 'Record it'), isFalse);

      await pick(tester, 'In or out of *', 'Maybank current');
      expect(enabled(tester, 'Record it'), isTrue);
    });
  });

  group('the cheque form', () {
    Future<void> openIt(WidgetTester tester) async {
      await onAPhone(
        tester,
        wrap(const ChequesScreen(), [
          postDatedChequesProvider((direction: null, status: null))
              .overrideWith((ref) async => []),
          pdcMaturingProvider.overrideWith((ref) async => []),
          outstandingProvider.overrideWith((ref, args) async => []),
        ]),
      );
      await tester.tap(find.text('Record one'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks where it will be banked, with a star', (tester) async {
      await openIt(tester);
      expect(find.text('Where it will be banked *'), findsOneWidget);
    });

    testWidgets('and will not register one that could never clear',
        (tester) async {
      await openIt(tester);
      await pick(tester, 'From whom', 'Kedai Runcit Aminah');
      await tester.enterText(
        find.widgetWithText(TextField, 'Cheque number'),
        '123456',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'How much'),
        '2500',
      );
      await tester.pumpAndSettle();

      expect(enabled(tester, 'Record it'), isFalse);

      await pick(tester, 'Where it will be banked *', 'Maybank current');
      expect(enabled(tester, 'Record it'), isTrue);
    });
  });
}

/// ## One mutant that survives here, and why it is equivalent
///
/// Gutting the `depositAccountProblem` check inside `_DepositDialog._save`
/// — replacing it with a null so the snackbar can never fire — is not
/// noticed by anything in this file, and no assertion can notice it.
///
/// `_save` is reachable only through the Record-it button, and that
/// button is disabled while `_bank == null`, which IS asserted above.
/// So with the guard in place the inline check is unreachable by
/// construction: there is no path that calls `_save` with no account.
///
/// It is kept rather than deleted because the two are not the same
/// claim. The button guard says "this cannot be pressed yet"; the check
/// in `_save` says "and if it somehow is, nothing is written". The
/// second costs three lines and stops a future change to the button's
/// condition from quietly becoming a change to what gets posted.
///
/// The same reasoning applies to `_ChequeDialog._save`.
///
/// Recorded per the header of `scripts/mutate.py`.
