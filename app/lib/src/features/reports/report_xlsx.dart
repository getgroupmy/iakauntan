/// A report as a workbook, not as a comma-separated file.
///
/// The third rendering of a [ReportSpec], beside the screen and the
/// PDF, and written from the same spec for the reason
/// `report_spec.dart` gives: renderings that filter the rows again on
/// their own are renderings that come to disagree.
///
/// ## What this has that the CSV does not
///
/// `report_csv.dart` explains why it writes `1200.00` and not
/// `RM 1,200.00`: in a CSV a cell has no type, so the only way to keep
/// a number a number is to write nothing but digits, and a currency
/// symbol turns a column of figures into a column of text whose total
/// is zero.
///
/// A spreadsheet cell has a value AND a format. So this writes 1200 as
/// a number and lets the workbook show `1,200.00` — a column that sums
/// and reads at the same time, which is the whole of what the OCA
/// audit's D12 says CSV loses, along with column widths and more than
/// one sheet.
///
/// ## One sheet per spec, and the list is not decoration
///
/// [reportXlsx] takes a LIST. Today every call site passes one, because
/// `reports_screen.dart` watches only the visible tab's provider — the
/// specs for the other tabs do not exist unless their data has been
/// fetched, and fetching all of them to build a file somebody asked
/// about one report would be a worse trade than the extra sheets are
/// worth.
///
/// The list is there so that a future "export every report" is a call
/// site rather than a rewrite of this file.
///
/// ## No formulas
///
/// A total is written as the figure the database computed, not as
/// `=SUM(C5:C12)`. A formula in an exported report is a second
/// arithmetic, in a file nobody reviews, that can disagree with the one
/// the ledger did — and when it disagrees the spreadsheet wins, because
/// it recalculates on open.
library;

import 'dart:typed_data';

import '../../core/xlsx.dart';
import 'report_spec.dart';

/// The workbook: one sheet per report.
Uint8List reportXlsx(List<ReportSpec> specs) => buildXlsx([
  for (final spec in specs)
    XlsxSheet(
      // `xlsxSheetNames` makes these distinct and legal; passing the
      // raw title would produce a file Excel offers to repair the first
      // time a report is called something with a slash in it.
      name: spec.title,
      rows: _rows(spec),
      // A code, a name, then figures. The name column is the one that
      // matters: at Excel's default width an account called
      // "Administrative expenses — professional fees" shows as
      // "Administrativ", and the first thing anybody does with a CSV
      // export is widen that column by hand.
      columnWidths: const [12, 46, 16, 16, 16, 16, 16],
      // The title and the period, held while the rows scroll. A report
      // read at row 200 with no heading in sight is a column of figures
      // that could be anybody's.
      //
      // Two rows and not one: the subtitle IS the period, and a profit
      // and loss with no period on it is not a report.
      freezeRows: 2,
    ),
]);

List<List<XlsxCell>> _rows(ReportSpec spec) {
  final rows = <List<XlsxCell>>[
    [XlsxText(spec.title, bold: true)],
    [XlsxText(spec.subtitle)],
    const [],
  ];

  for (final block in spec.blocks) {
    final built = _block(block);
    if (built.isEmpty) continue;
    rows.addAll(built);
    rows.add(const []);
  }

  if (spec.note != null) rows.add([XlsxText(spec.note!)]);
  return rows;
}

List<List<XlsxCell>> _block(ReportBlock block) => switch (block) {
  // Consistent with the PDF and the CSV, which drop an empty section
  // rather than printing a heading with a nought under it.
  ReportSection s when s.lines.isEmpty && s.statedTotal == null => const [],

  // A section whose total was GIVEN rather than derived — `0637`'s
  // `show_accounts: false`, an accountant's one-line "Administrative
  // expenses" with the detail in a note. It has a real total and no
  // lines, so it is a heading and a figure and no column headers.
  ReportSection s when s.lines.isEmpty => [
    [
      XlsxText(s.title, bold: true),
      const XlsxBlank(),
      XlsxNumber(s.total, bold: true),
    ],
  ],

  ReportSection s => [
    [XlsxText(s.title, bold: true)],
    const [
      XlsxText('Code', bold: true),
      XlsxText('Account', bold: true),
      XlsxText('Amount', bold: true),
    ],
    for (final l in s.lines)
      // The CODE as TEXT, deliberately. A chart of accounts is full of
      // codes like `0100` and `3300`, and written as numbers they
      // become 100 and 3300 — the leading nought gone, the column
      // right-aligned, and the account no longer findable by its code.
      [XlsxText(l.code), XlsxText(l.name), XlsxNumber(l.amount)],
    [
      const XlsxBlank(),
      XlsxText('Total ${s.title}', bold: true),
      XlsxNumber(s.total, bold: true),
    ],
  ],

  ReportGrid g => [
    if (g.title != null) [XlsxText(g.title!, bold: true)],
    [for (final h in g.headers) XlsxText(h, bold: true)],
    for (final r in g.rows) [for (final c in r) _cell(c)],
    if (g.total != null) [for (final c in g.total!) _cell(c, bold: true)],
  ],

  ReportHighlight h => [
    [XlsxText(h.label, bold: true), XlsxNumber(h.value, bold: true)],
  ],
};

/// One cell, keeping the type the spec gave it.
///
/// This is the line the whole file exists for. A [MoneyCell] becomes a
/// NUMBER and a [TextCell] becomes TEXT, whatever either happens to
/// contain — so a document number that looks like a figure keeps its
/// leading noughts and a figure that looks like text still sums.
///
/// `signed` is not consulted, the same way `report_csv.dart` does not
/// consult it: that flag is about whether a READER should be shown the
/// sign, and a negative written as a bare magnitude is a figure that
/// adds up the wrong way.
XlsxCell _cell(Cell c, {bool bold = false}) => switch (c) {
  TextCell t => XlsxText(t.text, bold: bold),
  MoneyCell m => XlsxNumber(m.value, bold: bold),
};
