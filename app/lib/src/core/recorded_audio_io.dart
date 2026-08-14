import 'dart:io';
import 'dart:typed_data';

/// Somewhere to record to, and the bytes back afterwards.
Future<Uint8List?> readRecording(String location) async {
  final file = File(location);
  if (!await file.exists()) return null;
  final bytes = await file.readAsBytes();
  // The recording has been read into memory and is about to be uploaded;
  // leaving it in the cache directory serves nobody.
  try {
    await file.delete();
  } catch (_) {
    // A temp file that will not delete is not worth failing a message
    // over. The platform clears its own cache.
  }
  return bytes;
}
