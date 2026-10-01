import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/named_account.dart';

/// The four sentences a form says when it does not know which account
/// the money moved through.
///
/// Pure functions, so they are asserted here rather than through four
/// widgets. What the widgets assert is that the button is disabled and
/// the box is starred — `settlement_dialog_test.dart`, `deposits_test.dart`
/// and `cheques_test.dart` — and this file asserts that the sentence a
/// person then reads tells them what to do.
///
/// Why any of it exists: account 1120 is "Bank Accounts", postable but
/// the heading that `upsert_bank_account` hangs the real accounts
/// beneath. Six posting functions used to post there when handed no
/// account. The entry balanced, reported, and reconciled against
/// nothing, and no bank balance moved. `0727` and `0728` refuse it in
/// SQL; these are the same refusals arriving while the form is still
/// open.
void main() {
  group('an account named', () {
    test('is nothing to complain about', () {
      expect(depositAccountProblem('bank-1'), isNull);
      expect(chequeAccountProblem('bank-1'), isNull);
      expect(settlementAccountProblem('bank-1', isReceipt: true), isNull);
      expect(settlementAccountProblem('bank-1', isReceipt: false), isNull);
    });
  });

  group('no account named', () {
    test('a deposit says which box to fill', () {
      final said = depositAccountProblem(null);
      expect(said, isNotNull);
      expect(said, contains('Choose the account'));
      expect(said, contains('reconciled'));
    });

    test('a cheque says it could never be cleared', () {
      final said = chequeAccountProblem(null);
      expect(said, isNotNull);
      // The reason is specific to a cheque and is the whole argument
      // for asking at recording rather than at clearing.
      expect(said, contains('cleared'));
    });

    test('a receipt is received INTO an account', () {
      final said = settlementAccountProblem(null, isReceipt: true);
      expect(said, contains('received into'));
      expect(said, isNot(contains('paid from')));
    });

    test('and a payment is paid FROM one', () {
      // The direction is the point. One sentence for both would be
      // wrong in one direction every time it was shown.
      final said = settlementAccountProblem(null, isReceipt: false);
      expect(said, contains('paid from'));
      expect(said, isNot(contains('received into')));
    });

    test('the four sentences are four sentences', () {
      final all = {
        depositAccountProblem(null),
        chequeAccountProblem(null),
        settlementAccountProblem(null, isReceipt: true),
        settlementAccountProblem(null, isReceipt: false),
      };
      expect(all, hasLength(4));
    });
  });
}
