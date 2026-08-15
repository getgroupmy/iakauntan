import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/push.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/settings/notifications_card.dart';

/// What somebody is told about notifications, in each of the five ways
/// this can stand.
///
/// The reason this is worth asserting is that four of the five are
/// failures, and they need four different things from the person
/// reading them. "Notifications are off" would be true in all four and
/// useful in none: a browser that has refused cannot be asked again by
/// any button this app draws, and offering one would be a lie that
/// wastes somebody's afternoon.
void main() {
  Widget harness(PushStatus state) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      pushStatusProvider.overrideWith((ref) async => state),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: NotificationsCard()),
    ),
  );

  testWidgets('a browser that has never been asked is offered the button', (
    tester,
  ) async {
    await tester.pumpWidget(harness(PushStatus.askable));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('enable-push')), findsOneWidget);
  });

  testWidgets('a browser that refused is not offered a button that cannot '
      'work, and is told where to change it', (tester) async {
    await tester.pumpWidget(harness(PushStatus.denied));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('enable-push')),
      findsNothing,
      reason: 'the browser will not ask again, whatever this app does',
    );
    expect(find.textContaining('site settings'), findsOneWidget);
  });

  testWidgets('a build that cannot do it at all says which ones can', (
    tester,
  ) async {
    await tester.pumpWidget(harness(PushStatus.unsupported));
    await tester.pumpAndSettle();

    expect(find.textContaining('Chrome, Edge and Firefox'), findsOneWidget);
    expect(find.byKey(const ValueKey('enable-push')), findsNothing);
  });

  testWidgets('a deployment with no keys says so rather than offering a '
      'switch that registers a device nothing can send to', (tester) async {
    await tester.pumpWidget(harness(PushStatus.notConfigured));
    await tester.pumpAndSettle();

    expect(find.textContaining('VAPID'), findsOneWidget);
    expect(find.byKey(const ValueKey('enable-push')), findsNothing);
  });

  testWidgets('and one that is on can be turned off again', (tester) async {
    await tester.pumpWidget(harness(PushStatus.on));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('disable-push')), findsOneWidget);
    expect(find.byKey(const ValueKey('enable-push')), findsNothing);
  });

  testWidgets('the promise about what a notification says is on the screen '
      'where somebody decides', (tester) async {
    // Not buried in a document nobody reads: the reason to accept this
    // prompt is that the notification cannot leak the message, and that
    // is worth saying at the moment of the decision.
    await tester.pumpWidget(harness(PushStatus.askable));
    await tester.pumpAndSettle();

    expect(find.textContaining('never what it says'), findsOneWidget);
  });

  testWidgets('the stub build reports unsupported rather than pretending', (
    tester,
  ) async {
    // This test runs on the Dart VM, which is what a phone build sees:
    // `push_stub.dart`. If it ever answered anything else, the settings
    // card would offer Android and iOS a button that registers a device
    // no sender can reach.
    expect(await pushStatus('a-key'), PushStatus.unsupported);
    expect(await subscribeToPush('a-key', ask: true), isNull);
    expect(await currentPushEndpoint(), isNull);
  });
}
