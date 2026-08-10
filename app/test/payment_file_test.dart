import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/download.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/hr/payment_file.dart';

PaymentLine _line({
  String employeeNo = 'EMP-0001',
  String employeeName = 'Nurul Aisyah binti Rahman',
  String? bankName = 'Maybank',
  String? bankAccountNo = '512345678901',
  double amount = 4306.75,
  String reference = '2026-02 PYR-2026-00002',
  String? problem,
}) =>
    PaymentLine(
      employeeNo: employeeNo,
      employeeName: employeeName,
      bankName: bankName,
      bankAccountNo: bankAccountNo,
      amount: amount,
      reference: reference,
      problem: problem,
    );

/// The payment file is the last thing between a posted run and someone's
/// salary, so the shape of it is worth pinning down.
void main() {
  group('csv', () {
    test('writes a header and one CRLF-terminated row per payable line', () {
      final csv = PaymentFile.csv([_line(), _line(employeeNo: 'EMP-0002')]);
      final rows = csv.split('\r\n')..removeLast();

      expect(rows, hasLength(3));
      expect(rows.first,
          '"Employee No","Employee Name","Bank","Account No","Amount","Reference"');
      expect(
        rows[1],
        '"EMP-0001","Nurul Aisyah binti Rahman","Maybank","512345678901",'
        '"4306.75","2026-02 PYR-2026-00002"',
      );
    });

    test('leaves held lines out of the file entirely', () {
      final csv = PaymentFile.csv([
        _line(),
        _line(
            employeeNo: 'EMP-0009',
            bankAccountNo: null,
            problem: 'No bank account on file'),
      ]);

      expect(csv, isNot(contains('EMP-0009')));
      expect(csv.split('\r\n').where((r) => r.isNotEmpty), hasLength(2));
    });

    test('quotes every field, so a comma in a name cannot shift a column',
        () {
      final csv = PaymentFile.csv([_line(employeeName: 'Tan Wei Ming, Jr')]);
      expect(csv, contains('"Tan Wei Ming, Jr"'));
      expect(csv.split('\r\n')[1].split('","'), hasLength(6));
    });

    test('doubles an embedded quote rather than breaking the row', () {
      final csv = PaymentFile.csv([_line(employeeName: 'Ah "Boy" Lim')]);
      expect(csv, contains('"Ah ""Boy"" Lim"'));
    });

    test('flattens a newline pasted into a name', () {
      final csv = PaymentFile.csv([_line(employeeName: 'Siti\nBinti Ali')]);
      expect(csv.split('\r\n').where((r) => r.isNotEmpty), hasLength(2));
      expect(csv, contains('"Siti Binti Ali"'));
    });

    test('writes the amount plainly, with sen and no separator', () {
      final csv = PaymentFile.csv([_line(amount: 10582.8)]);
      expect(csv, contains('"10582.80"'));
      expect(csv, isNot(contains('10,582')));
      expect(csv, isNot(contains('RM')));
    });

    test('keeps a leading zero on an account number', () {
      final csv = PaymentFile.csv([_line(bankAccountNo: '0012345678')]);
      expect(csv, contains('"0012345678"'));
    });
  });

  group('total', () {
    test('counts only what is actually going out', () {
      final total = PaymentFile.total([
        _line(amount: 4306.75),
        _line(amount: 10582.80),
        _line(amount: 4420.00, problem: 'No bank account on file'),
      ]);
      expect(total, closeTo(14889.55, 0.001));
    });
  });

  group('filename', () {
    test('names the run it came from', () {
      expect(PaymentFile.filename('PYR-2026-00002'),
          'payment-pyr-2026-00002.csv');
    });
  });

  group('saving', () {
    // Also compiles the non-web half of the conditional import, which the
    // web build alone would never exercise.
    test('reports that it did nothing off the web, so the caller falls back',
        () async {
      expect(await saveTextFile('payment.csv', 'text/csv', 'a,b'), isFalse);
    });
  });
}
