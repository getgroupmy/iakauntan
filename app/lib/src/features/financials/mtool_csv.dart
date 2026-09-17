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

/// The five statements MBRS asks a lodgement for, in the order they are
/// presented.
///
/// A list rather than the screen's map, so "which are missing" can be
/// asked without a widget.
const fsStatements = <String, String>{
  'sofp': 'Statement of financial position',
  'soploci': 'Profit or loss and other comprehensive income',
  'socie': 'Changes in equity',
  'socf': 'Cash flows',
  'disclosure': 'Disclosures',
};

/// Which of those a set of exported rows does not contain, in order.
///
/// The screen groups `fs_export` by statement and draws a section per
/// group, so a statement with no rows simply does not appear — and a
/// preparer reads two sections, exports them, and is three statements
/// short at the counter without anything having said so.
///
/// `mbrs_elements` seeds `sofp` and `soploci` only, sixteen and nine
/// elements, so on today's taxonomy THREE are always absent: changes in
/// equity, cash flows and the disclosures. `0171` says why the table is
/// a table — "the MBRS taxonomy is versioned and changes between
/// releases" — and says the seeded codes "must be reconciled against
/// the mTool taxonomy in use before the first live lodgement". The
/// elements for the other three come from that reconciliation.
List<String> missingStatements(Iterable<String> present) {
  final seen = present.toSet();
  return [
    for (final code in fsStatements.keys)
      if (!seen.contains(code)) fsStatements[code]!,
  ];
}

/// What to say about them.
///
/// Named rather than counted, because "three statements are missing" is
/// something a preparer has to go and work out, and the point of saying
/// it at all is that they should not have to.
///
/// Deliberately does NOT claim which of the two reasons applies. A
/// statement is absent either because no taxonomy element for it is
/// loaded or because this company has no figures for it, and the export
/// cannot tell those apart — what the preparer needs either way is to
/// know it is not in the file.
String? missingStatementsNote(Iterable<String> present) {
  final missing = missingStatements(present);
  if (missing.isEmpty) return null;
  final names = missing.length == 1
      ? missing.single
      : '${missing.sublist(0, missing.length - 1).join(', ')} and '
            '${missing.last}';
  return 'Not in this export: $names. A full MBRS lodgement carries all '
      'five, so these have to come from elsewhere — load the taxonomy '
      'elements for them into mbrs_elements, or enter them in mTool '
      'directly.';
}
