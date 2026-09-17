import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/expenses/expense_split.dart';

void main() {
  group('a charge divided across accounts', () {
    test('no split is not a problem', () {
      const split = ExpenseSplit.none();
      expect(split.isOn, isFalse);
      expect(split.problem, isNull);
      expect(split.toJson(), isEmpty);
    });

    test('the total is added up, not typed', () {
      const split = ExpenseSplit([
        SplitLine(accountId: 'a', amount: 320),
        SplitLine(accountId: 'b', amount: 180),
      ]);
      expect(split.total, 500);
      expect(split.isReady, isTrue);
    });

    // One line is the expense as it always was, and sending it as a
    // split would only bury the account a level deeper.
    test('one line is not a split', () {
      const split = ExpenseSplit([SplitLine(accountId: 'a', amount: 100)]);
      expect(split.problem, 'A split needs at least two accounts');
    });

    test('every line needs an account', () {
      const split = ExpenseSplit([
        SplitLine(accountId: 'a', amount: 60),
        SplitLine(amount: 40),
      ]);
      expect(split.problem, 'Every line needs an account');
    });

    test('and an amount', () {
      const split = ExpenseSplit([
        SplitLine(accountId: 'a', amount: 60),
        SplitLine(accountId: 'b'),
      ]);
      expect(split.problem, 'Every line needs an amount');
    });

    test('the same account twice is allowed — two dinners are two lines', () {
      const split = ExpenseSplit([
        SplitLine(accountId: 'a', amount: 60, description: 'Monday'),
        SplitLine(accountId: 'a', amount: 40, description: 'Thursday'),
      ]);
      expect(split.isReady, isTrue);
    });

    test('what is sent carries the account, the amount and the note', () {
      const split = ExpenseSplit([
        SplitLine(accountId: 'a', amount: 320, description: 'Flights'),
        SplitLine(accountId: 'b', amount: 180, description: '  '),
      ]);
      final json = split.toJson();
      expect(json.first, {
        'account_id': 'a',
        'amount': 320.0,
        'description': 'Flights',
      });
      // A blank note is no note, not an empty string in the ledger.
      expect(json.last.containsKey('description'), isFalse);
    });

    test('lines can be added, changed and taken out', () {
      var split = const ExpenseSplit([
        SplitLine(accountId: 'a', amount: 60),
        SplitLine(accountId: 'b', amount: 40),
      ]);
      split = split.withLine(const SplitLine(accountId: 'c', amount: 10));
      expect(split.total, 110);

      split = split.replace(0, split.lines[0].copyWith(amount: 90));
      expect(split.total, 140);

      split = split.without(1);
      expect(split.lines.length, 2);
      expect(split.total, 100);
    });

    test('copyWith can clear an account rather than keeping the old one', () {
      const line = SplitLine(accountId: 'a', amount: 10);
      expect(line.copyWith(accountId: null).accountId, isNull);
      expect(line.copyWith(amount: 20).accountId, 'a');
    });
  });
}
