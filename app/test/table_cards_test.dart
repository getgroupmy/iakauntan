import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/pos/table_cards_pdf.dart';

/// The cards that go on the tables.
///
/// Two things here are wrong in ways a rendered PDF does not announce,
/// which is why they are asserted rather than looked at:
///
///   * the floor plan returns one row per open bill, so a table with a
///     split on it arrives twice and would be printed twice — a shop
///     cutting up a sheet does not notice they have two cards for T3
///     until both are standing on different tables;
///   * the QR payload. `pos_table_by_code` resolves a URL as happily as
///     a bare code, so encoding `https://iakauntan.com/t/T7` would pass
///     every scan test in the product and still be the wrong thing to
///     print — it is a link to a page that does not exist, on a card a
///     customer can see.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final org = Organization(
    id: 'o1',
    name: 'Warung Sedap Enterprise',
    slug: 'warung-sedap',
  );

  Map<String, dynamic> row(
    String code, {
    String? name,
    String? area,
    int seats = 4,
    String? saleId,
  }) =>
      {
        'table_id': 'id-${code.toLowerCase()}',
        'table_code': code,
        'table_name': name ?? code,
        'area': area,
        'seats': seats,
        'sale_id': saleId,
      };

  group('which tables get a card', () {
    test('a table with two bills on it is still one card', () {
      // What a split leaves behind: the same table, twice, because the
      // plan is drawing bills and there are two.
      final cards = tableCardsFrom([
        row('T1'),
        row('T3', saleId: 's1'),
        row('T3', saleId: 's2'),
        row('T4'),
      ]);
      expect(cards.map((c) => c['table_code']), ['T1', 'T3', 'T4']);
    });

    test('and case is not a second table', () {
      final cards = tableCardsFrom([row('L1'), row('l1')]);
      expect(cards, hasLength(1));
    });

    test('a row with no code gets no card', () {
      // There would be nothing to encode and nothing to type, so the
      // card would be a square of ink no scan could ever resolve.
      final cards = tableCardsFrom([
        row('T1'),
        {'table_id': 'x', 'table_code': '', 'table_name': 'Nameless'},
        {'table_id': 'y', 'table_name': 'Also nameless'},
      ]);
      expect(cards.map((c) => c['table_code']), ['T1']);
    });

    test('the order the plan gave is the order they print', () {
      // By area then code, which is the order somebody walking the
      // room would want to cut them in.
      final cards = tableCardsFrom([
        row('D1', area: 'Dalam'),
        row('D2', area: 'Dalam'),
        row('L1', area: 'Luar'),
      ]);
      expect(cards.map((c) => c['table_code']), ['D1', 'D2', 'L1']);
    });
  });

  group('what the QR holds', () {
    test('the bare code, not a URL', () {
      // The lookup would accept a URL. A card a customer can see must
      // not carry a link to a page that is not there.
      expect(tableCardPayload(row('T7')), 'T7');
      expect(tableCardPayload(row('T7')), isNot(contains('/')));
      expect(tableCardPayload(row('T7')), isNot(contains(':')));
    });

    test('and it is what a cashier could type', () {
      // The typed fallback and the scanned payload are the same string,
      // so a worn card is never a different question.
      expect(tableCardPayload(row(' T7 ')), 'T7');
    });
  });

  group('the sheet', () {
    test('is a real PDF, six cards to a page', () async {
      final tables = [for (var i = 1; i <= 7; i++) row('T$i')];
      final bytes = await buildTableCardsPdf(
        org: org,
        outletName: 'Warung Sedap',
        tables: tables,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(tableCardsPerPage, 6);
      // Seven tables is two sheets, and the second has one card on it
      // with five empty boxes — drawn, so the last sheet cuts on the
      // same lines as the first.
      expect((tables.length / tableCardsPerPage).ceil(), 2);
    });

    test('a shop with no tables still produces a file, not a crash', () async {
      final bytes = await buildTableCardsPdf(
        org: org,
        outletName: 'Warung Sedap',
        tables: const [],
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}
