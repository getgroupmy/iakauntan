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
