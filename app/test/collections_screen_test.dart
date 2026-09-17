import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/collections/collections_screen.dart';

/// The chasing worklist.
///
/// Two things live only in this widget.
///
/// WHICH SENTENCE A CUSTOMER GETS. There are four states and the screen
/// picks between them in order, so a customer who promised a date AND
/// broke it must read "promised and did not pay" rather than the
/// ordinary "promised" -- the branch above it is the whole point. And
/// "never chased" is not "chased and got nowhere": a credit controller
/// decides what to do next from exactly that difference, and the
/// screen's own comment says so.
///
/// THE ORDER IS THE DATABASE'S. Broken promises, then customers nobody
/// has rung, then oldest debt. The point of the ordering is that the
/// top of the list is the money most likely to be lost if nobody looks
/// at it today; a list re-sorted here would eventually disagree with
/// the report it came from. So the test hands the screen a list in an
/// order no local sort would produce and checks it comes out unchanged.
void main() {
  /// A row shaped the way `report_collections` returns one.
  ///
  /// `never_chased` is `(l.contact_id is null)` on the same left join
  /// that produces `last_attempt_on`, so the two are the same fact: a
  /// customer is never-chased EXACTLY when there is no last attempt.
  /// The screen leans on that -- its final branch does
  /// `DateTime.parse(last!)` -- so a fixture with neither flag nor date
  /// is not a row the database can produce, and building one only
  /// crashes the test with a TypeError that says nothing about the
  /// screen. This helper keeps the invariant instead of leaving it to
  /// each call.
  Map<String, dynamic> customer({
    String id = 'c1',
    String name = 'Kedai Runcit Aminah',
    num outstanding = 4200,
    bool promiseBroken = false,
    bool neverChased = false,
    String? promiseDate,
    String? lastAttemptOn = '2026-09-10',
    String? lastOutcome,
    int invoices = 3,
    int oldestDays = 62,
    String? assignedName,
  }) => {
    'contact_id': id,
    'contact_name': name,
    'outstanding': outstanding,
    'promise_broken': promiseBroken,
    'never_chased': neverChased,
    'promise_date': promiseDate,
    'last_attempt_on': neverChased ? null : lastAttemptOn,
    'last_outcome': lastOutcome,
    'invoices': invoices,
    'oldest_days': oldestDays,
    'assigned_name': assignedName,
  };

  Widget wrap(List<Map<String, dynamic>> rows) => ProviderScope(
        overrides: [
          collectionsWorklistProvider.overrideWith((ref) async => rows),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const CollectionsScreen(),
        ),
      );

  Future<void> show(
      WidgetTester tester, List<Map<String, dynamic>> rows) async {
    await tester.pumpWidget(wrap(rows));
    await tester.pumpAndSettle();
  }

  group('which sentence a customer gets', () {
    testWidgets('a broken promise says it was not kept', (tester) async {
      // Both flags and a date, which is what a broken promise really
      // looks like in the row. The branch order decides whether this
      // reads as a broken promise or as an ordinary one.
      await show(tester, [
        customer(promiseBroken: true, promiseDate: '2026-09-01'),
      ]);

      expect(find.textContaining('Promised 01/09/2026 and did not pay'),
          findsOneWidget);
    });

    testWidgets('a promise still standing says only that', (tester) async {
      await show(tester, [customer(promiseDate: '2026-09-30')]);

      expect(find.textContaining('Promised 30/09/2026'), findsOneWidget);
      // Not the broken sentence: this customer has not failed anything
      // yet, and saying they did is how a credit controller loses one.
      expect(find.textContaining('did not pay'), findsNothing);
    });

    testWidgets('never chased is not the same as chased and got nowhere',
        (tester) async {
      await show(tester, [
        customer(id: 'a', name: 'Syarikat Bina Jaya', neverChased: true),
        customer(
          id: 'b',
          name: 'Perniagaan Lim',
          lastAttemptOn: '2026-09-10',
          lastOutcome: 'no answer',
        ),
      ]);

      expect(find.textContaining('Never chased'), findsOneWidget);
      expect(find.textContaining('Last contacted 10/09/2026 — no answer'),
          findsOneWidget);
    });

    testWidgets('and a contact with no outcome recorded says just the date',
        (tester) async {
      // The control for the em dash: no outcome must not render a
      // trailing separator with nothing after it.
      await show(tester, [
        customer(lastAttemptOn: '2026-09-10', lastOutcome: null),
      ]);

      expect(find.textContaining('Last contacted 10/09/2026'), findsOneWidget);
      expect(find.textContaining('—'), findsNothing);
    });
  });

  group('the order is the database order', () {
    testWidgets('the list comes out exactly as it went in', (tester) async {
      // Deliberately not sorted by anything this screen could sort by:
      // the largest debt is last, the oldest is in the middle, and the
      // names are not alphabetical. Any local sort changes this.
      await show(tester, [
        customer(id: 'a', name: 'Zulkifli Trading', outstanding: 900,
            promiseBroken: true, promiseDate: '2026-09-01', oldestDays: 20),
        customer(id: 'b', name: 'Ahmad Hardware', outstanding: 1500,
            neverChased: true, oldestDays: 200),
        customer(id: 'c', name: 'Mega Supplies', outstanding: 80000,
            lastAttemptOn: '2026-09-10', oldestDays: 35),
      ]);

      double y(String name) => tester.getCenter(find.text(name)).dy;

      expect(y('Zulkifli Trading'), lessThan(y('Ahmad Hardware')));
      expect(y('Ahmad Hardware'), lessThan(y('Mega Supplies')));
    });
  });

  group('what the worklist adds up to', () {
    testWidgets('the total is every customer on it', (tester) async {
      await show(tester, [
        customer(id: 'a', outstanding: 4200),
        customer(id: 'b', name: 'Perniagaan Lim', outstanding: 800.50),
        customer(id: 'c', name: 'Mega Supplies', outstanding: 15000),
      ]);

      expect(find.textContaining('RM 20,000.50 outstanding'), findsOneWidget);
    });

    testWidgets('and counts the two states worth interrupting somebody for',
        (tester) async {
      await show(tester, [
        customer(id: 'a', promiseBroken: true, promiseDate: '2026-09-01'),
        customer(id: 'b', name: 'B', promiseBroken: true,
            promiseDate: '2026-09-02'),
        customer(id: 'c', name: 'C', neverChased: true),
        customer(id: 'd', name: 'D', lastAttemptOn: '2026-09-10'),
      ]);

      expect(find.textContaining('2 broken promises'), findsOneWidget);
      expect(find.textContaining('1 never chased'), findsOneWidget);
    });

    testWidgets('one broken promise is singular', (tester) async {
      await show(tester, [
        customer(promiseBroken: true, promiseDate: '2026-09-01'),
      ]);

      expect(find.textContaining('1 broken promise'), findsOneWidget);
      expect(find.textContaining('promises'), findsNothing);
    });

    testWidgets('and a clean worklist says only what is owed', (tester) async {
      // The control. Both clauses are conditional, and "0 broken
      // promises · 0 never chased" reads as a warning where there is
      // none.
      await show(tester, [customer(lastAttemptOn: '2026-09-10')]);

      expect(find.textContaining('RM 4,200.00 outstanding'), findsOneWidget);
      expect(find.textContaining('broken promise'), findsNothing);
      expect(find.textContaining('never chased'), findsNothing);
    });
  });

  group('what the row carries', () {
    testWidgets('the count of invoices, the oldest, and who owns it',
        (tester) async {
      await show(tester, [
        customer(
          lastAttemptOn: '2026-09-10',
          invoices: 3,
          oldestDays: 62,
          assignedName: 'Siti',
        ),
      ]);

      expect(find.textContaining('3 invoices · oldest 62 days · Siti'),
          findsOneWidget);
      expect(find.text('RM 4,200.00'), findsOneWidget);
    });

    testWidgets('one invoice is singular, and nobody assigned is silent',
        (tester) async {
      await show(tester, [
        customer(lastAttemptOn: '2026-09-10', invoices: 1, oldestDays: 9,
            assignedName: null),
      ]);

      expect(find.textContaining('1 invoice · oldest 9 days'), findsOneWidget);
      expect(find.textContaining('invoices'), findsNothing);
      // No trailing separator where a name would have been.
      expect(find.textContaining('oldest 9 days ·'), findsNothing);
    });
  });

  group('nothing outstanding', () {
    testWidgets('says every invoice raised has been paid', (tester) async {
      await show(tester, []);

      expect(find.text('Nothing outstanding'), findsOneWidget);
      expect(find.textContaining('Every invoice raised has been paid'),
          findsOneWidget);
    });
  });
}
