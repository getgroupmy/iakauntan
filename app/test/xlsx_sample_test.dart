import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/reports/report_spec.dart';
import 'package:iakauntan/src/features/reports/report_xlsx.dart';

/// Writes a sample workbook for `scripts/check_xlsx.py` to read back.
///
/// Not an assertion. It is a FIXTURE GENERATOR that happens to be a
/// test, because `report_spec.dart` imports `package:flutter/material`
/// for `DateTimeRange` and so a plain `dart run` cannot compile it --
/// the Dart VM tries to build the Flutter framework and stops on a
/// switch inside the text layout code. `flutter test` is the only
/// runner here that can execute code importing Flutter.
///
/// It exists because nothing on a build machine can open Excel, and
/// `xlsx_test.dart` can only ask the writer what it wrote -- one
/// implementation asserting against itself, which on a file format is
/// worth much less than it looks. The Python gate unzips this file and
/// reads the XML with the standard library's own parsers: a second
/// implementation, which is the only kind of check that can disagree.
///
/// The sample is built from a real [ReportSpec] rather than from
/// hand-written cells, so what is checked is what the app produces --
/// including the parts that are easy to get wrong and invisible from
/// Dart: an account code kept as text, a negative kept negative, a
/// section with a total and no lines, and a sheet name containing a
/// slash.
///
/// Writes nothing unless `XLSX_SAMPLE_OUT` is set, so an ordinary
/// `flutter test` run neither produces a file nor fails for the want of
/// a path.
void main() {
  test('writes the sample workbook when asked', () {
    final out = Platform.environment['XLSX_SAMPLE_OUT'];
    if (out == null || out.isEmpty) {
      markTestSkipped('XLSX_SAMPLE_OUT is not set');
      return;
    }

    final spec = ReportSpec(
      title: 'Profit & Loss',
      subtitle: '1 Jan 2026 to 31 Dec 2026',
      note: 'Assets 170,000.00 equal liabilities and equity 170,000.00.',
      blocks: const [
        ReportSection(
          title: 'Revenue',
          lines: [
            // `0100` is the case that matters: as a number this is 100.
            ReportLine(code: '0100', name: 'Sales', amount: 240000),
            ReportLine(
              code: '0110',
              name: 'Administrative expenses — professional fees',
              amount: 1234.56,
            ),
          ],
        ),
        // Given its total with no lines under it: `0637`'s
        // `show_accounts: false`.
        ReportSection(
          title: 'Administrative expenses',
          lines: [],
          statedTotal: 70000,
        ),
        // A negative, which must stay negative.
        ReportSection(
          title: 'Other income',
          lines: [
            ReportLine(code: '0900', name: 'Foreign exchange', amount: -250.5),
          ],
        ),
        ReportGrid(
          title: 'Trial balance',
          headers: ['Code', 'Account', 'Debit', 'Credit'],
          rows: [
            [
              TextCell('0100'),
              TextCell('Sales'),
              MoneyCell(0),
              MoneyCell(240000),
            ],
          ],
          total: [
            TextCell(''),
            TextCell('Total'),
            MoneyCell(0),
            MoneyCell(240000),
          ],
        ),
        ReportHighlight(label: 'Net profit', value: 168515.06, emphasise: true),
      ],
    );

    // A second sheet, so the gate can check that more than one is
    // written and that the names come out legal and distinct. The
    // slash is the point: Excel reports a sheet name containing one as
    // a broken WORKBOOK rather than as a bad name.
    const other = ReportSpec(
      title: 'Receivables 1/4/26',
      subtitle: 'As at 30 Apr 2026',
      blocks: [
        ReportGrid(
          title: null,
          headers: ['Customer', 'Current', '30 days'],
          rows: [
            [TextCell('Bumi Maju'), MoneyCell(1200), MoneyCell(0)],
          ],
        ),
      ],
    );

    File(out).writeAsBytesSync(reportXlsx([spec, other]));
  });
}
