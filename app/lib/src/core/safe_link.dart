import 'package:url_launcher/url_launcher.dart';

/// Open a link that came from somewhere else.
///
/// `launchUrl` will hand a `javascript:` URI to `window.open` on the web,
/// and a `file:` or an app scheme to the platform handler everywhere
/// else. That is fine for a URL this application built; it is not fine
/// for one that arrived over the wire.
///
/// The one that arrives over the wire is `einvoice_documents.
/// validation_link`, which is whatever LHDN's MyInvois API put in its
/// response and which the e-Invoice screen turns into a button. Nobody
/// expects a tax authority to return `javascript:…`, but "nobody expects
/// this upstream to misbehave" is the assumption every supply-chain
/// incident is made of, and the check costs a line.
///
/// Returns false without launching anything if the scheme is not http or
/// https, so a caller can say so rather than appearing to do nothing.
Future<bool> launchExternal(String? url) async {
  if (url == null) return false;
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The origin a shareable link is built against.
///
/// `Uri.base.origin` THROWS — `Bad state: Origin is only applicable
/// schemes http and https` — and on Android, iOS, macOS and Windows
/// `Uri.base` is a `file:` URI. So every unguarded `'${Uri.base.origin}
/// /#/...'` in this app is a crash on a phone rather than a wrong
/// string, and four of them were unguarded.
///
/// The one in `menu_links_screen.dart` was the worst of the four
/// because it sat in `build`: the published-menus list threw on every
/// row on every native build, so the screen was a column of grey error
/// boxes. The other three are in handlers and throw at a tap. None of
/// them could have been noticed by a web build, which is where this
/// app is mostly looked at.
///
/// On the web this is the right answer and a per-tenant one: a company
/// on `sinar.iakauntan.com` gets its own address in the link, which is
/// the whole point of `0328`.
///
/// ## The fallback is the platform address, and it is a compromise
///
/// [_platformOrigin] is the same string `app.portal_url` falls back to
/// when `platform_settings.site_url` is unset, and it is written here
/// as the same fact. A link built with it WORKS — the routes are the
/// same on the platform domain — but a company on a custom domain,
/// sharing from the phone app, hands out a `iakauntan.com` address
/// instead of its own.
///
/// Reading `site_url` would fix that, and it is the proper answer:
/// it needs the setting exposed to the client, which
/// `platform_settings` does not do today. Recorded rather than
/// pretended about.
String shareOrigin() {
  final base = Uri.base;
  if (base.isScheme('http') || base.isScheme('https')) return base.origin;
  return _platformOrigin;
}

/// Where the platform answers when nothing else says. The same default
/// `app.portal_url` carries, from `0494`.
const _platformOrigin = 'https://iakauntan.com';
