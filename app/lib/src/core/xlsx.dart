/// A workbook, written by hand, because a spreadsheet is not a CSV.
///
/// `report_csv.dart` explains why it writes `1200.00` and not
/// `RM 1,200.00`: a currency symbol and a thousands separator turn a
/// column of figures into a column of text, and the symptom is a
/// spreadsheet total of zero rather than an error. That is the right
/// answer for CSV, where a cell has no type and the only way to keep a
/// number a number is to write nothing but digits.
///
/// It is the wrong answer for a spreadsheet, where a cell has BOTH — a
/// numeric value and a format. A workbook can hold 1200 and show
/// `1,200.00`, so an accountant gets a column that sums and reads at
/// the same time. That is the whole of what the audit's D12 says CSV
/// loses: number formats, column widths, and more than one sheet.
///
/// ## Written here rather than taken from a package
///
/// An `.xlsx` is a ZIP of XML, and the parts a workbook needs are few
/// enough to write out: a content-type map, two relationship files, a
/// workbook, a stylesheet and a sheet per tab. `archive` supplies the
/// ZIP, which the app already has through `pdf`.
///
/// The alternative was a spreadsheet package, and the reason against it
/// is the same one `scripts/check_app_icons.py` gives for decoding a
/// PNG by hand: this has to be CHECKABLE. What is written here is
/// validated part by part by `scripts/check_xlsx.py`, which unzips a
/// real workbook and reads the XML with Python's own parser — a second
/// implementation, which is the only kind of check worth having on a
/// file format.
///
/// ## What it deliberately does not do
///
/// No formulas, no merged cells, no charts, no images, no shared string
/// table. A report is values; a formula in an exported report is a
/// second arithmetic to disagree with the one the database did. Strings
/// go inline (`t="inlineStr"`) rather than into a shared table: the
/// table saves bytes on a file with much repetition and costs a second
/// structure to keep consistent, and a report is mostly numbers.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// What a cell holds.
///
/// The type is the point. A [XlsxNumber] is written as a numeric cell
/// so the spreadsheet sums it; a [XlsxText] that happens to contain
/// digits is written as text so a document number like `0012` keeps its
/// leading nought.
sealed class XlsxCell {
  const XlsxCell();
}

final class XlsxText extends XlsxCell {
  const XlsxText(this.text, {this.bold = false});
  final String text;
  final bool bold;
}

final class XlsxNumber extends XlsxCell {
  const XlsxNumber(this.value, {this.format = XlsxFormat.money, this.bold = false});
  final double value;
  final XlsxFormat format;
  final bool bold;
}

/// A cell with nothing in it.
///
/// Distinct from `XlsxText('')`, which writes an empty string and makes
/// the cell exist. This writes no cell at all, which is what a
/// spreadsheet means by blank and what `COUNTA` counts.
final class XlsxBlank extends XlsxCell {
  const XlsxBlank();
}

/// How a number is shown, without changing what it is.
enum XlsxFormat {
  /// `1,200.00` — two decimals and a thousands separator. The default,
  /// because nearly every number in this application is money.
  money,

  /// `1,200` — for counts, which have no sen.
  whole,

  /// `12.50%`.
  percent,

  /// `18/09/2026`, written as a date serial so the spreadsheet can sort
  /// and subtract it.
  date,
}

/// One tab.
class XlsxSheet {
  XlsxSheet({
    required this.name,
    required this.rows,
    this.columnWidths = const [],
    this.freezeRows = 0,
  });

  /// What the tab is called.
  ///
  /// Excel refuses `: \ / ? * [ ]`, refuses an empty name, and refuses
  /// anything over 31 characters. [xlsxSheetName] does the trimming so
  /// a caller cannot produce a file that will not open.
  final String name;

  final List<List<XlsxCell>> rows;

  /// How wide each column is, in Excel's character units. Any column
  /// not named here is left to the default.
  final List<double> columnWidths;

  /// How many rows stay put when the sheet is scrolled. 1 pins a header
  /// row, which is what a report with more rows than a screen needs.
  final int freezeRows;
}

