/// The rules a report-layout builder enforces while it is open, kept
/// out of the widget so they can be asserted without a widget tree.
///
/// `0637`. Every one of these is also enforced by the database — this
/// is the copy that tells somebody which row to fix while they are
/// still looking at it, rather than after a round trip that comes back
/// saying "constraint violated". Where the two could disagree, a test
/// asserts they do not.
library;

import '../../data/models.dart';

/// A key that is safe to refer to and stable across a rename.
///
/// Derived from the label rather than typed, because nobody building a
/// P&L wants to invent identifiers — and a key that a person edits is
/// a key that gets edited after a formula points at it.
String layoutRowKey(String label, {Iterable<String> taken = const []}) {
  var base = label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (base.isEmpty) base = 'row';
  if (!taken.contains(base)) return base;
  // A layout with two "Other income" sections is a real thing, and the
  // second must not silently become the first.
  for (var n = 2; ; n++) {
    final candidate = '${base}_$n';
    if (!taken.contains(candidate)) return candidate;
  }
}

/// Which rows a formula at [index] may refer to.
///
/// Only rows ABOVE it, which is the rule that makes a cycle impossible
/// rather than merely detected: there is no way to refer forwards, so
/// there is nothing to check for. A heading is left out because it has
/// no amount.
List<LayoutRow> referenceableFrom(List<LayoutRow> rows, int index) => [
  for (var i = 0; i < index && i < rows.length; i++)
    if (rows[i].kind != 'heading') rows[i],
];

/// Why this layout cannot be saved, or null.
String? layoutProblem(List<LayoutRow> rows) {
  if (rows.isEmpty) return 'A layout needs at least one row.';

  final seen = <String>{};
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    if (r.label.trim().isEmpty) return 'Row ${i + 1} needs a name.';
    if (r.rowKey.trim().isEmpty) return 'Row ${i + 1} has no key.';
    if (!seen.add(r.rowKey)) {
      return 'Two rows are called "${r.label}". Rename one.';
    }
    if (r.kind == 'section' &&
        r.accountTypes.isEmpty &&
        r.accountSubtypes.isEmpty &&
        r.accountIds.isEmpty) {
      return '"${r.label}" does not select any accounts.';
    }
    if (r.kind == 'formula') {
      if (r.formula.isEmpty) {
        return '"${r.label}" is a total of nothing. Add a row to it.';
      }
      final above = referenceableFrom(rows, i).map((x) => x.rowKey).toSet();
      for (final f in r.formula) {
        final ref = f['row']?.toString() ?? '';
        if (!above.contains(ref)) {
          // Naming both rows, because "invalid formula" leaves somebody
          // hunting through a page of them.
          return '"${r.label}" uses a row that is not above it. '
              'Move it up, or remove that part of the total.';
        }
      }
    }
  }
  return null;
}

/// Moving a row, with the forward-reference rule applied rather than
/// checked afterwards.
///
/// A row cannot move above something its formula depends on, and a row
/// that others depend on cannot move below them. Returning null rather
/// than reordering into an invalid state means the builder can grey the
/// arrow out instead of letting somebody make a move it then refuses.
List<LayoutRow>? moveRow(List<LayoutRow> rows, int from, int to) {
  if (from < 0 || from >= rows.length) return null;
  if (to < 0 || to >= rows.length) return null;
  if (from == to) return null;

  final next = [...rows];
  final row = next.removeAt(from);
  next.insert(to, row);
  return layoutProblem(next) == null ? next : null;
}

/// What a row says about itself in one line.
String layoutRowSummary(LayoutRow r) => switch (r.kind) {
  'heading' => 'Heading',
  'formula' => _formulaSummary(r),
  _ => _sectionSummary(r),
};

String _formulaSummary(LayoutRow r) {
  if (r.formula.isEmpty) return 'A total of nothing';
  final parts = <String>[];
  for (var i = 0; i < r.formula.length; i++) {
    final f = r.formula[i];
    final sign = (f['sign'] as num?)?.toInt() ?? 1;
    final name = f['row']?.toString() ?? '';
    // The first term reads as a plain name; a leading "+" looks like a
    // typo rather than arithmetic.
    parts.add(i == 0 ? (sign < 0 ? '− $name' : name) : (sign < 0 ? '− $name' : '+ $name'));
  }
  return parts.join(' ');
}

String _sectionSummary(LayoutRow r) {
  final bits = <String>[
    for (final t in r.accountTypes) t.replaceAll('_', ' '),
    for (final s in r.accountSubtypes) s.replaceAll('_', ' '),
    if (r.accountIds.isNotEmpty)
      '${r.accountIds.length} named account'
          '${r.accountIds.length == 1 ? '' : 's'}',
  ];
  if (bits.isEmpty) return 'No accounts selected';
  final what = bits.join(', ');
  return r.showAccounts ? what : '$what — total only';
}
