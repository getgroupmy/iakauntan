import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../shared/file_viewer.dart';
import '../shared/receipt_capture.dart' show cameraLikely;
import '../../core/error_text.dart';
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
    await _send(
      fileName: file.name,
      bytes: file.bytes!,
      mimeType: _mimeFor(file.extension),
    );
  }

  /// A photograph, from the shutter or from the roll.
  ///
  /// `file_picker` reaches neither. It opens a document browser, and a
  /// photograph taken thirty seconds ago is somewhere inside it under a
  /// name nobody knows — so the two ways people actually send a picture
  /// get their own entries, through `image_picker`, which is already a
  /// dependency for the receipt camera and already asks for the right
  /// permission on each platform.
  ///
  /// Sized down on the way out. A modern phone camera produces four to
  /// twelve megabytes a shot; nobody sending a picture to a colleague
  /// wants that off their data plan, and the long edge kept here is
  /// still wider than any screen it will be read on.
  Future<void> _pickImage(ImageSource source) async {
    final XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
        source: source,
        imageQuality: 88,
        maxWidth: 2400,
      );
    } catch (e) {
      // A refused permission arrives as an exception, and "nothing
      // happened" is the worst possible answer to a tapped shutter.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open it: ${errorText(e)}')),
      );
      return;
    }
    if (shot == null || !mounted) return;

    final bytes = await shot.readAsBytes();
    if (!mounted) return;

    // The camera names its files `image_picker_9F3A….jpg`, which tells
    // nobody anything in a thread a year later.
    final stamp = DateTime.now();
    final named = source == ImageSource.camera
        ? 'photo-${stamp.year}'
              '${stamp.month.toString().padLeft(2, '0')}'
              '${stamp.day.toString().padLeft(2, '0')}'
              '-${stamp.millisecondsSinceEpoch % 100000}.jpg'
        : shot.name;

    await _send(
      fileName: named,
      // `image_picker` reports the type on the web and leaves it null
      // on a phone, where the extension is the only thing that knows.
      // Without one, storage falls back to `application/octet-stream`
      // and the picture downloads instead of opening.
      mimeType: shot.mimeType ?? _mimeFor(named.split('.').last),
      bytes: bytes,
    );
  }

  Future<void> _send({
    required String fileName,
    required Uint8List bytes,
    required String? mimeType,
  }) async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .chatSendAttachment(
            conversationId: widget.conversationId,
            senderOrgId: widget.senderOrgId,
            fileName: fileName,
            bytes: bytes,
            mimeType: mimeType,
          ),
      successMessage: null,
      pendingMessage: 'Sending $fileName…',
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
        // One button, three answers. Three icons in a composer that also
        // holds a microphone and a text field leaves no room for the
        // text field on a phone, which is the surface this is mostly
        // used from.
        PopupMenuButton<_Attach>(
          key: const ValueKey('chat-attach'),
          tooltip: 'Attach',
          enabled: !_busy,
          icon: const Icon(Icons.attach_file, size: 20),
          onSelected: (choice) => switch (choice) {
            _Attach.camera => _pickImage(ImageSource.camera),
            _Attach.gallery => _pickImage(ImageSource.gallery),
            _Attach.file => _pickFile(),
          },
          itemBuilder: (_) => [
            // Only where there is plausibly a camera. On a desktop
            // browser `image_picker` falls back to a file dialog, which
            // is the third entry wearing a shutter icon.
            if (cameraLikely)
              const PopupMenuItem(
                key: ValueKey('chat-attach-camera'),
                value: _Attach.camera,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.photo_camera_outlined, size: 20),
                  title: Text('Take a photo'),
                ),
              ),
            const PopupMenuItem(
              key: ValueKey('chat-attach-gallery'),
              value: _Attach.gallery,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.photo_library_outlined, size: 20),
                title: Text('Photo'),
              ),
            ),
            const PopupMenuItem(
              key: ValueKey('chat-attach-file'),
              value: _Attach.file,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.insert_drive_file_outlined, size: 20),
                title: Text('File'),
              ),
            ),
          ],
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

/// Where an attachment comes from.
enum _Attach { camera, gallery, file }

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
        // What the recorder said it wrote. Carried down because on iOS
        // it is the only thing that makes the note playable at all —
        // see `_VoiceNoteState._toggle`.
        mimeType: attachment['mime_type']?.toString(),
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
    // In the app, from the bytes -- see `showFileInApp`. This used to
    // hand a signed link to the external browser, which left a working
    // URL into somebody's private conversation in another
    // application's history for an hour.
    final path = attachment['storage_path'].toString();
    await showFileInApp(
      context,
      ref,
      storagePath: path,
      fileName: attachment['file_name']?.toString() ?? 'File',
      mimeType: attachment['mime_type']?.toString(),
      // Its own bucket, behind its own policy.
      fetch: () => ref.read(repoProvider)!.chatFileBytes(path),
    );
  }
}

String _bytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _VoiceNote extends ConsumerStatefulWidget {
  const _VoiceNote({
    required this.path,
    required this.durationMs,
    this.mimeType,
  });

  final String path;
  final int durationMs;

  /// The content type the row carries — `audio/mp4` from a phone,
  /// `audio/webm` from a browser. Null on a note recorded before the
  /// column was filled, which is why the fallback below exists.
  final String? mimeType;

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
        // Bytes, not a signed URL. A voice note is somebody's private
        // conversation, and `UrlSource` puts a working link to it into
        // an `<audio>` element where anything that can read the page
        // can read it. `BytesSource` keeps it in memory.
        final bytes = await ref.read(repoProvider)!.chatFileBytes(widget.path);
        await _player.play(BytesSource(bytes, mimeType: _containerType));
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

  /// Which container these bytes are in, said out loud.
  ///
  /// iOS refused to play any voice note at all:
  ///
  /// > PlatformException(DarwinAudioError, Failed to set source ...
  /// > AVPlayerItem.Status.failed on setSourceUrl)
  ///
  /// `BytesSource` is not a byte source on Apple platforms.
  /// `audioplayers` has no `setSourceBytes` there — the native side
  /// answers "not currently implemented on iOS" — so the Dart side
  /// writes the bytes to a temporary file *named after their hash*,
  /// with **no extension**, and plays that file instead. AVFoundation
  /// then has nothing to go on: no extension, no content type, no way
  /// to know an m4a from a webm, and `AVPlayerItem` fails to open it.
  ///
  /// A mime type is the whole fix. `audioplayers` forwards it to
  /// `AVURLAssetOverrideMIMETypeKey`, which is exactly the hint
  /// AVFoundation is missing. It costs nothing on Android or the web,
  /// where the decoder sniffs the container itself.
  ///
  /// The fallback is what this app records: `_stopRecording` sends
  /// `audio/mp4` off a phone and `audio/webm` off a browser, so a row
  /// from before `mime_type` was carried is one of those two, and the
  /// platform says which.
  String get _containerType {
    final stored = widget.mimeType;
    if (stored != null && stored.startsWith('audio/')) return stored;
    return kIsWeb ? 'audio/webm' : 'audio/mp4';
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
