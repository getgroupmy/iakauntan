/// Putting a counter sale on a customer's account.
///
/// `app.pos_tender_kind` has had `on_account` since 0208 and it meant
/// nothing until 0357: the sale wrote and posted a receipt for the whole
/// basket whatever the tender was, so a bill put on an account was
/// cleared by a payment nobody had made. 0357 makes the invoice keep its
/// balance and requires the sale to name a customer, because the
/// outlet's walk-in contact is one row every anonymous sale is billed to
/// and a receivable balance on it belongs to nobody.
///
/// The refusal is the database's and would arrive as a red banner after
/// the cashier has already pressed Take it. These decide the same thing
/// one step earlier, where the answer is a sentence next to a button
/// rather than an error over a queue.
library;

/// The tender kind that is a promise rather than payment.
const kOnAccount = 'on_account';

bool isOnAccount(Map<String, dynamic>? tenderType) =>
    tenderType?['kind'] == kOnAccount;

/// Why this sale cannot go on an account yet, or null when it can.
///
/// [saleContact] is whoever the bill is already made out to — set at the
/// basket, or by billing it to somebody for an e-Invoice. [chosenContact]
/// is a customer picked in the tender sheet itself. Either will do; the
/// database takes the second in preference and falls back to the first,
/// and this says the same thing.
String? onAccountBlockedBecause({
  required Map<String, dynamic>? tenderType,
  required String? saleContact,
  required String? chosenContact,
}) {
  if (!isOnAccount(tenderType)) return null;
  if ((chosenContact ?? saleContact) != null) return null;
  return 'Say whose account this goes on. A bill on the counter '
      'customer is a debt nobody would ever be chased for.';
}

/// What the receipt dialog says instead of change.
///
/// Nothing was handed over, so "Change RM0.00" is not merely useless —
/// it reads as a completed cash sale on the one screen a cashier checks
/// before handing the bag over.
String? onAccountNote({required double onAccount}) =>
    onAccount <= 0 ? null : 'On account';
