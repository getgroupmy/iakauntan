/// Everywhere that is not a browser.
///
/// Android and iOS have no tab, no address bar to tint and no manifest.
/// Their launcher name, icon and splash colour are baked into the store
/// build and cannot be changed from inside the running app at all — so
/// doing nothing is the whole correct behaviour, and the honest note is
/// that a native rebrand is a rebuild rather than a console setting.
void applyBrandChrome({
  String? themeColour,
  String? title,
  String? description,
}) {}
