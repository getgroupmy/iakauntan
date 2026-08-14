import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/recorded_audio.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Sending a file, recording a voice note, and playing one back.
///
/// Kept out of `chat_screen.dart` because it is the only part of chat
/// that touches a microphone, a file dialog and an audio player — three
/// plugins with three permission models and four platforms between them.
/// The thread should be readable without any of that in the way.
///
/// **Not verified on a device.** Recording and playback were written
/// against the plugin APIs and compile; whether the microphone prompt
/// behaves on a real phone, and whether the recorded container plays
/// back on every browser, is not something this environment can
/// exercise. The upload, the row it writes and the permission model
/// underneath are asserted in `supabase/tests/chat.sql`; the audio path
/// itself needs a device before it can be called finished.
class ChatComposerActions extends ConsumerStatefulWidget {
  const ChatComposerActions({
    super.key,
    required this.conversationId,
    required this.senderOrgId,
    required this.onSent,
  });

  final String conversationId;
  final String senderOrgId;
  final VoidCallback onSent;

  @override
  ConsumerState<ChatComposerActions> createState() =>
      _ChatComposerActionsState();
}

class _ChatComposerActionsState extends ConsumerState<ChatComposerActions> {
  final _recorder = AudioRecorder();
  Timer? _tick;
  DateTime? _startedAt;
  bool _busy = false;

  /// Long enough for a sentence somebody could not be bothered to type,
  /// short enough that a phone left in a pocket does not fill the
  /// bucket. Stops on its own at the limit rather than refusing later.
  static const _maxRecording = Duration(minutes: 5);

  bool get _recording => _startedAt != null;

  @override
  void dispose() {
    _tick?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    // withData because the web has no path to read from afterwards, and
    // the upload wants bytes on every platform anyway.
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.singleOrNull;
    if (file == null || file.bytes == null || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .chatSendAttachment(
            conversationId: widget.conversationId,
            senderOrgId: widget.senderOrgId,
            fileName: file.name,
            bytes: file.bytes!,
            mimeType: _mimeFor(file.extension),
          ),
      successMessage: null,
      pendingMessage: 'Sending ${file.name}…',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onSent();
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The microphone is not available. Check the '
            'permission for this app, or for this site in the browser.',
          ),
        ),
      );
      return;
    }

    // AAC in an m4a container on mobile, opus in webm on the web, which
    // is what each platform can actually record and play without a
    // transcoding step nobody would notice until it failed.
    if (kIsWeb) {
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.opus, bitRate: 48000),
        path: '',
      );
    } else {
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: await _recordingPath(),
      );
    }

    setState(() => _startedAt = DateTime.now());
    _tick = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      if (DateTime.now().difference(_startedAt!) >= _maxRecording) {
        _stopRecording(send: true);
      } else {
        setState(() {});
      }
    });
  }

  /// path_provider is already a dependency, for the OCR scanner. Not
  /// reached on the web, where `record` writes to a blob instead.
  Future<String> _recordingPath() async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
  }

  Future<void> _stopRecording({required bool send}) async {
    _tick?.cancel();
    _tick = null;
    final started = _startedAt;
    setState(() => _startedAt = null);
    if (started == null) return;

    final path = await _recorder.stop();
    if (!send || path == null || !mounted) return;

    final elapsed = DateTime.now().difference(started);
    // Anything this short is a misfire — a tapped button, a fumbled
    // press — and sending it would be noise at the other end.
    if (elapsed.inMilliseconds < 800) return;

    final bytes = await readRecording(path);
    if (bytes == null || !mounted) return;

    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .chatSendAttachment(
            conversationId: widget.conversationId,
            senderOrgId: widget.senderOrgId,
            fileName: kIsWeb ? 'voice.webm' : 'voice.m4a',
            bytes: bytes,
            mimeType: kIsWeb ? 'audio/webm' : 'audio/mp4',
            durationMs: elapsed.inMilliseconds,
          ),
      successMessage: null,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onSent();
  }

  @override
  Widget build(BuildContext context) {
    if (_recording) {
      final elapsed = DateTime.now().difference(_startedAt!);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.fiber_manual_record,
            size: 14,
            color: context.colors.danger,
          ),
          const SizedBox(width: 4),
          Text(
            _clock(elapsed),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.colors.danger,
            ),
          ),
          IconButton(
            tooltip: 'Discard',
            onPressed: () => _stopRecording(send: false),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
          IconButton.filled(
            key: const ValueKey('chat-stop-recording'),
            tooltip: 'Send',
            onPressed: () => _stopRecording(send: true),
            icon: const Icon(Icons.send, size: 18),
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('chat-attach'),
          tooltip: 'Attach a file',
          onPressed: _busy ? null : _pickFile,
          icon: const Icon(Icons.attach_file, size: 20),
        ),
        IconButton(
          key: const ValueKey('chat-record'),
          tooltip: 'Record a voice note',
          onPressed: _busy ? null : _startRecording,
          icon: const Icon(Icons.mic_none, size: 20),
        ),
      ],
    );
  }
}

