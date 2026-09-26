import 'package:supabase_flutter/supabase_flutter.dart';

/// The sentence to put in front of a person when something failed.
///
/// ## The failure this exists for
///
/// Reported with a screenshot of the bank reconciliation screen. The
/// database had refused to close a reconciliation that was out by
/// RM 11,008.23, and it said so in a sentence written for exactly that
/// moment:
///
///     The reconciliation is out by -11008.23. There are 24 statement
///     lines still unmatched. Completing it now would bury the
///     difference.
///
/// What arrived on the phone was that sentence wrapped in
///
///     PostgrestException(message: ..., code: 23514,
///                        details: Bad Request, hint: null)
///
/// because every screen in this app shows a caught error with `'$e'`,
/// and `PostgrestException.toString()` prints its fields. The careful
/// half of the message is the part a person has to read past the
/// driver's half to reach.
///
/// This is not one screen's problem. `runWithFeedback` is how every
/// action button in the app reports a failure and `AsyncView` is how
/// every screen reports one on load, so both funnels showed the wrapper
/// on every refusal the database has ever made.
///
/// ## What it does
///
/// Takes the message the sender wrote and leaves the envelope behind.
/// It never invents a sentence where there is one to show, and it never
/// hides a failure it does not recognise -- an unknown error still
/// prints, because a screen that swallowed it would be worse than one
/// that printed it untidily.
String errorText(Object? error) {
  if (error == null) return _unknown;

  // The app's own exceptions, which carry the sentence deliberately.
  if (error is Explained) {
    final said = error.message.trim();
    if (said.isNotEmpty) return said;
  }

  // The driver's three envelopes. All of them hold a `message` that is
  // either Postgres's own text or the sentence a `raise exception` in
  // `supabase/migrations/` wrote, and all of them print their fields
  // when interpolated.
  if (error is PostgrestException) {
    final said = error.message.trim();
    if (said.isNotEmpty) return said;
    final more = error.details?.toString().trim() ?? '';
    return more.isEmpty ? _unknown : more;
  }
  if (error is AuthException) {
    final said = error.message.trim();
    if (said.isNotEmpty) return said;
  }
  if (error is StorageException) {
    final said = error.message.trim();
    if (said.isNotEmpty) return said;
  }

  final raw = '$error'.trim();
  if (raw.isEmpty) return _unknown;

  // A connection that never reached the server. Matched on the text
  // rather than on `SocketException`, because `dart:io` does not exist
  // in the browser and this file is on the web build's path.
  if (_looksOffline(raw)) return offlineMessage;

  return _withoutDartsPrefix(raw);
}

/// Whether an error is one of the app's own, carrying its own sentence.
///
/// Implemented by the exception rather than known to this file, so that
/// a new one does not have to be added here to read properly -- and so
/// that `core/` does not end up importing `data/` and `services/` to
/// name their types.
abstract interface class Explained {
  /// Already in plain language, and already the whole sentence.
  String get message;
}

/// Shown when a connection never reached the server.
///
/// A host lookup failure is not something a person can act on by
/// reading it, and "Failed host lookup: 'xyz.supabase.co'" tells them
/// where the server lives while telling them nothing they can do.
const String offlineMessage =
    'Could not reach the server. Check your connection and try again.';

const String _unknown = 'Something went wrong.';

bool _looksOffline(String raw) {
  final m = raw.toLowerCase();
  return m.contains('socketexception') ||
      m.contains('failed host lookup') ||
      m.contains('connection refused') ||
      m.contains('connection closed') ||
      m.contains('connection reset') ||
      m.contains('network is unreachable') ||
      m.contains('clientexception');
}

/// Strips the noise `Object.toString()` puts in front of a message.
///
/// `Exception('x')` prints `Exception: x` and `StateError('x')` prints
/// `Bad state: x`. Neither prefix is information; both are what the
/// language does to an object nobody gave a `toString` to.
String _withoutDartsPrefix(String raw) {
  for (final prefix in const [
    'Exception: ',
    '_Exception: ',
    'Bad state: ',
    'Invalid argument(s): ',
    'Invalid argument: ',
    'FormatException: ',
  ]) {
    if (raw.startsWith(prefix)) {
      final rest = raw.substring(prefix.length).trim();
      if (rest.isNotEmpty) return rest;
    }
  }
  return raw;
}
