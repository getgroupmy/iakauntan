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
/// Which app, and everything the console needs to say about it.
///
/// The two are genuinely different products with different stores,
/// different destinations and different costs, so they get a card
/// each. What they share is every word of the machinery behind the
/// button — see `supabase/functions/_shared/release.ts`, which holds
/// the same split on the server.
enum ReleasePlatform {
  ios(
    fn: 'ios-release',
    label: 'iOS',
    title: 'Release the iOS app',
    subtitle: 'Builds on a Mac and uploads to App Store Connect',
    choices: ['testflight', 'appstore'],
    labels: ['TestFlight', 'App Store'],
    // Said out loud in the confirmation, because it is the one number
    // that decides whether somebody presses now or later: a macOS
    // runner bills at ten times an Ubuntu one.
    buildTime: 'It builds on a Mac, which takes twenty to thirty '
        'minutes and costs about ten times an Ubuntu build.',
  ),
  android(
    fn: 'android-release',
    label: 'Android',
    title: 'Release the Android app',
    subtitle: 'Builds on Ubuntu and uploads to Google Play',
    choices: ['internal', 'alpha', 'beta', 'production'],
    labels: ['Internal', 'Alpha', 'Beta', 'Production'],
    buildTime: 'It builds on Ubuntu, which takes about eight minutes.',
  );

  const ReleasePlatform({
    required this.fn,
    required this.label,
    required this.title,
    required this.subtitle,
    required this.choices,
    required this.labels,
    required this.buildTime,
  });

  /// The edge function's name. The same string on both sides.
  final String fn;

  /// "iOS" or "Android", for a sentence.
  final String label;
  final String title;
  final String subtitle;

  /// How long it takes and what it costs, for the confirmation.
  final String buildTime;

  /// Every destination, in the order the workflow declares them. The
  /// first is the default, and `scripts/check_release_choices.py`
  /// holds this list to the workflow's own `options:`.
  final List<String> choices;

  /// What to call each of those on a button.
  final List<String> labels;

  /// The name the workflow gives its destination input. `lane` for
  /// one and `track` for the other, and sending the wrong one is a
  /// 422 that names neither.
  String get input => this == ReleasePlatform.ios ? 'lane' : 'track';
}

class AppReleases {
  const AppReleases.runs(this.runs) : unavailable = null;

  /// Releasing is not set up here yet, and [unavailable] says what it
  /// needs. Not an error: nothing is broken.
  const AppReleases.unavailable(String this.unavailable)
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
