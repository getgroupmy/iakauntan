import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCVideoRenderer, RTCVideoView, RTCVideoViewObjectFit;

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
  Widget harness(FakeCallEngine engine, {bool isMine = false}) => ProviderScope(
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

    expect(engine.micCalls, [
      false,
    ], reason: 'a button that looks muted without muting is the whole bug');
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

  testWidgets('and whoever did is offered it, beside leaving', (tester) async {
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

  group('an incoming camera is drawn exactly as it arrives', () {
    // A remote camera was 90 degrees out for a while, and a RotatedBox
    // around the view was the stopgap. The cause was the mediasoup
    // package's `RtpCapabilities.toMap()` dropping every RTP header
    // extension, so `urn:3gpp:video-orientation` never reached the
    // consumer and the receiver drew a phone's raw landscape sensor
    // frames; `call_rtp.dart` sends the capabilities whole and
    // `scripts/check_rtp_capabilities.py` keeps that call site honest.
    //
    // These assertions are the other half of removing the stopgap.
    // Putting a turn back here would be the easy mistake — it was in
    // this file for two commits — and with the rotation arriving
    // natively it would draw an upright picture 90 degrees out the
    // OTHER way. So the absence is asserted rather than assumed.
    testWidgets('with nothing in the tree turning it', (tester) async {
      final seen = CallPeer(id: 'a', displayName: 'Ahmad')
        ..camera = _StubRenderer();
      await open(tester, FakeCallEngine(peers: [seen]));

      expect(find.byType(RTCVideoView), findsOneWidget);
      expect(find.byType(RotatedBox), findsNothing);
      // `Transform` is deliberately NOT asserted here. Material builds
      // four of them in this tree on its own -- the floating button and
      // the ink effects -- so `findsNothing` fails on widgets this file
      // has no opinion about, and `findsNWidgets(4)` would pin a number
      // belonging to somebody else's implementation. `RotatedBox` is
      // the one this screen would reach for and the one Material does
      // not use, which is what makes its absence worth asserting.
    });

    testWidgets('and neither of two cameras is turned', (tester) async {
      // Per-tile, because the stopgap lived inside the grid's loop: a
      // turn reintroduced there would come back twice and a check on
      // the stage alone would miss it.
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
      expect(find.byType(RotatedBox), findsNothing);
    });

    testWidgets('nor my own picture, which never was', (tester) async {
      // The local preview never goes through RTP, so it was never
      // sideways and was never turned. Asserted so that a future fix
      // aimed at the remote side cannot quietly catch it.
      final engine = FakeCallEngine(
        peers: [CallPeer(id: 'a', displayName: 'Ahmad')],
      )..localVideo = _StubRenderer();
      await open(tester, engine);

      expect(find.byType(RTCVideoView), findsOneWidget);
      expect(find.byType(RotatedBox), findsNothing);
    });

    testWidgets('nor a shared screen', (tester) async {
      final sharer = CallPeer(id: 'a', displayName: 'Ahmad')
        ..screen = _StubRenderer();
      await open(tester, FakeCallEngine(peers: [sharer]));

      expect(find.byType(RTCVideoView), findsOneWidget);
      expect(find.byType(RotatedBox), findsNothing);
    });
  });

  /// Turning the phone must not take the picture away.
  ///
  /// It did. The stage was a `GridView.count` with a fixed
  /// `childAspectRatio: 3 / 4`, which fits a portrait phone and cannot
  /// fit a landscape one: at 915x412 the single tile was laid out 1,199
  /// logical pixels tall in a 268-pixel viewport, so 78% of it sat below
  /// the fold of a scrolling list nobody scrolls during a call, and
  /// `cover` magnified the top strip of the far end's frame to fill what
  /// was left. The symptom was reported as "incoming video shows blank
  /// dark screen when the device is rotated", because the top strip of
  /// somebody's frame is usually their ceiling.
  ///
  /// Every assertion below is at a REAL device size. The default widget
  /// test surface is 800x600 — landscape, and wrong in the same
  /// direction as the bug — so the old code passed every test in this
  /// file while being unusable the moment a phone was turned.
  group('the stage fits the window, both ways up', () {
    /// Opens a call with [peerCount] cameras on a [size] screen.
    Future<FakeCallEngine> openAt(
      WidgetTester tester,
      Size size,
      int peerCount,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = FakeCallEngine(
        peers: [
          for (var i = 0; i < peerCount; i++)
            CallPeer(id: '$i', displayName: 'Peer $i')
              ..camera = _StubRenderer(),
        ],
      );
      await open(tester, engine);
      return engine;
    }

    /// Every tile, in the order the grid laid them out.
    List<Rect> tiles(WidgetTester tester) {
      final views = find.byType(RTCVideoView);
      return [
        for (var i = 0; i < tester.widgetList(views).length; i++)
          tester.getRect(views.at(i)),
      ];
    }

    /// Every tile is inside the STAGE, which is the window less the
    /// banner and the controls: `EdgeInsets.fromLTRB(8, 72, 8, 72)`.
    ///
    /// Against the window rather than the stage this check was too kind
    /// to catch anything: the stage clips, so a tile eight pixels past
    /// the bottom of the grid is invisible while still being four
    /// hundred pixels inside the screen. Two arithmetic mutants —
    /// forgetting the gap between rows, and forgetting it between
    /// columns — survived exactly that gap in this helper.
    void allInsideTheStage(List<Rect> rects, Size screen) {
      expect(rects, isNotEmpty);
      const edge = Space.sm;
      const top = 72.0;
      const bottom = Space.xl * 3;
      for (final r in rects) {
        expect(
          r.top,
          greaterThanOrEqualTo(top - 0.5),
          reason: 'a tile starts above the stage',
        );
        expect(
          r.left,
          greaterThanOrEqualTo(edge - 0.5),
          reason: 'a tile starts left of the stage',
        );
        // The one that failed before: a tile whose bottom is past the
        // bottom of the stage is a tile somebody cannot see.
        expect(
          r.bottom,
          lessThanOrEqualTo(screen.height - bottom + 0.5),
          reason: 'a tile runs off the bottom of the stage',
        );
        expect(
          r.right,
          lessThanOrEqualTo(screen.width - edge + 0.5),
          reason: 'a tile runs off the side of the stage',
        );
        expect(r.height, greaterThan(0));
        expect(r.width, greaterThan(0));
      }
      // And they FILL it rather than merely fitting inside it. A tile
      // can be well within the stage and still be a postage stamp, and
      // one mutant — dropping the gap between columns from the width the
      // aspect ratio is computed from — is visible only here, as a few
      // pixels of stage nothing is drawn on.
      final lowest = rects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      final furthest = rects
          .map((r) => r.right)
          .reduce((a, b) => a > b ? a : b);
      expect(
        lowest,
        closeTo(screen.height - bottom, 1),
        reason: 'the tiles stop short of the bottom of the stage',
      );
      expect(
        furthest,
        closeTo(screen.width - edge, 1),
        reason: 'the tiles stop short of the side of the stage',
      );
    }

    testWidgets('one other person, phone held sideways', (tester) async {
      const screen = Size(915, 412);
      await openAt(tester, screen, 1);

      final rects = tiles(tester);
      expect(rects, hasLength(1));
      allInsideTheStage(rects, screen);
      // And it uses the room it has: the stage is the window less the
      // banner at the top and the controls at the bottom. A tile that
      // merely FITS could also be a postage stamp, which would pass the
      // check above and still look broken.
      expect(rects.single.height, closeTo(screen.height - 144, 1));
    });

    testWidgets('one other person, phone held upright', (tester) async {
      const screen = Size(412, 915);
      await openAt(tester, screen, 1);

      final rects = tiles(tester);
      expect(rects, hasLength(1));
      allInsideTheStage(rects, screen);
      expect(rects.single.height, closeTo(screen.height - 144, 1));
    });

    testWidgets('two people sideways stand side by side', (tester) async {
      const screen = Size(915, 412);
      await openAt(tester, screen, 2);

      final rects = tiles(tester);
      expect(rects, hasLength(2));
      allInsideTheStage(rects, screen);
      // Same row, different columns.
      expect(rects[0].top, closeTo(rects[1].top, 0.5));
      expect(rects[0].right, lessThan(rects[1].left));
    });

    testWidgets('and upright they stack', (tester) async {
      const screen = Size(412, 915);
      await openAt(tester, screen, 2);

      final rects = tiles(tester);
      expect(rects, hasLength(2));
      allInsideTheStage(rects, screen);
      // Same column, different rows — two half-width slivers down a
      // portrait phone is the arrangement this replaced.
      expect(rects[0].left, closeTo(rects[1].left, 0.5));
      expect(rects[0].bottom, lessThan(rects[1].top));
    });

    testWidgets('four people fit on a sideways phone', (tester) async {
      const screen = Size(915, 412);
      await openAt(tester, screen, 4);

      allInsideTheStage(tiles(tester), screen);
    });

    testWidgets('and on an upright one', (tester) async {
      const screen = Size(412, 915);
      await openAt(tester, screen, 4);

      allInsideTheStage(tiles(tester), screen);
    });

    testWidgets('and three on a tablet', (tester) async {
      const screen = Size(1280, 800);
      await openAt(tester, screen, 3);

      allInsideTheStage(tiles(tester), screen);
    });

    testWidgets('three on an upright tablet, where a row is half empty', (
      tester,
    ) async {
      // 834x1112 is an iPad held upright, and three people there is the
      // one arrangement where the head count does not divide by the
      // column count: two columns, two rows, and the second row holding
      // one person. Rounding the row count DOWN instead of up — `3 ~/ 2`
      // rather than `(3 / 2).ceil()` — gives every tile the full height
      // of the stage and puts the third person entirely below it, and
      // every other size in this group divides exactly, so this is the
      // only case that can catch it.
      const screen = Size(834, 1112);
      await openAt(tester, screen, 3);

      final rects = tiles(tester);
      expect(rects, hasLength(3));
      allInsideTheStage(rects, screen);
      expect(rects[2].top, greaterThan(rects[0].bottom));
    });

    testWidgets('the stage does not scroll', (tester) async {
      // The tiles are sized to fit, so nothing CAN be scrolled out of
      // sight — but a scrollable stage is exactly how the picture went
      // missing, and a later change to the arithmetic would hide itself
      // below a fold again rather than failing a test. So the refusal to
      // scroll is asserted, not left to follow from the arithmetic.
      await openAt(tester, const Size(915, 412), 4);

      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.physics, isA<NeverScrollableScrollPhysics>());
    });

    testWidgets('a remote camera is never cropped to fit its tile', (
      tester,
    ) async {
      // `contain`. Nothing on this side knows which way up the far end
      // is holding their phone, so cover on a tile shaped by THIS
      // window throws away whichever edges disagree — on a sideways
      // phone with an upright camera at the other end, most of the
      // person.
      await openAt(tester, const Size(915, 412), 1);

      final view = tester.widget<RTCVideoView>(find.byType(RTCVideoView));
      expect(
        view.objectFit,
        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    });

    testWidgets('but my own thumbnail still is', (tester) async {
      // The 108x144 corner preview is the one place cropping is right:
      // it is a thumbnail of your own face and letterboxing it would
      // waste the little room it has. Asserted so a sweep over the
      // remote tiles cannot quietly take it too.
      final engine = FakeCallEngine(
        peers: [CallPeer(id: 'a', displayName: 'Ahmad')],
      )..localVideo = _StubRenderer();
      await open(tester, engine);

      final view = tester.widget<RTCVideoView>(find.byType(RTCVideoView));
      expect(view.objectFit, RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
    });
  });

  /// The column count, on its own, at sizes a widget test cannot easily
  /// reach — and including the one case that tells a symmetric measure
  /// of squareness from an asymmetric one.
  group('callStageColumns', () {
    test('one person is one column, whatever the window', () {
      expect(callStageColumns(1, const Size(915, 412)), 1);
      expect(callStageColumns(1, const Size(412, 915)), 1);
    });

    test('a wide window spreads people out, a tall one stacks them', () {
      expect(callStageColumns(2, const Size(915, 268)), 2);
      expect(callStageColumns(2, const Size(396, 771)), 1);
      expect(callStageColumns(4, const Size(899, 268)), 4);
      expect(callStageColumns(4, const Size(396, 771)), 2);
    });

    test('a nearly square window stacks two rather than splitting them', () {
      // 450x500. Stacked, each tile is 1.8 times as wide as it is tall;
      // side by side, each is 2.2 times as TALL as it is wide. Stacking
      // is the lesser distortion, and only a symmetric measure says so:
      // `(aspect - 1).abs()` scores 0.8 against 0.55 and splits them.
      expect(callStageColumns(2, const Size(450, 500)), 1);
    });

    test('a window of no size still answers', () {
      // LayoutBuilder is given finite constraints here, but a zero or
      // infinite box must not divide by nothing or loop forever.
      expect(callStageColumns(2, Size.zero), 1);
      expect(callStageColumns(3, const Size(double.infinity, 400)), 2);
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

    Future<void> openWatched(WidgetTester tester, FakeCallEngine engine) async {
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
