import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/push.dart';

/// The iOS half of push, without an iPhone.
///
/// Everything below the channel is Swift and cannot run here. What CAN
/// run here is the whole of the decision-making — which tokens are
/// returned, under which transport, and what the settings card is told
/// — and that is where the mistakes with silent consequences live:
///
///   * a PushKit token returned as `apns` is a message delivered to a
///     VoIP token, which gets the app killed by iOS;
///   * a token returned without its `deviceId` is a handset the sender
///     cannot pair, so a ringing phone also gets a banner;
///   * an `on` status with no token is a settings screen telling
///     somebody they will be notified when nothing can reach them.
///
/// `debugDefaultTargetPlatformOverride` is what makes any of it
/// reachable. `push_native.dart` asks `currentSurface` rather than
/// `Platform.isIOS` for exactly this reason.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The last thing `register` was asked, so a test can assert that the
  /// app did not raise the permission prompt on its own.
  Map<Object?, Object?>? lastRegisterArguments;

  /// Stand in for `AppDelegate.swift`, answering the four methods it
  /// answers. [answer] is what the native side would hand back.
  void nativeSide(Map<String, Object?>? answer, {bool missing = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pushChannel, (call) async {
          if (missing) throw MissingPluginException(call.method);
          if (call.method == 'register') {
            lastRegisterArguments = call.arguments as Map<Object?, Object?>?;
          }
          if (call.method == 'unregister') return null;
          return answer;
        });
  }

  setUp(() {
    lastRegisterArguments = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pushChannel, null);
  });

  const alert = 'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4'
      'a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4';
  const voip = 'f0e1d2c3f0e1d2c3f0e1d2c3f0e1d2c3'
      'f0e1d2c3f0e1d2c3f0e1d2c3f0e1d2c3';
  const phone = 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F';

  group('the tokens that come back', () {
    test('both of them, each under its own transport', () async {
      nativeSide({
        'authorization': 'authorized',
        'alert': alert,
        'voip': voip,
        'deviceId': phone,
        'label': 'iPhone',
      });

      final devices = await subscribeToPush('', ask: true);
      expect(devices.map((d) => d.transport), ['apns', 'apns_voip']);
      expect(devices.map((d) => d.token), [alert, voip]);
      // The pairing. Without it the sender cannot tell one iPhone
      // holding two tokens from two iPhones holding one each.
      expect(devices.map((d) => d.deviceId), [phone, phone]);
      expect(devices.every((d) => d.platform == 'ios'), isTrue);
      // A device token is not a browser subscription and 0143 refuses
      // one carrying encryption keys.
      expect(devices.every((d) => d.p256dh == null && d.auth == null), isTrue);
    });

    test('the alert token alone, when PushKit has not answered yet',
        () async {
      // The state this build is actually in: `AppDelegate.swift`
      // registers for alerts and deliberately not for PushKit, so
      // `voip` is an absent key rather than a null one.
      nativeSide({
        'authorization': 'authorized',
        'alert': alert,
        'deviceId': phone,
        'label': 'iPhone',
      });

      final devices = await subscribeToPush('', ask: false);
      expect(devices.single.transport, 'apns');
      expect(devices.single.token, alert);
    });

    test('and nothing at all when permission was refused', () async {
      // PushKit needs no permission, so iOS would let this app register
      // a VoIP token for somebody who said no and ring their phone.
      // Registering nothing is the point of this assertion.
      nativeSide({
        'authorization': 'denied',
        'voip': voip,
        'deviceId': phone,
      });

      expect(await subscribeToPush('', ask: true), isEmpty);
    });

    test('nor is a blank token registered as a real one', () async {
      nativeSide({
        'authorization': 'authorized',
        'alert': '',
        'voip': voip,
        'deviceId': phone,
      });

      final devices = await subscribeToPush('', ask: true);
      expect(devices.single.transport, 'apns_voip');
    });
  });

  group('what the settings card is told', () {
    test('authorized with a token is on', () {
      expect(
        statusFor('authorized', haveToken: true),
        PushStatus.on,
      );
    });

    test('authorized WITHOUT a token is not', () {
      // Permission outlives a registration Apple has since dropped, and
      // somebody looking at "on" with no token is looking at a lie.
      expect(
        statusFor('authorized', haveToken: false),
        PushStatus.askable,
      );
    });

    test('provisional is a yes, not a not-yet', () {
      // Quiet notifications are delivered. Treating this as "nobody has
      // been asked" would ask somebody who already answered, and iOS
      // only allows one asking.
      expect(statusFor('provisional', haveToken: true), PushStatus.on);
    });

    test('denied is its own answer, because nothing can ask again', () {
      expect(statusFor('denied', haveToken: false), PushStatus.denied);
      expect(statusFor('denied', haveToken: true), PushStatus.denied);
    });

    test('and anything else is askable', () {
      expect(statusFor('notDetermined', haveToken: false), PushStatus.askable);
      expect(statusFor(null, haveToken: false), PushStatus.askable);
    });

    test('pushStatus reads the channel rather than guessing', () async {
      nativeSide({'authorization': 'authorized', 'alert': alert});
      expect(await pushStatus(''), PushStatus.on);

      nativeSide({'authorization': 'authorized'});
      expect(await pushStatus(''), PushStatus.askable);
    });
  });

  group('the app does not ask on its own', () {
    test('ask: false is passed through to the native side', () async {
      // iOS raises the permission prompt once, ever. Asking on start-up
      // would spend that one chance on somebody who had not yet decided
      // they wanted it, and nothing could ask again.
      nativeSide({'authorization': 'notDetermined'});
      await subscribeToPush('', ask: false);
      expect(lastRegisterArguments?['ask'], isFalse);

      await subscribeToPush('', ask: true);
      expect(lastRegisterArguments?['ask'], isTrue);
    });
  });

  group('when the native side is not there', () {
    test('a build whose Dart is ahead of its AppDelegate is unsupported',
        () async {
      // A hot restart onto an older build, or an iOS target somebody
      // forgot to rebuild. Not an error to show anybody: it is this
      // device being unable to, which is what unsupported means.
      nativeSide(null, missing: true);
      expect(await pushStatus(''), PushStatus.unsupported);
      expect(await subscribeToPush('', ask: true), isEmpty);
      expect(await currentPushTokens(), isEmpty);
    });

    test('and neither is Android, which has no way through at all',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      nativeSide({'authorization': 'authorized', 'alert': alert});
      expect(await pushStatus(''), PushStatus.unsupported);
      expect(await subscribeToPush('', ask: true), isEmpty);
    });
  });

  group('taking a handset off the register', () {
    test('hands back every token it holds', () async {
      // Both, because leaving the PushKit one behind would leave the
      // phone ringing for calls after somebody switched notifications
      // off — which is the one outcome nobody would report as a bug.
      nativeSide({'alert': alert, 'voip': voip});
      expect(await currentPushTokens(), [alert, voip]);
    });

    test('and skips the ones it does not', () async {
      nativeSide({'alert': alert});
      expect(await currentPushTokens(), [alert]);

      nativeSide({'alert': '', 'voip': voip});
      expect(await currentPushTokens(), [voip]);
    });
  });
}
