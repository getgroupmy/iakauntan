import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCVideoRenderer, RTCVideoView;

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/chat/call_engine.dart';
import 'package:iakauntan/src/features/chat/call_screen.dart';

/// What a call screen tells somebody, and what its buttons do.
///
/// The media itself cannot be tested here and is not pretended to be:
/// there is no microphone, no camera and no media server in a widget
/// test, which is exactly why `CallEngine` is an interface. What is
/// asserted is the half that is testable — that the screen says which
/// state the call is in, that mute reaches the engine, and that hanging
/// up both closes the engine and leaves the screen. A mute button that
/// looks muted while the microphone is still sending is the one bug
/// nobody forgives, so it gets an assertion.
class FakeCallEngine extends ChangeNotifier implements CallEngine {
  FakeCallEngine({
    this.phase = CallPhase.connected,
    this.failure,
    List<CallPeer>? peers,
  }) : peers = peers ?? const [];

  @override
  CallPhase phase;
  @override
  String? failure;
  @override
  List<CallPeer> peers;
  @override
  RTCVideoRenderer? localVideo;
  @override
  bool micOn = true;
  @override
  bool cameraOn = false;

  @override
  bool sharingScreen = false;
  @override
  bool canShareScreen = true;

  @override
  CallPeer? get screenSharer {
    for (final peer in peers) {
      if (peer.isSharing) return peer;
    }
    return null;
  }

  bool closed = false;
  final micCalls = <bool>[];
  final cameraCalls = <bool>[];
  final screenCalls = <bool>[];
  int flips = 0;

  @override
  Future<void> setScreenShare(bool on) async {
    screenCalls.add(on);
    sharingScreen = on;
    notifyListeners();
  }

  @override
  Future<void> connect(CallCredentials credentials, {required bool video}) =>
      Future.value();

  @override
  Future<void> setMic(bool on) async {
    micCalls.add(on);
    micOn = on;
    notifyListeners();
  }

  @override
  Future<void> setCamera(bool on) async {
    cameraCalls.add(on);
    cameraOn = on;
    notifyListeners();
  }

  @override
  Future<void> switchCamera() async => flips++;

  @override
  Future<void> close() async {
    closed = true;
    phase = CallPhase.closed;
    notifyListeners();
  }

  void moveTo(CallPhase next, {String? why}) {
    phase = next;
    failure = why;
    notifyListeners();
  }
}

