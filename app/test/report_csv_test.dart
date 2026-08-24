import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/csv.dart';
import 'package:iakauntan/src/features/reports/report_csv.dart';
import 'package:iakauntan/src/features/reports/report_spec.dart';

/// A report as something a spreadsheet can add up.
///
/// The PDF is for reading and this is for calculating, and the whole
/// difference between them is in the cells: `RM 1,200.00` is a figure a
/// person understands and a string a spreadsheet cannot sum. What is
/// asserted here is mostly that no formatting leaked across.
///
/// Read back through `splitCsvLine`, which is the parser this project
/// already ships, so the quoting is checked by the thing that has to
/// survive it rather than by a regex written to match what was produced.
void main() {
  final range = DateTimeRange(
    start: DateTime(2026, 1, 1),
    end: DateTime(2026, 8, 11),
  );

  List<List<String>> parse(String csv) => csv
      .split('\r\n')
      .where((l) => l.isNotEmpty)
      .map(splitCsvLine)
      .toList();

  final deferred = <Map<String, dynamic>>[
    {
      'contact_name': 'Ali, Baba & Co Sdn Bhd',
      'doc_no': 'INV-1',
      'doc_date': '2026-01-01',
      'description': 'Annual support',
      'service_start': '2026-01-01',
      'service_end': '2026-12-31',
      'deferred': 12000.0,
      'recognised': 7000.0,
      'cancelled': 0.0,
      'balance': 5000.0,
      'ledger_balance': 5000.0,
    },
  ];

  group('reportCsv', () {
    test('names itself before it says anything else', () {
      final rows = parse(reportCsv(deferredRevenueSpec(deferred, range.end)));
      expect(rows.first.first, 'Deferred Revenue');
      expect(rows[1].first, contains('11/08/2026'));
    });

    test('money is a number a spreadsheet can add, not a string', () {
      final csv = reportCsv(deferredRevenueSpec(deferred, range.end));
      expect(csv, isNot(contains('RM ')));

      final row = parse(csv).firstWhere((r) => r.contains('INV-1 · Annual support'));
      expect(row, contains('12000.00'));
      expect(row, contains('5000.00'));
    });

    // The PDF blanks an unsigned zero so the eye runs past it. A blank
    // cell in a spreadsheet reads as a figure nobody supplied, and every
    // one of these is a figure somebody did.
    test('a zero is written as a zero', () {
      final csv = reportCsv(deferredRevenueSpec(deferred, range.end));
      final row = parse(csv).firstWhere((r) => r.contains('INV-1 · Annual support'));
      expect(row, contains('0.00'));
    });

    test('a comma in a customer name does not shift the columns', () {
      final rows = parse(reportCsv(deferredRevenueSpec(deferred, range.end)));
      final row = rows.firstWhere((r) => r.contains('Ali, Baba & Co Sdn Bhd'));
      // Seven columns, whatever is inside them.
      expect(row.length, greaterThanOrEqualTo(7));
      expect(row[0], 'Ali, Baba & Co Sdn Bhd');
      expect(row[1], 'INV-1 · Annual support');
    });

    // The failure this guards against: an importer that takes its column
    // count from the first row would throw away six of seven columns,
    // because the first row is the report's title.
    test('every row is the same width', () {
      final rows = parse(reportCsv(deferredRevenueSpec(deferred, range.end)));
      final widths = rows.map((r) => r.length).toSet();
      expect(widths.length, 1, reason: 'the file has to be rectangular');
    });

    test('the reconciliation note is carried', () {
      final csv = reportCsv(deferredRevenueSpec(deferred, range.end));
      expect(csv, contains('Agrees with account 2127'));
    });

    test('a profit and loss keeps its sections and their totals', () {
      final spec = profitLossSpec([
        {
          'code': '4000',
          'name': 'Sales',
          'account_type': 'revenue',
          'amount': 100000.0,
        },
        {
          'code': '6000',
          'name': 'Salaries',
          'account_type': 'expense',
          'amount': 25000.0,
        },
      ], range);
      final rows = parse(reportCsv(spec));

      expect(rows.any((r) => r.first == 'Revenue'), isTrue);
      expect(
        rows.any((r) => r.contains('4000') && r.contains('100000.00')),
        isTrue,
      );
      expect(rows.any((r) => r.contains('Total Revenue')), isTrue);
      // Net profit is a highlight, not a section.
      expect(rows.any((r) => r.first.contains('Net')), isTrue);
    });

    test('a report with nothing in it is still a file', () {
      final csv = reportCsv(deferredRevenueSpec(const [], range.end));
      expect(csv, startsWith('"Deferred Revenue"'));
      expect(csv, endsWith('\r\n'));
    });
  });
}
