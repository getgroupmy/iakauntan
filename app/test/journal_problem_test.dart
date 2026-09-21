import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/ledger/journal_editor.dart';

/// The database refuses an unbalanced journal with SQLSTATE 23514 and
/// that is the real guard. These assert the thing a bookkeeper actually
/// meets: the message that appears while they are still typing, and the
/// button that stays disabled until the entry is one the ledger will
/// take.
void main() {
  _whatALineSends();
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

/// What a line sends, and the dimension it did not send for years.
///
/// `gl_lines.department_code` has existed as long as the analysis
/// dimensions have, and `app.create_gl_entry_internal` has always read
/// `department_code` off each line's JSON. Nothing sent it: this editor
/// offered a project per line and no department, so every cost a
/// bookkeeper moved by hand arrived with a null.
///
/// That is the worst shape a reporting gap can take. The P&L's
/// department filter answered confidently, summing only what came in
/// through documents, so a department whose spending was journalled read
/// as a department that had underspent — and a missing figure that looks
/// like a small figure is one nobody reports.
///
/// The fix was a picker and a key in a map, with no schema change at
/// all. Which is exactly why this is asserted here AND in
/// `supabase/tests/pricing_and_dimensions.sql`: nothing in the database
/// changed, so nothing in the database would notice if the app quietly
/// stopped sending it again.
void _whatALineSends() {
  group('what a journal line sends', () {
    test('omits both dimensions when neither was chosen', () {
      // Absent rather than null. Most journals have no departmental or
      // project meaning, and a key present with a null value is a
      // different thing from a key that was never set — the first
      // overwrites, which matters on the day this map is used to patch
      // rather than to insert.
      final json = JournalDraft(accountId: 'a', debit: 10).toJson();
      expect(json.containsKey('project_code'), isFalse);
      expect(json.containsKey('department_code'), isFalse);
    });

    test('and carries a department when one was', () {
      final json = JournalDraft(
        accountId: 'a',
        debit: 10,
        departmentCode: 'OPS',
      ).toJson();
      expect(json['department_code'], 'OPS');
    });

    test('and both, because they are independent', () {
      // A job run by one department is an ordinary thing to post. The
      // two dimensions are not alternatives and the editor must not
      // make them behave like a choice.
      final json = JournalDraft(
        accountId: 'a',
        debit: 10,
        projectCode: 'JOB-9',
        departmentCode: 'OPS',
      ).toJson();
      expect(json['project_code'], 'JOB-9');
      expect(json['department_code'], 'OPS');
    });

    test('per line, so one journal can name two departments', () {
      // The reason it is on the line and not the header: the entry that
      // moves a cost from Sales to Marketing touches both, and a header
      // field could not express it.
      final lines = [
        JournalDraft(accountId: 'a', debit: 300, departmentCode: 'OPS'),
        JournalDraft(accountId: 'b', credit: 300, departmentCode: 'MKT'),
      ];
      expect(
        lines.map((l) => l.toJson()['department_code']).toList(),
        ['OPS', 'MKT'],
      );
    });

    test('and an empty line still says nothing', () {
      // `journalProblem` drops empty lines before anything is sent, and
      // this is the belt: an untouched row must not arrive as a
      // department posting of nothing.
      expect(JournalDraft().isEmpty, isTrue);
    });
  });
}
