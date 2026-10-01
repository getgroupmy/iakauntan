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

/// The call row, held somewhere a test can change it.
///
/// `chatActiveCallProvider` reads `chat_active_call`, which is the one
/// thing that knows a call is over: ending a call writes the database
/// and tells the media server nothing at all.
final _theCallRow = StateProvider<Map<String, dynamic>?>((ref) => null);

void main() {
  Widget harness(FakeCallEngine engine, {bool isMine = false}) =>
      ProviderScope(
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
                    isMine: isMine,
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

  Future<void> open(
    WidgetTester tester,
    FakeCallEngine engine, {
    bool isMine = false,
  }) async {
    await tester.pumpWidget(harness(engine, isMine: isMine));
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

  testWidgets('only whoever started the call may end it for everybody', (
    tester,
  ) async {
    // `chat_end_call` refuses everybody else -- "Only whoever started
    // the call may end it for everybody" -- so the button is only
    // offered to the one person the server will take it from. Absent
    // rather than greyed out, like the share button below.
    await open(tester, FakeCallEngine());
    expect(find.byKey(const ValueKey('call-end-all')), findsNothing);
    expect(
      find.byKey(const ValueKey('call-hang-up')),
      findsOneWidget,
      reason: 'leaving is always yours to do',
    );
  });

  testWidgets('and whoever did is offered it, beside leaving', (
    tester,
  ) async {
    await open(tester, FakeCallEngine(), isMine: true);
    expect(find.byKey(const ValueKey('call-end-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-hang-up')), findsOneWidget);
  });

  testWidgets('ending it for everybody asks first', (tester) async {
    // Hanging up on four colleagues is not the same act as leaving
    // them to it, and the two buttons sit next to each other.
    await open(tester, FakeCallEngine(), isMine: true);
    await tester.tap(find.byKey(const ValueKey('call-end-all')));
    await tester.pumpAndSettle();

    expect(find.text('End the call for everybody?'), findsOneWidget);
    expect(
      find.textContaining('lets the rest carry on without you'),
      findsOneWidget,
    );
  });

  testWidgets('and saying no leaves everybody on it', (tester) async {
    // Including the person who asked. Backing out of hanging up on
    // four colleagues must not hang up on them.
    await open(tester, FakeCallEngine(), isMine: true);
    await tester.tap(find.byKey(const ValueKey('call-end-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('call-hang-up')),
      findsOneWidget,
      reason: 'still on the call',
    );
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

  group('an incoming camera is turned only when it has to be', () {
    // A phone ships landscape sensor frames and sends the rotation
    // beside them in `urn:3gpp:video-orientation`. Where that extension
    // reached the consumer the pixels arrive upright and must be left
    // alone; where it did not they arrive raw and need a quarter turn.
    // `call_rtp.dart` is why it used not to reach anything.
    //
    // `quarterTurns`, read off the widget. `find.byType(RotatedBox)`
    // alone would pass with a turn of 2, 3 or 0 — three wrong answers
    // out of four — and 0 is the exact bug this is fixing.
    int turnsOn(WidgetTester tester, Finder video) => tester
        .widget<RotatedBox>(
          find.ancestor(of: video, matching: find.byType(RotatedBox)).first,
        )
        .quarterTurns;

    testWidgets('one quarter turn, not two and not none', (tester) async {
      final seen = CallPeer(id: 'a', displayName: 'Ahmad')
        ..camera = _StubRenderer();
      await open(tester, FakeCallEngine(peers: [seen]));

      expect(find.byType(RTCVideoView), findsOneWidget);
      expect(turnsOn(tester, find.byType(RTCVideoView)), 1);
    });

    testWidgets('each of them, on a call with two stripped cameras',
        (tester) async {
      // The rotation is on the tile, so a grid must not leave one of
      // them upright — which is what putting it on the stage rather
      // than inside the loop would do. Neither peer here carries its
      // own rotation, so both need the turn.
      await open(
        tester,
        FakeCallEngine(
          peers: [
            CallPeer(id: 'a', displayName: 'Ahmad')..camera = _StubRenderer(),
            CallPeer(id: 'b', displayName: 'Mei Ling')
              ..camera = _StubRenderer(),
          ],
        ),
      );

      expect(find.byType(RTCVideoView), findsNWidgets(2));
      expect(find.byType(RotatedBox), findsNWidgets(2));
    });

    testWidgets('NOT turned when the stream carries its own rotation',
        (tester) async {
      // The fix working. `cameraCarriesRotation` is read off the
      // consumer the server built, and when it is true the pixels have
      // already been turned natively — a RotatedBox here would put them
      // 90° out in the other direction, which is the failure the
      // stopgap would have caused for every desktop peer.
      final upright = CallPeer(id: 'a', displayName: 'Ahmad')
        ..camera = _StubRenderer()
        ..cameraCarriesRotation = true;
      await open(tester, FakeCallEngine(peers: [upright]));

      expect(find.byType(RTCVideoView), findsOneWidget);
      expect(turnsOn(tester, find.byType(RTCVideoView)), 0);
    });

    testWidgets('one of each on the same call, turned differently',
        (tester) async {
      // The reason this is per-peer and not a constant. A phone whose
      // rotation was stripped and a browser whose was not are in the
      // same grid, and one answer cannot be right for both.
      await open(
        tester,
        FakeCallEngine(
          peers: [
            CallPeer(id: 'a', displayName: 'Ahmad')..camera = _StubRenderer(),
            CallPeer(id: 'b', displayName: 'Mei Ling')
              ..camera = _StubRenderer()
              ..cameraCarriesRotation = true,
          ],
        ),
      );

      final turns = tester
          .widgetList<RotatedBox>(find.byType(RotatedBox))
          .map((b) => b.quarterTurns)
          .toList();
      expect(turns, hasLength(2));
      expect(turns.toSet(), {0, 1}, reason: 'one turned, one left alone');
    });

    testWidgets('and MY OWN picture is left alone, because it is upright',
        (tester) async {
      // The local preview never goes through RTP, so it was never
      // sideways. Turning it as well would fix the complaint and break
      // the thing nobody complained about.
      final engine = FakeCallEngine(
        peers: [CallPeer(id: 'a', displayName: 'Ahmad')],
      )..localVideo = _StubRenderer();
      await open(tester, engine);

      expect(find.byType(RTCVideoView), findsOneWidget,
          reason: 'the self-view, and no remote camera');
      expect(find.byType(RotatedBox), findsNothing);
    });

    testWidgets('and a shared screen is left alone too', (tester) async {
      // A shared desktop is not a phone camera and arrives the right
      // way up. A quarter turn here would make a trial balance
      // unreadable, which is the one thing sharing exists for.
      final sharer = CallPeer(id: 'a', displayName: 'Ahmad')
        ..screen = _StubRenderer();
      await open(tester, FakeCallEngine(peers: [sharer]));

      expect(find.byType(RTCVideoView), findsOneWidget);
      expect(find.byType(RotatedBox), findsNothing);
    });
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

  // -------------------------------------------------------------------
  // The call ending somewhere else
  // -------------------------------------------------------------------
  //
  // The screen used to close on exactly three things: the button, the
  // back gesture, and its own socket dying. None of those is what
  // happens when the person at the other end hangs up.
  //
  // `chat_end_call` marks every participant left and the call `ended`
  // IN THE DATABASE. It does not touch the media server, so this
  // device's websocket stays up, `CallPhase` stays `connected`, and the
  // only visible change is that the grid empties — which this screen
  // draws as "Waiting for somebody to answer". A call finished minutes
  // ago went on saying it was waiting.
  group('a call that ended somewhere else', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          repoProvider.overrideWithValue(null),
          chatActiveCallProvider.overrideWith(
            (ref, conversationId) => ref.watch(_theCallRow),
          ),
        ],
      );
      addTearDown(container.dispose);
    });

    Future<void> openWatched(
      WidgetTester tester,
      FakeCallEngine engine,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
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
                          conversationId: 'conv-1',
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
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    void rowSays(Map<String, dynamic>? row) =>
        container.read(_theCallRow.notifier).state = row;

    testWidgets('the row going away closes the screen', (tester) async {
      rowSays({'id': 'call-1', 'my_state': 'joined', 'joined': 2});
      final engine = FakeCallEngine();
      await openWatched(tester, engine);
      expect(find.text('Siti Nurhaliza'), findsOneWidget);

      // `chat_active_call` returns nothing once the status is `ended`.
      rowSays(null);
      await tester.pumpAndSettle();

      expect(find.text('Siti Nurhaliza'), findsNothing);
      expect(engine.closed, isTrue);
    });

    testWidgets('being marked left closes it, row or no row', (tester) async {
      rowSays({'id': 'call-1', 'my_state': 'joined', 'joined': 2});
      final engine = FakeCallEngine();
      await openWatched(tester, engine);

      // What `chat_end_call` writes for everybody it hangs up on.
      //
      // Three still joined, on purpose: with the count down at one this
      // would also be closed by the "everybody else has left" rule, and
      // the assertion would pass with the `my_state` rule deleted. It
      // did, until a mutant said so.
      rowSays({'id': 'call-1', 'my_state': 'left', 'joined': 3});
      await tester.pumpAndSettle();

      expect(find.text('Siti Nurhaliza'), findsNothing);
      expect(engine.closed, isTrue);
    });

    testWidgets('the other person simply leaving closes it too', (
      tester,
    ) async {
      // Only whoever STARTED a call may end it for everybody, so in a
      // two-person call the other one can only leave — which writes
      // their own row and nothing else, and used to leave this screen
      // alone with an empty grid for ever.
      rowSays({'id': 'call-1', 'my_state': 'joined', 'joined': 2});
      final engine = FakeCallEngine();
      await openWatched(tester, engine);

      rowSays({'id': 'call-1', 'my_state': 'joined', 'joined': 1});
      await tester.pumpAndSettle();

      expect(find.text('Siti Nurhaliza'), findsNothing);
      expect(engine.closed, isTrue);
    });

    testWidgets('but waiting for somebody to answer is not the call ending', (
      tester,
    ) async {
      // The caller is alone in the room until somebody picks up. A
      // screen that closed on "nobody else here" would hang up on every
      // call before it was answered.
      rowSays({'id': 'call-1', 'my_state': 'joined', 'joined': 1});
      final engine = FakeCallEngine();
      await openWatched(tester, engine);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Siti Nurhaliza'), findsOneWidget);
      expect(engine.closed, isFalse);
    });

    testWidgets('and neither is a row that has not arrived yet', (
      tester,
    ) async {
      // Null before the join has landed is "not started", not "over".
      rowSays(null);
      final engine = FakeCallEngine();
      await openWatched(tester, engine);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Siti Nurhaliza'), findsOneWidget);
      expect(engine.closed, isFalse);
    });
  });
}

/// A renderer that has never been initialised and never will be.
///
/// `RTCVideoView` only reads `textureId`, `srcObject` and `renderVideo`
/// to decide what to lay out, and with no texture it draws nothing —
/// which is all a layout test needs. Initialising a real one would need
/// the platform channel that a widget test does not have.
class _StubRenderer extends RTCVideoRenderer {}
