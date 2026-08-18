/// Build-time configuration.
///
/// The publishable key is designed to be shipped in clients — row level
/// security is what protects the data. Never put the service role key
/// here; it belongs only in edge function secrets.
///
/// Override per environment with:
///   flutter build web --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class Env {
  const Env._();

  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://ewwcgtnniwqndrzukksm.supabase.co',
  );

  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_QcTtzLYCECOYRVOt4erFtg_k-YaQWHA',
  );

  /// The VAPID public key browsers subscribe to push with.
  ///
  /// Public by design — it is handed to every push service on every
  /// send, and it is what lets them tell our notifications from
  /// somebody else's. The private half is a function secret and appears
  /// nowhere in this bundle.
  ///
  /// Empty by default, because a wrong key is worse than none: a
  /// browser that subscribes with one key and is pushed to with another
  /// silently drops every message. Empty means the app says push is not
  /// configured, which is true.
  static const webPushPublicKey = String.fromEnvironment('WEB_PUSH_PUBLIC_KEY');

  static const appName = 'iAkauntan';
  static const supportEmail = 'support@iakauntan.com';

  /// What is wrong with this build's configuration, or null if nothing
  /// is. Checked before `Supabase.initialize`, which refuses to run
  /// without it.
  ///
  /// The defaults above mean a build that simply omitted every
  /// `--dart-define` is configured, so this cannot fire on one. What it
  /// catches is the pipeline that passed the flag with an empty or
  /// wrong-shaped value behind it — `--dart-define=SUPABASE_URL=` when
  /// the secret was never set is the usual way, and it produces a bundle
  /// that starts, fails every query, and blames the network.
  ///
  /// Deliberately shape-only. Whether the key is *accepted* is not
  /// something a client can know before it asks, and pretending
  /// otherwise would only move the failure.
  static String? misconfiguration() {
    final problems = <String>[
      if (supabaseUrl.isEmpty)
        'SUPABASE_URL is empty'
      else if (!supabaseUrl.startsWith('https://'))
        'SUPABASE_URL is not an https:// address',
      if (supabaseAnonKey.isEmpty) 'SUPABASE_ANON_KEY is empty',
    ];
    return problems.isEmpty ? null : problems.join('\n');
  }
}
