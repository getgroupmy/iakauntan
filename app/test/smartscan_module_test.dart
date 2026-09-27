import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/ocr_repository.dart';

/// SmartScan as a module, and a statement as many rows. `0682`.
///
/// Both of these read off the wire, and both have a wrong answer that
/// looks exactly like a right one:
///
///   * `has_module` absent must mean ON. A database that predates
///     `0682` does not send it, and reading a missing field as "off"
///     would tell every company on the old schema that their module has
///     lapsed — on a card that then refuses to work.
///
///   * `rows` absent must mean an empty list, not a list of empty maps.
///     A statement with three blank lines in the middle is worse than
///     one with three lines missing: the blanks look like entries
///     somebody has to go and explain.
void main() {
  group('the module', () {
    test('a company that has it is told so', () {
      final s = OcrSettings.fromJson(const {
        'enabled': true,
        'has_module': true,
        'provider': 'gemini',
        'key_source': 'platform',
        'balance': 0,
        'price': 0,
      });
      expect(s.hasModule, isTrue);
    });

    test('and a company that does not', () {
      final s = OcrSettings.fromJson(const {
        'enabled': false,
        'has_module': false,
        'provider': 'gemini',
        'key_source': 'platform',
        'balance': 0,
        'price': 0,
      });
      expect(s.hasModule, isFalse);
    });

    // The one that would put a lapsed-module warning on every card in
    // the product the moment an older database answered.
    test('an older database that does not send it reads as on', () {
      final s = OcrSettings.fromJson(const {
        'enabled': true,
        'provider': 'gemini',
        'key_source': 'platform',
        'balance': 0,
        'price': 0,
      });
      expect(s.hasModule, isTrue);
    });

    test('and the default is on, for the same reason', () {
      expect(OcrSettings.off.hasModule, isTrue);
    });
  });

  group('a statement, which is many rows', () {
    test('the lines arrive in the order they were read', () {
      final e = OcrExtraction.fromJson(const {
        'target': 'accounting.bank_statement',
        'rows': [
          {'transaction_date': '01/09/2026', 'amount': '-250.00'},
          {'transaction_date': '03/09/2026', 'amount': '1,900.00'},
        ],
      });
      expect(e.rows, hasLength(2));
      expect(e.rows.first['amount'], '-250.00');
      // As printed. `1,900.00` is not a number until somebody who knows
      // the column decides what the comma is doing.
      expect(e.rows.last['amount'], '1,900.00');
      expect(e.target, 'accounting.bank_statement');
    });

    // Every other document, which is nearly all of them.
    test('a document that is one record has no rows', () {
      final e = OcrExtraction.fromJson(const {
        'target': 'purchases.bill',
        'fields': {'doc_no': 'INV-1'},
      });
      expect(e.rows, isEmpty);
      // And says nothing about rows on the way back out, rather than
      // writing `[]` — which reads as "asked and found none" when it
      // was never asked.
      expect(e.toJson().containsKey('rows'), isFalse);
    });

    test('a blank line is dropped, not kept as a gap', () {
      final e = OcrExtraction.fromJson(const {
        'rows': [
          {'amount': '10.00'},
          {'amount': '   ', 'description': ''},
          {'amount': '20.00'},
        ],
      });
      // Two, not three. A blank line in the middle of a statement looks
      // like an entry somebody has to go and explain.
      expect(e.rows, hasLength(2));
      expect(e.rows.map((r) => r['amount']), ['10.00', '20.00']);
    });

    test('nonsense in the array is skipped rather than thrown on', () {
      final e = OcrExtraction.fromJson(const {
        'rows': ['a string', 42, null, {'amount': '5.00'}],
      });
      expect(e.rows, hasLength(1));
    });

    test('rows survive a copyWith', () {
      final e = OcrExtraction.fromJson(const {
        'rows': [{'amount': '10.00'}],
      });
      expect(e.copyWith(note: 'checked').rows, hasLength(1));
    });

    test('and go back out the way they came in', () {
      final e = OcrExtraction.fromJson(const {
        'rows': [{'amount': '10.00'}],
      });
      expect(e.toJson()['rows'], [{'amount': '10.00'}]);
    });
  });
}
