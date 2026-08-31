import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/banking/statement_import.dart';

/// Reading a pasted bank statement.
///
/// Every failure here is silent: a misread date reconciles against the
/// wrong day, a shifted column reconciles against the wrong amount, and
/// a skipped line makes the account short by exactly that line. So the
/// parser reports what it could not read rather than dropping it.
void main() {
  group('dates as Malaysian banks write them', () {
    test('day first, because that is what they use', () {
      expect(parseStatementDate('06/03/2026'), DateTime(2026, 3, 6));
      expect(parseStatementDate('6-3-26'), DateTime(2026, 3, 6));
    });

    test('ISO is read as itself', () {
      expect(parseStatementDate('2026-03-06'), DateTime(2026, 3, 6));
    });

    test('and the named month form', () {
      expect(parseStatementDate('06 Mar 2026'), DateTime(2026, 3, 6));
      expect(parseStatementDate('6-March-2026'), DateTime(2026, 3, 6));
    });

    test('an impossible date is refused, not rolled over', () {
      // DateTime(2026, 2, 31) silently becomes 3 March.
      expect(parseStatementDate('31/02/2026'), isNull);
      expect(parseStatementDate('45/01/2026'), isNull);
    });

    test('and nonsense is refused', () {
      expect(parseStatementDate(''), isNull);
      expect(parseStatementDate('last Tuesday'), isNull);
    });
  });

  group('reading a paste', () {
    test('a signed amount column', () {
      final parsed = parseStatement('''
Date,Description,Reference,Amount
06/03/2026,Transfer in,RCP-1,1000.00
07/03/2026,Cheque 123,CHQ123,-250.50
''');
      expect(parsed.problems, isEmpty);
      expect(parsed.rows.length, 2);
      expect(parsed.rows[0].amount, 1000.00);
      expect(parsed.rows[0].description, 'Transfer in');
      expect(parsed.rows[1].amount, -250.50);
    });

    test('separate debit and credit columns', () {
      final parsed = parseStatement('''
Date,Details,Debit,Credit
06/03/2026,Deposit,,1000.00
07/03/2026,Withdrawal,250.50,
''');
      expect(parsed.rows[0].amount, 1000.00);
      expect(parsed.rows[1].amount, -250.50,
          reason: 'a debit on a bank statement is money leaving');
    });

    test('brackets mean negative', () {
      final parsed = parseStatement('''
Date,Description,Amount
06/03/2026,Charge,(25.00)
''');
      expect(parsed.rows.single.amount, -25.00);
    });

    test('thousands separators and RM are stripped', () {
      final parsed = parseStatement('''
Date,Description,Amount
06/03/2026,Big one,"RM 1,234,567.89"
''');
      expect(parsed.rows.single.amount, 1234567.89);
    });

    test('a comma inside a quoted description does not shift the columns', () {
      final parsed = parseStatement('''
Date,Description,Amount
06/03/2026,"Payment to Ali, Bakar and Co",-500.00
''');
      expect(parsed.rows.single.description, 'Payment to Ali, Bakar and Co');
      expect(parsed.rows.single.amount, -500.00);
    });

    test('columns are found by name, in any order', () {
      final parsed = parseStatement('''
Amount,Particulars,Posting Date
1000.00,Deposit,06/03/2026
''');
      expect(parsed.rows.single.amount, 1000.00);
      expect(parsed.rows.single.date, DateTime(2026, 3, 6));
    });

    test('tab separated pastes work too', () {
      final parsed = parseStatement('Date\tDescription\tAmount\n'
          '06/03/2026\tDeposit\t1000.00');
      expect(parsed.rows.single.amount, 1000.00);
    });

    test('a bad line is reported, not silently dropped', () {
      final parsed = parseStatement('''
Date,Description,Amount
06/03/2026,Good,1000.00
not a date,Bad,500.00
07/03/2026,No amount,
''');
      expect(parsed.rows.length, 1);
      expect(parsed.problems.length, 2);
      expect(parsed.problems.first, contains('3'),
          reason: 'the line number is what makes it fixable');
    });

    test('a missing date column is refused outright', () {
      final parsed = parseStatement('Description,Amount\nDeposit,1000');
      expect(parsed.isEmpty, isTrue);
      expect(parsed.problems.single, contains('date column'));
    });

    test('a missing amount column is refused outright', () {
      final parsed = parseStatement('Date,Description\n06/03/2026,Deposit');
      expect(parsed.isEmpty, isTrue);
      expect(parsed.problems.single, contains('amount column'));
    });
  });

  group('the balance column', () {
    // The only figure on a statement that can be checked against the
    // rest of the statement, and until 0369 it was read as nothing. It
    // is what lets the importer find a line the paste clipped, and what
    // tells two identical withdrawals on one day from the same line
    // pasted twice.
    test('is read, under any of the names a bank prints on it', () {
      for (final header in const [
        'Date,Description,Amount,Balance',
        'Date,Description,Amount,Running Balance',
        'Date,Description,Amount,Ledger Balance',
        'Date,Description,Amount,Baki',
      ]) {
        final parsed = parseStatement('$header\n'
            '06/03/2026,Deposit,1000.00,"5,432.10"');
        expect(parsed.rows.single.balance, 5432.10, reason: header);
      }
    });

    test('and an overdrawn account reads as negative', () {
      // Brackets and a minus sign both, because statements use both and
      // an overdraft read as a positive balance breaks the chain on the
      // next line rather than on itself.
      final parsed = parseStatement('''
Date,Description,Amount,Balance
06/03/2026,Charge,-25.00,(120.00)
07/03/2026,Charge,-25.00,-145.00
''');
      expect(parsed.rows[0].balance, -120.00);
      expect(parsed.rows[1].balance, -145.00);
    });

    test('a statement without one still imports', () {
      // Plenty of exports have no balance column. Refusing those would
      // trade a check nobody had for an import everybody did.
      final parsed = parseStatement('''
Date,Description,Amount
06/03/2026,Deposit,1000.00
''');
      expect(parsed.problems, isEmpty);
      expect(parsed.rows.single.balance, isNull);
    });

    test('and a blank cell breaks the chain rather than failing it', () {
      final parsed = parseStatement('''
Date,Description,Amount,Balance
06/03/2026,Deposit,1000.00,1000.00
07/03/2026,Deposit,500.00,
08/03/2026,Deposit,500.00,2000.00
''');
      expect(parsed.rows.length, 3);
      expect(parsed.rows[1].balance, isNull);
      expect(parsed.rows[2].balance, 2000.00);
    });
  });

  group('the row serialises the way the importer expects', () {
    test('date, amount and balance under the names the function reads', () {
      final row = StatementRow(
        date: DateTime(2026, 3, 6),
        amount: -250.5,
        description: 'Cheque',
        balance: 749.5,
      );
      expect(row.toJson()['transaction_date'], '2026-03-06');
      expect(row.toJson()['amount'], -250.5);
      // Named for the column, not for the Dart field: `import_bank_
      // transactions` reads `running_balance` out of each row and a key
      // it does not recognise is a check that silently does not run.
      expect(row.toJson()['running_balance'], 749.5);
    });

    test('and carries the balance as null rather than omitting it', () {
      // `->> 'running_balance'` on an absent key and on a JSON null both
      // come back null, so either would do — asserted so that a future
      // shortening of toJson is a decision rather than an accident.
      final row = StatementRow(date: DateTime(2026, 3, 6), amount: 10);
      expect(row.toJson().containsKey('running_balance'), isTrue);
      expect(row.toJson()['running_balance'], isNull);
    });
  });
}
