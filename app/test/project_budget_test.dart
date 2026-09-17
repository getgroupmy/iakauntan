import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/timesheets/project_budget.dart';

Map<String, dynamic> job({
  num? cost,
  num? variance,
  num? percent,
  num unbilled = 0,
}) => <String, dynamic>{
      'cost_to_date': cost,
      'variance': variance,
      'percent_spent': percent,
      'unbilled_time': unbilled,
    };

void main() {
  group('where a job stands', () {
    test('no budget is not a budget of nothing', () {
      final j = job(cost: 800, variance: null, percent: null);
      expect(budgetStateOf(j), BudgetState.none);
      expect(describeBudget(j), contains('no budget set'));
      // And the bar is not drawn as empty progress towards nothing.
      expect(budgetFraction(j), 0);
    });

    test('comfortably inside it', () {
      final j = job(cost: 15000, variance: 35000, percent: 30);
      expect(budgetStateOf(j), BudgetState.within);
      expect(describeBudget(j), contains('left'));
      expect(budgetFraction(j), closeTo(0.30, 0.001));
    });

    test('close enough to be worth a conversation', () {
      expect(budgetStateOf(job(percent: 85)), BudgetState.close);
      expect(budgetStateOf(job(percent: 99.9)), BudgetState.close);
    });

    test('and exactly on budget is not yet over it', () {
      expect(budgetStateOf(job(percent: 100)), BudgetState.close);
    });

    test('over it, and said as the amount over', () {
      final j = job(cost: 62000, variance: -12000, percent: 124);
      expect(budgetStateOf(j), BudgetState.over);
      expect(describeBudget(j), contains('over budget'));
      // The bar stops at full; the sentence does not have to.
      expect(budgetFraction(j), 1.0);
    });
  });

  group('whether the job can be closed', () {
    test('nothing outstanding, nothing in the way', () {
      expect(closeBlockedBecause(job()), isNull);
    });

    test('billable hours never invoiced are in the way, and named', () {
      final why = closeBlockedBecause(job(unbilled: 3000));
      expect(why, isNotNull);
      expect(why, contains('never'));
      expect(why, contains('writing the time off'));
    });
  });

  group('what a project row has to say', () {
    test('a code and a name', () {
      expect(
        projectBlockedBecause(
            code: '', name: 'Fit-out', budget: null, start: null, end: null),
        contains('code'),
      );
      expect(
        projectBlockedBecause(
            code: 'JOB-1', name: ' ', budget: null, start: null, end: null),
        contains('name'),
      );
    });

    test('a budget that is not negative', () {
      expect(
        projectBlockedBecause(
            code: 'J', name: 'N', budget: -1, start: null, end: null),
        contains('not negative'),
      );
      expect(
        projectBlockedBecause(
            code: 'J', name: 'N', budget: 0, start: null, end: null),
        isNull,
      );
    });

    test('and dates in the order they happen', () {
      expect(
        projectBlockedBecause(
          code: 'J',
          name: 'N',
          budget: null,
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 1, 1),
        ),
        contains('does not end before it starts'),
      );
      expect(
        projectBlockedBecause(
          code: 'J',
          name: 'N',
          budget: null,
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 6, 1),
        ),
        isNull,
      );
    });
  });

  group('the row it sends', () {
    test('carries the budget, and clears one that was removed', () {
      final v = projectValues(code: ' J-1 ', name: ' Fit-out ', budget: null);
      expect(v['code'], 'J-1');
      expect(v['name'], 'Fit-out');
      // Present and null, not absent: a budget somebody deleted has to
      // come off the record, or the report measures against a number
      // nobody stands behind.
      expect(v.containsKey('budget_amount'), isTrue);
      expect(v['budget_amount'], isNull);
    });

    test('and the dates as dates', () {
      final v = projectValues(
        code: 'J',
        name: 'N',
        budget: 50000,
        start: DateTime(2026, 3, 1),
        end: DateTime(2026, 9, 30),
      );
      expect(v['budget_amount'], 50000);
      expect(v['start_date'], '2026-03-01');
      expect(v['end_date'], '2026-09-30');
    });
  });
}
