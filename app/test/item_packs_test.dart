import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/items/item_packs_dialog.dart';

Map<String, dynamic> option(String code, {num qty = 1, bool pack = false}) =>
    <String, dynamic>{
      'uom_code': code,
      'uom_name': code,
      'qty_in_stock_uom': qty,
      'is_pack': pack,
    };

Map<String, dynamic> uom(String code) =>
    <String, dynamic>{'code': code, 'name': code};

void main() {
  group('which rows are the shop’s to change', () {
    test('only the packs it declared', () {
      // item_uom_options returns reference units of the item's own
      // dimension alongside the declared packs. The standards body has
      // already said how big a kilogram is.
      final list = declaredPacks([
        option('KGM', qty: 1000),
        option('GRM'),
        option('CT', qty: 24, pack: true),
      ]);
      expect(list.map((p) => p['uom_code']), ['CT']);
    });

    test('nothing declared is an empty list, not a missing one', () {
      expect(declaredPacks([option('KGM', qty: 1000)]), isEmpty);
    });
  });

  group('which units a pack size can be declared for', () {
    final all = [uom('C62'), uom('CT'), uom('BX'), uom('DZN')];

    test('not the item’s own unit', () {
      // upsert_item_uom_pack refuses it by name: "One % is one %, and
      // saying so twice is how the two copies come to disagree."
      final list = packableUoms(all, const [], 'C62');
      expect(list.map((u) => u['code']), ['CT', 'BX', 'DZN']);
    });

    test('not one already declared, which is edited in place', () {
      final list = packableUoms(all, [option('CT', qty: 24, pack: true)], 'C62');
      expect(list.map((u) => u['code']), ['BX', 'DZN']);
    });

    test('a reference unit is still offered', () {
      // A pack the shop sets beats the reference factor, so a bakery
      // whose dozen is thirteen can say so.
      expect(
        packableUoms(all, const [], 'C62').map((u) => u['code']),
        contains('DZN'),
      );
    });

    test('everything taken leaves nothing to add', () {
      final list = packableUoms(
        [uom('C62'), uom('CT')],
        [option('CT', qty: 24, pack: true)],
        'C62',
      );
      expect(list, isEmpty);
    });

    test('the order the reference list came in is kept', () {
      expect(
        packableUoms(all, const [], 'ZZZ').map((u) => u['code']),
        ['C62', 'CT', 'BX', 'DZN'],
      );
    });
  });

  group('how many it holds', () {
    test('a whole number of tins', () {
      expect(packSizeOf('24'), 24);
    });

    test('a fraction, because half a metre of cloth is a real pack', () {
      expect(packSizeOf('0.5'), 0.5);
      expect(packSizeOf('1.125'), 1.125);
    });

    test('commas the way people type them', () {
      expect(packSizeOf('1,000'), 1000);
    });

    test('nothing, zero and below are refused', () {
      // "A pack has to hold something."
      expect(packSizeOf(''), isNull);
      expect(packSizeOf('0'), isNull);
      expect(packSizeOf('-1'), isNull);
      expect(packSizeOf('a lot'), isNull);
    });
  });

  group('what a declared pack reads as', () {
    test('names both units and the count between them', () {
      final s = packLabel(option('CT', qty: 24, pack: true), 'C62');
      expect(s, contains('CT'));
      expect(s, contains('24'));
      expect(s, contains('C62'));
    });

    test('a fractional pack is not rounded away', () {
      expect(packLabel(option('MTR', qty: 0.5, pack: true), 'CMT'),
          contains('0.5'));
    });
  });
}
