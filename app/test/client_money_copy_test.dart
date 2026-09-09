import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/client_money_copy.dart';

/// The words on the receipt screen when the money is somebody else's.
///
/// A solicitor taking a cheque has to know which of two accounts it is
/// going into before pressing anything, and the two accounts are the
/// whole of the Solicitors' Accounts Rules 1990. The rules themselves
/// are the database's (0021, 0549) and are asserted in
/// `supabase/tests/client_money_crossing.sql`. What is asserted here is
/// that the screen says which is which — because a firm that meets the
/// rules by accident will stop meeting them the first time somebody is
/// in a hurry.
void main() {
  group('where money coming in goes', () {
    test('each choice is named by the account, not by the paperwork', () {
      expect(receiptDestinationLabel(ReceiptDestination.office),
          contains('office account'));
      expect(receiptDestinationLabel(ReceiptDestination.onAccount),
          contains('client account'));
      expect(receiptDestinationLabel(ReceiptDestination.fromClientAccount),
          contains('already held'));
    });

    test('money on account is said not to be income', () {
      // The mistake this sentence exists to prevent: banking a client's
      // deposit as a fee received, which is both a false profit and a
      // breach.
      final hint = receiptDestinationHint(ReceiptDestination.onAccount);
      expect(hint, contains('not income'));
      expect(hint, contains('settles nothing'));
      expect(hint, contains('client’s'));
    });

    test('and the transfer says the money moves between both accounts', () {
      final hint =
          receiptDestinationHint(ReceiptDestination.fromClientAccount);
      expect(hint, contains('leaves the client account'));
      expect(hint, contains('office'));
    });
  });

  group('where money going out comes from', () {
    test('the two sources are named', () {
      expect(paymentSourceLabel(PaymentSource.office), contains('office'));
      expect(paymentSourceLabel(PaymentSource.clientAccount),
          contains('client account'));
    });

    test('paying out of client money says whose behalf it is on', () {
      expect(paymentSourceHint(PaymentSource.clientAccount),
          contains('on the client’s behalf'));
    });
  });

  group('what the matter holds', () {
    test('a balance is money', () {
      expect(matterBalanceLine(2500), contains('RM 2,500.00'));
      expect(matterBalanceLine(2500), contains('client account'));
    });

    test('nothing held is said in words', () {
      // "RM 0.00 held" is a number somebody has to read twice. The
      // question being asked is "can I pay this out of it".
      expect(matterBalanceLine(0), 'Nothing is held for this matter.');
      expect(matterBalanceLine(0), isNot(contains('RM')));
    });
  });

  group('the warning before the server’s', () {
    test('there is none while the amount is within the balance', () {
      expect(overdrawWarning(held: 1000, amount: 1000), isNull);
      expect(overdrawWarning(held: 1000, amount: 999.99), isNull);
    });

    test('paying out exactly the balance is not a warning', () {
      // The last payment on a matter is always the exact one: the
      // balance goes back to the client and the ledger closes at zero.
      // A warning here would read as a refusal, and the database
      // allows it.
      expect(overdrawWarning(held: 750.25, amount: 750.25), isNull);
    });

    test('a sen over is', () {
      final warning = overdrawWarning(held: 1000, amount: 1000.01)!;
      expect(warning, contains('RM 1,000.00'));
      // The rule, not just the arithmetic. Somebody who reads only this
      // line should learn why it is refused.
      expect(warning, contains('cannot fund another'));
    });
  });

  group('what it says afterwards', () {
    test('each path is confirmed as the thing that happened', () {
      expect(receiptDone(ReceiptDestination.office), contains('Receipt'));
      expect(receiptDone(ReceiptDestination.onAccount),
          contains('client account'));
      expect(receiptDone(ReceiptDestination.fromClientAccount),
          contains('bill settled'));
      expect(paymentDone(PaymentSource.clientAccount),
          contains('client account'));
    });
  });
}