/// The workbook as bytes, ready to be saved.
Uint8List buildXlsx(List<XlsxSheet> sheets) {
  if (sheets.isEmpty) {
    throw ArgumentError('a workbook needs at least one sheet');
  }
  final archive = Archive();

  void add(String path, String xml) {
    final bytes = utf8.encode(xml);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('[Content_Types].xml', _contentTypes(sheets.length));
  add('_rels/.rels', _rootRels);
  add('xl/_rels/workbook.xml.rels', _workbookRels(sheets.length));
  add('xl/workbook.xml', _workbook(sheets));
  add('xl/styles.xml', _styles);
  for (var i = 0; i < sheets.length; i++) {
    add('xl/worksheets/sheet${i + 1}.xml', _sheet(sheets[i]));
  }

  // Stored, not deflated, would also open. Deflate because a trial
  // balance of four thousand accounts is mostly repeated XML and the
  // file is emailed.
  final zipped = ZipEncoder().encode(archive);
  return Uint8List.fromList(zipped);
}

/// A tab name Excel will accept.
///
/// Excel does not report a bad sheet name as a bad sheet name. It
/// reports the workbook as unreadable and offers to repair it, so a
/// report whose title happens to contain a slash — "Profit & loss" does
/// not, "Receivables 1/4/26" does — would produce a file that looks
/// written and opens as an error.
String xlsxSheetName(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'''[:\\/?*\[\]]'''), ' ').trim();
  if (cleaned.isEmpty) return 'Sheet1';
  return cleaned.length <= 31 ? cleaned : cleaned.substring(0, 31).trim();
}

/// The same, for a list, with duplicates made distinct.
///
/// Two tabs of the same name is the other way to produce a file Excel
/// will not open, and it is easy to reach: trimming to 31 characters
/// turns two long titles that differ at the end into one name twice.
List<String> xlsxSheetNames(List<String> raw) {
  final out = <String>[];
  for (final r in raw) {
    var name = xlsxSheetName(r);
    if (out.contains(name)) {
      for (var n = 2;; n++) {
        final suffix = ' ($n)';
        final head = name.length + suffix.length > 31
            ? name.substring(0, 31 - suffix.length).trim()
            : name;
        final candidate = '$head$suffix';
        if (!out.contains(candidate)) {
          name = candidate;
          break;
        }
      }
    }
    out.add(name);
  }
  return out;
}

/// A date as the number a spreadsheet keeps dates in.
///
/// Days since 1899-12-30. The two-day offset from the 1900 epoch is not
/// an error here: Lotus 1-2-3 treated 1900 as a leap year, Excel copied
/// the bug for compatibility and has never fixed it, and every
/// spreadsheet since has copied Excel. A date written without it is off
/// by two days, which on an invoice due date is the difference between
/// overdue and not.
double xlsxDateSerial(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day)
        .difference(DateTime.utc(1899, 12, 30))
        .inDays
        .toDouble();

/// The column's letter: 1 is A, 27 is AA.
String xlsxColumn(int oneBased) {
  if (oneBased < 1) throw ArgumentError('columns start at 1');
  var n = oneBased;
  final out = StringBuffer();
  while (n > 0) {
    final rem = (n - 1) % 26;
    out.write(String.fromCharCode(65 + rem));
    n = (n - 1) ~/ 26;
  }
  return out.toString().split('').reversed.join();
}