/// Enough of a content type for a browser to do the right thing when the
/// signed link is opened. `file_picker` does not report one, and storage
/// falls back to `application/octet-stream` — which downloads a PDF
/// instead of showing it, and downloads a photograph instead of showing
/// that. Anything not listed keeps the fallback, which is correct if
/// unexciting.
String? _mimeFor(String? extension) {
  return switch (extension?.toLowerCase()) {
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'txt' || 'csv' => 'text/plain',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'zip' => 'application/zip',
    'm4a' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'webm' => 'audio/webm',
    _ => null,
  };
}

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// A file or a voice note inside a bubble.
class ChatAttachmentView extends ConsumerWidget {
  const ChatAttachmentView({super.key, required this.attachment});

  final Map<String, dynamic> attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = attachment['duration_ms'] as int?;
    if (duration != null) {
      return _VoiceNote(
        path: attachment['storage_path'].toString(),
        durationMs: duration,
      );
    }

    final size = attachment['file_size'] as int?;
    return InkWell(
      onTap: () => _open(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment['file_name']?.toString() ?? 'File',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                  if (size != null)
                    Text(_bytes(size), style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // A signed link rather than a public one: the object is private and
    // the policy behind it asks whether you are in this conversation.
    await runWithFeedback(
      context,
      action: () async {
        final url = await ref
            .read(repoProvider)!
            .chatFileUrl(attachment['storage_path'].toString());
        final ok = await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
        if (!ok) throw Exception('Could not open ${attachment['file_name']}');
      },
      successMessage: null,
    );
  }
}

String _bytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _VoiceNote extends ConsumerStatefulWidget {
  const _VoiceNote({required this.path, required this.durationMs});

  final String path;
  final int durationMs;

  @override
  ConsumerState<_VoiceNote> createState() => _VoiceNoteState();
}

class _VoiceNoteState extends ConsumerState<_VoiceNote> {
  final _player = AudioPlayer();
  StreamSubscription<void>? _done;
  bool _playing = false;
  bool _loading = false;

  @override
  void dispose() {
    _done?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }

    setState(() => _loading = true);
    final ok = await runWithFeedback(
      context,
      action: () async {
        final url = await ref.read(repoProvider)!.chatFileUrl(widget.path);
        await _player.play(UrlSource(url));
        _done ??= _player.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _playing = false);
        });
      },
      successMessage: null,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _playing = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: _loading ? null : _toggle,
          icon: Icon(
            _playing ? Icons.pause_circle : Icons.play_circle,
            size: 28,
          ),
        ),
        const Icon(Icons.graphic_eq, size: 18),
        const SizedBox(width: 6),
        Text(
          _clock(Duration(milliseconds: widget.durationMs)),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