void main() {
  Widget harness(FakeCallEngine engine) => ProviderScope(
    // No session, so no repository. Every RPC the screen would make is
    // skipped, which is what makes this a test of the screen rather
    // than of Supabase.
    overrides: [repoProvider.overrideWithValue(null)],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CallScreen(
                    callId: 'call-1',
                    title: 'Siti Nurhaliza',
                    video: false,
                    engine: engine,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, FakeCallEngine engine) async {
    await tester.pumpWidget(harness(engine));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a call that is still connecting says so', (tester) async {
    await open(tester, FakeCallEngine(phase: CallPhase.connecting));

    expect(find.text('Siti Nurhaliza'), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('a connected call with nobody in it says nobody is in it', (
    tester,
  ) async {
    await open(tester, FakeCallEngine());

    expect(find.textContaining('Waiting for somebody to answer'), findsWidgets);
  });

  testWidgets('everybody on the call is named even without video', (
    tester,
  ) async {
    await open(
      tester,
      FakeCallEngine(
        peers: [
          CallPeer(id: 'a', displayName: 'Ahmad'),
          CallPeer(id: 'b', displayName: 'Mei Ling'),
        ],
      ),
    );

    expect(find.text('Ahmad'), findsOneWidget);
    expect(find.text('Mei Ling'), findsOneWidget);
    expect(find.text('2 on the call'), findsOneWidget);
  });

  testWidgets('somebody else muting is visible, not just silent', (
    tester,
  ) async {
    final muted = CallPeer(id: 'a', displayName: 'Ahmad')..micMuted = true;
    await open(
      tester,
      FakeCallEngine(
        peers: [
          muted,
          CallPeer(id: 'b', displayName: 'Mei Ling'),
        ],
      ),
    );

    // The server sends `consumerPaused` when somebody mutes. The engine
    // used to drop it, which made muting indistinguishable from having
    // stopped talking.
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
    expect(find.text('Ahmad'), findsOneWidget);
    expect(find.text('Mei Ling'), findsOneWidget);
  });

  testWidgets('mute reaches the engine and changes the button', (tester) async {
    final engine = FakeCallEngine();
    await open(tester, engine);

    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-mic')));
    await tester.pumpAndSettle();

    expect(
      engine.micCalls,
      [false],
      reason: 'a button that looks muted without muting is the whole bug',
    );
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
  });

  testWidgets('the camera can be turned on during a voice call', (
    tester,
  ) async {
    final engine = FakeCallEngine();
    await open(tester, engine);

    await tester.tap(find.byKey(const ValueKey('call-camera')));
    await tester.pumpAndSettle();

    expect(engine.cameraCalls, [true]);
    // Flipping between front and back only appears once there is
    // something to flip.
    expect(find.byKey(const ValueKey('call-flip')), findsOneWidget);
  });

  testWidgets('sharing a screen reaches the engine and says so on screen', (
    tester,
  ) async {
    final engine = FakeCallEngine();
    await open(tester, engine);

    await tester.tap(find.byKey(const ValueKey('call-share')));
    await tester.pumpAndSettle();

    expect(engine.screenCalls, [true]);
    // "Am I still sharing?" is the question people actually have, and
    // the answer is otherwise visible to everybody except them.
    expect(find.text('You are sharing your screen'), findsOneWidget);
    expect(find.byIcon(Icons.stop_screen_share_outlined), findsOneWidget);
  });

  testWidgets('a device that cannot share is not offered the button', (
    tester,
  ) async {
    // Android and iOS, for now. Absent rather than greyed out: a
    // disabled button invites somebody to work out what would enable
    // it, and nothing they can do will.
    await open(tester, FakeCallEngine()..canShareScreen = false);

    expect(find.byKey(const ValueKey('call-share')), findsNothing);
    expect(
      find.byKey(const ValueKey('call-hang-up')),
      findsOneWidget,
      reason: 'the other controls are still there',
    );
  });

  testWidgets('somebody else sharing takes the stage, and is named', (
    tester,
  ) async {
    final sharer = CallPeer(id: 'a', displayName: 'Ahmad')
      ..screen = _StubRenderer();
    await open(
      tester,
      FakeCallEngine(
        peers: [
          sharer,
          CallPeer(id: 'b', displayName: 'Mei Ling'),
        ],
      ),
    );

    expect(find.text('Ahmad is sharing'), findsOneWidget);
    // The screen gets the whole stage rather than a quarter of a grid —
    // a trial balance in a corner is a trial balance nobody can read.
    expect(find.byType(RTCVideoView), findsOneWidget);
    expect(
      find.text('Mei Ling'),
      findsNothing,
      reason: 'faces do not compete with the thing everybody is reading',
    );
  });

  testWidgets('hanging up closes the engine and leaves the screen', (
    tester,
  ) async {
    final engine = FakeCallEngine();
    await open(tester, engine);

    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    await tester.pumpAndSettle();

    expect(engine.closed, isTrue);
    expect(find.byKey(const ValueKey('call-hang-up')), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a failure says what went wrong rather than a black screen', (
    tester,
  ) async {
    final engine = FakeCallEngine();
    await open(tester, engine);

    engine.moveTo(
      CallPhase.failed,
      why: 'This device would not give the app a microphone.',
    );
    await tester.pumpAndSettle();

    expect(
      find.text('This device would not give the app a microphone.'),
      findsOneWidget,
    );
  });

  testWidgets('the socket dying ends the call rather than freezing it', (
    tester,
  ) async {
    final engine = FakeCallEngine();
    await open(tester, engine);

    engine.moveTo(CallPhase.closed);
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
  });
}

/// A renderer that has never been initialised and never will be.
///
/// `RTCVideoView` only reads `textureId`, `srcObject` and `renderVideo`
/// to decide what to lay out, and with no texture it draws nothing —
/// which is all a layout test needs. Initialising a real one would need
/// the platform channel that a widget test does not have.
class _StubRenderer extends RTCVideoRenderer {}
