import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/settings/bank_rules_card.dart';

/// Writing a bank rule. `0625`.
///
/// The database refuses a rule with no condition and a rule with no
/// action, with two check constraints, and those refusals reach a
/// screen as `bank_rules_says_something` — which is not a sentence
/// anybody can act on. So the dialog has to make the same two
/// judgements, in words, BEFORE the save.
///
/// That is what is asserted here, and it is behaviour rather than
/// layout: a Save button that is live when the database will refuse is
/// a button that always fails, and one that is live when the rule
/// matches every line on the statement is worse — it succeeds.
void main() {
  Future<void> pump(WidgetTester tester, {Map<String, dynamic>? existing}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: BankRuleDialog(existing: existing)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BankRuleDialogState state(WidgetTester tester) =>
      tester.state<BankRuleDialogState>(find.byType(BankRuleDialog));

  group('what the dialog refuses before the database has to', () {
    testWidgets('an empty rule is named first', (tester) async {
      await pump(tester);
      expect(state(tester).problem, contains('name'));
    });

    testWidgets('a named rule with no condition would match everything', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('bank-rule-name')),
        'Electricity',
      );
      await tester.pumpAndSettle();

      // The sentence matters as much as the refusal. "Invalid" sends
      // somebody back to a form with nothing to try.
      expect(state(tester).problem, contains('every line'));
    });

    testWidgets('a condition with no action does nothing', (tester) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('bank-rule-name')),
        'Electricity',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bank-rule-says')),
        'TNB',
      );
      await tester.pumpAndSettle();

      expect(state(tester).problem, contains('suggests nothing'));
    });

    testWidgets('a backwards amount window is caught', (tester) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('bank-rule-name')),
        'Electricity',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bank-rule-min')),
        '500',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bank-rule-max')),
        '100',
      );
      await tester.pumpAndSettle();

      // Reported before the missing account, because the window
      // belongs to "look for" and that is the half of the form
      // somebody is still on.
      expect(state(tester).problem, contains('nothing can be inside'));
    });

    testWidgets('and the Save button is dead while anything is wrong', (
      tester,
    ) async {
      await pump(tester);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('bank-rule-save')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('a rule in one line', () {
    test('says what it looks for and what it suggests', () {
      final summary = bankRuleSummary({
        'direction': 'out',
        'description_contains': 'TNB',
        'amount_min': 100,
      }, {'code': '6210', 'name': 'Electricity'});

      expect(summary, contains('money out'));
      expect(summary, contains('TNB'));
      expect(summary, contains('at least 100'));
      expect(summary, contains('6210 Electricity'));
    });

    test('a window with both ends reads as a range', () {
      expect(
        bankRuleSummary(
            {'description_contains': 'x', 'amount_min': 50, 'amount_max': 200},
            null),
        contains('between 50 and 200'),
      );
    });

    test('and one with only a top end says so', () {
      expect(
        bankRuleSummary({'description_contains': 'x', 'amount_max': 200}, null),
        contains('at most 200'),
      );
    });

    test('a rule with no condition at all says so out loud', () {
      // This cannot be saved through the dialog and the database
      // refuses it, but a row written another way must not read as a
      // narrow rule on a screen somebody is deciding from.
      expect(bankRuleSummary(const {}, null), contains('every line'));
    });

    test('every condition reaches the summary', () {
      // A summary that quietly dropped one would read as broader than
      // the rule is, and somebody would delete it for catching too
      // little when it was never asked to catch that.
      final summary = bankRuleSummary({
        'direction': 'in',
        'description_contains': 'REFUND',
        'reference_contains': 'INV-1',
        'amount_min': 10,
        'amount_max': 20,
      }, null);

      expect(summary, contains('money in'));
      expect(summary, contains('REFUND'));
      expect(summary, contains('INV-1'));
      expect(summary, contains('between 10 and 20'));
    });
  });
}
