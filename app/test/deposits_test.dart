import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/deposits_screen.dart';

void main() {
  group('depositKind', () {
    test('says which way the money went', () {
      expect(depositKind('customer'), 'Held for a customer');
      expect(depositKind('supplier'), 'Paid to a supplier');
    });
  });

  group('depositSummary', () {
    test('an untouched deposit says so rather than repeating the figure', () {
      expect(
        depositSummary({
          'party': 'Puan Salmah',
          'amount': 10000,
          'balance': 10000,
        }),
        'Puan Salmah · RM 10,000.00 · untouched',
      );
    });

    test('a part-used one says what is left', () {
      expect(
        depositSummary({
          'party': 'Puan Salmah',
          'amount': 10000,
          'balance': 4000,
        }),
        'Puan Salmah · RM 10,000.00 · RM 4,000.00 left',
      );
    });

    test('and a settled one says nothing about a balance of nothing', () {
      // "RM 0.00 left" on every closed deposit is the line that trains
      // people to stop reading the ones that matter.
      expect(
        depositSummary({'party': 'Puan Salmah', 'amount': 10000, 'balance': 0}),
        'Puan Salmah · RM 10,000.00',
      );
    });
  });

  group('depositOutcome', () {
    test('is silent while nothing has happened to it', () {
      expect(
        depositOutcome({'applied': 0, 'refunded': 0, 'forfeited': 0}),
        isNull,
      );
    });

    test('separates what was used from what was given back', () {
      // "Settled" alone does not say whether she got her money back or
      // the company kept it, and those are different conversations.
      expect(
        depositOutcome({'applied': 9000, 'refunded': 1000, 'forfeited': 0}),
        'RM 9,000.00 against documents, RM 1,000.00 given back',
      );
    });

    test('and names money kept, on its own', () {
      expect(
        depositOutcome({'applied': 0, 'refunded': 0, 'forfeited': 500}),
        'RM 500.00 kept',
      );
    });
  });

  group('depositEvent', () {
    test('names the document an application went to', () {
      expect(
        depositEvent({'happened': 'applied', 'document': 'INV-1'}),
        'Applied to INV-1',
      );
    });

    test('carries the reason a deposit was kept', () {
      expect(
        depositEvent({
          'happened': 'forfeit',
          'reason': 'She cancelled inside the fortnight',
        }),
        'Kept — She cancelled inside the fortnight',
      );
    });

    test('and does not leave a dangling dash when there is no reason', () {
      expect(depositEvent({'happened': 'refund'}), 'Given back');
      expect(depositEvent({'happened': 'refund', 'reason': '  '}), 'Given back');
    });
  });
}
