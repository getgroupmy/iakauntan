import 'dart:async' show scheduleMicrotask;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('an iPhone that refused is sent to Settings, not to a '
      "site's, because it has none", (tester) async {
    // Reset INSIDE the test body, not in `tearDown`: the framework's own
    // invariant check runs right after the test body returns and before
    // any registered `tearDown` fires, so a debug override only undone
    // there still reads as "changed by the test" and fails every test
    // that runs after this one in the same file.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(harness(PushStatus.denied));
      await tester.pumpAndSettle();

      expect(find.textContaining('Settings'), findsOneWidget);
      expect(
        find.textContaining('site settings'),
        findsNothing,
        reason: 'an iPhone has no site to have settings for',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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

  testWidgets('a build that is neither web nor iOS reports unsupported rather '
      'than pretending', (tester) async {
    // This test runs on the Dart VM, which resolves `push.dart` to
    // `push_io.dart` (`dart.library.io` is true here too, just as it
    // is on a phone) -- and the host running it is neither iOS nor
    // Android, so `defaultTargetPlatform` is neither. If this ever
    // answered anything but unsupported, the settings card would
    // offer a button that registers a device no sender can reach.
    expect(await pushStatus('a-key'), PushStatus.unsupported);
    expect(await subscribeToPush('a-key', ask: true), isNull);
    expect(await currentPushEndpoint(), isNull);
  });

  group('push_io.dart, once the host pretends to be an iPhone', () {
    const channel = MethodChannel('my.iakauntan.iakauntan/push');
    // Sixty-four hex characters: the shape `register_device` (0657)
    // requires and the shape a real APNs token has.
    final fakeToken = List.filled(32, 'ab').join();

    void handle(Future<Object?>? Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    // Sets the override for the duration of `body` and resets it before
    // returning, INSIDE the test body — see the note on the iPhone-denied
    // test above for why `setUp`/`tearDown` cannot do this.
    //
    // Run through `tester.runAsync`, outside the fake clock `testWidgets`
    // otherwise runs on: `_registerForRemoteToken`'s 10-second real
    // `Future.timeout` never fires under that fake clock unless something
    // pumps it forward, which nothing here does, so a mutant that reaches
    // that path — remove the denied guard below, say — hangs the test
    // forever rather than failing it. Found by mutating this file, not by
    // writing it correctly the first time.
    Future<void> asIPhone(
      WidgetTester tester,
      Future<void> Function() body,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.runAsync(body);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('a phone never asked is askable, not unsupported', (
      tester,
    ) async {
      await asIPhone(tester, () async {
        handle((call) async => 'notDetermined');
        expect(await pushStatus('unused'), PushStatus.askable);
      });
    });

    testWidgets('a phone that refused answers denied and registers nothing '
        'even when asked', (tester) async {
      await asIPhone(tester, () async {
        final calls = <String>[];
        handle((call) async {
          calls.add(call.method);
          return 'denied';
        });
        expect(await pushStatus('unused'), PushStatus.denied);
        expect(await subscribeToPush('unused', ask: true), isNull);
        // Not just that the result is null -- a null the timeout below
        // hands back looks the same as a null the denied guard hands
        // back immediately. A phone that has refused must not be asked
        // to register at all, ten-second wait or no.
        expect(
          calls,
          isNot(contains('registerForRemoteNotifications')),
          reason: 'a refusal must not still try to register the phone',
        );
      });
    });

    testWidgets('granting authorization registers, and the token comes back '
        'as an iOS/apns row rather than the web shape', (tester) async {
      await asIPhone(tester, () async {
        // Apple never hands the token back as a return value -- it
        // arrives later as its own call, which is exactly what
        // AppDelegate.swift does once `didRegisterForRemoteNotifications-
        // WithDeviceToken` fires. The mock plays that same part.
        handle((call) async {
          switch (call.method) {
            case 'authorizationStatus':
              return 'notDetermined';
            case 'requestAuthorization':
              return true;
            case 'registerForRemoteNotifications':
              scheduleMicrotask(() {
                TestDefaultBinaryMessengerBinding
                    .instance
                    .defaultBinaryMessenger
                    .handlePlatformMessage(
                      channel.name,
                      channel.codec.encodeMethodCall(
                        MethodCall('remoteToken', fakeToken),
                      ),
                      (_) {},
                    );
              });
              return null;
            default:
              return null;
          }
        });

        final subscription = await subscribeToPush('unused', ask: true);
        expect(subscription, isNotNull);
        expect(subscription!.endpoint, fakeToken);
        expect(subscription.platform, 'ios');
        expect(subscription.transport, 'apns');
        // Neither key a browser subscription carries -- 0657 refuses a
        // non-web row that has one, so this is not a detail to get
        // wrong by accident.
        expect(subscription.p256dh, isNull);
        expect(subscription.auth, isNull);
      });
    });
  });
}
