/// Whether the platform is taking new registrations, as the form has to
/// draw it.
///
/// `0018` seeded `signup_enabled` and nothing read it for five hundred
/// migrations, so an operator could switch it off, watch it save, and
/// strangers would go on getting accounts. `0563` makes the trigger on
/// `auth.users` refuse — that is the enforcement, and none of it is
/// here. What is here is only so nobody fills in eight fields to be
/// told at the end.
library;

/// Whether to offer the way on to the registration form.
///
/// [alreadyThere] is the exemption that matters: that half of the
/// toggle is the way *back* from a form somebody is already looking at,
/// and hiding it would strand them on a page with no exit.
bool offersRegistration({
  required bool signupsOpen,
  required bool alreadyThere,
}) => signupsOpen || alreadyThere;

/// Whether the button that creates the account may be pressed.
bool canRegister({required bool signupsOpen}) => signupsOpen;

/// What to tell somebody who cannot register.
///
/// The operator's own words where they wrote any, which is what
/// `app.signup_closed_message` already decided. The fallback here is
/// for the call that came back without one at all — a deployment whose
/// function predates `0563`, or a payload that lost the field.
///
/// "We are closed" with no reason reads as a fault, and somebody who
/// believes the site is broken comes back tomorrow and tries again.
String closedNotice(String? fromServer) {
  final said = (fromServer ?? '').trim();
  if (said.isNotEmpty) return said;
  return 'We are not taking new registrations at the moment. If somebody '
      'at a company that already uses iAkauntan invites you, that '
      'invitation still works.';
}
