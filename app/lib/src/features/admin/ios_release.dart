/// What the `ios-release` function answered, including when the answer
/// is "nobody has set this up".
///
/// Pure Dart with no Flutter and no Supabase in it, so the repository,
/// the console card and a test can all share the same reading of a
/// refusal.
///
/// ---------------------------------------------------------------------
/// Why "not configured" is a RESULT and not an error
///
/// The function already draws this distinction: a missing
/// `GITHUB_RELEASE_TOKEN` gets a 503 and a sentence rather than a 500,
/// because a release nobody has set up yet is not a broken build. The
/// Dart side used to flatten that back into a throw, and the console
/// drew it as `ErrorState` — a red exclamation, "Something went wrong",
/// and a raw `FunctionException(status: 503, details: {...})` under it.
///
/// That is the crying wolf `.github/workflows/ios-release.yml` refuses
/// to do when it checks its own secrets and STOPS rather than failing.
/// A console that shouts at somebody for not having finished a setup
/// they have not started is worse than one that says what is missing.
library;

/// The last few runs, or the reason there are none to show.
class IosReleases {
  const IosReleases.runs(this.runs) : unavailable = null;

  /// Releasing is not set up here yet, and [unavailable] says what it
  /// needs. Not an error: nothing is broken.
  const IosReleases.unavailable(String this.unavailable)
    : runs = const <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> runs;

  /// The sentence the function sent, or null when it sent a list.
  final String? unavailable;

  bool get isConfigured => unavailable == null;
}

/// Whether a refusal means "nobody has set this up" rather than "it
/// broke".
///
/// 503 and nothing else. A 403 is a person without the right to
/// release, a 502 is GitHub being unreachable, and a 500 is a bug —
/// three different things to do about them, and none is "add a secret".
bool releaseNotConfigured(int status) => status == 503;

/// The sentence the function sent, where it sent one.
///
/// `fail()` puts it under `error`. The fallbacks matter more than they
/// look: `FunctionException.details` is whatever the body decoded to,
/// which is a Map for this function's own refusals but a bare String
/// for anything that answered before the function did — a gateway, a
/// cold start that timed out. Returning the whole body would put a
/// JSON blob in a snack bar, which is how "not configured" ends up
/// looking like a crash.
String releaseRefusalLine(Object? details, {String orElse = 'The release could not be started'}) {
  if (details is Map && details['error'] is String) {
    final said = (details['error'] as String).trim();
    if (said.isNotEmpty) return said;
  }
  // A plain string body, but only when it is short enough to be a
  // sentence somebody wrote rather than a page of HTML from a proxy.
  if (details is String) {
    final said = details.trim();
    if (said.isNotEmpty && said.length <= 300 && !said.startsWith('<')) {
      return said;
    }
  }
  return orElse;
}
