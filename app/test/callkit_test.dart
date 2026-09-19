import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/callkit.dart';

/// The system's own call screen, without a system.
///
/// What cannot run here is Swift. What can — and what this covers — is
/// every decision above the channel, and those are the ones whose
/// mistakes are silent:
///
///   * an event this build has never heard of must not take the answer
///     beside it down with it;
///   * a drain must clear, because an answer delivered twice joins a
///     call somebody has already left;
///   * order must survive, because "rang, then was declined" and
///     "declined, then rang" are different calls.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late List<Object?> queued;

  /// Stand in for `AppDelegate.swift`: a queue that drains once.
  void nativeSide({bool missing = false, bool throws = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(callChannel, (call) async {
          calls.add(call);
          if (missing) throw MissingPluginException(call.method);
          if (throws) throw PlatformException(code: 'nope');
          if (call.method == 'drain') {
            final taken = queued;
            queued = const [];
            return taken;
          }
          return null;
        });
  }

  setUp(() {
    calls = [];
    queued = const [];
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(callChannel, null);
  });

  group('reading what the system did', () {
    test('each of the three kinds', () {
      expect(
        parseCallKitEvent({'event': 'ringing', 'call_id': 'c1'})?.kind,
        CallKitEventKind.ringing,
      );
      expect(
        parseCallKitEvent({'event': 'answered', 'call_id': 'c1'})?.kind,
        CallKitEventKind.answered,
      );
      expect(
        parseCallKitEvent({'event': 'ended', 'call_id': 'c1'})?.kind,
        CallKitEventKind.ended,
      );
    });

    test('and what it says about the call', () {
      final event = parseCallKitEvent({
        'event': 'ringing',
        'call_id': 'c1',
        'video': true,
        'caller': 'Siti',
      })!;
      expect(event.callId, 'c1');
      expect(event.video, isTrue);
      expect(event.caller, 'Siti');
    });

    test('a call with no id is not an event', () {
      // There is nothing to answer, join or decline. The native side
      // reports such a push to CallKit and ends it immediately rather
      // than being killed; this is the other half of that.
      expect(parseCallKitEvent({'event': 'answered'}), isNull);
      expect(parseCallKitEvent({'event': 'answered', 'call_id': ''}), isNull);
      expect(parseCallKitEvent({'event': 'answered', 'call_id': 7}), isNull);
    });

    test('nor is a kind this build has never heard of', () {
      expect(parseCallKitEvent({'event': 'held', 'call_id': 'c1'}), isNull);
      expect(parseCallKitEvent({'call_id': 'c1'}), isNull);
      expect(parseCallKitEvent('answered'), isNull);
      expect(parseCallKitEvent(null), isNull);
    });

    test('and an unreadable one does not take the answer beside it', () {
      // The assertion this file exists for. A newer native side sending
      // one kind this build does not know must not cost the answer
      // somebody is waiting on — which is what throwing would do.
      final events = parseCallKitEvents([
        {'event': 'held', 'call_id': 'c1'},
        {'event': 'answered', 'call_id': 'c2'},
        'nonsense',
        {'event': 'ended', 'call_id': 'c3'},
      ]);
      expect(events.map((e) => e.callId), ['c2', 'c3']);
      expect(
        events.map((e) => e.kind),
        [CallKitEventKind.answered, CallKitEventKind.ended],
      );
    });

    test('order survives, because two events about one call are a story', () {
      // "Rang, then was declined" leaves nothing to open. Reversed it
      // would open a call screen for a call nobody is on.
      final events = parseCallKitEvents([
        {'event': 'ringing', 'call_id': 'c1'},
        {'event': 'ended', 'call_id': 'c1'},
      ]);
      expect(events.first.kind, CallKitEventKind.ringing);
      expect(events.last.kind, CallKitEventKind.ended);
    });

    test('and a list that is not a list is simply nothing', () {
      expect(parseCallKitEvents(null), isEmpty);
      expect(parseCallKitEvents('answered'), isEmpty);
      expect(parseCallKitEvents(const []), isEmpty);
    });
  });

  group('draining', () {
    test('takes what is queued', () async {
      queued = [
        {'event': 'answered', 'call_id': 'c1', 'video': true},
      ];
      nativeSide();

      final events = await drainCallKitEvents();
      expect(events.single.callId, 'c1');
      expect(events.single.video, isTrue);
      expect(calls.single.method, 'drain');
    });

    test('and a second drain gets nothing', () async {
      // The queue is the delivery mechanism, so it has to clear. An
      // answer delivered twice joins a call somebody has already left.
      queued = [
        {'event': 'answered', 'call_id': 'c1'},
      ];
      nativeSide();

      expect(await drainCallKitEvents(), hasLength(1));
      expect(await drainCallKitEvents(), isEmpty);
    });

    test('a build whose Dart is ahead of its AppDelegate drains nothing',
        () async {
      nativeSide(missing: true);
      expect(await drainCallKitEvents(), isEmpty);
    });

    test('and a native side that threw is not an error anybody sees',
        () async {
      nativeSide(throws: true);
      expect(await drainCallKitEvents(), isEmpty);
      await reportCallKitEnded('c1');
    });
  });

  group('telling the system the app is done', () {
    test('names the call, because CallKit does not find out by itself',
        () async {
      // A call CallKit still believes is running is a green bar across
      // the top of the phone that nothing the person does will clear.
      nativeSide();
      await reportCallKitEnded('c1');
      expect(calls.single.method, 'end');
      expect(calls.single.arguments, {'call_id': 'c1'});
    });
  });

  group('being woken', () {
    test('the nudge carries nothing and the drain carries everything',
        () async {
      // One delivery path on purpose: an event cannot then arrive
      // twice, and a second path that could silently drop messages is
      // worse than no second path.
      queued = [
        {'event': 'answered', 'call_id': 'c1'},
      ];
      nativeSide();

      final seen = <CallKitEvent>[];
      listenForCallKit(seen.addAll);
      addTearDown(stopListeningForCallKit);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            callChannel.name,
            callChannel.codec.encodeMethodCall(
              const MethodCall('wake', null),
            ),
            (_) {},
          );

      expect(seen.single.callId, 'c1');
      expect(seen.single.kind, CallKitEventKind.answered);
    });
  });

  group('on a platform with no CallKit', () {
    test('nothing is asked of the native side at all', () async {
      // Android's full-screen incoming call is a notification with a
      // full-screen intent, which needs Firebase first — and a desktop
      // has no such thing at all.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      nativeSide();

      expect(callKitAvailable, isFalse);
      expect(await drainCallKitEvents(), isEmpty);
      await reportCallKitEnded('c1');
      listenForCallKit((_) => fail('nothing should arrive'));
      expect(calls, isEmpty);
    });
  });
}
