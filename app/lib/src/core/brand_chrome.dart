/// Putting the platform's own colour and name on the browser itself.
///
/// `web/index.html` and `web/manifest.json` are files. Until `0338`'s
/// companion change they carried this product's teal and this product's
/// name in plain text, so every deployment of this software told the
/// browser it was iAkauntan — on the address bar of an Android phone,
/// on the tab, in the PWA install prompt and on the page a search
/// engine reads.
///
/// Two halves fix that, and both are needed:
///
///   * CI stamps those two files from `landing_page()` before the
///     build, which is the only moment a file inside the bundle can
///     change. That is what a browser sees before any Dart has run, and
///     the only thing a PWA install reads at all.
///   * this, which repoints the same tags once the payload arrives — so
///     a colour changed in the console takes effect on the next load
///     rather than on the next deploy.
///
/// Exactly the arrangement `favicon.dart` already uses, for the same
/// reason and with the same division of labour.
library;

export 'brand_chrome_stub.dart'
    if (dart.library.js_interop) 'brand_chrome_web.dart';
