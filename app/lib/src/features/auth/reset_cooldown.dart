/// How long until a password reset can be asked for again.
///
/// Reported: pressing "Forgot password?" twice answered
///
///   AuthApiException(message: For security purposes, you can only
///   request this after 5 seconds., statusCode: 429, code:
///   over_email_send_rate_limit)
///
/// which tells somebody the name of a Dart class, an HTTP status and an
/// error code, and buries the one fact they need — that they have to
/// wait, and how long. The words are here, and so is the arithmetic
/// that turns a moment into "4 min 12 seconds", because a countdown
/// that is wrong by a minute is worse than no countdown.
library;

/// How long this product makes somebody wait between reset emails.
///
/// Five minutes, and it is OUR figure rather than GoTrue's. The project
/// is configured with a short security interval — the message above
/// says five seconds — and a password reset link that can be asked for
/// every five seconds is a way to fill somebody's inbox using nothing
/// but their address. The screen holds the line whatever the server
/// allows.
const resetCooldown = Duration(minutes: 5);

/// How long GoTrue says to wait, if it says.
///
/// Its sentence is "For security purposes, you can only request this
/// after 47 seconds." — the number varies, the wording has moved
/// between versions, and newer builds send `Retry-After` instead. Null
/// when nothing in the message is a number, and the caller falls back
/// to [resetCooldown] rather than guessing at zero.
Duration? statedWait(String? message) {
  final text = (message ?? '').toLowerCase();
  final seconds = RegExp(r'after (\d+) second').firstMatch(text);
  if (seconds != null) {
    return Duration(seconds: int.parse(seconds.group(1)!));
  }
  final minutes = RegExp(r'after (\d+) minute').firstMatch(text);
  if (minutes != null) {
    return Duration(minutes: int.parse(minutes.group(1)!));
  }
  return null;
}

/// Whether a refusal is "too soon" rather than anything else.
///
/// By code where there is one, because that is stable, and by the
/// sentence as well because older GoTrue versions send only that.
bool looksTooSoon({String? code, String? message}) {
  final c = (code ?? '').toLowerCase();
  if (c == 'over_email_send_rate_limit' || c == 'over_request_rate_limit') {
    return true;
  }
  final text = (message ?? '').toLowerCase();
  return text.contains('for security purposes') ||
      text.contains('only request this after') ||
      text.contains('rate limit');
}

/// What is left of a wait that started at [since].
///
/// Zero rather than a negative duration once it has passed, so callers
/// can treat "nothing left" and "never asked" the same way.
Duration remainingWait(
  DateTime? since,
  DateTime now, {
  Duration cooldown = resetCooldown,
}) {
  if (since == null) return Duration.zero;
  final left = since.add(cooldown).difference(now);
  return left.isNegative ? Duration.zero : left;
}

/// A duration as somebody reads a clock: `4 min 12 seconds`.
///
/// Under a minute it is seconds alone, because "0 min 12 seconds" is a
/// sentence written by a computer. A whole number of minutes still
/// carries its zero seconds, so the shape does not change while
/// somebody is watching it count down.
String waitFor(Duration left) {
  final total = left.inSeconds < 1 ? 1 : left.inSeconds;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  if (minutes == 0) {
    return '$seconds ${seconds == 1 ? 'second' : 'seconds'}';
  }
  return '$minutes min $seconds ${seconds == 1 ? 'second' : 'seconds'}';
}

/// What the banner says while somebody has to wait.
///
/// The sentence asked for, and it says the one thing the exception did
/// not: how long, and that trying again now will not help.
String tooSoonMessage(Duration left) =>
    'For security reasons your reset password request can only be '
    'resent after ${waitFor(left)}. Please try again later.';

/// What it says when the link has gone.
String resetSent(String email) => 'Password reset link sent to $email. '
    'It can take a minute, and it may be in the spam folder.';
