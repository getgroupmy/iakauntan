import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/stock/new_warehouse_dialog.dart';

/// Adding a warehouse from the box that wanted one.
void main() {
  group('the code suggested from a name', () {
    test('is the first word, upper case', () {
      expect(suggestWarehouseCode('Shah Alam store'), 'SHAH');
      expect(suggestWarehouseCode('penang'), 'PENANG');
    });

    test('drops what the column would not want', () {
      // A code is typed into reports and file names; a space or a
      // bracket in the suggestion is a suggestion nobody keeps.
      expect(suggestWarehouseCode('K.L. (main)'), 'KL');
      expect(suggestWarehouseCode('JB-2 warehouse'), 'JB2');
    });

    test('stops at six characters', () {
      expect(suggestWarehouseCode('Kualalumpur central'), 'KUALAL');
    });

    test('and a name with nothing usable suggests nothing', () {
      // Rather than suggesting something the person then has to clear.
      expect(suggestWarehouseCode(''), '');
      expect(suggestWarehouseCode('   '), '');
      expect(suggestWarehouseCode('!!!'), '');
    });
  });

  group('the rows the picker offers', () {
    final rows = [
      {'id': 'w1', 'code': 'KL', 'name': 'Kuala Lumpur'},
      {'id': 'w2', 'code': 'JB2', 'name': 'Johor Bahru second'},
    ];

    test('are named, and carry the code as a second line', () {
      final options = warehouseOptions(rows);
      expect(options.map((o) => o.value), ['w1', 'w2']);
      expect(options.first.label, 'Kuala Lumpur');
      expect(options.first.sublabel, 'KL');
    });

    test('and are findable by the code somebody says out loud', () {
      // The storeman types "JB2"; the clerk types "Johor". Neither
      // should have to know which the list was sorted by.
      expect(warehouseOptions(rows)[1].keywords, contains('JB2'));
    });

    test('a warehouse with no code shows no empty second line', () {
      final options = warehouseOptions([
        {'id': 'w3', 'code': '', 'name': 'Unnamed'},
      ]);
      expect(options.single.sublabel, isNull);
    });
  });
}
