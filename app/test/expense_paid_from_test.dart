import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/expenses/expenses_screen.dart';

/// Which account the money left, which the expense dialog did not say.
///
/// A real one, EXP-2026-00001 on production: RM22.50 to Lalamove,
/// posted, `bank_account_id` null, `payment_mode_code` `01` — Cash —
/// and a journal crediting `1120 Bank Accounts`. The dialog showed the
/// expense account it was charged TO and nothing at all about where it
/// came FROM, because the list query it renders from never fetched the
/// bank account. So the one fact a bank reconciliation turns on was the
/// one fact the screen omitted.
///
/// Three answers and not two, and the third is the point: an expense
/// posted with no account chosen has still been posted somewhere, and
/// saying nothing lets it sit in the books with nobody able to see that
/// it is reconcilable against nothing.
void main() {
  Map<String, dynamic> expense({
    String? bank,
    String status = 'posted',
  }) => {
    'id': 'e1',
    'status': status,
    if (bank != null) 'bank_accounts': {'name': bank},
  };

  test('a named account is named', () {
    final paidFrom = expensePaidFrom(expense(bank: 'CIMB Current 8801'));
    expect(paidFrom?.label, 'Paid from');
    expect(paidFrom?.value, 'CIMB Current 8801');
  });

  test('and a posted expense with none says where it actually went', () {
    // NOT "—", and not silence. `post_expense` credits the control
    // account when `bank_account_id` is null, which is a real posting
    // against no particular bank — so the line says so, and says the
    // consequence rather than leaving somebody to work it out.
    final paidFrom = expensePaidFrom(expense());
    expect(paidFrom, isNotNull);
    expect(paidFrom!.value, contains('1120'));
    expect(paidFrom.value, contains('no account was chosen'));
    expect(
      paidFrom.value,
      contains('no bank reconciliation'),
      reason: 'the consequence is the part somebody can act on',
    );
  });

  test('a draft says nothing, because nothing has been credited yet', () {
    // The one case where silence is right. No journal exists, so there
    // is no account to name, and naming the fallback would be
    // describing a posting that has not happened.
    expect(expensePaidFrom(expense(status: 'draft')), isNull);
  });

  group('and it cannot be left out any more', () {
    // `0727`. Asked for: "make the paid from required when recording an
    // expense". The database refuses it as well — that is where the rule
    // lives, because `expenses` is an ordinary table the client writes
    // to directly — and this is the half that tells somebody while the
    // form is still open.
    test('no account chosen is a reason not to save', () {
      final said = paidFromProblem(null);

      expect(said, isNotNull);
      // Says what to do, not that something is wrong. "Paid from is
      // required" names the field and leaves the person to work out
      // why it suddenly matters.
      expect(said, contains('Choose the account'));
      expect(said, contains('reconciled'));
    });

    test('and a chosen one is not', () {
      expect(paidFromProblem('bank-1'), isNull);
    });
  });

  test('a blank name is not a name', () {
    // A join that came back with an empty string is the absent case
    // wearing the present case's clothes.
    expect(
      expensePaidFrom(expense(bank: '  '))?.value,
      contains('1120'),
    );
  });
}
