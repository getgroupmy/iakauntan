import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/callkit.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'call_screen.dart';

/// A phone ringing.
///
/// Mounted by the app shell, not by the chat screen: the reason to ring
/// somebody is that they are doing something else, so a call has to
/// reach a person looking at the ledger. In a group it keeps ringing
/// after somebody else has answered, which is why
/// `chat_incoming_calls` keys on this participant's state rather than on
/// the call's.
///
/// On iOS it is no longer the only way a call arrives. A VoIP push
/// wakes the app and `AppDelegate.swift` reports the call to CallKit,
/// which draws the system's own full-screen ring — over the lock
/// screen, before any of this has run. What comes back is an answer or
/// a decline that has already happened, and this widget takes it from
/// `callkit.dart` and finishes the job: join, open the call, and tell
/// the system when the app is done with it.
///
/// So the sheet below is for every other platform, and for the one iOS
/// case where CallKit drew nothing — a ring the system refused, under
/// Do Not Disturb or from a blocked caller, which reports no `ringing`
/// event. On an iPhone where CallKit DID ring, the sheet stays down:
/// otherwise the person would get the system's call screen and, behind
/// it, this app asking the same question again.
///
/// Android still has neither. A full-screen incoming call there is a
/// notification with a full-screen intent, which needs Firebase first.
class IncomingCallWatcher extends ConsumerStatefulWidget {
  const IncomingCallWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingCallWatcher> createState() =>
      _IncomingCallWatcherState();
}

class _IncomingCallWatcherState extends ConsumerState<IncomingCallWatcher> {
  /// Calls already put in front of somebody, so a rebuild does not open
  /// a second sheet for the same ringing phone.
  final _shown = <String>{};

  /// Calls the system's own screen has already settled.
  ///
  /// Separate from [_shown] because they mean different things: that
  /// one says a sheet has been drawn, this one says drawing a sheet
  /// would be WRONG. Somebody who answered on the CallKit screen has
  /// said yes, and putting the app's own "answer or decline?" in front
  /// of them afterwards would ask twice and let them say no to a call
  /// they are already on.
  final _settledByTheSystem = <String>{};

  /// What the push said about each call the system rang.
  ///
  /// Kept because the answer does not repeat it: `ringing` carries who
  /// is calling and whether it is video, `answered` carries only the
  /// id, and on a cold start both arrive in the same drain. The
  /// alternative was reading `chatIncomingCallsProvider`, and `.value`
  /// on a provider THROWS when it is in an error state — here that
  /// would be inside a platform-channel callback, where nothing
  /// catches it. See `scripts/check_async_value.py`.
  final _rang = <String, CallKitEvent>{};

  @override
  void initState() {
    super.initState();
    // Before anything else: an answer may have happened before this
    // application ran at all. See `callkit.dart`.
    listenForCallKit(_handleCallKit);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final events = await drainCallKitEvents();
      if (mounted) _handleCallKit(events);
    });
  }

  @override
  void dispose() {
    stopListeningForCallKit();
    super.dispose();
  }

  /// What the system's call screen did, in the order it did it.
  void _handleCallKit(List<CallKitEvent> events) {
    for (final event in events) {
      switch (event.kind) {
        case CallKitEventKind.ringing:
          // The sheet must not ALSO appear. CallKit draws a full-screen
          // ring whether or not this app is in front, so on an iPhone
          // with the app open the person would otherwise get the
          // system's call screen and, behind it, this app asking the
          // same question again.
          //
          // `_shown` and not `_settledByTheSystem`: nothing has been
          // decided yet, and if the answer never comes the call simply
          // stops ringing. And a ring the system REFUSED — Do Not
          // Disturb, a blocked caller — never emits this at all, so the
          // sheet is still the fallback in the one case where CallKit
          // drew nothing.
          _shown.add(event.callId);
          _rang[event.callId] = event;
        
        case CallKitEventKind.answered:
          _settledByTheSystem.add(event.callId);
          _shown.add(event.callId);
          unawaited(_answeredElsewhere(event.callId));
        case CallKitEventKind.ended:
          _settledByTheSystem.add(event.callId);
          _shown.add(event.callId);
          unawaited(_declineQuietly(event.callId));
      }
    }
  }

  /// Answered on the system's screen: join and open the call, with no
  /// sheet in between.
  Future<void> _answeredElsewhere(String callId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    try {
      await repo.chatJoinCall(callId);
    } catch (_) {
      // The call was over before the app got here — the commonest case
      // by far, because answering a call that has already stopped
      // ringing is something CallKit allows. Nothing to say: the
      // system's screen has already closed.
      await reportCallKitEnded(callId);
      return;
    }
    if (!mounted) return;
    ref.invalidate(chatIncomingCallsProvider);

    final rang = _rang[callId];
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CallScreen(
          callId: callId,
          // What the system's own screen said, so the app does not
          // rename the call halfway through answering it.
          title: rang?.caller ?? 'Call',
          video: rang?.video ?? false,
        ),
      ),
    );
    // The app is done with it, so the system has to be told or the
    // green bar stays across the top of the phone.
    await reportCallKitEnded(callId);
    _rang.remove(callId);
    if (mounted) ref.invalidate(chatIncomingCallsProvider);
  }

  /// Declined on the system's screen, or hung up there.
  Future<void> _declineQuietly(String callId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    // `decline` rather than `leave`: this is only ever reached for a
    // call this device had not joined, because a call it HAD joined is
    // ended by the call screen itself.
    await repo.chatDeclineCall(callId).catchError((_) {});
    if (mounted) ref.invalidate(chatIncomingCallsProvider);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatIncomingCallsProvider, (_, next) {
      final calls = next.value;
      if (calls == null || calls.isEmpty) return;
      final call = calls.first;
      final id = call['id'] as String;
      // The system got there first. Asking again would be asking twice.
      if (_settledByTheSystem.contains(id)) return;
      if (!_shown.add(id)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ring(call));
      });
    });

    return widget.child;
  }

  Future<void> _ring(Map<String, dynamic> call) async {
    final answered = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _IncomingSheet(call: call),
    );

    if (!mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final callId = call['id'] as String;

    if (answered != true) {
      await repo.chatDeclineCall(callId).catchError((_) {});
      ref.invalidate(chatIncomingCallsProvider);
      return;
    }

    // Joining is what mints the credentials: the edge function refuses
    // anybody whose participant row is not `joined`, so this has to
    // happen before the call screen asks for a token.
    final ok = await runWithFeedback(
      context,
      action: () => repo.chatJoinCall(callId),
      successMessage: null,
    );
    if (!mounted || !ok) return;
    ref.invalidate(chatIncomingCallsProvider);

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CallScreen(
          callId: callId,
          title: call['conversation_title']?.toString() ?? 'Call',
          video: call['kind'] == 'video',
        ),
      ),
    );
  }
}

