import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/stock/landed_cost_screen.dart';

Map<String, dynamic> charge({
  String description = 'Ocean freight',
  num amount = 1200,
  String basis = 'value',
  String? accountId = 'a1',
  Map<String, dynamic>? account = const {'code': '5300', 'name': 'Freight in'},
}) => <String, dynamic>{
  'description': description,
  'amount': amount,
  'basis': basis,
  'account_id': accountId,
  'accounts': account,
};

void main() {
  group('whether a run can still be rewritten', () {
    test('only while it is a draft', () {
      // "That run is already %, and what it did to the stock cannot be
      // rewritten by editing it."
      expect(runIsAmendable('draft'), isTrue);
      expect(runIsAmendable('posted'), isFalse);
      expect(runIsAmendable('cancelled'), isFalse);
      expect(runIsAmendable(null), isFalse);
    });
  });

  group('how a charge is spread', () {
    test('said in words rather than the enum', () {
      // app.landed_cost_basis has exactly these two arms.
      expect(chargeBasis('value'), 'by value');
      expect(chargeBasis('quantity'), 'by quantity');
    });

    test('a row with nothing in it reads as what the column defaults to', () {
      expect(chargeBasis(null), 'by value');
      expect(chargeBasis(''), 'by value');
    });
  });

  group('what a charge reads as', () {
    test('names itself, the account and how it is spread', () {
      final s = chargeLine(charge());
      expect(s, contains('Ocean freight'));
      expect(s, contains('5300 Freight in'));
      expect(s, contains('by value'));
    });

    test('an unembedded account is left out rather than printed as null', () {
      final s = chargeLine(charge(account: null));
      expect(s, contains('Ocean freight'));
      expect(s, isNot(contains('null')));
    });
  });

  group('what the run is spreading altogether', () {
    test('is the sum of the charges', () {
      expect(
        chargesTotal([charge(amount: 1200), charge(amount: 340.50)]),
        1540.50,
      );
    });

    test('rounds to the sen', () {
      expect(
        chargesTotal([charge(amount: 0.1), charge(amount: 0.2)]),
        0.30,
      );
    });

    test('nothing spread is nothing', () {
      expect(chargesTotal(const []), 0);
    });

    test('amounts that arrive as strings still add up', () {
      // The numerics come across JSON as whichever of num or String
      // the driver felt like.
      expect(
        chargesTotal([
          <String, dynamic>{'amount': '1200.00'},
          <String, dynamic>{'amount': '340.50'},
        ]),
        1540.50,
      );
    });
  });

  group('turning saved charges back into drafts', () {
    test('carries every field the dialog edits', () {
      final d = draftsOf([
        charge(
          description: 'Duty',
          amount: 88.8,
          basis: 'quantity',
          accountId: 'a9',
        ),
      ]).single;
      expect(d.description, 'Duty');
      expect(d.amount, 88.8);
      expect(d.basis, 'quantity');
      expect(d.accountId, 'a9');
    });

    test('keeps them in the order they were saved', () {
      final list = draftsOf([
        charge(description: 'Freight'),
        charge(description: 'Duty'),
        charge(description: 'Insurance'),
      ]);
      expect(
        list.map((d) => d.description),
        ['Freight', 'Duty', 'Insurance'],
      );
    });

    test('a run with nothing on it still gets a row to type into', () {
      // Which is what a fresh dialog starts with, and an empty list
      // would leave a form with no fields at all.
      final list = draftsOf(const []);
      expect(list, hasLength(1));
      expect(list.single.description, '');
      expect(list.single.amount, 0);
    });

    test('the drafts are new objects, not the rows', () {
      final rows = [charge(description: 'Freight')];
      final d = draftsOf(rows).single;
      d.description = 'Changed';
      expect(rows.single['description'], 'Freight');
    });
  });

  group('which bills a run covers', () {
    test('is the bill of each target', () {
      expect(
        billIdsOf([
          {'bill_id': 'b1'},
          {'bill_id': 'b2'},
        ]),
        ['b1', 'b2'],
      );
    });

    test('a run covering nothing covers nothing', () {
      expect(billIdsOf(const []), isEmpty);
    });
  });

  group('whether the amended run can be saved', () {
    test('needs a bill and a charge with an amount on it', () {
      expect(canSaveRun(const [], draftsOf(const [])), isFalse);
      expect(canSaveRun(['b1'], draftsOf(const [])), isFalse);
      expect(
        canSaveRun(['b1'], draftsOf([charge(amount: 1200)])),
        isTrue,
      );
    });

    test('a reopened run is savable as it stands', () {
      // Which is the point: correcting one figure must not require
      // re-entering the rest.
      final bills = billIdsOf([
        {'bill_id': 'b1'},
      ]);
      final drafts = draftsOf([charge()]);
      expect(canSaveRun(bills, drafts), isTrue);
    });
  });
}
