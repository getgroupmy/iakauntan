/// Handing an invitation over, and taking one up.
///
/// `invite_member` has always written a token and `accept_invitation`
/// has always been able to spend one, and between the two there was
/// nothing: no e-mail carries the token, no screen showed it, and
/// `accept_invitation` had no caller anywhere in the app. The only
/// invitation that ever worked was the accidental one —
/// `app.handle_new_user` claims a pending row when somebody *signs up*
/// at that address — so an accountant who already had an account could
/// be invited to a second company and would never hear about it. The
/// row sat `invited` for a fortnight and expired.
///
/// `0353` closed the hole that made the missing half dangerous (any
/// member of a company could read a pending token and hand it to
/// anybody at all), and returns the raw token once so there is
/// something to give the person. This is the wording either end of it.
///
/// The token is handed over as a code to type, not as a link. That is a
/// smaller feature and a better one here: a code does not end up in a
/// browser history, a referer header, or a chat preview that fetches
/// what it was sent.
library;

/// The length `app.corp_new_token` produces: two v4 UUIDs with the
/// dashes taken out.
const int kInviteCodeLength = 64;

/// What to say after inviting somebody.
///
/// Null from `invite_member` is not a failure — it is what comes back
/// when the address was already a member and only their role changed.
/// The two need different sentences, because one of them ends with
/// "send them this" and the other has nothing to send.
String invitedOutcome({required String email, required String? token}) {
  if (token == null) {
    return '$email is already in this company. Their role has been '
        'changed.';
  }
  return 'Send $email the code below. Nobody else can use it, and it '
      'stops working in 14 days.';
}

/// Whether there is a code to hand over.
bool hasCodeToGive(String? token) => token != null && token.isNotEmpty;

/// A pasted code, cleaned up enough to try.
///
/// People paste with a trailing newline, with the whitespace a chat app
/// wrapped it in, and occasionally with the whole sentence around it.
/// Only the obvious wrapping is stripped; nothing is guessed out of the
/// middle, because a code this function had to hunt for is a code the
/// person should be asked to paste again.
String cleanCode(String typed) => typed.trim().toLowerCase();

/// Why a code cannot be tried yet, or null when it can.
///
/// Checked before the round trip only to save somebody a wait — the
/// database decides, and it decides on more than length. The refusal
/// that matters most is not here at all: `accept_invitation` requires
/// the caller to be signed in as the address the invitation names, and
/// nothing on this side of the wire can know what that address is.
String? joinBlockedBecause(String typed) {
  final code = cleanCode(typed);
  if (code.isEmpty) return 'Paste the code you were sent.';
  if (code.length != kInviteCodeLength) {
    return 'That does not look like an invitation code.';
  }
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(code)) {
    return 'That does not look like an invitation code.';
  }
  return null;
}
