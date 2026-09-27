import 'package:supabase_flutter/supabase_flutter.dart';

/// A refusal the server has already made, reported back so it is
/// written down.
///
/// `0235` explains why the client has to do this: "a refusal cannot
/// record itself, because the exception that carries it unwinds the
/// transaction the record was written in". `report_denied` was built
/// for exactly this, with its own membership check and its own
/// one-a-minute rate limit — and it had no caller, so the `denied` kind
/// in the security log was empty for everything the app did.

/// The SQLSTATE Postgres raises for a refusal of access, and the one
/// every `app.can_*` guard in this schema raises by hand.
const String kInsufficientPrivilege = '42501';

/// Whether an error is somebody being told no, as opposed to being told
/// they are wrong.
///
/// The distinction is the whole point of the log. `23514` — a check
/// constraint, "a draft has never been posted", "the shares come to
/// 90%" — is a business rule refusing a shape, and every one of them
/// recorded as a security event would bury the handful that are
/// somebody reaching for a company or a module they do not hold. Only
/// `42501` is that, plus the row-level security refusals Postgres
/// phrases in words rather than in a code the client can see.
bool looksLikeARefusal(Object error) {
  if (error is PostgrestException) {
    if (error.code == kInsufficientPrivilege) return true;
    return _saysRefused(error.message);
  }
  return _saysRefused('$error');
}

bool _saysRefused(String message) {
  final m = message.toLowerCase();
  return m.contains('not permitted') ||
      m.contains('permission denied') ||
      m.contains('row-level security') ||
      m.contains('row level security');
}

/// What the log records as the thing that was refused.
///
/// The screen's own name for what it was doing, because the message
/// coming back says what the database thought and not what the person
/// was trying to do. Falls back to the message when the caller gave no
/// name.
String deniedAction(Object error, {String? doing}) {
  final named = doing?.trim();
  if (named != null && named.isNotEmpty) return named;
  return deniedDetail(error);
}

/// The server's own sentence, short enough to sit in a log line.
///
/// A stack trace or a page of JSON in a security log is a security log
/// nobody reads.
String deniedDetail(Object error, {int limit = 200}) {
  // Deliberately NOT `errorText`. That one is for a person and drops
  // what a person cannot act on — the type name in front of a bare
  // `Exception`, the host in a failed lookup. A security log wants
  // exactly those: it is read when somebody is working out what was
  // refused and by what, and "nope" identifies nothing.
  final raw = error is PostgrestException ? error.message : '$error';
  final one = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (one.length <= limit) return one;
  return '${one.substring(0, limit - 1)}…';
}
