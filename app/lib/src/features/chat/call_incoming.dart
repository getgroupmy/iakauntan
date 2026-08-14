import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// What it does not do is ring while the app is closed. That needs a
/// push notification and a platform channel per operating system, and
/// neither exists yet; until then a call reaches somebody who has the
/// app open.
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

  @override
  Widget build(BuildContext context) {
    ref.listen(chatIncomingCallsProvider, (_, next) {
      final calls = next.value;
      if (calls == null || calls.isEmpty) return;
      final call = calls.first;
      final id = call['id'] as String;
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
    await _open(context, ref, callId!, video: video);
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    String callId, {
    required bool video,
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
        builder: (_) =>
            CallScreen(callId: callId, title: title ?? 'Call', video: video),
      ),
    );
    ref.invalidate(chatActiveCallProvider(conversationId));
  }
}
