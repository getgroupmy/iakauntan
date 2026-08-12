/// Groups a run of form fields into rows no wider than [perRow] flex
/// units, returning the indices that belong in each row.
///
/// Indices rather than widgets so the rule can be asserted without
/// building anything.
///
/// This replaces hand-indexed layouts — `fields[3]` beside `fields[2]`,
/// with anything past the fifth silently dropped. That form of layout is
/// correct exactly once: it reorders itself when a field is inserted in
/// the middle and loses fields off the end, and neither failure is
/// visible in the analyzer or in a screenshot of the old field set.
/// Adding a currency and a rate field to the document header is that
/// case.
List<List<int>> packRows(List<int> flexes, {int perRow = 3}) {
  final rows = <List<int>>[];
  var current = <int>[];
  var used = 0;

  for (var i = 0; i < flexes.length; i++) {
    // A field wider than a whole row still gets one — it overflows its
    // width budget rather than disappearing, which is the failure that
    // can at least be seen.
    if (current.isNotEmpty && used + flexes[i] > perRow) {
      rows.add(current);
      current = [];
      used = 0;
    }
    current.add(i);
    used += flexes[i];
  }
  if (current.isNotEmpty) rows.add(current);
  return rows;
}
