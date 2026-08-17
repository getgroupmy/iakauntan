/// The file that goes into mTool.
///
/// Kept out of the screen and free of Flutter imports so it can be
/// asserted directly: the whole value of an export is that the bytes are
/// right, and a format only exercised by tapping a button is a format
/// nobody checks.
///
/// A flat CSV keyed on the taxonomy element rather than an attempt at
/// mTool's own workbook. mTool is an Excel application whose template
/// changes between taxonomy releases; generating a workbook against a
/// version we cannot see would produce a file that looks right and fails
/// validation at SSM. One row per element, named and labelled, is
/// something a preparer can map onto whichever template they have in
/// front of them — and can check.
library;

String _escape(String value) {
  final needsQuotes =
      value.contains(',') || value.contains('"') || value.contains('\n');
  final escaped = value.replaceAll('"', '""');
  return needsQuotes ? '"$escaped"' : escaped;
}

String _amount(Object? value) {
  if (value == null) return '0.00';
  final n = value is num ? value : num.tryParse(value.toString()) ?? 0;
  return n.toStringAsFixed(2);
}

/// Rows as `fs_export` returns them, in the order it returns them —
/// which is taxonomy order, not alphabetical.
String mtoolCsv(List<Map<String, dynamic>> rows) {
  final buffer = StringBuffer()
    ..writeln('Statement,Section,Element,Label,CurrentYear,PriorYear');

  for (final r in rows) {
    buffer.writeln(
      [
        _escape(r['statement']?.toString() ?? ''),
        _escape(r['section']?.toString() ?? ''),
        _escape(r['element_code']?.toString() ?? ''),
        _escape(r['label']?.toString() ?? ''),
        _amount(r['current_amount']),
        _amount(r['prior_amount']),
      ].join(','),
    );
  }

  return buffer.toString();
}

/// A draft export says so in its own filename.
///
/// Draft figures follow the ledger, so two exports taken an hour apart
/// can differ. A file on somebody's desktop called `mbrs-figures.csv`
/// gives no way to tell which one is on the screen, and the one that
/// gets uploaded is whichever was open.
String mtoolFilename(List<Map<String, dynamic>> rows) {
  final frozen = rows.isNotEmpty && rows.first['is_frozen'] == true;
  return frozen ? 'mbrs-figures.csv' : 'mbrs-figures-DRAFT.csv';
}
