/// Closing a file, and what has to be true first.
///
/// `app.matter_status` has had `closed` since `0021` and this module's
/// screen has had a Closed tab for as long. Both were empty and always
/// would be: nothing ever wrote the value, so every file a practice
/// opened stayed on the live list for the life of the practice.
///
/// The one absolute rule is restated here so the button is greyed rather
/// than pressed and refused. `close_matter` is the enforcement — a rule
/// enforced only in Dart is not enforced — and it says the same things
/// last.
library;

/// Below this a balance is rounding, not client money.
///
/// `client_account_transactions.amount` is `numeric(18, 2)`, so a live
/// balance is always exact to the sen and this only guards the double
/// the app reads it back into.
const _sen = 0.005;

/// Why this matter cannot be closed, or null when it can.
///
/// One reason only, and it is about whose money it is. The Legal
/// Profession (Accounts) Rules hold that money received for a client is
/// held for a purpose and paid out when the purpose is done; a matter
/// closed with a balance on it is money nobody is looking at any more.
String? closeBlockedBecause({
  required String status,
  required double clientFunds,
}) {
  if (status == 'closed') return 'This matter is already closed.';
  if (clientFunds.abs() > _sen) {
    return clientFunds > 0
        ? 'The client account still holds money on this matter. Pay it '
            'out, or move it to their other matter, before closing the file.'
        // Negative is not a smaller version of the same problem. It means
        // more has gone out on this matter than came in, which under the
        // Accounts Rules is one client\'s money paying for another\'s
        // work — the breach the client account exists to prevent.
        : 'This matter is overdrawn on the client account. That is '
            'another client\'s money funding this file, and it has to be '
            'put right before anything else.';
  }
  return null;
}

/// What closing will leave behind, in one sentence, or null when there
/// is nothing to say.
///
/// Shown before confirming rather than as a refusal: unbilled time and
/// disbursements are the firm's own money, and a practice writing off
/// work on a file that came to nothing is entitled to. The difference
/// between a control and a nag is whose money it is.
String? unbilledWarning({
  required double unbilledTime,
  required double unbilledDisbursements,
}) {
  final parts = <String>[
    if (unbilledTime.abs() > _sen) 'time',
    if (unbilledDisbursements.abs() > _sen) 'disbursements',
  ];
  if (parts.isEmpty) return null;
  return 'There is unbilled ${parts.join(' and ')} on this matter. '
      'Closing it does not bill them, and nothing will chase them '
      'afterwards.';
}

/// Whether the file can be put back into service.
bool canReopen(String status) => status == 'closed' || status == 'archived';
