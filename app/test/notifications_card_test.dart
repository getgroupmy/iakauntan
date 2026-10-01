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

  testWidgets('and an Android build with no project names the thing that '
      'is missing', (tester) async {
    // Not "this device cannot": somebody CAN make it, by creating a
    // Firebase project. Naming it is the difference between a dead end
    // and a task.
    //
    // `notConfigured`, not `unsupported`, and the two swapped places
    // when the Android client was built. Before it, Android could not
    // be notified at all; now the handset is perfectly capable and it
    // is the BUILD that has nowhere to register — which is somebody's
    // job to finish rather than a fact about the phone.
    await tester.pumpWidget(
      harness(PushStatus.notConfigured, surface: Surface.android),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Firebase'), findsOneWidget);
    expect(find.textContaining('VAPID'), findsNothing);
  });

  testWidgets('and an Android handset that nothing can reach says that '
      'instead', (tester) async {
    // A Huawei sold after 2019, a de-Googled ROM, an Amazon tablet.
    // There is no Firebase project to create and no button to press:
    // FCM is delivered by Google Play Services, and this handset has
    // none. Saying "this build has no Firebase project" here would send
    // somebody to go and make one for nothing.
    await tester.pumpWidget(
      harness(PushStatus.unsupported, surface: Surface.android),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Google Play Services'), findsOneWidget);
    expect(find.textContaining('Firebase'), findsNothing);
    expect(find.byKey(const ValueKey('enable-push')), findsNothing);
  });

  testWidgets('an Android refusal is sent to Android settings', (
    tester,
  ) async {
    // Not iOS's sentence, which is what every handset used to get. Both
    // platforms stop asking — Android after two refusals, iOS after
    // one — so the only useful copy names the screen, and it is a
    // different screen.
    await tester.pumpWidget(
      harness(PushStatus.denied, surface: Surface.android),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Android will not ask again'), findsOneWidget);
    expect(find.textContaining('iOS'), findsNothing);
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

  // What a device with no answering native half reports — `unsupported`,
  // never a button that would register a device no sender can reach —
  // lives in `push_native_test.dart`, along with every other state the
  // two handset platforms can be in. It was here, as a `testWidgets`
  // case, and it HUNG when Android stopped being answered in Dart and
  // started crossing the method channel: a channel round trip inside
  // `testWidgets` runs under fake async and never completes without
  // pumping, so the test did not fail, it stopped. The states belong
  // beside each other in any case; this file is about the card.

  test('and says which of the four reasons it is', () {
    // One status, four quite different facts, and the person reading can
    // only act on one of them: swap the browser, or nothing at all.
    //
    // Android is NOT Firebase here any more, and that is the assertion
    // worth having: this sentence is the one shown to a handset that
    // can never be reached, and sending its owner off to create a
    // Firebase project would waste their afternoon.
    expect(pushUnsupportedNote(Surface.web), contains('Chrome'));
    expect(
      pushUnsupportedNote(Surface.android),
      contains('Google Play Services'),
    );
    expect(pushUnsupportedNote(Surface.android), isNot(contains('Firebase')));
    expect(pushUnsupportedNote(Surface.desktop), isNot(contains('Firebase')));
    expect(pushUnsupportedNote(Surface.desktop), isNot(contains('Chrome')));
  });

  test('and which half of the configuration is missing', () {
    // Two deployments' worth of unfinished setup, and naming the wrong
    // one sends somebody to the wrong dashboard: the VAPID pair lives
    // in the edge function's secrets, the Firebase project does not.
    expect(pushNotConfiguredNote(Surface.android), contains('Firebase'));
    expect(pushNotConfiguredNote(Surface.android), isNot(contains('VAPID')));
    expect(pushNotConfiguredNote(Surface.web), contains('VAPID'));
    expect(pushNotConfiguredNote(Surface.ios), contains('VAPID'));
  });

  test('and where a refusal has to be undone, per platform', () {
    expect(pushDeniedNote(Surface.web), contains('site settings'));
    expect(pushDeniedNote(Surface.web), isNot(contains('iOS')));
    expect(pushDeniedNote(Surface.android), contains('Android'));
    expect(pushDeniedNote(Surface.android), isNot(contains('iOS')));
    expect(pushDeniedNote(Surface.ios), contains('iOS'));
    expect(pushDeniedNote(Surface.ios), isNot(contains('site settings')));
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
