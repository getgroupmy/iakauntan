import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/xlsx.dart';

/// The workbook writer, checked at the level Dart can check it.
///
/// This asserts what `buildXlsx` PUT IN THE ZIP. It cannot assert that
/// Excel opens the result, and nothing on this machine can -- which is
/// why `scripts/check_xlsx.py` exists beside it and reads a real
/// workbook back with Python's own zip and XML parsers. Two
/// implementations of a file format disagreeing is the only check on
/// one worth having; this half is the fast one.
void main() {
  Map<String, String> parts(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    return {
      for (final f in archive.files)
        if (f.isFile) f.name: utf8.decode(f.content as List<int>),
    };
  }

  XlsxSheet sheet({
    String name = 'Sheet1',
    List<List<XlsxCell>>? rows,
    List<double> widths = const [],
    int freeze = 0,
  }) => XlsxSheet(
    name: name,
    rows:
        rows ??
        const [
          [XlsxText('Account', bold: true), XlsxText('Amount', bold: true)],
          [XlsxText('Sales'), XlsxNumber(1200)],
        ],
    columnWidths: widths,
    freezeRows: freeze,
  );

  group('the package', () {
    test('holds every part the format requires', () {
      final p = parts(buildXlsx([sheet()]));
      expect(
        p.keys,
        containsAll(const [
          '[Content_Types].xml',
          '_rels/.rels',
          'xl/_rels/workbook.xml.rels',
          'xl/workbook.xml',
          'xl/styles.xml',
          'xl/worksheets/sheet1.xml',
        ]),
      );
    });

    test('names every sheet in the content types', () {
      // A sheet part with no Override is a part Excel does not know the
      // type of, and it repairs the workbook by dropping it -- the tab
      // is simply not there, with no error.
      final p = parts(buildXlsx([sheet(name: 'A'), sheet(name: 'B')]));
      expect(p['xl/worksheets/sheet2.xml'], isNotNull);
      expect(p['[Content_Types].xml'], contains('/xl/worksheets/sheet1.xml'));
      expect(p['[Content_Types].xml'], contains('/xl/worksheets/sheet2.xml'));
    });

    test('gives every sheet a relationship, and styles one of its own', () {
      final rels = parts(
        buildXlsx([sheet(name: 'A'), sheet(name: 'B')]),
      )['xl/_rels/workbook.xml.rels']!;
      expect(rels, contains('Id="rId1"'));
      expect(rels, contains('Id="rId2"'));
      // Styles takes the id after the sheets, so a workbook with two
      // tabs numbers it rId3. A collision here points two relationships
      // at one target and the tab that loses is blank.
      expect(rels, contains('Id="rId3"'));
      expect(rels, contains('Target="styles.xml"'));
    });

    test('refuses a workbook with no sheets', () {
      // Excel opens it as a repair prompt. Better to fail where the
      // caller is than to write a file that reports itself damaged.
      expect(() => buildXlsx(const []), throwsArgumentError);
    });

    test('the style table declares as many entries as it holds', () {
      // The count attribute and the number of `<xf>` elements have to
      // agree, and both have to cover every index `_styleFor` returns.
      // A style index past the end is not an error -- it formats a
      // figure as whatever happens to sit at index 0.
      final styles = parts(buildXlsx([sheet()]))['xl/styles.xml']!;
      expect(styles, contains('<cellXfs count="$xlsxStyleCount">'));
      expect('<xf '.allMatches(styles).length, xlsxStyleCount + 1);
    });

    test('custom number formats start at 164', () {
      // 0 to 163 are the built-in ones. A custom format numbered inside
      // that range is ignored, or silently applied as the built-in.
      final styles = parts(buildXlsx([sheet()]))['xl/styles.xml']!;
      for (final id in const ['164', '165', '166', '167']) {
        expect(styles, contains('numFmtId="$id" formatCode='));
      }
      expect(styles, isNot(contains('numFmtId="163" formatCode=')));
    });
  });

  group('cells', () {
    String body(List<List<XlsxCell>> rows) =>
        parts(buildXlsx([sheet(rows: rows)]))['xl/worksheets/sheet1.xml']!;

    test('a number is written as a number, not as text', () {
      // The whole reason this file exists. A figure written as a string
      // sums to nothing, and the symptom is a total of zero rather than
      // an error.
      final xml = body(const [
        [XlsxNumber(1200.5)],
      ]);
      expect(xml, contains('<v>1200.5</v>'));
      expect(xml, isNot(contains('t="inlineStr"')));
    });

    test('a whole number loses its trailing point-nought', () {
      expect(
        body(const [
          [XlsxNumber(1200)],
        ]),
        contains('<v>1200</v>'),
      );
    });

    test('text is written as text even when it looks like a number', () {
      // A document number of `0012` written as a number is 12, and the
      // invoice cannot be found again.
      final xml = body(const [
        [XlsxText('0012')],
      ]);
      expect(xml, contains('t="inlineStr"'));
      expect(xml, contains('<t xml:space="preserve">0012</t>'));
    });

    test('a blank writes no cell at all', () {
      // Distinct from an empty string, which makes the cell exist and
      // makes COUNTA count it.
      final xml = body(const [
        [XlsxBlank(), XlsxText('x')],
      ]);
      expect(xml, isNot(contains('r="A1"')));
      expect(xml, contains('r="B1"'));
    });

    test('an empty row is still a row', () {
      // A report is blocks separated by blank lines. A sheet whose row
      // numbers jump reads as data that went missing.
      final xml = body(const [
        [XlsxText('a')],
        [],
        [XlsxText('b')],
      ]);
      expect(xml, contains('<row r="2">'));
      expect(xml, contains('r="A3"'));
    });

    test('each format gets its own style, and bold a different one', () {
      final xml = body(const [
        [
          XlsxNumber(1, format: XlsxFormat.money),
          XlsxNumber(1, format: XlsxFormat.whole),
          XlsxNumber(1, format: XlsxFormat.percent),
          XlsxNumber(1, format: XlsxFormat.date),
          XlsxNumber(1, format: XlsxFormat.money, bold: true),
        ],
      ]);
      final used = RegExp(
        r's="(\d+)"',
      ).allMatches(xml).map((m) => m.group(1)).toList();
      expect(used.toSet().length, 5, reason: 'five distinct styles: $used');
      for (final s in used) {
        expect(int.parse(s!), lessThan(xlsxStyleCount));
      }
    });

    test('a NaN does not reach the file', () {
      // `<v>NaN</v>` is not a number and Excel reports the workbook as
      // damaged. A division by zero upstream should cost a wrong cell,
      // not the file.
      expect(
        body([
          [XlsxNumber(double.nan), XlsxNumber(double.infinity)],
        ]),
        isNot(contains('NaN')),
      );
    });
  });

  group('escaping', () {
    test('the five XML characters are escaped', () {
      expect(xlsxEscape('a & b'), 'a &amp; b');
      expect(xlsxEscape('<tag>'), '&lt;tag&gt;');
      expect(xlsxEscape('"q"'), '&quot;q&quot;');
      expect(xlsxEscape("it's"), 'it&apos;s');
    });

    test('the ampersand is escaped first', () {
      // Otherwise the `&` this function itself writes is escaped a
      // second time and the cell reads `&amp;lt;`.
      expect(xlsxEscape('<'), '&lt;');
      expect(xlsxEscape('&lt;'), '&amp;lt;');
    });

    test('a control character is dropped rather than escaped', () {
      // It is not legal in XML 1.0 in any form, escaped or otherwise,
      // and one pasted into an account name would make the whole
      // workbook unreadable.
      final soh = String.fromCharCode(1);
      final nul = String.fromCharCode(0);
      expect(xlsxEscape('a${soh}b'), 'ab');
      expect(xlsxEscape('a${nul}b'), 'ab');
    });

    test('tab, newline and return survive', () {
      // Those three ARE legal, and a multi-line address is a real cell.
      final s = 'a\nb\tc\rd';
      expect(xlsxEscape(s), s);
    });

    test('an ampersand in a sheet name reaches the workbook escaped', () {
      final xml = parts(
        buildXlsx([sheet(name: 'Profit & loss')]),
      )['xl/workbook.xml']!;
      expect(xml, contains('name="Profit &amp; loss"'));
    });
  });

  group('sheet names', () {
    test('the characters Excel refuses are replaced', () {
      // Excel does not report a bad name as a bad name. It reports the
      // workbook as unreadable and offers to repair it.
      expect(xlsxSheetName('Receivables 1/4/26'), 'Receivables 1 4 26');
      expect(xlsxSheetName(r'a\b:c?d*e[f]g'), 'a b c d e f g');
    });

    test('a long one is trimmed to 31 characters', () {
      final long = xlsxSheetName('Statement of changes in equity for the year');
      expect(long.length, lessThanOrEqualTo(31));
      expect(long, 'Statement of changes in equity');
    });

    test('an empty one becomes something', () {
      expect(xlsxSheetName('   '), 'Sheet1');
      expect(xlsxSheetName('///'), 'Sheet1');
    });

    test('duplicates are made distinct', () {
      expect(xlsxSheetNames(const ['Trial balance', 'Trial balance']), [
        'Trial balance',
        'Trial balance (2)',
      ]);
    });

    test('duplicates created BY the trim are made distinct too', () {
      // The case that makes this worth a function: two titles that
      // differ only past character 31 trim to one name, and two tabs of
      // one name is a workbook Excel will not open.
      final names = xlsxSheetNames(const [
        'Statement of changes in equity 2025',
        'Statement of changes in equity 2026',
      ]);
      expect(names.toSet().length, 2);
      for (final n in names) {
        expect(n.length, lessThanOrEqualTo(31));
      }
    });
  });

  group('geometry', () {
    test('column letters run past Z', () {
      expect(xlsxColumn(1), 'A');
      expect(xlsxColumn(26), 'Z');
      expect(xlsxColumn(27), 'AA');
      expect(xlsxColumn(52), 'AZ');
      expect(xlsxColumn(53), 'BA');
      expect(xlsxColumn(702), 'ZZ');
      expect(xlsxColumn(703), 'AAA');
    });

    test('a column before the first is refused', () {
      expect(() => xlsxColumn(0), throwsArgumentError);
    });

    test('widths are written only where they were given', () {
      final xml = parts(
        buildXlsx([sheet(widths: const [30, 12])]),
      )['xl/worksheets/sheet1.xml']!;
      expect(xml, contains('<col min="1" max="1" width="30.0"'));
      expect(xml, contains('<col min="2" max="2" width="12.0"'));
      expect(xml, isNot(contains('min="3"')));
    });

    test('no widths means no cols element at all', () {
      expect(
        parts(buildXlsx([sheet()]))['xl/worksheets/sheet1.xml']!,
        isNot(contains('<cols>')),
      );
    });

    test('a frozen header stays put', () {
      final xml = parts(
        buildXlsx([sheet(freeze: 1)]),
      )['xl/worksheets/sheet1.xml']!;
      expect(xml, contains('ySplit="1"'));
      expect(xml, contains('topLeftCell="A2"'));
      expect(xml, contains('state="frozen"'));
    });

    test('no freeze means no pane', () {
      expect(
        parts(buildXlsx([sheet()]))['xl/worksheets/sheet1.xml']!,
        isNot(contains('<pane')),
      );
    });
  });

  group('dates', () {
    test('the epoch is 1899-12-30, not 1900-01-01', () {
      // Lotus treated 1900 as a leap year, Excel copied the bug for
      // compatibility and never fixed it. A date written without the
      // two-day offset is two days out, which on a due date is the
      // difference between overdue and not.
      expect(xlsxDateSerial(DateTime(1900, 1, 1)), 2);
      // 1900-03-01, where the bug stops mattering. Excel puts a
      // fictitious 1900-02-29 at serial 60, so from 1 March onwards its
      // serials agree with a plain day count from 1899-12-30 -- which
      // is why that epoch is right for every date this application will
      // ever write, and why the only dates it is wrong for are two
      // months in 1900.
      expect(xlsxDateSerial(DateTime(1900, 3, 1)), 61);
      expect(xlsxDateSerial(DateTime(2026, 9, 18)), 46283);
    });

    test('a day is one', () {
      expect(
        xlsxDateSerial(DateTime(2026, 9, 19)) -
            xlsxDateSerial(DateTime(2026, 9, 18)),
        1,
      );
    });

    test('the time of day is dropped', () {
      // A report date is a date. Keeping the clock would make two cells
      // of the same day compare unequal.
      expect(
        xlsxDateSerial(DateTime(2026, 9, 18, 23, 59)),
        xlsxDateSerial(DateTime(2026, 9, 18)),
      );
    });

    test('a date crossing a daylight-saving boundary does not slip', () {
      // Built in UTC on both sides, so an hour that does not exist in
      // some local zone cannot move the day.
      expect(
        xlsxDateSerial(DateTime(2026, 3, 29)) -
            xlsxDateSerial(DateTime(2026, 3, 28)),
        1,
      );
    });
  });
}
