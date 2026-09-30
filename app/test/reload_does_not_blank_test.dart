import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import 'package:iakauntan/src/core/live_updates.dart';
import 'package:iakauntan/src/core/skeletons.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/repository.dart';

/// "Why does the whole chat page reload when text is sent or received?"
///
/// It did, and so did every other screen in the app. Three things had to
/// be true at once, and each of them alone would have hidden the other
/// two — which is the argument for asserting all three here rather than
/// the one that happened to be found first.
///
/// 1. `chat_participants` carries a `live_change_*` trigger and had no
///    entry in `live_updates.dart`, so writing it fell through to the
///    deliberate sledgehammer: refetch every provider on screen. Chat
///    writes that table constantly — `chat_mark_read` on opening a
///    thread, `chat_mark_delivered` on every message that arrives.
/// 2. The sledgehammer reaches `currentOrgProvider`, which rebuilds
///    `repoProvider`, which built a NEW `Repo` every time because
///    `Repo` had no `==`. Nearly everything in the app watches it
///    through `requireRepo`.
/// 3. A watched dependency changing is a RELOAD, and `AsyncValue.when`
///    skips its loading arm on a refresh but not on a reload. So the
///    conversation was replaced by six skeleton rows and drawn again,
///    holding the whole time data that was still correct.
final _seed = StateProvider<int>((ref) => 0);

final _fetched = FutureProvider.autoDispose<String>((ref) async {
  final n = ref.watch(_seed);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return 'value $n';
});

void main() {
  group('an AsyncView holding data', () {
    Future<ProviderContainer> show(WidgetTester tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (_, ref, _) => AsyncView<String>(
                  value: ref.watch(_fetched),
                  skeleton: const ListSkeleton(rows: 3),
                  builder: (v) => Text(v),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      return container;
    }

    testWidgets('draws bones on the FIRST load, which is what they are for', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (_, ref, _) => AsyncView<String>(
                  value: ref.watch(_fetched),
                  skeleton: const ListSkeleton(rows: 3),
                  builder: (v) => Text(v),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ListSkeleton), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('value 0'), findsOneWidget);
    });

    testWidgets('keeps it when the provider is invalidated', (tester) async {
      final container = await show(tester);
      expect(find.text('value 0'), findsOneWidget);

      container.invalidate(_fetched);
      await tester.pump();

      expect(find.byType(ListSkeleton), findsNothing);
      expect(find.text('value 0'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('and keeps it when a watched DEPENDENCY changes', (
      tester,
    ) async {
      // The one that was wrong. Riverpod calls this a reload rather than
      // a refresh and `when` treats the two differently by default; a
      // person looking at the screen does not.
      final container = await show(tester);
      expect(find.text('value 0'), findsOneWidget);

      container.read(_seed.notifier).state = 1;
      await tester.pump();

      expect(find.byType(ListSkeleton), findsNothing);
      expect(find.text('value 0'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('value 1'), findsOneWidget);
    });
  });

  group('two repositories onto the same company', () {
    // A stand-in for the client. Only its identity is compared, which is
    // the point: `SupabaseClient` has no value equality and two clients
    // are the same client only when they are the same object.
    final client = _FakeClient();
    final other = _FakeClient();

    test('are equal, so watching one does not reload on the other', () {
      expect(Repo(client, 'org-1'), Repo(client, 'org-1'));
      expect(Repo(client, 'org-1').hashCode, Repo(client, 'org-1').hashCode);
    });

    test('a different company is a different repository', () {
      expect(Repo(client, 'org-1'), isNot(Repo(client, 'org-2')));
    });

    test('and so is a different client', () {
      expect(Repo(client, 'org-1'), isNot(Repo(other, 'org-1')));
    });
  });

  group('the tables chat writes', () {
    // An empty answer here is not "nothing goes stale" — it is the
    // broad refresh, which reaches `currentOrgProvider` and takes the
    // whole app down to bones with it. Every table chat writes needs a
    // narrow answer, and `chat_participants` is the one that was
    // missing: `chat_mark_read` and `chat_mark_delivered` both write it.
    for (final table in const [
      'chat_participants',
      'chat_messages',
      'chat_conversations',
      'chat_attachments',
      'chat_typing',
      'chat_presence',
      'chat_calls',
      'chat_call_participants',
      'chat_access',
    ]) {
      test('$table refreshes narrowly rather than everything', () {
        expect(
          liveUpdateProviders(table),
          isNotEmpty,
          reason:
              '$table has no narrow entry, so writing it refetches every '
              'provider on screen and blanks the app.',
        );
      });
    }
  });
}

class _FakeClient implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
