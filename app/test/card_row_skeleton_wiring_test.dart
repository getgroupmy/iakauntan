import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/dashboard/todo_card.dart';

/// The three loading states that do NOT go through `AsyncView`.
///
/// `skeletons_test.dart` asserts the shapes and asserts that
/// `AsyncView` draws the one it was given. Neither of those says
/// anything about a screen that calls `.when()` itself, and three did:
/// the to-do card on the dashboard, the clock card on My HR, and the
/// dialog that takes a practice on as a client. They were the last
/// spinners in a `loading:` callback in the whole app, and nothing
/// generic covers them, so the wiring is asserted here at one of them.
///
/// ## Why this file does not call `pumpAndSettle`
///
/// A skeleton SHIMMERS. `pumpAndSettle` waits for the frames to stop
/// being scheduled and they never do, so it runs to its timeout and
/// fails with a message about a pending timer rather than about the
/// screen. Two `pump`s are enough to resolve a provider that is
/// already complete and to draw one frame of an outline that is not.
void main() {
  Widget wrap(Future<List<Todo>> todos) => ProviderScope(
    overrides: [todosProvider(false).overrideWith((ref) => todos)],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: TodoCard()),
    ),
  );

  testWidgets('a to-do list on its way is outlined, not spun', (t) async {
    // Deliberately a future that never completes: the loading branch
    // is the whole subject, and a future that resolves between two
    // pumps would test the data branch by accident.
    await t.pumpWidget(wrap(Completer<List<Todo>>().future));
    await t.pump();

    expect(find.byKey(const ValueKey('skeleton-card-row-0')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('and the outline is as long as the card will be', (t) async {
    // `limit`, not six. The card draws at most `limit` rows and then a
    // line saying how many more there are, so an outline of six where
    // three are coming is content that appears to vanish.
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          todosProvider(false).overrideWith((ref) =>
              Completer<List<Todo>>().future),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: TodoCard(limit: 3)),
        ),
      ),
    );
    await t.pump();

    expect(find.byKey(const ValueKey('skeleton-card-row-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('skeleton-card-row-3')), findsNothing);
  });

  testWidgets('and once the rows arrive the outline is gone', (t) async {
    await t.pumpWidget(wrap(Future.value(const <Todo>[])));
    await t.pump();
    await t.pump();

    expect(find.byKey(const ValueKey('skeleton-card-row-0')), findsNothing);
    expect(
      find.textContaining('Nothing on your list'),
      findsOneWidget,
    );
  });
}
