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

  // -------------------------------------------------------------------
  // Reversing one, and entering it again
  // -------------------------------------------------------------------
  //
  // A posted expense had no correcting verb anywhere near it: the
  // dialog said "correcting one means reversing it, which is a
  // different verb and a different screen", and that screen only
  // existed for journals — so the way to fix EXP-2026-00001 was to go
  // and find `JV-2026-00001` by hand.
  //
  // `0102` is the shape of the correction: the mirror journal is
  // posted and THE ORIGINAL STANDS. So a re-entry is a second
  // document, and what it carries is the question these assert.
  group('what a re-entry carries', () {
    Map<String, dynamic> original() => {
      'id': 'e1',
      'expense_no': 'EXP-2026-00001',
      'expense_date': '2026-09-03',
      'description': 'Lalamove · 3576141065700467273',
      'amount': '22.50',
      'total_amount': '22.50',
      'reference': '3576141065700467273',
      'account_id': 'a-6250',
      'contact_id': 'c-1',
      'tax_code_id': 't-1',
      'project_code': 'P-1',
      'department_code': 'D-1',
      'matter_id': 'm-1',
      'payment_mode_code': '01',
      'bank_account_id': 'b-wrong',
    };

    test('everything that was right the first time', () {
      final from = reEntryFields(original());

      expect(from.date, DateTime(2026, 9, 3));
      expect(from.description, 'Lalamove · 3576141065700467273');
      // The NET, which is what the Amount box holds: the form adds the
      // tax back from the code's rate, so copying the total would
      // charge the tax twice.
      expect(from.amount, '22.50');
      expect(from.reference, '3576141065700467273');
      expect(from.accountId, 'a-6250');
      expect(from.contactId, 'c-1');
      expect(from.taxCodeId, 't-1');
      expect(from.projectCode, 'P-1');
      expect(from.departmentCode, 'D-1');
      expect(from.matterId, 'm-1');
      expect(from.paymentMode, '01');
    });

    test('the NET where there is tax, which is what the box holds', () {
      // The fixture above has no tax, so `amount` and `total_amount`
      // are the same number and copying the wrong one is invisible —
      // a mutant that swapped them SURVIVED against it. An expense
      // with tax is the only shape that can tell them apart, and
      // getting it wrong charges the tax twice: the form adds it back
      // from the code's rate on top of whatever is in the box.
      final from = reEntryFields({
        ...original(),
        'amount': '20.00',
        'tax_amount': '2.50',
        'total_amount': '22.50',
      });

      expect(from.amount, '20.00');
      expect(from.amount, isNot('22.50'));
    });

    test('and NOT the account it was paid from', () {
      // The whole point. The commonest reason to reverse an expense is
      // that this was wrong or missing, so carrying it forward would
      // re-enter the thing being corrected — and `0727` makes the form
      // refuse to save until somebody answers it.
      //
      // There is no field for it in the record at all, which is a
      // stronger guarantee than leaving it null: it cannot be copied
      // by accident later.
      expect(
        reEntryFields(original()).toString(),
        isNot(contains('b-wrong')),
      );
    });

    test('a blank is carried as absent, not as an empty box', () {
      final from = reEntryFields({
        ...original(),
        'description': '   ',
        'reference': '',
        'matter_id': null,
      });

      expect(from.description, isNull);
      expect(from.reference, isNull);
      expect(from.matterId, isNull);
    });

    test('and an unparseable date does not become today', () {
      // Silently dating a correction today would put it in the wrong
      // month, which is the error the reversal is being made to fix.
      expect(reEntryFields({...original(), 'expense_date': null}).date, isNull);
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
