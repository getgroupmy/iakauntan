import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/stock/landed_cost_screen.dart';

void main() {
  group('runSummary', () {
    test('a draft says what it holds and nothing about stock', () {
      // A draft has capitalised nothing yet, and saying "RM 0.00 onto
      // stock" would read as a failure rather than as a thing that has
      // not happened.
      expect(
        runSummary({
          'status': 'draft',
          'bills': 2,
          'total': 400,
          'capitalised': 0,
        }),
        '2 bills · RM 400.00',
      );
    });

    test('a posted run that landed all of it says so in words', () {
      expect(
        runSummary({
          'status': 'posted',
          'bills': 1,
          'total': 400,
          'capitalised': 400,
        }),
        '1 bill · RM 400.00 · all of it onto stock',
      );
    });

    test('and one that could not says how much did', () {
      expect(
        runSummary({
          'status': 'posted',
          'bills': 1,
          'total': 400,
          'capitalised': 300,
        }),
        '1 bill · RM 400.00 · RM 300.00 onto stock',
      );
    });
  });

  group('shortfallReason', () {
    test('is silent when the whole share went onto the stock', () {
      expect(
        shortfallReason({
          'amount': 200,
          'capitalised': 200,
          'received': 100,
          'on_hand': 100,
        }),
        isNull,
      );
    });

    test('names the money and why, when half the goods have gone', () {
      expect(
        shortfallReason({
          'amount': 200,
          'capitalised': 100,
          'received': 100,
          'on_hand': 50,
        }),
        'RM 100.00 stays on the expense account: 50 of 100 were already sold',
      );
    });

    test('and does not say "0 of 100 were sold" when none are left', () {
      // on_hand at nil is the case somebody will actually hit, and the
      // sentence has to still make sense.
      expect(
        shortfallReason({
          'amount': 200,
          'capitalised': 0,
          'received': 100,
          'on_hand': 0,
        }),
        'RM 200.00 stays on the expense account: none of these are left',
      );
    });
  });

  group('canSaveRun', () {
    test('needs a bill, a charge, and an amount on it', () {
      expect(canSaveRun([], [ChargeDraft(amount: 10)]), isFalse);
      expect(canSaveRun(['b'], []), isFalse);
      expect(canSaveRun(['b'], [ChargeDraft(amount: 0)]), isFalse);
      expect(canSaveRun(['b'], [ChargeDraft(amount: 10)]), isTrue);
    });

    test('one charge left blank stops the whole run', () {
      // Not "most of them are fine": a charge with no amount would be
      // saved as a zero the server then refuses, after the dialog has
      // already closed.
      expect(
        canSaveRun(['b'], [ChargeDraft(amount: 10), ChargeDraft(amount: 0)]),
        isFalse,
      );
    });
  });

  group('the charge the dialog sends', () {
    test('carries the basis and the account it comes off', () {
      final c = ChargeDraft(
        description: 'Ocean freight',
        amount: 400,
        basis: 'quantity',
        accountId: 'acct-1',
      );
      expect(c.toJson(), {
        'description': 'Ocean freight',
        'amount': 400.0,
        'basis': 'quantity',
        'account': 'acct-1',
      });
    });

    test('and a null account means the server picks 5400', () {
      expect(ChargeDraft(amount: 1).toJson()['account'], isNull);
    });
  });
}
