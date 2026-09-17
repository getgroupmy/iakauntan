import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/dashboard/todos_screen.dart';

/// The to-do list, and the one date rule in it.
///
/// OVERDUE IS STRICTLY BEFORE TODAY. The model says why in its own
/// words: an item due today is due, not late, and colouring it red at
/// one minute past midnight is how a list trains somebody to ignore the
/// colour. Both sides of that boundary are asserted, and so is the fact
/// that the comparison is DATE-ONLY -- a task due today at midnight is
/// not late at four in the afternoon, which a naive `isBefore` on the
/// raw timestamps gets wrong every afternoon of the year.
///
/// The fixtures are built relative to today rather than pinned to a
/// date, because a test that hard-codes "2026-09-14 is overdue" starts
/// passing for the wrong reason the moment the clock moves past it.
void main() {
  final today = DateTime.now();
  DateTime day(int offset) =>
      DateTime(today.year, today.month, today.day + offset);

  Todo todo({
    String id = 't1',
    String title = 'Chase the SSM lodgement',
    String? notes,
    DateTime? dueDate,
    String priority = 'normal',
    DateTime? doneAt,
    String? link,
  }) => Todo(
    id: id,
    title: title,
    notes: notes,
    dueDate: dueDate,
    priority: priority,
    doneAt: doneAt,
    link: link,
  );

  late GoRouter router;

  Widget wrap({List<Todo> open = const [], List<Todo> finished = const []}) {
    router = GoRouter(
      initialLocation: '/todos',
      routes: [
        GoRoute(path: '/todos', builder: (_, __) => const TodosScreen()),
        GoRoute(
          path: '/secretarial/:id',
          builder: (_, __) => const Scaffold(body: Text('a company file')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        todosProvider(false).overrideWith((ref) async => open),
        todosProvider(true).overrideWith((ref) async => finished),
        repoProvider.overrideWithValue(null),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> show(
    WidgetTester tester, {
    List<Todo> open = const [],
    List<Todo> finished = const [],
  }) async {
    await tester.pumpWidget(wrap(open: open, finished: finished));
    await tester.pumpAndSettle();
  }

  String where() => router.routerDelegate.currentConfiguration.uri.toString();

  group('overdue is strictly before today', () {
    testWidgets('yesterday is late and says so', (tester) async {
      await show(tester, open: [todo(dueDate: day(-1))]);

      expect(find.textContaining('Overdue — '), findsOneWidget);
    });

    testWidgets('today is due, not late', (tester) async {
      // The boundary, and the reason the model gives for it: red at one
      // minute past midnight on something still perfectly on time
      // teaches somebody to ignore red.
      await show(tester, open: [todo(dueDate: day(0))]);

      expect(find.textContaining('Overdue'), findsNothing);
      // The date is still shown -- it is due today, which is worth
      // knowing; it is just not a failure.
      expect(find.text(_d(day(0))), findsOneWidget);
    });

    testWidgets('and the comparison is on the date, not the moment',
        (tester) async {
      // A task due at midnight today, read in the afternoon. Comparing
      // the raw timestamps makes this overdue every day after lunch.
      await show(tester, open: [
        todo(dueDate: DateTime(today.year, today.month, today.day)),
      ]);

      expect(find.textContaining('Overdue'), findsNothing);
    });

    testWidgets('tomorrow is not late either', (tester) async {
      await show(tester, open: [todo(dueDate: day(1))]);

      expect(find.textContaining('Overdue'), findsNothing);
    });

    testWidgets('and a task with no date is never late', (tester) async {
      await show(tester, open: [todo(dueDate: null)]);

      expect(find.textContaining('Overdue'), findsNothing);
      expect(find.text('Chase the SSM lodgement'), findsOneWidget);
    });

    testWidgets('a finished task is not late however long ago it was due',
        (tester) async {
      // `isDone` short-circuits. Without it the Done tab is a wall of
      // red for work that was completed.
      await show(tester, finished: [
        todo(dueDate: day(-30), doneAt: day(-28)),
      ]);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Overdue'), findsNothing);
      expect(find.textContaining('Done ${_d(day(-28))}'), findsOneWidget);

      // And not red. The words come from the "Done" branch either way,
      // so `isOverdue` reaches this row ONLY through the colour -- drop
      // the `isDone` short-circuit and the Done tab turns into a wall
      // of red for work that was finished. The text assertions above
      // cannot see that; this is the one that can.
      expect(_subtitleColour(tester), isNull);
    });

    testWidgets('while something genuinely late is', (tester) async {
      // The contrast, so the assertion above is not just "the colour
      // happens to be null everywhere".
      await show(tester, open: [todo(dueDate: day(-1))]);

      expect(_subtitleColour(tester), isNotNull);
    });
  });

  group('what the row says', () {
    testWidgets('a done task is struck through and dated', (tester) async {
      await show(tester, finished: [todo(doneAt: day(-2))]);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final title = tester.widget<Text>(find.text('Chase the SSM lodgement'));
      expect(title.style?.decoration, TextDecoration.lineThrough);
      // The done date replaces the due date: once it is finished, when
      // it was due is no longer the question.
      expect(find.textContaining('Done ${_d(day(-2))}'), findsOneWidget);
    });

    testWidgets('notes follow the date', (tester) async {
      await show(tester, open: [
        todo(dueDate: day(3), notes: 'Ring Encik Rahman first'),
      ]);

      expect(
        find.text('${_d(day(3))} · Ring Encik Rahman first'),
        findsOneWidget,
      );
    });

    testWidgets('a task with neither date nor notes has no subtitle at all',
        (tester) async {
      // `_subtitle` returns null rather than an empty Text, which is
      // what keeps the row from growing a blank second line.
      await show(tester, open: [todo(dueDate: null, notes: null)]);

      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.subtitle, isNull);
    });

    testWidgets('a high priority open task is flagged', (tester) async {
      await show(tester, open: [todo(priority: 'high')]);

      expect(find.byIcon(Icons.flag), findsOneWidget);
    });

    testWidgets('and an ordinary open one is not', (tester) async {
      // The control the flag needed: without it, a mutant flagging
      // every unfinished task passes both assertions beside this one.
      await show(tester, open: [todo(priority: 'normal')]);

      expect(find.byIcon(Icons.flag), findsNothing);
    });

    testWidgets('and a finished one is not, however urgent it was',
        (tester) async {
      // Nothing left to be urgent about. A Done tab full of red flags
      // is the same defect as a Done tab full of Overdue.
      await show(tester, finished: [todo(priority: 'high', doneAt: day(-1))]);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.flag), findsNothing);
    });
  });

  group('what a task is about', () {
    testWidgets('a task carrying a link can open it', (tester) async {
      await show(tester, open: [
        todo(link: '/secretarial/abc', title: 'Lodge the annual return'),
      ]);

      await tester.tap(find.byTooltip('Open what this is about'));
      await tester.pumpAndSettle();

      expect(where(), '/secretarial/abc');
    });

    testWidgets('and one without carries no button', (tester) async {
      await show(tester, open: [todo(link: null)]);

      expect(find.byTooltip('Open what this is about'), findsNothing);
      // Remove is always there.
      expect(find.byTooltip('Remove'), findsOneWidget);
    });
  });
}

/// The colour of the one subtitle on screen, or null where it has none.
Color? _subtitleColour(WidgetTester tester) {
  final tile = tester.widget<ListTile>(find.byType(ListTile));
  return (tile.subtitle as Text?)?.style?.color;
}

/// The screen renders dates through `Fmt.date`, which is dd/MM/yyyy.
String _d(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';
