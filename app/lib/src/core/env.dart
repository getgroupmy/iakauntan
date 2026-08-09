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

  static const appName = 'iAkauntan';
  static const supportEmail = 'support@iakauntan.my';
}
