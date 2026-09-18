import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/pdf_kit.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/contacts/brought_forward.dart';
import 'package:iakauntan/src/features/contacts/brought_forward_pdf.dart';

/// A line, with only the fields a given assertion cares about spelled
/// out. The defaults are deliberately zero so a test that says nothing
/// about a currency amount is not accidentally asserting one.
StatementLine line({
  required int lineNo,
  String kind = 'invoice',
  String? docNo,
  DateTime? entryDate,
  DateTime? dueDate,
  String? currency,
  double debit = 0,
  double credit = 0,
  double baseDebit = 0,
  double baseCredit = 0,
  double balance = 0,
}) => StatementLine(
  lineNo: lineNo,
  entryDate: entryDate,
  kind: kind,
  docNo: docNo,
  dueDate: dueDate,
  currency: currency,
  debit: debit,
  credit: credit,
  baseDebit: baseDebit,
  baseCredit: baseCredit,
  balance: balance,
);

/// The shape `report_statement_of_account` actually returns: an opening
/// row at line 0, then movements numbered from 1, each carrying the
/// running balance after itself.
///
///   brought forward   500.00
///   invoice         1,200.00 -> 1,700.00
///   payment           700.00 -> 1,000.00
List<StatementLine> ordinaryStatement() => [
  line(lineNo: 0, kind: 'opening', balance: 500),
  line(
    lineNo: 1,
    kind: 'invoice',
    docNo: 'INV-0001',
    baseDebit: 1200,
    debit: 1200,
    balance: 1700,
  ),
  line(
    lineNo: 2,
    kind: 'receipt',
    docNo: 'RCP-0001',
    baseCredit: 700,
    credit: 700,
    balance: 1000,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('opening', () {
    test('is the balance on the line the function numbers zero', () {
      expect(statementOpening(ordinaryStatement()), 500);
    });

    test('is nil when the period begins with nothing owed', () {
      // The function still emits the opening row; it just carries zero.
      expect(
        statementOpening([
          line(lineNo: 0, kind: 'opening'),
          line(lineNo: 1, baseDebit: 300, balance: 300),
        ]),
        0,
      );
    });

    test('is nil when there are no lines at all', () {
      expect(statementOpening(const []), 0);
    });

    test('is negative when the customer was in credit', () {
      // An overpayment carried into the period. A statement that
      // clamped this at zero would ask for money already paid.
      expect(
        statementOpening([line(lineNo: 0, kind: 'opening', balance: -250)]),
        -250,
      );
    });

    test('is the opening line, not the first line', () {
      // Defensive: if a caller ever hands these over unsorted, reading
      // position 0 would take a movement's running balance as the
      // brought-forward figure and every number under it would be
      // wrong by that much.
      final shuffled = [
        line(lineNo: 1, baseDebit: 1200, balance: 1700),
        line(lineNo: 0, kind: 'opening', balance: 500),
      ];
      expect(statementOpening(shuffled), 500);
    });
  });

  group('closing', () {
    test('is the last running balance the function carried', () {
      expect(statementClosing(ordinaryStatement()), 1000);
    });

    test('is the opening balance when nothing happened in the period', () {
      expect(
        statementClosing([line(lineNo: 0, kind: 'opening', balance: 500)]),
        500,
      );
    });

    test('is nil when there are no lines at all', () {
      expect(statementClosing(const []), 0);
    });

    test('is not a sum computed here', () {
      // If closing were recomputed rather than read, this contrived row
      // -- whose movement disagrees with its own running balance --
      // would report 900 instead of the 999 the database said. The
      // disagreement is what statementAddsUp is for; closing's job is
      // to report the figure the report produced.
      final wrong = [
        line(lineNo: 0, kind: 'opening', balance: 500),
        line(lineNo: 1, baseDebit: 400, balance: 999),
      ];
      expect(statementClosing(wrong), 999);
    });
  });

  group('movements', () {
    test('are every line except the brought-forward one', () {
      final m = statementMovements(ordinaryStatement());
      expect(m.length, 2);
      expect(m.map((l) => l.docNo), ['INV-0001', 'RCP-0001']);
    });

    test('keep the order the function returned them in', () {
      final m = statementMovements(ordinaryStatement());
      expect(m.first.lineNo, 1);
      expect(m.last.lineNo, 2);
    });

    test('are empty when nothing happened in the period', () {
      expect(
        statementMovements([line(lineNo: 0, kind: 'opening', balance: 500)]),
        isEmpty,
      );
    });

    test('drop the opening line by its number, not by its kind', () {
      // `kind` is a label; `line_no` is the contract. A row the
      // database numbered 0 is the opening balance whatever it is
      // called, and including it would double-count the brought-forward
      // figure into the movements.
      expect(
        statementMovements([line(lineNo: 0, kind: 'invoice', balance: 500)]),
        isEmpty,
      );
    });
  });

  group('adds up', () {
    test('an ordinary statement does', () {
      expect(statementAddsUp(ordinaryStatement()), isTrue);
    });

    test('a statement whose running balance skips a movement does not', () {
      // 500 + 1200 - 700 is 1000. This one claims 1700, which is the
      // balance before the payment -- a receipt banked and not shown.
      // The customer pays twice or telephones; either way the statement
      // must not be sent.
      final missed = [
        line(lineNo: 0, kind: 'opening', balance: 500),
        line(lineNo: 1, baseDebit: 1200, balance: 1700),
        line(lineNo: 2, kind: 'receipt', baseCredit: 700, balance: 1700),
      ];
      expect(statementAddsUp(missed), isFalse);
    });

    test('a wrong opening balance is caught', () {
      // Movements and closing agree with each other; only the
      // brought-forward figure is wrong. Checking closing against the
      // last row alone would pass this.
      final lines = [
        line(lineNo: 0, kind: 'opening', balance: 400),
        line(lineNo: 1, baseDebit: 1200, balance: 1700),
        line(lineNo: 2, kind: 'receipt', baseCredit: 700, balance: 1000),
      ];
      expect(statementAddsUp(lines), isFalse);
    });

    test('a credit is subtracted, not added', () {
      // 0 + 1000 - 1000 is nil. If baseCredit were added the running
      // total would be 2000 and this statement would be rejected.
      final lines = [
        line(lineNo: 0, kind: 'opening'),
        line(lineNo: 1, baseDebit: 1000, balance: 1000),
        line(lineNo: 2, kind: 'receipt', baseCredit: 1000),
      ];
      expect(statementAddsUp(lines), isTrue);
    });

    test('the base figures are what is added, not the document ones', () {
      // A USD 1,000 invoice at 4.70, settled in full. The running
      // balance is kept in ringgit; adding the 1,000 and the 1,000 the
      // customer sees would produce nil by coincidence, so the amounts
      // here are chosen to differ.
      final lines = [
        line(lineNo: 0, kind: 'opening'),
        line(
          lineNo: 1,
          currency: 'USD',
          debit: 1000,
          baseDebit: 4700,
          balance: 4700,
        ),
      ];
      expect(statementAddsUp(lines), isTrue);
      expect(statementClosing(lines), 4700);
    });

    test('a half-sen of floating-point drift is tolerated', () {
      // Three thirds of a hundred: the sum of the rounded parts cannot
      // land exactly on the rounded whole in binary floating point.
      final lines = [
        line(lineNo: 0, kind: 'opening'),
        line(lineNo: 1, baseDebit: 33.33, balance: 33.33),
        line(lineNo: 2, baseDebit: 33.33, balance: 66.66),
        line(lineNo: 3, baseDebit: 33.34, balance: 100),
      ];
      expect(statementAddsUp(lines), isTrue);
    });

    test('a whole sen of disagreement is not tolerated', () {
      // The tolerance is for binary drift, not for a wrong figure. One
      // sen out is one sen the customer cannot explain.
      final lines = [
        line(lineNo: 0, kind: 'opening'),
        line(lineNo: 1, baseDebit: 100, balance: 100.01),
      ];
      expect(statementAddsUp(lines), isFalse);
    });

    test('an empty statement adds up', () {
      // Nothing to disagree. A contact with no history in the period is
      // a statement of nil, not an error.
      expect(statementAddsUp(const []), isTrue);
    });

    test('a statement of nothing but an opening balance adds up', () {
      expect(
        statementAddsUp([line(lineNo: 0, kind: 'opening', balance: 500)]),
        isTrue,
      );
    });
  });

  group('kind labels', () {
    test('name each kind the function can return', () {
      // Every value in the SQL's union -- if one gains a kind and this
      // does not, the fallthrough prints the column name at a customer.
      expect(statementKindLabel('opening'), 'Balance brought forward');
      expect(statementKindLabel('invoice'), 'Invoice');
      expect(statementKindLabel('credit_note'), 'Credit note');
      expect(statementKindLabel('debit_note'), 'Debit note');
      expect(statementKindLabel('refund_note'), 'Refund');
      expect(statementKindLabel('receipt'), 'Payment received');
    });

    test('call a receipt a payment, not a receipt', () {
      // The customer sent the money; "receipt" is our word for our
      // record of it.
      expect(statementKindLabel('receipt'), 'Payment received');
      expect(statementKindLabel('receipt'), isNot(contains('Receipt')));
    });

    test('never print an underscore at a customer', () {
      for (final k in const [
        'opening',
        'invoice',
        'credit_note',
        'debit_note',
        'refund_note',
        'receipt',
        'something_nobody_added_here',
      ]) {
        expect(statementKindLabel(k), isNot(contains('_')), reason: k);
      }
    });

    test('an unknown kind falls through to something readable', () {
      expect(statementKindLabel('proforma_invoice'), 'proforma invoice');
    });

    test('the labels are distinct', () {
      // A credit note and a debit note move the balance opposite ways.
      // Two lines labelled the same on a page of figures is the one
      // mislabelling a customer cannot see through.
      const kinds = [
        'opening',
        'invoice',
        'credit_note',
        'debit_note',
        'refund_note',
        'receipt',
      ];
      final labels = kinds.map(statementKindLabel).toSet();
      expect(labels.length, kinds.length);
    });
  });

  group('period label', () {
    test('reads as a Malaysian date range', () {
      expect(
        statementPeriodLabel(DateTime(2026, 4, 1), DateTime(2026, 4, 30)),
        '01/04/2026 to 30/04/2026',
      );
    });

    test('says the from date first', () {
      final s = statementPeriodLabel(DateTime(2026, 1, 5), DateTime(2026, 9, 8));
      expect(s.indexOf('05/01/2026'), lessThan(s.indexOf('08/09/2026')));
    });
  });

  group('default period', () {
    test('is the current month to today', () {
      final p = statementDefaultPeriod(DateTime(2026, 9, 18));
      expect(p.from, DateTime(2026, 9, 1));
      expect(p.to, DateTime(2026, 9, 18));
    });

    test('does not run past today into the rest of the month', () {
      // The statement is of what has happened. Ending it at the month
      // end would print a period whose last fortnight is blank because
      // it has not occurred yet.
      final p = statementDefaultPeriod(DateTime(2026, 9, 18));
      expect(p.to.day, 18);
      expect(p.to.isAfter(DateTime(2026, 9, 18)), isFalse);
    });

    test('begins on the first of the month on the first of the month', () {
      final p = statementDefaultPeriod(DateTime(2026, 2, 1));
      expect(p.from, DateTime(2026, 2, 1));
      expect(p.to, DateTime(2026, 2, 1));
    });

    test('keeps the year with the month in January', () {
      // A from-date built by subtracting a month somewhere would land
      // in the previous December here.
      final p = statementDefaultPeriod(DateTime(2026, 1, 9));
      expect(p.from, DateTime(2026, 1, 1));
      expect(p.from.year, 2026);
    });

    test('from is never after to', () {
      for (final d in [
        DateTime(2026, 1, 1),
        DateTime(2026, 2, 28),
        DateTime(2024, 2, 29),
        DateTime(2026, 12, 31),
      ]) {
        final p = statementDefaultPeriod(d);
        expect(p.from.isAfter(p.to), isFalse, reason: '$d');
      }
    });
  });

  group('from json', () {
    test('reads the columns the function returns', () {
      final l = StatementLine.fromJson(const {
        'line_no': 2,
        'entry_date': '2026-04-15',
        'kind': 'invoice',
        'doc_no': 'INV-0007',
        'due_date': '2026-05-15',
        'currency': 'USD',
        'debit': '1000.00',
        'credit': '0',
        'base_debit': '4700.00',
        'base_credit': '0',
        'balance': '4700.00',
      });
      expect(l.lineNo, 2);
      expect(l.entryDate, DateTime(2026, 4, 15));
      expect(l.kind, 'invoice');
      expect(l.docNo, 'INV-0007');
      expect(l.dueDate, DateTime(2026, 5, 15));
      expect(l.currency, 'USD');
      expect(l.debit, 1000);
      expect(l.baseDebit, 4700);
      expect(l.balance, 4700);
      expect(l.isOpening, isFalse);
    });

    test('reads the opening row, whose document columns are all null', () {
      final l = StatementLine.fromJson(const {
        'line_no': 0,
        'entry_date': '2026-03-31',
        'kind': 'opening',
        'doc_no': null,
        'due_date': null,
        'currency': null,
        'debit': 0,
        'credit': 0,
        'base_debit': 0,
        'base_credit': 0,
        'balance': 500,
      });
      expect(l.isOpening, isTrue);
      expect(l.docNo, isNull);
      expect(l.dueDate, isNull);
      expect(l.currency, isNull);
      expect(l.balance, 500);
    });

    test('trims the currency, which arrives as a padded char(3)', () {
      // The column is `char(3)`; postgrest returns it padded when the
      // code is shorter than three, and an untrimmed code would not
      // match the currency map.
      final l = StatementLine.fromJson(const {'line_no': 1, 'currency': 'MYR '});
      expect(l.currency, 'MYR');
    });

    test('a row read back keeps a statement adding up', () {
      final lines = [
        StatementLine.fromJson(const {
          'line_no': 0,
          'kind': 'opening',
          'balance': '500.00',
        }),
        StatementLine.fromJson(const {
          'line_no': 1,
          'kind': 'invoice',
          'base_debit': '1200.00',
          'balance': '1700.00',
        }),
        StatementLine.fromJson(const {
          'line_no': 2,
          'kind': 'receipt',
          'base_credit': '700.00',
          'balance': '1000.00',
        }),
      ];
      expect(statementAddsUp(lines), isTrue);
      expect(statementOpening(lines), 500);
      expect(statementClosing(lines), 1000);
    });
  });

  group('pdf', () {
    final org = Organization(
      id: 'o1',
      name: 'Sinar Teknologi Sdn Bhd',
      slug: 'sinar',
      registrationNo: '202301004567',
      addressLine1: 'Level 12, Menara Sinar',
      city: 'Kuala Lumpur',
    );

    final contact = Contact(
      id: 'c1',
      code: 'CUST-0004',
      name: 'Bumi Maju Enterprise',
      contactType: 'customer',
      addressLine1: 'No 8, Jalan Dagang',
      city: 'Shah Alam',
      postcode: '40000',
    );

    final from = DateTime(2026, 4, 1);
    final to = DateTime(2026, 4, 30);

    test('produces a real PDF', () async {
      final bytes = await buildBroughtForwardPdf(
        org: org,
        contact: contact,
        lines: ordinaryStatement(),
        from: from,
        to: to,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(), '%%EOF');
    });

    test('a customer with nothing in the period still gets a statement', () {
      // Not an error. A period with no movement and no opening balance
      // is a statement of nil, and the customer asked for it.
      expect(
        buildBroughtForwardPdf(
          org: org,
          contact: contact,
          lines: const [],
          from: from,
          to: to,
        ),
        completes,
      );
    });

    test('a foreign-currency line does not stop the page', () async {
      final bytes = await buildBroughtForwardPdf(
        org: org,
        contact: contact,
        lines: [
          line(lineNo: 0, kind: 'opening'),
          line(
            lineNo: 1,
            docNo: 'INV-9',
            currency: 'USD',
            debit: 1000,
            baseDebit: 4700,
            balance: 4700,
          ),
        ],
        from: from,
        to: to,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('honours pre-printed stationery', () async {
      final printed = await buildBroughtForwardPdf(
        org: org,
        contact: contact,
        lines: ordinaryStatement(),
        from: from,
        to: to,
      );
      final onPaper = await buildBroughtForwardPdf(
        org: org,
        contact: contact,
        lines: ordinaryStatement(),
        from: from,
        to: to,
        mode: LetterheadMode.stationery,
      );
      // The two differ: the stationery form leaves the head of the page
      // blank for what is already on the paper.
      expect(printed.length, isNot(onPaper.length));
    });
  });
}
