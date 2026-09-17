import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/items/item_categories.dart';

/// A warung's shelf: drinks with two kinds of coffee under them, and
/// raw ingredients with a coffee of their own.
List<Map<String, dynamic>> shelf() => [
  {'id': 'minum', 'code': 'MINUM', 'name': 'Minuman', 'parent_id': null},
  {'id': 'kopi', 'code': 'KOPI', 'name': 'Kopi', 'parent_id': 'minum'},
  {'id': 'teh', 'code': 'TEH', 'name': 'Teh', 'parent_id': 'minum'},
  {'id': 'bahan', 'code': 'BAHAN', 'name': 'Bahan Mentah', 'parent_id': null},
  {'id': 'biji', 'code': 'BIJI', 'name': 'Kopi', 'parent_id': 'bahan'},
];

void main() {
  group('why a category cannot be saved', () {
    test('both columns are not null, so both are asked for', () {
      expect(
        categoryBlockedBecause(code: '', name: 'Minuman'),
        'A category needs a short code.',
      );
      expect(
        categoryBlockedBecause(code: 'MINUM', name: ''),
        'And something to call it.',
      );
    });

    test('and whitespace is not a name', () {
      expect(categoryBlockedBecause(code: '  ', name: 'x'), isNotNull);
      expect(categoryBlockedBecause(code: 'x', name: '   '), isNotNull);
    });

    test('a real one is not blocked', () {
      expect(categoryBlockedBecause(code: 'MINUM', name: 'Minuman'), isNull);
    });
  });

  group('whether a code is taken', () {
    test('it is when something else has it', () {
      expect(codeIsTaken(shelf(), 'KOPI'), isTrue);
    });

    test('but not when the something else is this one', () {
      // Renaming Kopi without changing its code must not refuse itself.
      expect(codeIsTaken(shelf(), 'KOPI', exceptId: 'kopi'), isFalse);
    });

    test('compared the way Postgres compares it', () {
      // `unique (org_id, code)` is exact, so MINUM and minum are two
      // codes and the person typing the second is not told otherwise.
      expect(codeIsTaken(shelf(), 'minum'), isFalse);
      expect(codeIsTaken(shelf(), 'MINUM'), isTrue);
    });

    test('a code nobody has is free', () {
      expect(codeIsTaken(shelf(), 'ROTI'), isFalse);
    });
  });

  group('what is filed directly under one', () {
    test('the top-level categories are the ones with no parent', () {
      expect(
        [for (final c in categoriesUnder(shelf(), null)) c['id']],
        ['bahan', 'minum'],
      );
    });

    test('and a category names its own children', () {
      expect(
        [for (final c in categoriesUnder(shelf(), 'minum')) c['id']],
        ['kopi', 'teh'],
      );
    });

    test('in name order, not in the order they arrived', () {
      // Bahan Mentah before Minuman.
      expect(categoriesUnder(shelf(), null).first['name'], 'Bahan Mentah');
    });

    test('a leaf has nothing under it', () {
      expect(categoriesUnder(shelf(), 'teh'), isEmpty);
    });
  });

  group('the whole tree', () {
    test('reads down each branch before starting the next', () {
      expect(
        [for (final n in categoryTree(shelf())) n.row['id']],
        ['bahan', 'biji', 'minum', 'kopi', 'teh'],
      );
    });

    test('and says how deep each row sits', () {
      final tree = categoryTree(shelf());
      expect(tree.first.depth, 0);
      expect(tree[1].depth, 1);
    });

    test('a row whose parent is gone is shown rather than dropped', () {
      // Deleted by somebody else while this screen was open. Losing a
      // category off the list because of a row that is not on it is how
      // a list quietly stops being the list.
      final orphaned = [
        {'id': 'kopi', 'code': 'KOPI', 'name': 'Kopi', 'parent_id': 'gone'},
      ];
      expect(
        [for (final n in categoryTree(orphaned)) n.row['id']],
        ['kopi'],
      );
    });

    test('and a cycle written before this screen existed does not hang', () {
      final looped = [
        {'id': 'a', 'code': 'A', 'name': 'A', 'parent_id': 'b'},
        {'id': 'b', 'code': 'B', 'name': 'B', 'parent_id': 'a'},
      ];
      expect(categoryTree(looped).length, 2);
    });

    test('nothing at all is no rows', () {
      expect(categoryTree(const []), isEmpty);
    });
  });

  group('what is filed under one, however deep', () {
    test('everything below it', () {
      expect(descendantsOf(shelf(), 'minum'), {'kopi', 'teh'});
    });

    test('a leaf has no descendants', () {
      expect(descendantsOf(shelf(), 'teh'), isEmpty);
    });

    test('and grandchildren count', () {
      final deep = [
        ...shelf(),
        {'id': 'kaw', 'code': 'KAW', 'name': 'Kopi O Kaw', 'parent_id': 'kopi'},
      ];
      expect(descendantsOf(deep, 'minum'), {'kopi', 'teh', 'kaw'});
    });
  });

  group('what one may be filed under', () {
    test('not itself', () {
      // Postgres has no cycle check on parent_id -- it would take a
      // trigger walking the tree on every write -- so a category made
      // its own parent would be accepted and hang every reader.
      expect(
        [for (final c in assignableParents(shelf(), 'minum')) c['id']],
        isNot(contains('minum')),
      );
    });

    test('and not anything already filed under it', () {
      expect(
        [for (final c in assignableParents(shelf(), 'minum')) c['id']],
        ['bahan', 'biji'],
      );
    });

    test('a new category may go anywhere', () {
      expect(assignableParents(shelf(), null).length, 5);
    });
  });

  group('the full name of a category', () {
    test('reads from the top down', () {
      expect(categoryPath(shelf(), 'kopi'), 'Minuman › Kopi');
    });

    test('which is the point, where two of them share a name', () {
      // A picker showing both as "Kopi" is a picker that picks the
      // wrong one.
      expect(categoryPath(shelf(), 'biji'), 'Bahan Mentah › Kopi');
    });

    test('a top-level category is just itself', () {
      expect(categoryPath(shelf(), 'minum'), 'Minuman');
    });

    test('nothing is nothing', () {
      expect(categoryPath(shelf(), null), '');
    });

    test('and a cycle stops rather than walking for ever', () {
      final looped = [
        {'id': 'a', 'code': 'A', 'name': 'A', 'parent_id': 'b'},
        {'id': 'b', 'code': 'B', 'name': 'B', 'parent_id': 'a'},
      ];
      expect(categoryPath(looped, 'a'), 'B › A');
    });
  });

  group('what removing one takes with it', () {
    test('nothing, and it says so', () {
      // parent_id and items.category_id are both `on delete set null`.
      expect(
        deletionWarning(shelf(), 'teh'),
        contains('The items themselves are untouched.'),
      );
    });

    test('the children come up a level, and are counted', () {
      expect(deletionWarning(shelf(), 'minum'), startsWith('2 categories'));
    });

    test('one child is said as one', () {
      expect(deletionWarning(shelf(), 'bahan'), startsWith('1 category '));
    });
  });
}
