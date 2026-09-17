/// Changing the address and the number we reach somebody on, behind
/// the password.
///
/// Both of these are how an account is recovered: the email is where a
/// reset link goes, and the mobile is what a person is rung on when
/// something is wrong. Somebody who walks past an unattended signed-in
/// screen and changes the email address owns the account a minute
/// later, and the real owner finds out when their next reset link goes
/// somewhere else.
///
/// So the password is asked for again. It is the one question that
/// separates the account holder from whoever is at the keyboard: the
/// session proves somebody signed in once, and re-entering the password
/// proves it is still them. A captcha cannot answer that -- it asks
/// whether anybody is human, not which human -- which is why these two
/// are guarded this way and the signed-out forms are guarded with
/// Turnstile.
///
/// GoTrue verifies the password, by being asked to sign in with it. A
/// check written here would be a check the client could skip.
library;

/// The words on the account card.
const changeEmailLabel = 'Change email address';
const changeMobileLabel = 'Change mobile number';

/// The heading over each dialog.
const changeEmailTitle = 'Change your email address';
const changeMobileTitle = 'Change your mobile number';

/// Why the password is being asked for, said where it is asked.
const whyPasswordAgain =
    'Your password, again — this is the address a password reset goes '
    'to, so we ask before it moves.';
const whyPasswordAgainMobile =
    'Your password, again — this is the number we ring when something '
    'is wrong with the account.';

/// What the password box is called here.
const currentPasswordLabel = 'Your password';

/// What is wrong with the password box, or null.
String? currentPasswordError(String? value) =>
    (value ?? '').isEmpty ? 'Enter your password' : null;

/// Whether a failure was the password rather than anything else.
///
/// GoTrue answers a wrong password on the re-authentication with
/// `invalid_credentials`, and saying "that password is wrong" beats
/// repeating its sentence, which is written for a sign-in screen and
/// talks about signing in.
bool looksWrongPassword({String? code, String? message}) {
  final c = (code ?? '').toLowerCase();
  if (c == 'invalid_credentials' || c == 'invalid_grant') return true;
  final text = (message ?? '').toLowerCase();
  return text.contains('invalid login credentials') ||
      text.contains('invalid credentials');
}

/// What it says when the password was wrong.
const wrongPassword = 'That password is not right. Nothing has changed.';

/// What it says once an email change has been asked for.
///
/// The address does NOT move when this returns. GoTrue sends a
/// confirmation to the new address and waits, which is the whole
/// protection: somebody who changes an address they cannot read has
/// changed nothing.
String emailChangeSent(String email) =>
    'Check $email and follow the link there. Your address does not '
    'change until you do.';

/// And when a number has been saved, which is immediate because there
/// is nothing to confirm.
String mobileChanged(String phone) => 'Your mobile number is now $phone.';

/// What it says when the number was taken off.
const mobileRemoved = 'Your mobile number has been removed.';
