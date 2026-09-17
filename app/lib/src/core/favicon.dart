/// Pointing the browser tab at the platform's own icon, without a build.
///
/// The favicon is a file: `web/index.html` carries
/// `<link rel="icon" href="favicon.png">`, CI regenerates that file from
/// the uploaded icon, and until the next deploy the tab keeps whatever
/// the last build put there. That is fine for a platform that rebrands
/// once, and it reads as broken to somebody who has just uploaded a logo
/// and is watching the tab.
///
/// So the running page repoints the link at the stored image. The built
/// file is still generated and still matters — it is what the tab shows
/// on the first paint, before any data has loaded, and what a browser
/// with no session gets. This only overrides it once the brand is known.
library;

export 'favicon_stub.dart' if (dart.library.js_interop) 'favicon_web.dart';
