/// A report as something a spreadsheet can add up.
///
/// Written from the same [ReportSpec] the screen draws and the PDF
/// prints, for the reason `report_spec.dart` gives: three renderings of
/// one report that disagree are worse than two, and the way they come to
/// disagree is each one filtering the rows again on its own.
///
/// ## Numbers, not money
///
/// The PDF prints `RM 1,200.00` because somebody is going to read it.
/// This writes `1200.00`, unformatted and unprefixed, because somebody
/// is going to sum it — a currency symbol and a thousands separator turn
/// a column of figures into a column of text, and the symptom is a
/// spreadsheet total of zero rather than an error.
///
/// The PDF also leaves an unsigned zero blank so the eye runs past it.
/// Here it is written as `0.00`: a blank cell reads as a figure nobody
/// supplied, and every one of these is a figure somebody did.
library;

import 'report_spec.dart';

/// The whole report as CSV: what it is, then each block in the order the
/// spec puts them, then whatever the report had to say for itself.
String reportCsv(ReportSpec spec) {
  final rows = <List<String>>[
    [spec.title],
    [spec.subtitle],
    const [],
  ];

  for (final block in spec.blocks) {
    rows.addAll(_block(block));
    rows.add(const []);
  }

  if (spec.note != null) rows.add([spec.note!]);

  return _serialise(_rectangular(rows));
}

List<List<String>> _block(ReportBlock block) => switch (block) {
  // Consistent with the PDF, which drops an empty section rather than
  // printing a heading with a nought under it.
  ReportSection s when s.lines.isEmpty => const [],
  ReportSection s => [
    [s.title],
    const ['Code', 'Account', 'Amount'],
    for (final l in s.lines) [l.code, l.name, _number(l.amount)],
    ['', 'Total ${s.title}', _number(s.total)],
  ],
  ReportGrid g => [
    if (g.title != null) [g.title!],
    g.headers,
    for (final r in g.rows) [for (final c in r) _cell(c)],
    if (g.total != null) [for (final c in g.total!) _cell(c)],
  ],
  ReportHighlight h => [
    [h.label, _number(h.value)],
  ],
};

String _cell(Cell c) => switch (c) {
  TextCell t => t.text,
  MoneyCell m => _number(m.value),
};

/// Two decimals and nothing else. Negatives keep their minus sign
/// whether or not the cell was declared `signed`: that flag is about
/// whether a reader should be shown the sign, and a spreadsheet is not
/// a reader.
String _number(double value) => value.toStringAsFixed(2);

/// Every row padded to the width of the widest.
///
/// A report is blocks of different shapes stacked up, so its rows are
/// naturally ragged — and the first row here is the title, one cell
/// wide. An importer that takes its column count from the first row
/// would then throw away every column but one. Padding costs some
/// trailing commas and removes that failure entirely.
List<List<String>> _rectangular(List<List<String>> rows) {
  final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
  return [
    for (final r in rows)
      [...r, for (var i = r.length; i < width; i++) ''],
  ];
}

/// CRLF, as RFC 4180 asks for and as `PaymentFile` already writes.
String _serialise(List<List<String>> rows) {
  final buffer = StringBuffer();
  for (final row in rows) {
    buffer.write(row.map(_escape).join(','));
    buffer.write('\r\n');
  }
  return buffer.toString();
}

/// Everything quoted rather than only what needs it. Account names,
/// customer names and report notes here carry commas, quotes and the
/// odd newline, and a quoted field is never ambiguous.
String _escape(String value) =>
    '"${value.replaceAll('"', '""').replaceAll(RegExp(r'[\r\n]+'), ' ')}"';
