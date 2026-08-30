import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/stall_items_dialog.dart';

Map<String, dynamic> item(String code, {String? stall}) => <String, dynamic>{
      'id': 'i-$code',
      'code': code,
      'name': 'Nasi $code',
      'stall_id': stall,
    };

void main() {
  group('what a stall sells', () {
    final all = [
      item('A1', stall: 's1'),
      item('A2'),
      item('A3', stall: 's2'),
      item('A4', stall: 's1'),
    ];

    test('is the dishes stamped with it', () {
      expect(itemsOnStall(all, 's1').map((i) => i['code']), ['A1', 'A4']);
    });

    test('an unassigned dish belongs to no stall', () {
      // pos_stall_takings counts only lines where stall_id is not
      // null, so an unassigned dish settles for nobody.
      expect(itemsOnStall(all, 's2').map((i) => i['code']), ['A3']);
      expect(itemsOnStall(all, 'nobody'), isEmpty);
    });

    test('everything else can be moved onto it', () {
      // The unassigned and the dishes another stall sells alike. 0268
      // has already decided what a move means: the line was stamped
      // when it was rung up, so moving the item "must not move money
      // with it".
      expect(
        itemsOffStall(all, 's1').map((i) => i['code']),
        ['A2', 'A3'],
      );
    });

    test('the two halves account for everything', () {
      expect(
        itemsOnStall(all, 's1').length + itemsOffStall(all, 's1').length,
        all.length,
      );
    });
  });

  group('whether a dish is spoken for', () {
    test('one on no stall is not', () {
      expect(itemIsUnassigned(item('A2')), isTrue);
    });

    test('one on a stall is', () {
      expect(itemIsUnassigned(item('A1', stall: 's1')), isFalse);
    });
  });

  group('where a dish sits now', () {
    final names = {'s1': 'Nasi Kandar Hameed', 's2': 'Char Kuey Teow Ah Seng'};

    test('says so by name, so nobody moves one without noticing', () {
      expect(
        stallItemNote(item('A3', stall: 's2'), names),
        'Now on Char Kuey Teow Ah Seng',
      );
    });

    test('says plainly when it is on none', () {
      expect(stallItemNote(item('A2'), names), 'On no stall');
    });

    test('a stall the list does not carry still reads as a stall', () {
      // A closed stall at another outlet, say: the dish is still
      // somebody's, and a blank there would read as free to take.
      expect(
        stallItemNote(item('A9', stall: 's99'), names),
        'Now on another stall',
      );
    });
  });

  group('the stalls by id', () {
    test('are keyed for looking one up', () {
      final map = stallNamesOf([
        {'id': 's1', 'code': 'A', 'name': 'Nasi Kandar Hameed'},
        {'id': 's2', 'code': 'B', 'name': 'Char Kuey Teow Ah Seng'},
      ]);
      expect(map['s1'], 'Nasi Kandar Hameed');
      expect(map['s2'], 'Char Kuey Teow Ah Seng');
    });

    test('a stall with no name falls back on its code', () {
      final map = stallNamesOf([
        {'id': 's1', 'code': 'A', 'name': null},
      ]);
      expect(map['s1'], 'A');
    });

    test('a row with no id is left out rather than keyed on null', () {
      final map = stallNamesOf([
        {'code': 'A', 'name': 'Orphan'},
      ]);
      expect(map, isEmpty);
    });
  });
}
