import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/features/documents/recurring_documents_screen.dart';

/// Schedules that raise documents on their own.
///
/// Three things live only in this widget.
///
/// WHY A SCHEDULE STOPPED BILLING. `last_error` is, in the screen's own
/// words, the thing somebody came here to find out: a schedule that
/// silently failed last month is revenue that was never invoiced, and
/// nothing else in the app says so.
///
/// WHETHER THERE IS A NEXT RUN AT ALL. "next 01/10/2026" on a PAUSED
/// schedule is a promise the scheduler will not keep. The date is
/// printed only while the schedule is active.
///
/// AND HOW OFTEN. Five frequencies, each singular or plural, and an
/// interval that only earns a mention when it is not one -- "Every
/// month", not "Every 1 month". Every one of those is a sentence
/// somebody reads to decide whether the billing is set up right.
void main() {
  Map<String, dynamic> schedule({
    String id = 'r1',
    String name = 'Menara Ampang — monthly service',
    String kind = 'sales',
    String frequency = 'monthly',
    int intervalCount = 1,
    bool isActive = true,
    String nextRun = '2026-10-01',
    int? maxOccurrences,
    int occurrences = 0,
    String? endDate,
    bool autoPost = false,
    bool autoEmail = false,
    String? lastError,
  }) => {
    'id': id,
    'name': name,
    'kind': kind,
    'frequency': frequency,
    'interval_count': intervalCount,
    'is_active': isActive,
    'next_run_date': nextRun,
    'max_occurrences': maxOccurrences,
    'occurrences': occurrences,
    'end_date': endDate,
    'auto_post': autoPost,
    'auto_email': autoEmail,
    'last_error': lastError,
  };

  Widget wrap(List<Map<String, dynamic>> rows, {String role = 'owner'}) =>
      ProviderScope(
        overrides: [
          recurringDocumentsProvider.overrideWith((ref) async => rows),
          memberRoleProvider.overrideWith((ref) async => role),
          repoProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const RecurringDocumentsScreen(),
        ),
      );

  Future<void> show(
    WidgetTester tester,
    List<Map<String, dynamic>> rows, {
    String role = 'owner',
  }) async {
    await tester.pumpWidget(wrap(rows, role: role));
    await tester.pumpAndSettle();
  }

  group('why a schedule stopped billing', () {
    testWidgets('the last failure is on the row, in red', (tester) async {
      // A schedule that failed silently last month is revenue nobody
      // invoiced, and nothing else in the app says so.
      await show(tester, [
        schedule(lastError: 'Customer has no billing address'),
      ]);

      expect(
        find.text('Last run failed: Customer has no billing address'),
        findsOneWidget,
      );
      final text = tester.widget<Text>(
          find.text('Last run failed: Customer has no billing address'));
      expect(text.style?.color, isNotNull,
          reason: 'a failure that is not coloured is a failure nobody sees');
    });

    testWidgets('and a schedule that has not failed says nothing',
        (tester) async {
      // The control. "Last run failed: " with nothing after it is
      // worse than silence.
      await show(tester, [schedule(lastError: null)]);

      expect(find.textContaining('Last run failed'), findsNothing);
    });

    testWidgets('an empty error string is not a failure either',
        (tester) async {
      // What a cleared column looks like. The guard is `!= null &&
      // isNotEmpty`, and only the second half catches this.
      await show(tester, [schedule(lastError: '')]);

      expect(find.textContaining('Last run failed'), findsNothing);
    });
  });

  group('whether there is a next run at all', () {
    testWidgets('an active schedule says when', (tester) async {
      await show(tester, [schedule(isActive: true, nextRun: '2026-10-01')]);

      expect(find.textContaining('next 01/10/2026'), findsOneWidget);
      expect(find.byType(StatusChip), findsNothing);
    });

    testWidgets('and a paused one says paused instead of a date',
        (tester) async {
      // "next 01/10/2026" on a paused schedule is a promise the
      // scheduler will not keep, and the row otherwise looks identical.
      await show(tester, [schedule(isActive: false, nextRun: '2026-10-01')]);

      expect(find.textContaining('next '), findsNothing);
      expect(find.text('Paused'), findsOneWidget);
    });
  });

  group('how often', () {
    testWidgets('an interval of one is not mentioned', (tester) async {
      await show(tester, [schedule(frequency: 'monthly', intervalCount: 1)]);

      expect(find.textContaining('Every month · '), findsOneWidget);
      expect(find.textContaining('Every 1 month'), findsNothing);
      // And singular: "Every months" would match a containing check on
      // "Every month".
      expect(find.textContaining('Every months'), findsNothing);
    });

    testWidgets('and anything else is', (tester) async {
      await show(tester, [schedule(frequency: 'weekly', intervalCount: 2)]);

      expect(find.textContaining('Every 2 weeks'), findsOneWidget);
    });

    testWidgets('every frequency has its own word, singular and plural',
        (tester) async {
      // All eight on screen at once rather than pumped one after
      // another. Re-pumping a ProviderScope into the same tree reuses
      // the elements, and the second case in a loop can go on showing
      // the first one's text -- which reads as a failure of the code
      // rather than of the test. It is also a better assertion: eight
      // rows where every cadence must be distinguishable from the
      // seven beside it.
      const cases = [
        ('daily', 1, 'Every day'),
        ('daily', 3, 'Every 3 days'),
        ('weekly', 1, 'Every week'),
        ('monthly', 1, 'Every month'),
        ('monthly', 6, 'Every 6 months'),
        ('quarterly', 1, 'Every quarter'),
        ('quarterly', 2, 'Every 2 quarters'),
        ('yearly', 1, 'Every year'),
      ];

      await show(tester, [
        for (final (i, c) in cases.indexed)
          schedule(
            id: 'r$i',
            name: 'Schedule $i',
            frequency: c.$1,
            intervalCount: c.$2,
          ),
      ]);

      // Each one with the separator that follows it in the subtitle.
      // Without it "Every day" matches "Every dayS", and a mutant that
      // drops every singular form passes the whole list -- which is
      // exactly what happened before this line said ' · '.
      for (final (freq, every, expected) in cases) {
        expect(find.textContaining('$expected · '), findsOneWidget,
            reason: '$freq x $every should read "$expected"');
      }
    });

    testWidgets('an unknown frequency falls back to months', (tester) async {
      // The default arm. A frequency the app has not heard of is far
      // likelier to be monthly than daily, and billing somebody thirty
      // times a month is the expensive way to be wrong.
      await show(tester, [schedule(frequency: 'fortnightly', intervalCount: 1)]);

      expect(find.textContaining('Every month'), findsOneWidget);
    });
  });

  group('when it stops', () {
    testWidgets('a capped schedule counts what it has raised',
        (tester) async {
      await show(tester, [
        schedule(maxOccurrences: 12, occurrences: 3),
      ]);

      expect(find.textContaining('3 of 12'), findsOneWidget);
    });

    testWidgets('an end date is shown where there is no cap', (tester) async {
      await show(tester, [
        schedule(maxOccurrences: null, endDate: '2026-12-31'),
      ]);

      expect(find.textContaining('until 31/12/2026'), findsOneWidget);
    });

    testWidgets('and a cap wins over an end date', (tester) async {
      // Both can be set. The count is the tighter promise and the one
      // the scheduler enforces first.
      await show(tester, [
        schedule(maxOccurrences: 12, occurrences: 3, endDate: '2026-12-31'),
      ]);

      expect(find.textContaining('3 of 12'), findsOneWidget);
      expect(find.textContaining('until'), findsNothing);
    });

    testWidgets('a schedule with neither runs on, and says neither',
        (tester) async {
      await show(tester, [
        schedule(maxOccurrences: null, endDate: null),
      ]);

      expect(find.textContaining(' of '), findsNothing);
      expect(find.textContaining('until'), findsNothing);
      // The whole line, with the limit simply absent. Not a check for a
      // doubled separator: `_limit` returns '' and the
      // `.where((s) => s.isNotEmpty)` drops it before the join, so no
      // doubling is reachable and that assertion would pass whatever
      // happened.
      expect(find.text('Every month · next 01/10/2026'), findsOneWidget);
    });
  });

  group('what it does by itself', () {
    testWidgets('posting and emailing are named together', (tester) async {
      await show(tester, [schedule(autoPost: true, autoEmail: true)]);

      expect(find.textContaining('posts itself and emails the customer'),
          findsOneWidget);
    });

    testWidgets('or one alone, with no dangling "and"', (tester) async {
      await show(tester, [schedule(autoPost: true, autoEmail: false)]);

      expect(find.textContaining('posts itself'), findsOneWidget);
      expect(find.textContaining(' and '), findsNothing);
    });

    testWidgets('and a schedule that only drafts says neither',
        (tester) async {
      await show(tester, [schedule(autoPost: false, autoEmail: false)]);

      expect(find.textContaining('posts itself'), findsNothing);
      expect(find.textContaining('emails the customer'), findsNothing);
    });
  });

  group('who may change one', () {
    testWidgets('somebody who may post gets the menu', (tester) async {
      await show(tester, [schedule(isActive: true)]);

      expect(find.byType(PopupMenuButton<String>), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      // An active schedule is offered a pause, not a resume.
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Resume'), findsNothing);
    });

    testWidgets('and a paused one is offered a resume', (tester) async {
      await show(tester, [schedule(isActive: false)]);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Pause'), findsNothing);
    });

    testWidgets('a viewer gets no menu at all', (tester) async {
      // Pausing a schedule stops invoices being raised. Reading the
      // list is not that.
      await show(tester, [schedule()], role: 'viewer');

      expect(find.byType(PopupMenuButton<String>), findsNothing);
      // The row is still readable.
      expect(find.textContaining('Every month'), findsOneWidget);
    });
  });
}
