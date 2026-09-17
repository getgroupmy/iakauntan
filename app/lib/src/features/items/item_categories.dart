/// What a shop files its items under.
///
/// `item_categories` has been in `0003` since the first migration —
/// self-referencing through `parent_id`, unique on `(org_id, code)`,
/// wired to `items.category_id` — and nothing in the app could read it,
/// write it, or show it. So `category_id` was null on every item
/// anybody typed, and `0215`'s kitchen router, whose whole first arm is
/// "everything in this category that has no counter of its own", had no
/// categories to route.
library;

/// Why a category cannot be saved.
///
/// Both columns are `not null` in 0003; a blank one arrives as an
/// error from Postgres about a constraint rather than as a sentence.
String? categoryBlockedBecause({required String code, required String name}) {
  if (code.trim().isEmpty) return 'A category needs a short code.';
  if (name.trim().isEmpty) return 'And something to call it.';
  return null;
}

/// Whether a code is already taken.
///
/// `unique (org_id, code)` decides, and it is compared here the way
/// Postgres compares it — exactly, so "MINUM" and "minum" are two
/// codes and the person typing the second one is not told otherwise.
bool codeIsTaken(
  Iterable<Map<String, dynamic>> all,
  String code, {
  String? exceptId,
}) {
  final wanted = code.trim();
  for (final c in all) {
    if (c['id'] == exceptId) continue;
    if ('${c['code']}' == wanted) return true;
  }
  return false;
}

/// Everything filed directly under one category, in name order.
List<Map<String, dynamic>> categoriesUnder(
  Iterable<Map<String, dynamic>> all,
  String? parentId,
) {
  final rows = [
    for (final c in all)
      if ((c['parent_id'] as String?) == parentId) c,
  ];
  rows.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
  return rows;
}

/// The whole tree, flattened in the order it reads, with how deep each
/// row sits.
///
/// Anything the walk down from the top does not reach is shown at the
/// top anyway: a row whose parent was deleted by somebody else while
/// this screen was open, and a whole branch that loops back on itself
/// and so has no top to be reached from. Losing a category off the
/// screen is how a list quietly stops being the list, and it is worst
/// exactly where the row is the one that needs correcting.
List<({Map<String, dynamic> row, int depth})> categoryTree(
  Iterable<Map<String, dynamic>> all,
) {
  final out = <({Map<String, dynamic> row, int depth})>[];
  final seen = <String>{};

  void walk(String? parentId, int depth) {
    for (final c in categoriesUnder(all, parentId)) {
      final id = '${c['id']}';
      // Marked, not guarded. A row has one `parent_id`, so the walk
      // down cannot arrive at the same row twice however the tree is
      // shaped; what `seen` is for is the pass below, which needs to
      // know what the walk never arrived at.
      seen.add(id);
      out.add((row: c, depth: depth));
      walk(id, depth + 1);
    }
  }

  walk(null, 0);
  // Whatever the walk could not reach from the top.
  for (final c in all) {
    if (seen.add('${c['id']}')) out.add((row: c, depth: 0));
  }
  return out;
}

/// Everything filed under one category, however deep.
Set<String> descendantsOf(Iterable<Map<String, dynamic>> all, String id) {
  final found = <String>{};
  void walk(String parentId) {
    for (final c in categoriesUnder(all, parentId)) {
      final childId = '${c['id']}';
      if (found.add(childId)) walk(childId);
    }
  }

  walk(id);
  return found;
}

/// The categories one may be filed under.
///
/// Not itself, and not anything already filed under it. Postgres has
/// no cycle check on `parent_id` — it would take a trigger walking the
/// tree on every write — so a category made its own grandparent would
/// be accepted and would then hang every reader that walks upwards.
List<Map<String, dynamic>> assignableParents(
  Iterable<Map<String, dynamic>> all,
  String? id,
) {
  if (id == null) return all.toList();
  final barred = descendantsOf(all, id)..add(id);
  return [
    for (final c in all)
      if (!barred.contains('${c['id']}')) c,
  ];
}

/// The full name of a category, from the top down.
///
/// "Minuman › Kopi" rather than "Kopi", because half a dozen shops
/// have a Kopi under Minuman and another under Bahan Mentah, and a
/// picker showing both as "Kopi" is a picker that picks the wrong one.
String categoryPath(Iterable<Map<String, dynamic>> all, String? id) {
  if (id == null) return '';
  final byId = {for (final c in all) '${c['id']}': c};
  final parts = <String>[];
  final seen = <String>{};
  var at = id;
  while (byId.containsKey(at) && seen.add(at)) {
    parts.insert(0, '${byId[at]!['name']}');
    at = '${byId[at]!['parent_id']}';
  }
  return parts.join(' › ');
}

/// What removing one takes with it, said before it is done.
///
/// Nothing, is the answer 0003 gives: `parent_id` and
/// `items.category_id` are both `on delete set null`, so the children
/// come up a level and the items end up filed under nothing. Worth
/// saying plainly, because "delete a category" reads to most people
/// like it might take the items too.
String deletionWarning(Iterable<Map<String, dynamic>> all, String id) {
  final children = categoriesUnder(all, id).length;
  if (children == 0) {
    return 'Anything filed under it ends up filed under nothing. The '
        'items themselves are untouched.';
  }
  return '$children ${children == 1 ? 'category' : 'categories'} filed '
      'under it come up a level, and anything in it ends up filed under '
      'nothing. The items themselves are untouched.';
}
