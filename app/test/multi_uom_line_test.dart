import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/line_draft.dart';

/// What `item_uom_options` returns for a tin of milk powder that the
/// shop also buys by the carton of twenty-four.
const _tin = <Map<String, dynamic>>[
  {'uom_code': 'C62', 'uom_name': 'Unit', 'qty_in_stock_uom': 1, 'is_pack': false},
  {'uom_code': 'DZN', 'uom_name': 'Dozen', 'qty_in_stock_uom': 12, 'is_pack': false},
  {'uom_code': 'CT', 'uom_name': 'Carton', 'qty_in_stock_uom': 24, 'is_pack': true},
];

void main() {
  group('uomFactor', () {
    test('a carton of this item is twenty-four of it', () {
      expect(uomFactor(_tin, 'CT'), 24);
    });

    test('the item own unit is one of itself', () {
      expect(uomFactor(_tin, 'C62'), 1);
    });

    test('a unit nobody has defined converts by one, not by null', () {
      // app.uom_qty raises on a unit it cannot turn into the item's own,
      // and the editor must not guess a different number than the one
      // the ledger will use. One is the only safe answer.
      expect(uomFactor(_tin, 'PF'), 1);
      expect(uomFactor(_tin, null), 1);
    });

    test('a factor that arrived as a string still converts', () {
      // PostgREST hands numeric back as a string often enough that a
      // silent 1 here would be a wrong invoice.
      expect(
        uomFactor([
          {'uom_code': 'CT', 'qty_in_stock_uom': '24.000000'},
        ], 'CT'),
        24,
      );
    });

    test('a nonsense factor does not divide the price by zero', () {
      expect(
        uomFactor([
          {'uom_code': 'CT', 'qty_in_stock_uom': 0},
        ], 'CT'),
        1,
      );
    });
  });

  group('rescaleForUom', () {
    test('ten ringgit a tin is two hundred and forty a carton', () {
      expect(rescaleForUom(10, 1, 24), 240);
    });

    test('and back again', () {
      expect(rescaleForUom(240, 24, 1), 10);
    });

    test('a price already per carton is left alone by the same unit', () {
      expect(rescaleForUom(240, 24, 24), 240);
    });
  });

  group('baseQuantityHint', () {
    test('says what two cartons take off the shelf', () {
      expect(
        baseQuantityHint(
          quantity: 2,
          uom: 'CT',
          baseUom: 'C62',
          factor: 24,
        ),
        '= 48 C62',
      );
    });

    test('says nothing when the line is already in the item own unit', () {
      expect(
        baseQuantityHint(
          quantity: 2,
          uom: 'C62',
          baseUom: 'C62',
          factor: 1,
        ),
        isNull,
      );
    });

    test('half a kilo of rice is five hundred grams, not 500.000', () {
      expect(
        baseQuantityHint(
          quantity: 0.5,
          uom: 'KGM',
          baseUom: 'GRM',
          factor: 1000,
        ),
        '= 500 GRM',
      );
    });

    test('and a quantity that does not come out whole keeps its decimals', () {
      expect(
        baseQuantityHint(
          quantity: 1.5,
          uom: 'PR',
          baseUom: 'C62',
          factor: 2.5,
        ),
        '= 3.75 C62',
      );
    });
  });

  group('the line the editor sends', () {
    test('carries the unit it was written in', () {
      final line = LineDraft(itemId: 'i', quantity: 2, unitPrice: 240)
        ..uomCode = 'CT';
      expect(line.toJson()['uom_code'], 'CT');
      expect(line.toJson()['quantity'], 2);
      // The money is per the line's own unit and does not convert: the
      // database converts the stock, not the price.
      expect(line.totals.total, 480);
    });
  });
}
