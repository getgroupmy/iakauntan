import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/ledger/journal_editor.dart';

/// The database refuses an unbalanced journal with SQLSTATE 23514 and
/// that is the real guard. These assert the thing a bookkeeper actually
/// meets: the message that appears while they are still typing, and the
/// button that stays disabled until the entry is one the ledger will
/// take.
void main() {
  JournalDraft line(String account, {double debit = 0, double credit = 0}) =>
      JournalDraft(accountId: account, debit: debit, credit: credit);

  group('journalProblem', () {
    test('accepts a balanced two-line journal', () {
      expect(
        journalProblem([
          line('a', debit: 500),
          line('b', credit: 500),
        ]),
        isNull,
      );
    });

    test('accepts one debit against several credits', () {
      expect(
        journalProblem([
          line('a', debit: 1000),
          line('b', credit: 400),
          line('c', credit: 600),
        ]),
        isNull,
      );
    });

    test('reports which way an unbalanced journal is out', () {
      final problem = journalProblem([
        line('a', debit: 500),
        line('b', credit: 450),
      ]);
      expect(problem, isNotNull);
      expect(problem, contains('50'));
    });

    test('tolerates a half-cent, refuses a full one', () {
      // Rounding to two decimals is the database's job; a difference it
      // will round away must not block the button.
      expect(journalProblem([
        line('a', debit: 100),
        line('b', credit: 100.004),
      ]), isNull);
      expect(journalProblem([
        line('a', debit: 100),
        line('b', credit: 100.01),
      ]), isNotNull);
    });

    test('refuses a line that is both a debit and a credit', () {
      expect(
        journalProblem([
          line('a', debit: 100, credit: 100),
          line('b', credit: 100),
        ]),
        contains('not both'),
      );
    });

    test('refuses negative amounts', () {
      expect(
        journalProblem([
          line('a', debit: -100),
          line('b', credit: -100),
        ]),
        contains('positive'),
      );
    });

    test('refuses a line with an amount and no account', () {
      expect(
        journalProblem([
          JournalDraft(debit: 100),
          line('b', credit: 100),
        ]),
        contains('account'),
      );
    });

    test('refuses a line with an account and no amount', () {
      expect(
        journalProblem([
          line('a', debit: 100),
          line('b', credit: 100),
          line('c'),
        ]),
        contains('amount'),
      );
    });

    test('ignores untouched blank lines', () {
      // The editor opens with two empty rows and grows by empty rows;
      // those must not count against the entry.
      expect(
        journalProblem([
          line('a', debit: 100),
          line('b', credit: 100),
          JournalDraft(),
          JournalDraft(),
        ]),
        isNull,
      );
    });

    test('refuses an empty journal', () {
      expect(journalProblem([JournalDraft(), JournalDraft()]), isNotNull);
    });

    test('refuses a journal that balances at zero', () {
      // Two lines, both zero, is balanced arithmetically and is not an
      // entry.
      expect(
        journalProblem([
          line('a', debit: 0, credit: 0),
          line('b', debit: 0, credit: 0),
        ]),
        isNotNull,
      );
    });
  });

  group('JournalDraft.toJson', () {
    test('sends the keys create_gl_entry reads', () {
      final json = JournalDraft(
        accountId: 'acct',
        description: ' Accrue December electricity ',
        debit: 1200,
        projectCode: 'JOB-1',
      ).toJson();

      expect(json['account_id'], 'acct');
      expect(json['description'], 'Accrue December electricity');
      expect(json['debit'], 1200);
      expect(json['credit'], 0);
      expect(json['project_code'], 'JOB-1');
    });

    test('omits a blank narrative rather than sending an empty string', () {
      final json = JournalDraft(accountId: 'acct', credit: 50).toJson();
      expect(json['description'], isNull);
      expect(json.containsKey('project_code'), isFalse);
    });
  });
}
