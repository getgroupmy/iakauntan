/// Write the icon set into `web/`, from whatever the console uploaded.
///
///   dart run tool/make_icons.dart URL-OR-PATH
///
/// Run by CI before `flutter build web`. Given nothing, or given a
/// source it cannot use, it leaves the shipped icons exactly as they are
/// and exits zero — which is the important behaviour and the reason this
/// is not a step that can turn a deploy red.
///
/// The argument against being strict here: the icons are decoration, the
/// deploy is the product. A branding upload that is the wrong size
/// should cost somebody a second attempt at the branding tab, not a
/// blocked release of an accounting system. What it does instead is say
/// loudly, in the job log and the step summary, that it kept the old
/// ones and why.
library;

import 'dart:io';
import 'dart:typed_data';

import 'icons.dart';

Future<void> main(List<String> args) async {
  final source = args.isEmpty ? '' : args.first.trim();
  if (source.isEmpty) {
    _say('No icon source given. The shipped icons are unchanged.');
    return;
  }

  final Uint8List bytes;
  try {
    bytes = await _read(source);
  } catch (e) {
    _warn('Could not fetch the icon source: $e');
    return;
  }

  final List<GeneratedIcon> icons;
  try {
    icons = generateIcons(bytes);
  } catch (e) {
    _warn('Could not use that icon: $e');
    return;
  }

  for (final icon in icons) {
    final file = File(icon.path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(icon.bytes);
  }

  _say('Wrote ${icons.length} icons from $source.');
}

Future<Uint8List> _read(String source) async {
  if (!source.startsWith('http://') && !source.startsWith('https://')) {
    return File(source).readAsBytes();
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(Uri.parse(source));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
      // A public bucket is still somebody else's disk. The bucket caps
      // uploads at 5 MB; this refuses to sit and read forever if that
      // ever stops being true.
      if (chunks.length > 8 * 1024 * 1024) {
        throw const HttpException('the file is larger than 8 MB');
      }
    }
    return Uint8List.fromList(chunks);
  } finally {
    client.close(force: true);
  }
}

void _say(String message) {
  stdout.writeln(message);
  _summary(message);
}

/// Loud, but not fatal. `::warning::` puts it on the run's summary page
/// where somebody will see it, without failing the job.
void _warn(String message) {
  stdout.writeln('::warning::$message The shipped icons are unchanged.');
  _summary('$message The shipped icons are unchanged.');
}

void _summary(String message) {
  final path = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (path == null || path.isEmpty) return;
  try {
    File(path).writeAsStringSync('\n$message\n', mode: FileMode.append);
  } catch (_) {
    // A summary that cannot be written is not a reason to stop.
  }
}
