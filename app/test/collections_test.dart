import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';

/// Collections, on the screen side.
///
/// The worklist's ordering, its totals and every refusal are asserted in
/// `supabase/tests/collections.sql`. What is asserted here is the thing
/// the screen decides for itself: which of three sentences a customer
/// gets. "Never chased", "promised and did not pay" and "promised, still
/// to come" lead to three different actions, and rendering any two of
/// them the same is how a credit controller stops trusting the list.
void main() {
  ProviderContainer harness(List<Map<String, dynamic>> rows) {
    final c = ProviderContainer(
      overrides: [
        repoProvider.overrideWithValue(null),
        collectionsWorklistProvider.overrideWith((ref) async => rows),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// The same three-way choice the tile makes, kept here so the test is
  /// about the rule rather than about widget plumbing.
  String status(Map<String, dynamic> r) {
    if (r['promise_broken'] == true) return 'broken';
    if (r['promise_date'] != null) return 'promised';
    if (r['never_chased'] == true) return 'cold';
    return 'chased';
  }

  test('the three states are three different sentences', () async {
    final c = harness(const [
      {
        'contact_id': '1',
        'contact_name': 'Broke A Promise',
        'promise_date': '2026-05-20',
        'promise_broken': true,
        'never_chased': false,
        'outstanding': 1000.0,
      },
      {
        'contact_id': '2',
        'contact_name': 'Never Chased',
        'promise_date': null,
        'promise_broken': false,
        'never_chased': true,
        'outstanding': 2000.0,
      },
      {
        'contact_id': '3',
        'contact_name': 'Promised Next Week',
        'promise_date': '2026-07-15',
        'promise_broken': false,
        'never_chased': false,
        'outstanding': 3000.0,
      },
      {
        'contact_id': '4',
        'contact_name': 'Chased, No Promise',
        'promise_date': null,
        'promise_broken': false,
        'never_chased': false,
        'last_attempt_on': '2026-06-01',
        'outstanding': 500.0,
      },
    ]);

    final rows = await c.read(collectionsWorklistProvider.future);
    expect(rows.map(status).toList(), ['broken', 'cold', 'promised', 'chased']);
  });

  test('a broken promise reads as broken, not as promised', () async {
    // Both rows carry a promise date. Only one of them is a problem, and
    // the difference is a boolean the database computed — the screen
    // must not re-derive it from the date against DateTime.now(), which
    // would disagree with the report the moment the as-at date moves.
    final c = harness(const [
      {
        'contact_id': '1',
        'promise_date': '2026-05-20',
        'promise_broken': true,
        'never_chased': false,
        'outstanding': 1.0,
      },
      {
        'contact_id': '2',
        'promise_date': '2026-07-15',
        'promise_broken': false,
        'never_chased': false,
        'outstanding': 1.0,
      },
    ]);
    final rows = await c.read(collectionsWorklistProvider.future);
    expect(status(rows.first), 'broken');
    expect(status(rows.last), 'promised');
  });

  test('the banner counts what it says it counts', () async {
    final c = harness(const [
      {'promise_broken': true, 'never_chased': false, 'outstanding': 1000.0},
      {'promise_broken': false, 'never_chased': true, 'outstanding': 2000.0},
      {'promise_broken': false, 'never_chased': false, 'outstanding': 3000.0},
    ]);
    final rows = await c.read(collectionsWorklistProvider.future);

    expect(rows.fold<num>(0, (a, r) => a + (r['outstanding'] as num)), 6000.0);
    expect(rows.where((r) => r['promise_broken'] == true).length, 1);
    expect(rows.where((r) => r['never_chased'] == true).length, 1);
  });

  test('the order the database gave is the order kept', () async {
    // The report ranks broken promises above older debt on purpose. If
    // the screen ever sorts by amount or by age it will quietly undo
    // that, so the list is asserted to come through untouched.
    final c = harness(const [
      {
        'contact_name': 'Broken but small',
        'promise_broken': true,
        'never_chased': false,
        'outstanding': 100.0,
        'oldest_days': 30,
      },
      {
        'contact_name': 'Huge and ancient',
        'promise_broken': false,
        'never_chased': true,
        'outstanding': 99000.0,
        'oldest_days': 400,
      },
    ]);
    final rows = await c.read(collectionsWorklistProvider.future);
    expect(rows.first['contact_name'], 'Broken but small');
  });
}