class _IncomingSheet extends StatelessWidget {
  const _IncomingSheet({required this.call});

  final Map<String, dynamic> call;

  @override
  Widget build(BuildContext context) {
    final video = call['kind'] == 'video';
    final who = call['started_by_name']?.toString() ?? 'Somebody';
    final where = call['conversation_title']?.toString();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              video ? Icons.videocam_outlined : Icons.call_outlined,
              size: 40,
            ),
            const SizedBox(height: Space.md),
            Text(
              who,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            Text(
              where == null || where == who
                  ? (video ? 'Incoming video call' : 'Incoming call')
                  : '${video ? 'Video call' : 'Call'} · $where',
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('call-decline'),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.colors.danger,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.call_end),
                  label: const Text('Decline'),
                ),
                FilledButton.icon(
                  key: const ValueKey('call-answer'),
                  onPressed: () => Navigator.of(context).pop(true),
                  icon: const Icon(Icons.call),
                  label: const Text('Answer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The two buttons in the thread header, and what they do.
///
/// A call is started in the database first and joined immediately after,
/// because starting one does not put the caller in it — `chat_start_call`
/// leaves everybody, including the caller, in state `ringing`. Without
/// the join the caller would be refused their own credentials, which is
/// exactly the check working.
class CallButtons extends ConsumerWidget {
  const CallButtons({super.key, required this.conversationId, this.title});

  final String conversationId;
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(chatActiveCallProvider(conversationId)).value;

    if (active != null && active['my_state'] != 'joined') {
      return TextButton.icon(
        key: const ValueKey('chat-join-call'),
        onPressed: () => _open(
          context,
          ref,
          active['id'] as String,
          video: active['kind'] == 'video',
        ),
        icon: const Icon(Icons.call, size: 18),
        label: const Text('Join call'),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('chat-voice-call'),
          tooltip: 'Voice call',
          icon: const Icon(Icons.call_outlined, size: 20),
          onPressed: () => _start(context, ref, video: false),
        ),
        IconButton(
          key: const ValueKey('chat-video-call'),
          tooltip: 'Video call',
          icon: const Icon(Icons.videocam_outlined, size: 20),
          onPressed: () => _start(context, ref, video: true),
        ),
      ],
    );
  }

  Future<void> _start(
    BuildContext context,
    WidgetRef ref, {
    required bool video,
  }) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    String? callId;
    final ok = await runWithFeedback(
      context,
      action: () async {
        callId = await repo.chatStartCall(conversationId, video: video);
      },
      successMessage: null,
    );
    if (!ok || callId == null || !context.mounted) return;
    // Started here, so this is the one person `chat_end_call` will
    // take an ending from.
    await _open(context, ref, callId!, video: video, isMine: true);
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    String callId, {
    required bool video,
    bool isMine = false,
  }) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      action: () => repo.chatJoinCall(callId),
      successMessage: null,
    );
    if (!ok || !context.mounted) return;
    ref.invalidate(chatActiveCallProvider(conversationId));

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CallScreen(
          callId: callId,
          title: title ?? 'Call',
          video: video,
          isMine: isMine,
        ),
      ),
    );
    ref.invalidate(chatActiveCallProvider(conversationId));
  }
}
