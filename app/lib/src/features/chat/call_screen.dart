import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCVideoView, RTCVideoViewObjectFit;

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'call_engine.dart';

/// Being on a call.
///
/// Opened once somebody has already joined in the database — the row is
/// the state, and this screen is the media plus the buttons. It hangs up
/// in both places on the way out: the RPC, so the other end stops
/// showing "in a call", and the engine, so the microphone stops.
///
/// The engine is injected rather than constructed here so the screen can
/// be driven by a fake in a test. Nothing below needs a media stack to
/// lay out; everything below it needs one to work.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({
    super.key,
    required this.callId,
    this.isMine = false,
    required this.title,
    required this.video,
    this.engine,
  });

  final String callId;
  final String title;
  final bool video;

  /// Whether this person started the call.
  ///
  /// `chat_end_call` refuses anybody else — "Only whoever started the
  /// call may end it for everybody" — so the button is only offered to
  /// the one person the server will accept it from.
  final bool isMine;

  /// Left null in the app; supplied by tests.
  final CallEngine? engine;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  late final CallEngine _engine;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    final given = widget.engine;
    if (given != null) {
      _engine = given;
    } else {
      _engine = MediasoupCallEngine();
      unawaited(_start());
    }
    _engine.addListener(_onEngine);
  }

  Future<void> _start() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    try {
      final creds = await repo.chatCallCredentials(widget.callId);
      if (!mounted) return;
      await _engine.connect(
        CallCredentials.fromMap(creds),
        video: widget.video,
      );
    } catch (error) {
      if (!mounted) return;
      // A failure to get credentials is a failure to join, and the
      // person is looking at a screen that says "connecting". Say what
      // happened and leave.
      _showAndLeave(error.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _onEngine() {
    if (!mounted) return;
    setState(() {});
    // The socket dying is the call being over, and standing on a dead
    // call screen is worse than being dropped back to the thread.
    if (_engine.phase == CallPhase.closed && !_leaving) {
      unawaited(_leave());
    }
  }

  void _showAndLeave(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    unawaited(_leave());
  }

  /// Hangs up on everybody, rather than leaving them to it.
  ///
  /// `chat_end_call` was in `0140` from the day calls were built and
  /// had no caller: join, decline and leave all reached the screen and
  /// ending did not, so the person who started a meeting could only
  /// walk out of it. It marks every participant left and the call
  /// ended, which is why it is asked about first.
  Future<void> _endForEverybody() async {
    final go = await confirm(
      context,
      title: 'End the call for everybody?',
      message: 'Everybody still on it is hung up on. Leaving instead '
          'lets the rest carry on without you.',
      confirmLabel: 'End it',
      destructive: true,
    );
    if (!go || !mounted) return;
    await ref
        .read(repoProvider)
        ?.chatEndCall(widget.callId)
        .catchError((_) {});
    if (mounted) await _leave();
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    // The database first: it is what everybody else is watching, and it
    // is the one that still matters if closing the media hangs.
    await ref
        .read(repoProvider)
        ?.chatLeaveCall(widget.callId)
        .catchError((_) {});
    // Whoever built the engine, leaving the call is the end of it — the
    // microphone does not belong to the screen and must not outlive it.
    await _engine.close();
    if (!mounted) return;
    ref.invalidate(chatIncomingCallsProvider);
    // `pop`, not `maybePop`. `maybePop` asks the `PopScope` below, which
    // is set to refuse — that is how a hardware back button is turned
    // into a proper hang-up — so asking it here would refuse the very
    // hang-up that has already happened and strand somebody on a dead
    // call screen.
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngine);
    unawaited(_engine.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peers = _engine.peers;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(child: _stage(context, peers)),

              // Every remote microphone, mounted and invisible. On the
              // web a track only plays once its element is in the
              // document, so an audio renderer that is never built is
              // simply silence — the bug reads as "the call connected
              // and nobody can hear anything".
              for (final peer in peers)
                if (peer.mic != null)
                  SizedBox(width: 1, height: 1, child: RTCVideoView(peer.mic!)),

              Align(
                alignment: Alignment.topCenter,
                child: _Banner(
                  title: widget.title,
                  phase: _engine.phase,
                  failure: _engine.failure,
                  others: peers.length,
                  sharing: _engine.sharingScreen
                      ? 'You are sharing your screen'
                      : _engine.screenSharer == null
                      ? null
                      : '${_engine.screenSharer!.displayName} is sharing',
                ),
              ),

              if (_engine.localVideo != null)
                Positioned(
                  right: Space.lg,
                  bottom: 108,
                  width: 108,
                  height: 144,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RTCVideoView(
                      _engine.localVideo!,
                      mirror: true,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),

              Align(
                alignment: Alignment.bottomCenter,
                child: _Controls(
                  micOn: _engine.micOn,
                  cameraOn: _engine.cameraOn,
                  sharingScreen: _engine.sharingScreen,
                  onMic: () => _engine.setMic(!_engine.micOn),
                  onCamera: () => _engine.setCamera(!_engine.cameraOn),
                  onFlip: _engine.cameraOn ? _engine.switchCamera : null,
                  onShare: _engine.canShareScreen
                      ? () => _engine.setScreenShare(!_engine.sharingScreen)
                      : null,
                  onHangUp: _leave,
                  onEndForEverybody: widget.isMine ? _endForEverybody : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stage(BuildContext context, List<CallPeer> peers) {
    // A shared screen wins the stage. When somebody puts a trial balance
    // up, nobody is looking at faces, and a grid that gives the
    // spreadsheet a quarter of the window makes it unreadable — which is
    // the entire point of having shared it.
    final sharer = _engine.screenSharer;
    if (sharer != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.sm,
          72,
          Space.sm,
          Space.xl * 3,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: RTCVideoView(
            sharer.screen!,
            // `contain`, not `cover`. Cropping a camera loses some
            // background; cropping a spreadsheet loses the figures down
            // the right-hand side, and nobody notices they are missing.
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
        ),
      );
    }

    final withVideo = peers.where((p) => p.hasVideo).toList();

    if (withVideo.isEmpty) {
      // A voice call, or a video call before anybody's camera has
      // arrived. Names, because a black rectangle tells nobody whether
      // they are connected.
      return Center(
        child: Wrap(
          spacing: Space.lg,
          runSpacing: Space.lg,
          alignment: WrapAlignment.center,
          children: [
            for (final peer in peers)
              _Face(name: peer.displayName, muted: peer.micMuted),
            if (peers.isEmpty)
              const _Face(name: 'Waiting for somebody to answer'),
          ],
        ),
      );
    }

    // One column for one other person, two beyond that. Anything
    // cleverer needs to know how big the tiles want to be, which needs a
    // call to look at.
    final columns = withVideo.length == 1 ? 1 : 2;
    return GridView.count(
      padding: const EdgeInsets.fromLTRB(Space.sm, 72, Space.sm, Space.xl * 3),
      crossAxisCount: columns,
      mainAxisSpacing: Space.sm,
      crossAxisSpacing: Space.sm,
      childAspectRatio: 3 / 4,
      children: [
        for (final peer in withVideo)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RTCVideoView(
                  peer.camera!,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (peer.micMuted) ...[
                          const Icon(
                            Icons.mic_off,
                            size: 14,
                            color: Colors.white,
                            shadows: [Shadow(blurRadius: 4)],
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          peer.displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [Shadow(blurRadius: 4)],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.title,
    required this.phase,
    required this.failure,
    required this.others,
    this.sharing,
  });

  final String title;
  final CallPhase phase;
  final String? failure;
  final int others;

  /// Who is sharing a screen, in words. Shown above everything else,
  /// because "am I still sharing?" is the question people actually have
  /// and the answer is otherwise only visible to everybody except them.
  final String? sharing;

  @override
  Widget build(BuildContext context) {
    final line = switch (phase) {
      CallPhase.connecting => 'Connecting…',
      CallPhase.connected =>
        others == 0 ? 'Waiting for somebody to answer' : '$others on the call',
      CallPhase.failed => failure ?? 'The call failed',
      CallPhase.closed => 'Call ended',
    };

    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        children: [
          if (sharing != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: context.colors.info,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.screen_share_outlined,
                    size: 14,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    sharing!,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            line,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: phase == CallPhase.failed
                  ? context.colors.danger
                  : Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({required this.name, this.muted = false});

  final String name;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: Colors.white24,
          child: Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: const TextStyle(color: Colors.white, fontSize: 24),
          ),
        ),
        const SizedBox(height: Space.sm),
        SizedBox(
          width: 140,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (muted) ...[
                const Icon(Icons.mic_off, size: 12, color: Colors.white70),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  name,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.micOn,
    required this.cameraOn,
    required this.sharingScreen,
    required this.onMic,
    required this.onCamera,
    required this.onFlip,
    required this.onShare,
    required this.onHangUp,
    this.onEndForEverybody,
  });

  final bool micOn;
  final bool cameraOn;
  final bool sharingScreen;
  final VoidCallback onMic;
  final VoidCallback onCamera;
  final VoidCallback? onFlip;

  /// Null where the device cannot capture a screen at all — Android and
  /// iOS, for now, for the reasons in `call_engine.dart`. Absent rather
  /// than greyed out: a disabled button invites people to work out what
  /// would enable it, and nothing they can do will.
  final VoidCallback? onShare;
  final VoidCallback onHangUp;

  /// Null for everybody but whoever started the call, because
  /// `chat_end_call` refuses everybody but them. Absent rather than
  /// greyed out, for the same reason as screen sharing above: a
  /// disabled button invites people to work out what would enable it,
  /// and nothing they can do will.
  final VoidCallback? onEndForEverybody;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.xl),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _Round(
            key: const ValueKey('call-mic'),
            icon: micOn ? Icons.mic : Icons.mic_off,
            tooltip: micOn ? 'Mute' : 'Unmute',
            active: micOn,
            onPressed: onMic,
          ),
          const SizedBox(width: Space.lg),
          _Round(
            key: const ValueKey('call-camera'),
            icon: cameraOn ? Icons.videocam : Icons.videocam_off,
            tooltip: cameraOn ? 'Turn the camera off' : 'Turn the camera on',
            active: cameraOn,
            onPressed: onCamera,
          ),
          if (onFlip != null) ...[
            const SizedBox(width: Space.lg),
            _Round(
              key: const ValueKey('call-flip'),
              icon: Icons.flip_camera_ios_outlined,
              tooltip: 'Switch camera',
              active: true,
              onPressed: onFlip!,
            ),
          ],
          if (onShare != null) ...[
            const SizedBox(width: Space.lg),
            _Round(
              key: const ValueKey('call-share'),
              icon: sharingScreen
                  ? Icons.stop_screen_share_outlined
                  : Icons.screen_share_outlined,
              tooltip: sharingScreen ? 'Stop sharing' : 'Share your screen',
              active: sharingScreen,
              onPressed: onShare!,
            ),
          ],
          const SizedBox(width: Space.lg),
          _Round(
            key: const ValueKey('call-hang-up'),
            icon: Icons.call_end,
            tooltip: 'Hang up',
            active: true,
            danger: true,
            onPressed: onHangUp,
          ),
          if (onEndForEverybody != null) ...[
            const SizedBox(width: Space.lg),
            _Round(
              key: const ValueKey('call-end-all'),
              icon: Icons.cancel_outlined,
              tooltip: 'End the call for everybody',
              active: true,
              danger: true,
              onPressed: onEndForEverybody!,
            ),
          ],
        ],
      ),
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final bool danger;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final background = danger
        ? context.colors.danger
        : (active ? Colors.white24 : Colors.white70);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Icon(
              icon,
              color: danger || active ? Colors.white : Colors.black87,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}
