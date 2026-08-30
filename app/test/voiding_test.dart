import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/banking/transfers_history_dialog.dart';
import 'package:iakauntan/src/features/documents/deposits_screen.dart';
import 'package:iakauntan/src/features/documents/void_document.dart';

void main() {
  group('voiding a sales document', () {
    String? blocked({
      String status = 'posted',
      num paid = 0,
      String? einvoice = 'not_applicable',
    }) =>
        voidBlockedBecause(
          status: status,
          paidAmount: paid,
          einvoiceStatus: einvoice,
        );

    test('a posted invoice nobody has paid can go', () {
      expect(blocked(), isNull);
    });

    test('not one already void', () {
      expect(blocked(status: 'void'), contains('already void'));
    });

    test('a draft is discarded, not voided', () {
      // There is nothing to reverse, and void_sales_document would
      // leave a 'void' document that never reached the ledger.
      expect(blocked(status: 'draft'), contains('Discard'));
    });

    test('not once money has been received against it', () {
      // "Cannot void %: payments have been applied"
      expect(blocked(paid: 0.01), contains('receipt'));
      expect(blocked(status: 'partial', paid: 500), contains('receipt'));
    });

    test('not once LHDN has accepted the e-Invoice', () {
      // "Cannot void %: cancel the e-Invoice with LHDN first"
      expect(blocked(einvoice: 'valid'), contains('LHDN'));
    });

    test('an e-Invoice that was only submitted does not block it', () {
      // Only 'valid' is what LHDN has accepted. A submission that is
      // still pending, or one that was rejected, is not.
      expect(blocked(einvoice: 'submitted'), isNull);
      expect(blocked(einvoice: 'rejected'), isNull);
      expect(blocked(einvoice: null), isNull);
    });

    test('a payment blocks it even when the e-Invoice is fine', () {
      // The order the reasons are tested in decides which sentence is
      // read, and the receipt is the one somebody can act on.
      expect(blocked(paid: 100, einvoice: 'valid'), contains('receipt'));
    });
  });

  group('discarding', () {
    test('only a draft', () {
      expect(canDiscard('draft'), isTrue);
      expect(canDiscard('posted'), isFalse);
      expect(canDiscard('partial'), isFalse);
      expect(canDiscard('paid'), isFalse);
      expect(canDiscard('void'), isFalse);
    });
  });

  group('voiding a deposit', () {
    Map<String, dynamic> note({
      String status = 'open',
      num amount = 1000,
      num? balance,
    }) => <String, dynamic>{
      'deposit_no': 'DEP-0001',
      'status': status,
      'amount': amount,
      'balance': balance ?? amount,
    };

    test('an untouched deposit can go', () {
      expect(depositVoidBlockedBecause(note()), isNull);
    });

    test('not one already void', () {
      expect(
        depositVoidBlockedBecause(note(status: 'void')),
        contains('already void'),
      );
    });

    test('not once any of it has been used', () {
      // "Deposit % has already been used... Undo those first."
      expect(
        depositVoidBlockedBecause(note(amount: 1000, balance: 999.99)),
        contains('Undo'),
      );
      expect(
        depositVoidBlockedBecause(note(amount: 1000, balance: 0)),
        contains('Undo'),
      );
    });

    test('the numbers may arrive as strings and still compare', () {
      // deposit_notes_list returns numerics, which come across JSON as
      // whichever of num or String the driver felt like.
      expect(
        depositVoidBlockedBecause(<String, dynamic>{
          'status': 'open',
          'amount': '1000.00',
          'balance': '1000.00',
        }),
        isNull,
      );
      expect(
        depositVoidBlockedBecause(<String, dynamic>{
          'status': 'open',
          'amount': '1000.00',
          'balance': '400.00',
        }),
        contains('Undo'),
      );
    });
  });

  group('voiding a transfer', () {
    test('anything but an already void one', () {
      // Money moved between two accounts of the same company has no
      // customer who might have paid against it, so there is no later
      // state that stops it being undone.
      expect(transferIsVoidable('posted'), isTrue);
      expect(transferIsVoidable('draft'), isTrue);
      expect(transferIsVoidable('void'), isFalse);
    });
  });

  group('what a transfer reads as', () {
    Map<String, dynamic> transfer({
      num sent = 5000,
      num? received,
      num charges = 0,
      String from = 'MYR',
      String to = 'MYR',
    }) => <String, dynamic>{
      'from_account': {'name': 'Maybank current', 'currency': from},
      'to_account': {'name': 'CIMB savings', 'currency': to},
      'amount_sent': sent,
      'amount_received': received ?? sent,
      'bank_charges': charges,
    };

    test('names both ends', () {
      expect(transferRoute(transfer()), 'Maybank current → CIMB savings');
    });

    test('survives an account that came back without a name', () {
      expect(
        transferRoute(<String, dynamic>{}),
        '— → —',
      );
    });

    test('one figure when nothing was lost on the way', () {
      expect(transferAmounts(transfer()), 'RM 5,000.00');
    });

    test('both figures once they differ', () {
      final s = transferAmounts(transfer(sent: 5000, received: 4980));
      expect(s, contains('RM 5,000.00'));
      expect(s, contains('RM 4,980.00 arrived'));
    });

    test('the charge is named, since it is why they differ', () {
      final s =
          transferAmounts(transfer(sent: 5000, received: 4980, charges: 20));
      expect(s, contains('RM 20.00 charges'));
    });

    test('a charge with no shortfall is still stated', () {
      // The bank can take its fee out of the sending account
      // separately, and it is still money gone.
      final s = transferAmounts(transfer(sent: 5000, charges: 20));
      expect(s, contains('RM 20.00 charges'));
      expect(s, isNot(contains('arrived')));
    });

    test('each end is in its own money', () {
      // A transfer out to a Singapore account: RM went out, SGD
      // arrived, and one prefix on both would misstate one of them.
      final s = transferAmounts(
        transfer(sent: 5000, received: 1480, charges: 30, to: 'SGD'),
      );
      expect(s, contains('RM 5,000.00'));
      expect(s, contains('SGD 1,480.00 arrived'));
      // The fee follows the sending account.
      expect(s, contains('RM 30.00 charges'));
    });

    test('equal figures in different currencies are still both shown', () {
      // 1,000 out and 1,000 in is a coincidence of numbers, not one
      // amount, and collapsing it would read as a transfer that lost
      // nothing.
      final s = transferAmounts(transfer(sent: 1000, received: 1000, to: 'SGD'));
      expect(s, contains('RM 1,000.00'));
      expect(s, contains('SGD 1,000.00 arrived'));
    });

    test('a missing currency is taken as ringgit, as the column is', () {
      final s = transferAmounts(<String, dynamic>{
        'amount_sent': 100,
        'amount_received': 100,
        'bank_charges': 0,
      });
      expect(s, 'RM 100.00');
    });
  });
}
