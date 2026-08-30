import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/reports/budget_line_editor.dart';

Map<String, dynamic> line(
  String account,
  String period,
  num amount, {
  String code = '5100',
}) => <String, dynamic>{
  'account_id': account,
  'code': code,
  'name': 'Staff costs',
  'period_id': period,
  'period_no': 1,
  'period_name': 'January',
  'amount': amount,
};

void main() {
  group('whether the numbers can still be changed', () {
    test('only while the budget is a draft', () {
      // "That budget is %. Its numbers are what was agreed and are not
      // edited afterwards."
      expect(budgetIsEditable('draft'), isTrue);
      expect(budgetIsEditable('approved'), isFalse);
      expect(budgetIsEditable('archived'), isFalse);
      expect(budgetIsEditable(null), isFalse);
    });
  });

  group('an amount', () {
    test('is a plain number', () {
      expect(budgetAmountOf('12000'), 12000);
      expect(budgetAmountOf('1,250.50'), 1250.50);
    });

    test('may be negative', () {
      // A budgeted contra -- returns against revenue, a discount
      // allowed -- is a real line.
      expect(budgetAmountOf('-500'), -500);
    });

    test('is rounded to the sen, as the function rounds it', () {
      expect(budgetAmountOf('100.567'), 100.57);
    });

    test('is nothing when it is not a number', () {
      expect(budgetAmountOf(''), isNull);
      expect(budgetAmountOf('about ten thousand'), isNull);
    });

    test('zero is an amount, not a refusal', () {
      // It is how a line is removed, so the field has to accept it.
      expect(budgetAmountOf('0'), 0);
    });
  });

  group('whether a line survives', () {
    test('a zero is not a budget line', () {
      expect(lineSurvives(0), isFalse);
    });

    test('anything else is', () {
      expect(lineSurvives(1), isTrue);
      expect(lineSurvives(-1), isTrue);
      expect(lineSurvives(0.01), isTrue);
    });
  });

  group('what is sent', () {
    test('every line, because the function replaces the set', () {
      // set_budget_lines deletes every line of the budget and
      // re-inserts what it is given. Sending one row would delete the
      // rest of the budget.
      final payload = budgetLinePayload([
        line('a1', 'p1', 1000),
        line('a1', 'p2', 1100),
        line('a2', 'p1', 500),
      ]);
      expect(payload.length, 3);
    });

    test('in the keys the function reads', () {
      final one = budgetLinePayload([line('a1', 'p1', 1000)]).single;
      expect(one, {'account': 'a1', 'period': 'p1', 'amount': 1000});
    });

    test('zeros are left out, since the function would skip them anyway', () {
      final payload = budgetLinePayload([
        line('a1', 'p1', 1000),
        line('a1', 'p2', 0),
      ]);
      expect(payload.length, 1);
      expect(payload.single['period'], 'p1');
    });

    test('a negative survives the trip', () {
      expect(
        budgetLinePayload([line('a1', 'p1', -250)]).single['amount'],
        -250,
      );
    });

    test('nothing budgeted sends an empty set, which empties the budget', () {
      expect(budgetLinePayload(const []), isEmpty);
    });
  });

  group('changing one amount', () {
    final lines = [
      line('a1', 'p1', 1000),
      line('a1', 'p2', 1100),
      line('a2', 'p1', 500),
    ];

    test('replaces only the row for that account and that period', () {
      final out = withBudgetAmount(lines, line('a1', 'p2', 0), 1250);
      expect(out.length, 3);
      expect(out[0]['amount'], 1000);
      expect(out[1]['amount'], 1250);
      expect(out[2]['amount'], 500);
    });

    test('needs both the account and the period to match', () {
      // Same account, different period, and the other way round.
      final out = withBudgetAmount(lines, line('a1', 'p9', 0), 77);
      expect(out.length, 4);
      expect(out.last['amount'], 77);

      final out2 = withBudgetAmount(lines, line('a9', 'p1', 0), 88);
      expect(out2.length, 4);
      expect(out2.last['amount'], 88);
    });

    test('adds the row where the budget had nothing for it', () {
      final out = withBudgetAmount(lines, line('a3', 'p1', 0), 250);
      expect(out.length, 4);
      expect(out.last['account_id'], 'a3');
      expect(out.last['amount'], 250);
    });

    test('keeps the order, so an edited row does not jump', () {
      final out = withBudgetAmount(lines, line('a1', 'p1', 0), 999);
      expect(out.map((l) => '${l['account_id']}/${l['period_id']}'),
          ['a1/p1', 'a1/p2', 'a2/p1']);
    });

    test('leaves the display fields of the row it replaced', () {
      final out = withBudgetAmount(lines, line('a1', 'p1', 0), 999);
      expect(out.first['period_name'], 'January');
      expect(out.first['code'], '5100');
    });

    test('does not change the list it was given', () {
      withBudgetAmount(lines, line('a1', 'p1', 0), 999);
      expect(lines.first['amount'], 1000);
    });

    test('setting a line to zero keeps it in view until it is saved', () {
      // Struck through rather than vanishing, so somebody can see what
      // their edit is about to do.
      final out = withBudgetAmount(lines, line('a1', 'p1', 0), 0);
      expect(out.length, 3);
      expect(lineSurvives(out.first['amount'] as num), isFalse);
      expect(budgetLinePayload(out).length, 2);
    });
  });

  group('what it adds up to', () {
    test('is the sum of the lines', () {
      expect(
        budgetWorkingTotal([
          line('a1', 'p1', 1000),
          line('a1', 'p2', 1100.50),
        ]),
        2100.50,
      );
    });

    test('nets a negative off, because that is what a contra does', () {
      expect(
        budgetWorkingTotal([
          line('a1', 'p1', 1000),
          line('a2', 'p1', -250),
        ]),
        750,
      );
    });

    test('rounds to the sen', () {
      expect(
        budgetWorkingTotal([
          line('a1', 'p1', 0.1),
          line('a2', 'p1', 0.2),
        ]),
        0.30,
      );
    });

    test('nothing budgeted is nothing', () {
      expect(budgetWorkingTotal(const []), 0);
    });
  });
}
