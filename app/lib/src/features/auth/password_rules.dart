/// What makes a password acceptable, and what makes two of them the
/// same one.
///
/// The rules are here rather than inside the form's `validator` for the
/// reason `module_offer.dart` gives about sentences: a rule written
/// inside a `build` method is a rule nobody can assert, and this one is
/// checked twice — once when somebody registers, and once when they set
/// a new password after a reset.
library;

/// The shortest a password may be.
///
/// Eight, which is what the form has asked for since it was written and
/// what Supabase is configured to accept. Named so that the field, the
/// refusal and the test cannot disagree about it.
const passwordMinLength = 8;

/// The label on the second box.
const confirmPasswordLabel = 'Confirm password';

/// What is wrong with a password, or null if nothing is.
String? passwordError(String? value, {bool isNew = false}) {
  final text = value ?? '';
  if (text.isEmpty) return 'Enter your password';
  // Only when one is being CHOSEN. An existing password that is shorter
  // than eight is still their password, and refusing it at sign-in
  // locks somebody out of their own account over a rule that arrived
  // after they set it.
  if (isNew && text.length < passwordMinLength) {
    return 'Use at least $passwordMinLength characters';
  }
  return null;
}

/// What is wrong with the confirmation, or null if nothing is.
///
/// Empty is its own refusal rather than "they do not match": somebody
/// who has not typed it yet has not made a mistake, and being told they
/// have is a form arguing with them about the order they fill it in.
String? confirmPasswordError({
  required String? password,
  required String? confirm,
}) {
  final second = confirm ?? '';
  if (second.isEmpty) return 'Type the password again';
  if (second != (password ?? '')) return passwordMismatch;
  return null;
}

/// What it says when they do not match.
///
/// Said about the pair rather than about the second box, because
/// either one of them could be the one with the typo in it — and a
/// password nobody can see is one nobody can compare by eye.
const passwordMismatch = 'The two passwords are not the same';
