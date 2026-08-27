/// Put the platform's own colour and name on the built web files.
///
///   dart run tool/brand_chrome.dart < landing-page.json
///
/// Run by CI before `flutter build web`, from the same `landing_page()`
/// response that chooses the icons. `web/index.html` and
/// `web/manifest.json` are files inside the bundle, so this is the only
/// moment they can change — and they are the only thing a browser sees
/// before any Dart has run, and the whole of what a PWA install reads.
///
/// The running app repoints the same tags again once the payload
/// arrives (`lib/src/core/brand_chrome.dart`). Neither half is enough:
/// without this, an install prompt shows a nameless app and an Android
/// address bar is untinted until the bundle boots; without that, a
/// colour changed in the console waits for a deploy.
///
/// ## Never fatal
///
/// Same bargain as the icons. A branding field that is missing or
/// malformed should cost somebody a second go at the console, not a
/// blocked release of an accounting system — so every path exits zero
/// and says in the log which of "nothing was set" and "I could not
/// ask" happened, because they produce the same files and only one of
/// them is fine.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final raw = await systemEncoding.decodeStream(stdin);
  if (raw.trim().isEmpty) {
    _say('No branding was read; index.html and manifest.json are unchanged.');
    return;
  }

  final Brand brand;
  try {
    brand = Brand.fromPayload(jsonDecode(raw));
  } catch (_) {
    _say('The branding did not parse; index.html and manifest.json are '
        'unchanged.');
    return;
  }

  if (brand.isEmpty) {
    _say('No name or colour is set in the console; index.html and '
        'manifest.json are unchanged.');
    return;
  }

  final root = Directory.current.path;
  _rewrite('$root/web/index.html', (s) => stampIndexHtml(s, brand));
  _rewrite('$root/web/manifest.json', (s) => stampManifest(s, brand));
  _say('Stamped the console\'s name and colour onto index.html and '
      'manifest.json.');
}

void _rewrite(String path, String Function(String) f) {
  final file = File(path);
  if (!file.existsSync()) return;
  file.writeAsStringSync(f(file.readAsStringSync()));
}

void _say(String message) {
  stdout.writeln(message);
  final summary = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (summary == null || summary.isEmpty) return;
  try {
    File(summary).writeAsStringSync('\n$message\n', mode: FileMode.append);
  } catch (_) {
    // The summary is a nicety; the log line above is the record.
  }
}

/// The handful of fields that end up in the browser's own furniture.
class Brand {
  const Brand({this.name, this.title, this.description, this.colour});

  /// What the platform calls itself — `wordmark`.
  final String? name;

  /// The tab and install title — `meta_title`, falling back to [name].
  final String? title;
  final String? description;

  /// `brand_colour`, as `#RRGGBB`. Anything else is treated as unset:
  /// a manifest with a malformed colour is a manifest some browsers
  /// reject wholesale, which would cost the install prompt entirely.
  final String? colour;

  bool get isEmpty =>
      name == null && title == null && description == null && colour == null;

  /// Reads `landing_page()`'s shape.
  ///
  /// `brand` first and `page` as a fallback, exactly as the icon script
  /// does: `brand` is not gated on the marketing site being published,
  /// and a platform that has not written one still has a name.
  static Brand fromPayload(Object? payload) {
    Map<String, Object?>? at(Object? o) =>
        o is Map ? o.cast<String, Object?>() : null;

    final root = at(payload);
    final brand = at(root?['brand']);
    final page = at(root?['page']);

    String? str(String key) {
      for (final source in [brand, page]) {
        final v = source?[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    final colour = str('brand_colour');
    return Brand(
      name: str('wordmark'),
      title: str('meta_title') ?? str('wordmark'),
      description: str('meta_description'),
      colour: RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(colour ?? '')
          ? colour!.toUpperCase()
          : null,
    );
  }
}

/// The three markers `web/index.html` leaves for this, replaced.
///
/// Markers rather than a regex over whatever tag happens to be there:
/// the checked-in file carries no brand at all, so there is nothing to
/// match against — and a marker is visible to whoever edits that file
/// next, which a regex in another directory is not.
///
/// A field this platform has not set leaves its marker in place. An
/// HTML comment renders as nothing, which is the correct rendering of
/// "this platform has not said".
String stampIndexHtml(String html, Brand brand) {
  var out = html;

  if (brand.colour != null) {
    out = out.replaceAll(
      '<!-- brand:theme-color -->',
      '<meta name="theme-color" content="${_attr(brand.colour!)}">',
    );
  }
  if (brand.description != null) {
    out = out.replaceAll(
      '<!-- brand:description -->',
      '<meta name="description" content="${_attr(brand.description!)}">',
    );
  }
  if (brand.name != null) {
    out = out.replaceAll(
      '<!-- brand:apple-title -->',
      '<meta name="apple-mobile-web-app-title" '
          'content="${_attr(brand.name!)}">',
    );
  }
  final title = brand.title ?? brand.name;
  if (title != null) {
    out = out.replaceAll(
      '<title>Loading…</title>',
      '<title>${_text(title)}</title>',
    );
  }
  return out;
}

/// The PWA manifest, with the empty fields filled and the colours added.
///
/// Re-encoded from the parsed object rather than string-substituted:
/// this file is JSON, an operator's name can contain a quote, and a
/// manifest that does not parse is one the browser ignores entirely —
/// which loses the icons as well as the name.
String stampManifest(String json, Brand brand) {
  final Map<String, Object?> manifest;
  try {
    manifest = (jsonDecode(json) as Map).cast<String, Object?>();
  } catch (_) {
    return json;
  }

  if (brand.title != null) manifest['name'] = brand.title;
  if (brand.name != null) manifest['short_name'] = brand.name;
  if (brand.description != null) manifest['description'] = brand.description;
  if (brand.colour != null) manifest['theme_color'] = brand.colour;

  return '${const JsonEncoder.withIndent('    ').convert(manifest)}\n';
}

/// Enough escaping for an HTML attribute this file is building.
String _attr(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// And for text between tags.
String _text(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
