import 'package:web/web.dart' as web;

/// Repoints the tab's icon at [url].
///
/// Rewrites the existing `<link rel="icon">` rather than appending a new
/// one: browsers differ on which of several icon links they honour, and
/// the reliable answer is to have exactly one. `apple-touch-icon` gets
/// the same treatment for a page added to an iOS home screen.
///
/// Null does nothing — the built-in file stays. Removing the link
/// instead would give the browser no icon at all, which is worse than a
/// slightly stale one and is what a platform with no uploaded icon would
/// otherwise get.
///
/// The URL already carries the `?v=` stamp `uploadLandingLogo` appends,
/// so a replaced image is a different URL and the browser fetches it
/// rather than serving the one it cached. Without that, a favicon
/// swapped for another at the same address can sit in the cache for
/// days.
String? _applied;

void applyFavicon(String? url) {
  if (url == null || url.isEmpty) return;

  // The caller is a `build`, so this runs on every rebuild of the root
  // widget. Setting an attribute to the value it already holds is
  // harmless but not free, and skipping it keeps the DOM untouched on
  // every rebuild that was not about the brand.
  if (url == _applied) return;
  _applied = url;

  for (final rel in const ['icon', 'apple-touch-icon']) {
    final existing = web.document.querySelector('link[rel="$rel"]');
    if (existing != null) {
      existing.setAttribute('href', url);
      continue;
    }
    // No such link in this document. Only worth adding for `icon`:
    // an apple-touch-icon nobody declared is not one anybody is missing.
    if (rel != 'icon') continue;
    final link = web.document.createElement('link') as web.HTMLLinkElement
      ..rel = rel
      ..href = url;
    web.document.head?.appendChild(link);
  }
}
