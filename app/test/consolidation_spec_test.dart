import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/reports/report_spec.dart';

/// What a consolidated trial balance says on its face.
///
/// The arithmetic is asserted in `supabase/tests/group_consolidation.sql`
/// — the database is what matches the two sides and proves the
/// eliminations sum to zero. What is asserted here is the sentence, and
/// it matters more than it looks: a consolidation with unreconciled
/// inter-company pairs is not one, and the difference between "this is
/// consolidated" and "this is consolidated except for two pairs nobody
/// has agreed yet" is the difference between a figure somebody can file
/// and a figure somebody has to check.
void main() {
  final range = DateTimeRange(
    start: DateTime(2026, 1, 1),
    end: DateTime(2026, 8, 15),
  );

  Map<String, dynamic> row(
    String code,
    String name, {
    double combined = 0,
    double elimination = 0,
  }) => {
    'code': code,
    'name': name,
    'account_type': 'asset',
    'account_subtype': null,
    'companies': 2,
    'combined_balance': combined,
    'elimination': elimination,
    'consolidated_balance': combined + elimination,
  };

  final reconciled = [
    row('1100', 'Trade Debtors', combined: 1080, elimination: -1080),
    row('2110', 'Trade Creditors', combined: -1080, elimination: 1080),
    row('4000', 'Sales', combined: -1000, elimination: 1000),
    row('5000', 'Cost of Sales', combined: 1000, elimination: -1000),
    row('1000', 'Cash', combined: 5000),
  ];

  test('a fully reconciled group says what is still not adjusted', () {
    final spec = consolidatedSpec(
      reconciled,
      range,
      companies: 2,
      unreconciled: 0,
    );
    expect(spec.title, 'Consolidated Trial Balance');
    expect(spec.note, contains('have been eliminated'));
    // The honest caveat. Stock bought from another company in the group
    // still carries the seller's margin, and nothing here removes it.
    expect(spec.note, contains('unrealised profit'));
  });

  test('and one with a pair that does not agree says so instead, with the '
      'count', () {
    final spec = consolidatedSpec(
      reconciled,
      range,
      companies: 2,
      unreconciled: 2,
    );
    expect(spec.note, contains('2 inter-company'));
    expect(spec.note, contains('do not agree'));
    expect(
      spec.note,
      contains('Reconcile'),
      reason: 'it has to say what to do about it, not just that it is so',
    );
  });

  test('one outstanding pair is singular', () {
    final spec = consolidatedSpec(
      reconciled,
      range,
      companies: 2,
      unreconciled: 1,
    );
    expect(spec.note, contains('1 inter-company pair does not agree'));
    expect(spec.note, isNot(contains('pairs do')));
  });

  test('the combined figure is shown beside the consolidated one', () {
    // A single column would hide what came off, which is the thing an
    // accountant reading a consolidation is actually checking.
    final spec = consolidatedSpec(
      reconciled,
      range,
      companies: 2,
      unreconciled: 0,
    );
    final grid = spec.blocks.whereType<ReportGrid>().single;

    expect(grid.headers, contains('Combined'));
    expect(grid.headers, contains('Eliminated'));
    expect(grid.headers, contains('Consolidated'));

    final debtors = grid.rows.firstWhere(
      (r) => (r[0] as TextCell).text == '1100',
    );
    expect((debtors[2] as MoneyCell).value, 1080);
    expect((debtors[3] as MoneyCell).value, -1080);
    expect((debtors[4] as MoneyCell).value, 0);
  });

  test('an account nothing touched is left off', () {
    final spec = consolidatedSpec(
      [
        row('1100', 'Trade Debtors', combined: 1080, elimination: -1080),
        row('1300', 'Stock'),
      ],
      range,
      companies: 2,
      unreconciled: 0,
    );

    final grid = spec.blocks.whereType<ReportGrid>().single;
    expect(grid.rows, hasLength(1));
  });

  test('an account with a balance and no elimination stays', () {
    // The control for the test above: "left off" must mean "nothing at
    // all", not "nothing was eliminated from it".
    final spec = consolidatedSpec(
      [row('1000', 'Cash', combined: 5000)],
      range,
      companies: 2,
      unreconciled: 0,
    );

    expect(spec.blocks.whereType<ReportGrid>().single.rows, hasLength(1));
  });
}