/// XML's five, and nothing else.
///
/// `&` FIRST, or the ampersands this function itself writes are escaped
/// a second time and `&amp;` reaches the sheet as `&amp;amp;`.
String xlsxEscape(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
    // A control character is not legal in XML 1.0 at all, escaped or
    // otherwise, and one in a pasted account name would make the
    // workbook unreadable. Tab, newline and carriage return are the
    // three that are.
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

// ---------------------------------------------------------------------
// The parts
// ---------------------------------------------------------------------

/// Which style index each kind of cell uses.
///
/// The order here IS the order of `<cellXfs>` in [_styles], and the two
/// cannot be allowed to drift: a wrong index does not fail, it formats
/// a figure as a date. `xlsx_test.dart` asserts the count matches.
const _styleDefault = 0;
const _styleBold = 1;
const _styleMoney = 2;
const _styleMoneyBold = 3;
const _styleWhole = 4;
const _styleWholeBold = 5;
const _stylePercent = 6;
const _stylePercentBold = 7;
const _styleDate = 8;
const _styleDateBold = 9;

/// How many `<xf>` entries [_styles] declares. Read by the test that
/// keeps the two in step.
const xlsxStyleCount = 10;

int _styleFor(XlsxCell cell) => switch (cell) {
  XlsxBlank() => _styleDefault,
  XlsxText t => t.bold ? _styleBold : _styleDefault,
  XlsxNumber n => switch (n.format) {
    XlsxFormat.money => n.bold ? _styleMoneyBold : _styleMoney,
    XlsxFormat.whole => n.bold ? _styleWholeBold : _styleWhole,
    XlsxFormat.percent => n.bold ? _stylePercentBold : _stylePercent,
    XlsxFormat.date => n.bold ? _styleDateBold : _styleDate,
  },
};

String _contentTypes(int sheets) => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
${[
  for (var i = 1; i <= sheets; i++)
    '<Override PartName="/xl/worksheets/sheet$i.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
].join('\n')}
</Types>''';

const _rootRels = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''';

String _workbookRels(int sheets) => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
${[
  for (var i = 1; i <= sheets; i++)
    '<Relationship Id="rId$i" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet$i.xml"/>',
].join('\n')}
<Relationship Id="rId${sheets + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>''';

String _workbook(List<XlsxSheet> sheets) {
  final names = xlsxSheetNames([for (final s in sheets) s.name]);
  return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
${[
    for (var i = 0; i < names.length; i++)
      '<sheet name="${xlsxEscape(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>',
  ].join('\n')}
</sheets>
</workbook>''';
}

/// The stylesheet.
///
/// It ends with a named default style -- `<cellStyles>` with "Normal".
/// Excel opens a workbook without it and so does every reader tried
/// here, but openpyxl warns "Workbook contains no default style, apply
/// openpyxl's default", and a real reader complaining about a file this
/// repository generates is a signal rather than noise.
/// `scripts/check_xlsx.py` turns that warning into a failure, which is
/// what stops the element being dropped again by somebody tidying.
///
/// The explanation is HERE and not in an XML comment inside the string,
/// because an XML comment may not contain a double hyphen and this
/// paragraph is full of them. Writing it there produced a stylesheet
/// that openpyxl refused to parse at all -- a worse fault than the
/// warning it was added to remove.
///
/// The custom number formats start at 164, which is where OOXML says a
/// file's own formats begin — 0 to 163 are reserved for the built-in
/// ones, and a custom format numbered inside that range is either
/// ignored or applied as whatever the built-in at that number is.
const _styles = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="4">
<numFmt numFmtId="164" formatCode="#,##0.00"/>
<numFmt numFmtId="165" formatCode="#,##0"/>
<numFmt numFmtId="166" formatCode="0.00%"/>
<numFmt numFmtId="167" formatCode="dd/mm/yyyy"/>
</numFmts>
<fonts count="2">
<font><sz val="11"/><name val="Calibri"/></font>
<font><b/><sz val="11"/><name val="Calibri"/></font>
</fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="$xlsxStyleCount">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
<xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="167" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
</cellXfs>
<cellStyles count="1">
<cellStyle name="Normal" xfId="0" builtinId="0"/>
</cellStyles>
</styleSheet>''';

String _sheet(XlsxSheet sheet) {
  final body = StringBuffer();
  for (var r = 0; r < sheet.rows.length; r++) {
    final cells = sheet.rows[r];
    // A row with nothing in it is written as an empty <row> rather than
    // skipped: a report is blocks separated by blank lines, and a sheet
    // whose row numbers jump reads as data that went missing.
    body.write('<row r="${r + 1}">');
    for (var c = 0; c < cells.length; c++) {
      final ref = '${xlsxColumn(c + 1)}${r + 1}';
      final style = _styleFor(cells[c]);
      switch (cells[c]) {
        case XlsxBlank():
          break;
        case XlsxText t:
          body.write(
            '<c r="$ref" s="$style" t="inlineStr">'
            '<is><t xml:space="preserve">${xlsxEscape(t.text)}</t></is></c>',
          );
        case XlsxNumber n:
          body.write('<c r="$ref" s="$style"><v>${_number(n.value)}</v></c>');
      }
    }
    body.write('</row>');
  }

  final cols = sheet.columnWidths.isEmpty
      ? ''
      : '<cols>${[
          for (var i = 0; i < sheet.columnWidths.length; i++)
            '<col min="${i + 1}" max="${i + 1}" '
                'width="${sheet.columnWidths[i]}" customWidth="1"/>',
        ].join()}</cols>';

  final pane = sheet.freezeRows <= 0
      ? '<sheetView workbookViewId="0"/>'
      : '<sheetView workbookViewId="0">'
            '<pane ySplit="${sheet.freezeRows}" '
            'topLeftCell="A${sheet.freezeRows + 1}" activePane="bottomLeft" '
            'state="frozen"/>'
            '</sheetView>';

  return '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetViews>$pane</sheetViews>
$cols<sheetData>$body</sheetData>
</worksheet>''';
}

/// A figure as XML wants it.
///
/// `toString()` on a double gives `1200.0` for a whole number and
/// `1.2e+21` for a large one. The first is harmless; the second is not
/// valid in a `<v>` and Excel reports the workbook as damaged. Neither
/// appears in this application's figures, and writing them out properly
/// costs one line.
String _number(double v) {
  if (v.isNaN || v.isInfinite) return '0';
  if (v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  return v.toStringAsFixed(10).replaceFirst(RegExp(r'0+$'), '').replaceFirst(
    RegExp(r'\.$'),
    '',
  );
}
