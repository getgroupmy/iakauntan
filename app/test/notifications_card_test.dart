import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/push.dart';
import 'package:iakauntan/src/core/surface.dart';
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
  // The surface is injected rather than read from the build, because
  // `currentSurface` reads `kIsWeb` and that is a compile-time constant:
  // a widget test on the Dart VM can otherwise never see the browser
  // half of this card's copy, which is most of it.
  Widget harness(PushStatus state, {Surface surface = Surface.web}) =>
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(null),
          pushStatusProvider.overrideWith((ref) async => state),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: NotificationsCard(surface: surface)),
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

  testWidgets('and an iPhone that refused is sent to Settings, not to site '
      'settings it does not have', (tester) async {
    await tester.pumpWidget(harness(PushStatus.denied, surface: Surface.ios));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('enable-push')), findsNothing);
    expect(find.textContaining('site settings'), findsNothing);
    expect(find.textContaining('Settings'), findsOneWidget);
  });

  testWidgets('a build that cannot do it at all says which ones can', (
    tester,
  ) async {
    await tester.pumpWidget(harness(PushStatus.unsupported));
    await tester.pumpAndSettle();

    expect(find.textContaining('Chrome, Edge and Firefox'), findsOneWidget);
    expect(find.byKey(const ValueKey('enable-push')), findsNothing);
  });

  testWidgets('and an Android build names the thing that is missing', (
    tester,
  ) async {
    // Not "this device cannot": somebody CAN make it, by creating a
    // Firebase project. Naming it is the difference between a dead end
    // and a task.
    await tester.pumpWidget(
      harness(PushStatus.unsupported, surface: Surface.android),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Firebase'), findsOneWidget);
    expect(find.textContaining('Chrome'), findsNothing);
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

  testWidgets('a platform with no native half reports unsupported rather '
      'than pretending', (tester) async {
    // This test runs on the Dart VM with the default target platform,
    // which is Android — and Android is exactly the case that has no
    // way through: Firebase needs a `google-services.json` that cannot
    // live in this repository. If it ever answered anything else, the
    // settings card would offer a button that registers a device no
    // sender can reach. iOS is covered in `push_native_test.dart`.
    expect(await pushStatus('a-key'), PushStatus.unsupported);
    expect(await subscribeToPush('a-key', ask: true), isEmpty);
    expect(await currentPushTokens(), isEmpty);
  });

  test('and says which of the three reasons it is', () {
    // One status, three quite different facts, and the person reading
    // can only act on one of them: swap the browser, create a Firebase
    // project, or nothing at all.
    expect(pushUnsupportedNote(Surface.web), contains('Chrome'));
    expect(pushUnsupportedNote(Surface.android), contains('Firebase'));
    expect(pushUnsupportedNote(Surface.desktop), isNot(contains('Firebase')));
    expect(pushUnsupportedNote(Surface.desktop), isNot(contains('Chrome')));
  });

  test('and what to call the thing being notified', () {
    // Permission belongs to this browser on this machine, or this app
    // on this handset. A card that said "you" would describe something
    // that does not exist.
    expect(pushDeviceNoun(Surface.web), 'browser');
    expect(pushDeviceNoun(Surface.ios), 'device');
    expect(pushDeviceNoun(Surface.android), 'device');
    expect(pushDeviceNoun(Surface.desktop), 'device');
  });
}
