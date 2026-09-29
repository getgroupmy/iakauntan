import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/features/expenses/scanned_expense.dart';

/// What a read receipt actually fills in on the expense form.
///
/// `scan_target_fields` asks the reader for eight columns on
/// `accounting.expense` and the form used four typed properties off the
/// parse. The reader's own `description` — the "being payment of" line,
/// in the words on the page — its `payment_mode_code`, its `currency`
/// and its `tax_amount` were asked for on every receipt and dropped.
///
/// The tax is the one worth reading carefully. The form takes a tax
/// CODE and computes the figure from its rate; it does not take a
/// figure. So a printed tax can only choose a code, and only where the
/// choice recomputes to what is printed.
void main() {
  final codes = [
    TaxCode(
      id: 'sst6',
      code: 'SST6',
      name: 'Service tax 6%',
      rate: 6,
      taxTypeCode: 'SST',
    ),
    TaxCode(
      id: 'sst8',
      code: 'SST8',
      name: 'Service tax 8%',
      rate: 8,
      taxTypeCode: 'SST',
    ),
    TaxCode(
      id: 'zero',
      code: 'EX',
      name: 'Exempt',
      rate: 0,
      taxTypeCode: 'SST',
      isExempt: true,
    ),
  ];

  const modes = [
    {'code': '01', 'description': 'Cash'},
    {'code': '02', 'description': 'Cheque'},
    {'code': '03', 'description': 'Bank transfer'},
    {'code': '04', 'description': 'Credit card'},
  ];

  ScannedExpense read(Map<String, String> fields, {OcrExtraction? from}) =>
      scannedExpense(
        (from ?? const OcrExtraction()).copyWith(fields: fields),
        taxCodes: codes,
        paymentModes: modes,
      );

  test('the columns the reader answered reach the form', () {
    final filled = read({
      'expense_date': '2026-03-04',
      'reference': 'PV-1187',
      'description': 'Being payment of office rental for March 2026',
      'payment_mode_code': '02',
      'amount': '1000.00',
      'tax_amount': '60.00',
      'total_amount': '1060.00',
    });

    expect(filled.date, DateTime(2026, 3, 4));
    expect(filled.reference, 'PV-1187');
    // The four that had no path into this form before.
    expect(filled.description, 'Being payment of office rental for March 2026');
    expect(filled.paymentModeCode, '02');
    expect(filled.taxCodeId, 'sst6');
    expect(filled.amount, 1000.00);
  });

  test('a reading with no columns fills exactly what it used to', () {
    // Every receipt read before `0681`. The typed properties are the
    // fallback, and the description is still the old pairing.
    final filled = scannedExpense(
      OcrExtraction(
        supplierName: 'Kedai Runcit Maju',
        documentNo: 'R-9921',
        documentDate: DateTime(2026, 2, 2),
        totalAmount: 42.50,
      ),
      taxCodes: codes,
      paymentModes: modes,
    );

    expect(filled.description, 'Kedai Runcit Maju · R-9921');
    expect(filled.reference, 'R-9921');
    expect(filled.date, DateTime(2026, 2, 2));
    expect(filled.amount, 42.50);
    expect(filled.taxCodeId, isNull);
    // Nothing said how it was paid, so the form's own default stands.
    expect(filled.paymentModeCode, isNull);
  });

  group('the tax', () {
    test('a code is chosen only where its rate reproduces the figure', () {
      // 8% of 1000 is 80, and the chart has an 8% code.
      expect(
        read({'amount': '1000.00', 'tax_amount': '80.00'}).taxCodeId,
        'sst8',
      );
      // 9% is Singapore's. Nothing in this chart produces 90.00 on
      // 1000.00, so nothing is chosen.
      expect(
        read({'amount': '1000.00', 'tax_amount': '90.00'}).taxCodeId,
        isNull,
      );
    });

    test('the match is to the sen, on a figure that does not divide', () {
      // 6% of 138.05 is 8.283, which the form rounds to 8.28 — half
      // away from zero, in integers, the way Postgres does. A match
      // computed as tax/net would read 5.9999% and miss it.
      expect(
        read({'amount': '138.05', 'tax_amount': '8.28'}).taxCodeId,
        'sst6',
      );
      // And a sen out is not a match. 8.29 is not what 6% produces,
      // so choosing SST6 would store a figure the document does not
      // show.
      expect(
        read({'amount': '138.05', 'tax_amount': '8.29'}).taxCodeId,
        isNull,
      );
    });

    test('a tax of nothing chooses nothing', () {
      // Not the zero-rated code either: it is the absence of a charge,
      // and the form's own default of no code says that already.
      expect(
        read({'amount': '100.00', 'tax_amount': '0.00'}).taxCodeId,
        isNull,
      );
    });

    test('an exempt code is refused even where its rate would match', () {
      // `isExempt` is a claim about the PURCHASE -- nothing was charged
      // -- and a chart can carry one beside a rate. 6% of 1000 is 60,
      // so the arithmetic matches and the code is still wrong: an
      // exempt code posts to a different place and reports differently.
      final filled = scannedExpense(
        const OcrExtraction(
          fields: {'amount': '1000.00', 'tax_amount': '60.00'},
        ),
        taxCodes: [
          TaxCode(
            id: 'ex6',
            code: 'EX6',
            name: 'Exempt supply',
            rate: 6,
            taxTypeCode: 'SST',
            isExempt: true,
          ),
        ],
      );

      expect(filled.taxCodeId, isNull);
    });

    test('no chart means no code, not a guess', () {
      expect(
        scannedExpense(
          const OcrExtraction(
            fields: {'amount': '1000.00', 'tax_amount': '60.00'},
          ),
        ).taxCodeId,
        isNull,
      );
    });

    test('a matched code puts the NET in the amount box', () {
      // The form computes the tax from the rate and adds it, so the
      // box holds the figure before tax and the expense totals 1060.
      final filled = read({
        'amount': '1000.00',
        'tax_amount': '60.00',
        'total_amount': '1060.00',
      });

      expect(filled.amount, 1000.00);
      expect(filled.taxCodeId, 'sst6');
    });

    test('an unmatched tax puts the TOTAL in the amount box', () {
      // The behaviour this file changes, and the reason it exists. The
      // form used to take `subtotal ?? total`, so a receipt printing
      // 1000 + 90 = 1090 with no matching code recorded an expense of
      // 1000 with no tax: ninety ringgit of a real payment gone from
      // the ledger, with nothing on screen saying so. A company that
      // cannot match the code is not claiming the input tax, and for
      // it the whole 1090 is the cost.
      final filled = read({
        'amount': '1000.00',
        'tax_amount': '90.00',
        'total_amount': '1090.00',
      });

      expect(filled.amount, 1090.00);
      expect(filled.taxCodeId, isNull);
    });

    test('a receipt showing one figure is that figure', () {
      expect(read({'total_amount': '42.50'}).amount, 42.50);
      // And with no total at all, whatever it did print.
      expect(read({'amount': '42.50'}).amount, 42.50);
    });
  });

  group('the payment mode', () {
    test('a code the company offers is taken', () {
      expect(read({'payment_mode_code': '04'}).paymentModeCode, '04');
    });

    test('anything else is refused, leaving the form its default', () {
      // `payment_mode_code` is a foreign key into `ref_payment_modes`.
      // The reader is given the eight codes and still answers in words
      // often enough to be worth refusing rather than trusting: written
      // through, it fails at save time with a message about a
      // constraint.
      expect(read({'payment_mode_code': 'cash'}).paymentModeCode, isNull);
      expect(read({'payment_mode_code': '99'}).paymentModeCode, isNull);
      expect(
        scannedExpense(
          const OcrExtraction(fields: {'payment_mode_code': '01'}),
        ).paymentModeCode,
        isNull,
      );
    });
  });

  group('the currency', () {
    test('a document in the company currency says nothing', () {
      expect(read({'currency': 'MYR'}).foreignCurrency, isNull);
    });

    test('a document in another currency is named', () {
      // It cannot be stored -- `recordExpense` sets neither `currency`
      // nor `exchange_rate` -- so the only honest thing is to say so.
      // A USD receipt posted as ringgit is a wrong number that looks
      // like a right one.
      expect(read({'currency': 'USD'}).foreignCurrency, 'USD');
    });

    test('against a company that does not keep books in ringgit', () {
      final filled = scannedExpense(
        const OcrExtraction(fields: {'currency': 'SGD'}),
        homeCurrency: 'SGD',
      );

      expect(filled.foreignCurrency, isNull);
    });
  });

  group('what is refused', () {
    test('a date that is not a date', () {
      // Neither becomes the first of January, or the fourth of March.
      expect(read({'expense_date': '2026'}).date, isNull);
      expect(read({'expense_date': '04/03/2026'}).date, isNull);
      expect(read({'expense_date': 'last Tuesday'}).date, isNull);
      expect(read({'expense_date': '2026-03-04'}).date, DateTime(2026, 3, 4));
    });

    test('a timestamp keeps its day and loses its time', () {
      // `expenses.expense_date` is a `date`. The day is taken exactly
      // as written -- 18:00 UTC is already the fifth in Malaysia, and a
      // document dated the fourth must not be filed on the fifth by
      // arithmetic nobody asked for.
      expect(
        read({'expense_date': '2026-03-04T18:00:00Z'}).date,
        DateTime(2026, 3, 4),
      );
    });

    test('a blank answer is not an answer', () {
      final filled = scannedExpense(
        OcrExtraction(
          documentNo: 'R-9921',
          documentDate: DateTime(2026, 2, 2),
          fields: const {'reference': '  ', 'expense_date': ''},
        ),
        taxCodes: codes,
        paymentModes: modes,
      );

      expect(filled.reference, 'R-9921');
      expect(filled.date, DateTime(2026, 2, 2));
    });

    test('nothing read fills nothing', () {
      expect(scannedExpense(null).isEmpty, isTrue);
      expect(scannedExpense(const OcrExtraction()).isEmpty, isTrue);
    });
  });
}
