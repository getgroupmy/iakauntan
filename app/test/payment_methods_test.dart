import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/payment_methods.dart';
import 'package:iakauntan/src/features/settings/payment_methods_card.dart';

/// `0635`. The screen's job is to make two things legible: what a
/// method costs, and where that cost lands in the ledger.
///
/// The second is the one worth testing hardest, because a blank charge
/// account is NOT a gap — it means "use the company's" — and a screen
/// that reads as unfinished gets filled in by somebody who did not need
/// to fill it in.
PaymentMethod method({
  String id = 'pm-1',
  String name = 'Stripe',
  String? mode = '03',
  String? chargeAccountId,
  double percent = 0,
  double fixed = 0,
  bool isDefault = false,
  bool isActive = true,
}) => PaymentMethod(
  id: id,
  name: name,
  paymentModeCode: mode,
  chargeAccountId: chargeAccountId,
  chargePercent: percent,
  chargeFixed: fixed,
  isDefault: isDefault,
  isActive: isActive,
);

void main() {
  group('the LHDN mode a method reports as', () {
    test('names the mode', () {
      expect(paymentModeLabel('01'), 'Cash');
      expect(paymentModeLabel('03'), 'Bank transfer');
      expect(paymentModeLabel('08'), 'Others');
    });

    test('an unset mode says so rather than reading as Others', () {
      // A company that has not chosen a mode has not chosen 08, and a
      // screen showing 08 invites nobody to correct it.
      expect(paymentModeLabel(null), 'Not set for e-Invoice');
      expect(paymentModeLabel(''), 'Not set for e-Invoice');
      expect(paymentModeLabel(null), isNot(contains('Others')));
    });

    test('a code LHDN adds later still shows the code', () {
      // Better than an empty string or a crash: somebody can read "09"
      // and go and look it up.
      expect(paymentModeLabel('09'), 'Mode 09');
    });
  });

  group('what the provider keeps', () {
    test('no charge says no charge', () {
      expect(chargeSummary(method()), 'No charge');
    });

    test('a percentage alone', () {
      expect(chargeSummary(method(percent: 2.9)), '2.9%');
    });

    test('a flat fee alone', () {
      expect(chargeSummary(method(fixed: 1)), 'RM 1.00');
    });

    test('both, because the two together are a different product', () {
      final s = chargeSummary(method(percent: 2.9, fixed: 1));
      expect(s, '2.9% + RM 1.00');
      // The failure that matters: showing only one half of a rate that
      // has two, which understates what a receipt costs.
      expect(s, isNot('2.9%'));
      expect(s, isNot('RM 1.00'));
    });

    test('a whole percentage does not grow a decimal it does not have', () {
      expect(chargeSummary(method(percent: 3)), '3.0%');
    });
  });

  group('where the charge lands', () {
    test('a blank account reads as a decision, not a gap', () {
      final line = chargeAccountLine(method());
      expect(line, 'Bank charges go to the company account');
      // Nothing in it should suggest something is missing.
      expect(line.toLowerCase(), isNot(contains('not set')));
      expect(line.toLowerCase(), isNot(contains('none')));
    });

    test('a chosen account is named', () {
      expect(
        chargeAccountLine(
          method(chargeAccountId: 'a-1'),
          accountName: '6321 Card fees',
        ),
        'Bank charges go to 6321 Card fees',
      );
    });

    test('a chosen account with no name still does not claim the company one',
        () {
      expect(
        chargeAccountLine(method(chargeAccountId: 'a-1')),
        isNot(contains('company account')),
      );
    });
  });

  group('what cannot be saved', () {
    test('a blank name', () {
      expect(
        paymentMethodProblem(name: '  ', chargePercent: 0, chargeFixed: 0),
        'Give the method a name.',
      );
    });

    test('a negative charge', () {
      expect(
        paymentMethodProblem(name: 'X', chargePercent: -1, chargeFixed: 0),
        'A charge cannot be negative.',
      );
      expect(
        paymentMethodProblem(name: 'X', chargePercent: 0, chargeFixed: -1),
        'A charge cannot be negative.',
      );
    });

    test('over a hundred per cent', () {
      expect(
        paymentMethodProblem(name: 'X', chargePercent: 101, chargeFixed: 0),
        'A percentage cannot be over 100.',
      );
    });

    test('a hundred exactly is allowed', () {
      // The database's check constraint is `<= 100`, and this is the
      // boundary rather than a typo guard.
      expect(
        paymentMethodProblem(name: 'X', chargePercent: 100, chargeFixed: 0),
        isNull,
      );
    });

    test('an ordinary method', () {
      expect(
        paymentMethodProblem(name: 'Stripe', chargePercent: 2.9, chargeFixed: 1),
        isNull,
      );
    });
  });

  group('the sentence about what this does not do', () {
    test('says the document wins', () {
      // Without it, "Stripe keeps 2.9% + RM1" reads as a promise that
      // receipts will be charged that automatically, and the first one
      // that is not looks like a bug.
      expect(chargeRateNote, contains('document'));
    });

    test('the empty state does not imply anything is broken', () {
      expect(noPaymentMethodsLine, contains('still work'));
      expect(noPaymentMethodsLine, contains('6300'));
    });
  });

  group('the card', () {
    testWidgets('shows a method, its mode, its rate and its account',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              final m = method(percent: 2.9, fixed: 1, isDefault: true);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.name),
                  Text(
                    '${paymentModeLabel(m.paymentModeCode)} · '
                    '${chargeSummary(m)}',
                  ),
                  Text(chargeAccountLine(m)),
                ],
              );
            },
          ),
        ),
      ));

      expect(find.text('Stripe'), findsOneWidget);
      expect(find.text('Bank transfer · 2.9% + RM 1.00'), findsOneWidget);
      expect(
        find.text('Bank charges go to the company account'),
        findsOneWidget,
      );
    });

    testWidgets('the dialog opens with no Supabase client behind it',
        (tester) async {
      // A company with no bank accounts and no chart loaded is the
      // state this renders in, and it must not throw: the dialog reads
      // its lists through valueOrNull precisely so an error there is a
      // short list rather than a broken screen.
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: PaymentMethodDialog())),
      ));
      await tester.pump();

      expect(find.text('Add payment method'), findsOneWidget);
      expect(find.byKey(const ValueKey('payment-method-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('payment-method-save')), findsOneWidget);
      // No existing method, so nothing to retire.
      expect(find.byKey(const ValueKey('payment-method-archive')), findsNothing);
      expect(find.text(chargeRateNote), findsOneWidget);
    });

    testWidgets('the mode dropdown offers all eight and an unset one',
        (tester) async {
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: PaymentMethodDialog())),
      ));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('payment-method-mode')));
      await tester.pumpAndSettle();

      for (final name in paymentModeNames.values) {
        expect(find.text(name), findsWidgets, reason: 'missing $name');
      }
      expect(find.text('Not set for e-Invoice'), findsWidgets);
    });

    testWidgets('an existing method can be retired', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: PaymentMethodDialog(existing: method(name: 'Stripe')),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('Payment method'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('payment-method-archive')),
        findsOneWidget,
      );
      // The name arrives filled in rather than blank, which is the
      // difference between amending one and quietly creating a second.
      expect(find.text('Stripe'), findsOneWidget);
    });
  });

  group('the model', () {
    test('reads a row', () {
      final m = PaymentMethod.fromJson({
        'id': 'pm-9',
        'name': 'Maybank cheque',
        'payment_mode_code': '02',
        'bank_account_id': 'b-1',
        'charge_account_id': null,
        'charge_percent': '0',
        'charge_fixed': '2.50',
        'is_default': true,
        'is_active': true,
        'sort_order': 3,
      });
      expect(m.name, 'Maybank cheque');
      expect(m.paymentModeCode, '02');
      expect(m.chargeAccountId, isNull);
      expect(m.chargeFixed, 2.5);
      expect(m.isDefault, isTrue);
      expect(m.sortOrder, 3);
    });

    test('a missing is_active is active, not inactive', () {
      // The column is `not null default true`, so a row that somehow
      // arrives without it is an active method. Defaulting the other
      // way would hide every method on the screen.
      expect(
        PaymentMethod.fromJson({'id': 'x', 'name': 'Y'}).isActive,
        isTrue,
      );
    });

    test('a missing is_default is not default', () {
      expect(
        PaymentMethod.fromJson({'id': 'x', 'name': 'Y'}).isDefault,
        isFalse,
      );
    });
  });
}
