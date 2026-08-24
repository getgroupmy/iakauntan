/// Everywhere that is not a browser.
///
/// Android and iOS have no tab to put an icon in; their launcher icons
/// are baked into the store build and cannot be changed from inside the
/// running app at all. Doing nothing is the whole correct behaviour.
void applyFavicon(String? url) {}
