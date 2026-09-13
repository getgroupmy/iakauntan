/// Sending the confirmation link again.
///
/// Somebody signs up, the confirmation email goes astray — a slow
/// inbox, a spam folder, a typo they have since corrected, or
/// Supabase's built-in auth SMTP quietly hitting its hourly limit
/// (`docs/email-setup.md`) — and every attempt to sign in answers
/// "Email not confirmed" with nothing to do about it. The only way
/// out was to register again with the same address, which is not
/// something the form allows.
///
/// The words live here rather than in the screen for the reason
/// `module_offer.dart` gives: they are the whole of what somebody who
/// is locked out has to go on, and a sentence assembled inside a
/// `build` method is a sentence nobody can assert.
library;

import 'dart:convert';

/// Whether an authentication failure is "your address is not confirmed
/// yet".
///
/// Matched on the error code where there is one, because that is
/// stable, and on the message as well because a code arrives only from
/// newer GoTrue versions and the message is what older ones send. Both
/// are compared in lower case: the same condition comes back as "Email
/// not confirmed" from the password grant and "email not confirmed"
/// from elsewhere.
bool looksUnconfirmed({String? code, String? message}) {
  if (code != null && code.toLowerCase() == 'email_not_confirmed') return true;
  final text = (message ?? '').toLowerCase();
  return text.contains('email not confirmed') ||
      text.contains('email_not_confirmed');
}

/// Whether the resend was refused for being too soon.
///
/// GoTrue allows one confirmation email a minute per address. Pressing
/// the button twice is the most likely thing anybody does with it, so
/// the second press has to say something better than the raw error.
bool looksRateLimited({String? code, String? message}) {
  if (code != null &&
      const {
        'over_email_send_rate_limit',
        'over_request_rate_limit',
      }.contains(code.toLowerCase())) {
    return true;
  }
  final text = (message ?? '').toLowerCase();
  return text.contains('rate limit') ||
      text.contains('for security purposes') ||
      text.contains('only request this after');
}

/// The button under the refusal.
const resendConfirmationLabel = 'Send the confirmation link again';

/// What it says once it has gone.
///
/// Names the address, because the commonest reason a confirmation
/// never arrives is that it went somewhere else — and somebody looking
/// at their own typo is the fastest fix available.
String resendConfirmationSent(String email) =>
    'Sent to $email. Follow the link in it, then sign in. It can take a '
    'minute, and it may be in the spam folder.';

/// What it says when it was too soon.
const resendConfirmationTooSoon =
    'One confirmation email a minute. Wait a moment and try again — and '
    'check the spam folder while you wait, in case the first one is '
    'already there.';

/// What it says when the send itself failed.
///
/// Deliberately not "something went wrong": the address is the thing
/// worth checking, and a failure here is usually an address that does
/// not exist rather than a fault anybody can act on.
String resendConfirmationFailed(String detail) =>
    'That could not be sent: $detail';

/// What it says when the send failed at the mail server.
///
/// The failure this was written for: the project had just been moved
/// off Supabase's built-in auth SMTP onto a custom one, and the
/// credentials were wrong, so GoTrue's `/resend` answered
/// `unexpected_failure` and the mail server answered `535
/// "Authentication credentials invalid"`. Nothing about the address
/// was wrong and pressing the button again would not help, so saying
/// "check the address" — which is the right advice for every other
/// failure here — sends somebody to look at the one thing that is
/// fine.
const resendConfirmationMailBroken =
    'The confirmation email could not be sent. The mail server refused '
    'it, which is a setting on our side rather than anything about your '
    'address — trying again will not change it. Tell us and we will fix '
    'the mail account.';

/// Whether the failure was the mail server rather than the address.
///
/// GoTrue reports a refused SMTP login as `unexpected_failure` with
/// "Error sending confirmation email", which is the same code it uses
/// for anything else it did not expect. The sentence is what
/// distinguishes a mail failure from the rest, so both are read.
bool looksMailFailure({String? code, String? message}) {
  final text = (message ?? '').toLowerCase();
  if (text.contains('error sending') || text.contains('sending email')) {
    return true;
  }
  return code != null &&
      code.toLowerCase() == 'unexpected_failure' &&
      text.contains('email');
}

/// What the banner says when the reason is not worth showing.
///
/// Used when the detail that arrived is a JSON body or an exception's
/// `toString` — text that names the fault to a developer and nothing
/// at all to the person reading it.
const resendConfirmationOpaque = 'the mail server refused it';

/// The readable half of whatever the failure arrived as.
///
/// A 500 from GoTrue reaches the app as a body — `{"code":
/// "unexpected_failure","message":"Error sending confirmation email"}`
/// — and depending on the client version the exception's message is
/// either the `message` field or the whole of that. The first put a
/// line of JSON in front of somebody who had done nothing but press a
/// button, so the field is pulled out and everything that is still
/// punctuation is thrown away.
String resendFailureDetail(String raw) {
  final text = raw.trim();

  final open = text.indexOf('{');
  final close = text.lastIndexOf('}');
  if (open >= 0 && close > open) {
    final field = _jsonMessage(text.substring(open, close + 1));
    if (field != null && field.isNotEmpty) return field;
  }

  // `AuthApiException(message: Error sending confirmation email,
  // statusCode: 500, code: unexpected_failure)`.
  final named = RegExp(
    r'message:\s*(.+?)(?:,\s*\w+:|\)\s*$)',
    dotAll: true,
  ).firstMatch(text);
  if (named != null) {
    final field = named.group(1)!.trim();
    if (field.isNotEmpty && !field.contains('{')) return field;
  }

  if (text.isEmpty || text.contains('{') || text.contains('Exception')) {
    return resendConfirmationOpaque;
  }
  return text;
}

/// The message field of a JSON error body, under any of the names
/// GoTrue has used for it.
String? _jsonMessage(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  for (final key in const ['message', 'msg', 'error_description', 'error']) {
    final value = decoded[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
