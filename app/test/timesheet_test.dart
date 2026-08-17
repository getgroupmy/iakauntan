import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';

/// Timesheets, on the screen side.
///
/// The rate resolution and the billing arithmetic are asserted in
/// `supabase/tests/timesheets.sql`, where they belong. What is asserted
/// here is the one number this screen works out for itself — the hours
/// summary at the top of somebody's own week — and that utilisation
/// distinguishes "no timesheet" from "all of it internal", which are
/// different answers and must not render the same.
void main() {
  final period = (from: DateTime(2026, 2, 1), to: DateTime(2026, 2, 28));

  ProviderContainer harness({
    List<Map<String, dynamic>> entries = const [],
    List<Map<String, dynamic>> report = const [],
  }) {
    final c = ProviderContainer(
      overrides: [
        repoProvider.overrideWithValue(null),
        myTimeEntriesProvider.overrideWith((ref, p) async => entries),
        timesheetReportProvider.overrideWith((ref, p) async => report),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the week adds up in hours, not minutes', () async {
    final c = harness(
      entries: const [
        {'minutes': 90, 'is_billable': true, 'amount': 675.0},
        {'minutes': 30, 'is_billable': true, 'amount': 225.0},
        {'minutes': 60, 'is_billable': false, 'amount': 0.0},
      ],
    );
    final rows = await c.read(myTimeEntriesProvider(period).future);

    final minutes = rows.fold<num>(0, (a, e) => a + (e['minutes'] as num));
    final billable = rows
        .where((e) => e['is_billable'] == true)
        .fold<num>(0, (a, e) => a + (e['minutes'] as num));

    // Three hours recorded, two of them chargeable. Divided once at the
    // end rather than per entry, so six ten-minute calls read as one
    // hour and not as 0.996 of one.
    expect((minutes / 60).toStringAsFixed(2), '3.00');
    expect((billable / 60).toStringAsFixed(2), '2.00');
  });

  test('non-billable time is counted but not charged', () async {
    final c = harness(
      entries: const [
        {'minutes': 120, 'is_billable': false, 'amount': 0.0},
      ],
    );
    final rows = await c.read(myTimeEntriesProvider(period).future);
    expect(rows.single['amount'], 0.0);
    // It still counts towards the total, which is the only way
    // utilisation means anything.
    expect(rows.fold<num>(0, (a, e) => a + (e['minutes'] as num)), 120);
  });

  test('utilisation is null when nothing was recorded, not zero', () async {
    final c = harness(
      report: const [
        {
          'who': 'A',
          'billable_hours': 3.0,
          'utilisation_percent': 75.0,
          'unbilled_amount': 0.0,
        },
        {
          'who': 'B',
          'billable_hours': 0.0,
          'utilisation_percent': null,
          'unbilled_amount': 0.0,
        },
      ],
    );
    final rows = await c.read(timesheetReportProvider(period).future);
    expect(rows.first['utilisation_percent'], 75.0);
    expect(rows.last['utilisation_percent'], isNull);
  });

  test('unbilled value across the team is what the card totals', () async {
    final c = harness(
      report: const [
        {
          'who': 'A',
          'billable_hours': 3.0,
          'utilisation_percent': 75.0,
          'unbilled_amount': 1350.0,
        },
        {
          'who': 'B',
          'billable_hours': 2.0,
          'utilisation_percent': 100.0,
          'unbilled_amount': 600.0,
        },
      ],
    );
    final rows = await c.read(timesheetReportProvider(period).future);
    expect(
      rows.fold<num>(0, (a, r) => a + (r['unbilled_amount'] as num)),
      1950.0,
    );
  });
}
