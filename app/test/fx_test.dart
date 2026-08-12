import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/layout.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/fx.dart';

/// The currency rules the forms enforce.
///
/// The ledger is the authority — `app.exchange_rate_for` refuses to
/// guess a rate, `app.realised_fx_on_settlement` refuses a mixed-currency
/// receipt — and these assert that the client refuses the same things,
/// early enough that the user can still fix them.
void main() {
  BusinessDocument doc(String no, String currency, {double rate = 1}) =>
      BusinessDocument(
        id: no,
        docType: 'invoice',
        docNo: no,
        docDate: DateTime(2026, 1, 1),
        contactId: 'c1',
        currency: currency,
        exchangeRate: rate,
      );

  group('a rate that may be submitted', () {
    test('base currency needs none', () {
      expect(
        rateIsUsable(currency: 'MYR', baseCurrency: 'MYR', rate: null),
        isTrue,
      );
    });

    test('a foreign document with no rate is refused', () {
      expect(
        rateIsUsable(currency: 'USD', baseCurrency: 'MYR', rate: null),
        isFalse,
        reason: 'saving would post the invoice at par — the failure '
            'migration 0078 exists to prevent',
      );
    });

    test('a foreign document at a positive rate is accepted', () {
      expect(
        rateIsUsable(currency: 'USD', baseCurrency: 'MYR', rate: 4.7),
        isTrue,
      );
    });

    test('zero and negative rates are refused', () {
      for (final bad in [0.0, -4.7]) {
        expect(
          rateIsUsable(currency: 'USD', baseCurrency: 'MYR', rate: bad),
          isFalse,
          reason: 'exchange_rates.rate carries check (rate > 0)',
        );
      }
    });
  });

  group('parsing a typed rate', () {
    test('accepts what the column accepts', () {
      expect(parseRate('4.70'), 4.7);
      expect(parseRate(' 4.7 '), 4.7);
      expect(parseRate('0.00028'), 0.00028);
      expect(parseRate('1,234.5'), 1234.5);
    });

    test('rejects what it does not', () {
      expect(parseRate(''), isNull);
      expect(parseRate('nought'), isNull);
      expect(parseRate('0'), isNull);
      expect(parseRate('-4.7'), isNull);
    });
  });

  test('the caption states the direction', () {
    expect(
      rateCaption(currency: 'USD', baseCurrency: 'MYR', rate: 4.7),
      '1 USD = 4.70 MYR',
      reason: '4.70 and 0.2128 are both plausible rates for this pair and '
          'only one of them posts the invoice correctly',
    );
  });

  group('realised gain and loss', () {
    // The same two cases as supabase/tests/multicurrency.sql. If these
    // drift apart, the dialog is promising one figure and the ledger is
    // posting another.
    test('a receipt at a lower rate is a loss', () {
      expect(
        realisedFx(
          isReceipt: true,
          settlementRate: 4.50,
          allocations: [(amount: 10000, documentRate: 4.70)],
        ),
        closeTo(-2000, 0.005),
      );
    });

    test('a receipt at a higher rate is a gain', () {
      expect(
        realisedFx(
          isReceipt: true,
          settlementRate: 4.70,
          allocations: [(amount: 10000, documentRate: 4.50)],
        ),
        closeTo(2000, 0.005),
      );
    });

    test('a payment flips the sign', () {
      expect(
        realisedFx(
          isReceipt: false,
          settlementRate: 4.70,
          allocations: [(amount: 10000, documentRate: 4.50)],
        ),
        closeTo(-2000, 0.005),
        reason: 'a payable that cost more to settle than it was booked at '
            'is a loss, where the same movement on a receivable is a gain',
      );
    });

    test('nothing moves when the rate did not', () {
      expect(
        realisedFx(
          isReceipt: true,
          settlementRate: 4.70,
          allocations: [
            (amount: 10000, documentRate: 4.70),
            (amount: 2500, documentRate: 4.70),
          ],
        ),
        0,
      );
    });

    test('each allocation is rounded before they are added', () {
      // Matches round(..., 2) per row in the SQL, not one rounding at
      // the end — two 0.005 differences must not compound into a sen
      // the ledger did not post.
      expect(
        realisedFx(
          isReceipt: true,
          settlementRate: 4.7,
          allocations: [
            (amount: 33.33, documentRate: 4.5),
            (amount: 33.33, documentRate: 4.5),
          ],
        ),
        closeTo(13.34, 0.0001),
      );
    });
  });

  group('the currency a settlement must carry', () {
    test('nothing selected falls back to the base currency', () {
      final chosen = settlementCurrency(const [], 'MYR');
      expect(chosen.code, 'MYR');
      expect(chosen.isConflicting, isFalse);
    });

    test('one currency across the selection is that currency', () {
      final chosen = settlementCurrency(
        [doc('INV-1', 'USD', rate: 4.7), doc('INV-2', 'USD', rate: 4.5)],
        'MYR',
      );
      expect(chosen.code, 'USD');
      expect(chosen.isConflicting, isFalse,
          reason: 'two rates in one currency is ordinary — that difference '
              'is the realised gain, not a conflict');
    });

    test('a mixture is refused, naming the documents', () {
      final chosen = settlementCurrency(
        [doc('INV-1', 'USD'), doc('INV-2', 'MYR')],
        'MYR',
      );
      expect(chosen.isConflicting, isTrue);
      expect(chosen.conflict, contains('INV-1'));
      expect(chosen.conflict, contains('INV-2'));
    });
  });

  group('packing form fields into rows', () {
    test('fills to the row width and no further', () {
      // The document header: contact, date, due date, currency, rate,
      // reference, supplier invoice no.
      expect(
        packRows([2, 1, 1, 1, 1, 2, 1]),
        [
          [0, 1],
          [2, 3, 4],
          [5, 6],
        ],
      );
    });

    test('no field is ever dropped', () {
      for (final flexes in [
        <int>[],
        [1],
        [3, 3, 3],
        [2, 2, 2, 2],
        [1, 1, 1, 1, 1, 1, 1],
      ]) {
        final packed = packRows(flexes).expand((r) => r).toList();
        expect(packed, List.generate(flexes.length, (i) => i),
            reason: 'every field, once, in order — the old hand-indexed '
                'layout guaranteed neither');
      }
    });

    test('a field wider than a row gets one to itself', () {
      expect(packRows([4, 1]), [
        [0],
        [1],
      ]);
    });
  });
}
