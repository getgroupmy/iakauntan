import 'package:web/web.dart' as web;

/// What was applied last, so a rebuild that changed nothing touches no
/// DOM. The caller is a `build`, so this runs often.
String? _applied;

/// Points the browser's own furniture at the platform's brand.
///
/// [themeColour] tints the Android address bar and the iOS PWA status
/// bar; [title] is the tab and the iOS home-screen name; [description]
/// is what a search engine and a link preview read.
///
/// A null or empty value leaves that tag exactly as the build shipped
/// it rather than clearing it. Clearing would be worse than stale: a
/// page with no title shows its URL, and a `theme-color` removed
/// mid-session leaves some browsers with the last colour anyway.
void applyBrandChrome({
  String? themeColour,
  String? title,
  String? description,
}) {
  final key = '$themeColour|$title|$description';
  if (key == _applied) return;
  _applied = key;

  _meta('theme-color', themeColour);
  _meta('description', description);
  // The name an iOS home-screen shortcut is given. Same value as the
  // tab: a platform does not have two names.
  _meta('apple-mobile-web-app-title', title);

  if (title != null && title.isNotEmpty) web.document.title = title;
}

/// Sets `<meta name="[name]" content="[value]">`, creating the tag if
/// this document has none.
///
/// Created rather than skipped, because the whole point is that the
/// shipped HTML no longer carries a colour or a description of its own —
/// so on a bundle built without credentials there is nothing here to
/// rewrite, and the first thing to put a brand on the browser is this.
void _meta(String name, String? value) {
  if (value == null || value.isEmpty) return;

  final existing = web.document.querySelector('meta[name="$name"]');
  if (existing != null) {
    existing.setAttribute('content', value);
    return;
  }
  final meta = web.document.createElement('meta') as web.HTMLMetaElement
    ..name = name
    ..content = value;
  web.document.head?.appendChild(meta);
}
