import '../../data/models.dart';

/// Moving client money from one of a client's matters to another.
///
/// `app.client_txn_type` has had `transfer_in` and `transfer_out` since
/// 0021 and nothing wrote either until 0358, which writes them as a
/// pair. The pair is the design: one `transfer_out` on its own is money
/// taken off a matter and put nowhere, posted exactly like a payment
/// and reconcilable against nothing.
///
/// The decisions live here rather than in the sheet because both of
/// them are claims about money and both are silent when wrong — a
/// transfer to another client's matter is a breach that balances, and a
/// transfer of more than is held is an overdrawn client ledger.

/// The matters this one's balance may be moved to.
///
/// The same client's other matters and nothing else. Not a filter for
/// tidiness: money held for one client may not be applied for another,
/// and the ordinary way that goes wrong is a mistyped matter number in
/// a list where both are open. A list that cannot contain the wrong
/// answer is better than a refusal after the fact.
List<Matter> transferDestinations(List<Matter> all, Matter from) => [
  for (final m in all)
    if (m.id != from.id && m.clientId == from.clientId) m,
];

/// Why this transfer cannot be made, or null when it can.
///
/// `held` is what the source matter holds — the sum of its client
/// account transactions, which is what the matter screen already shows.
String? transferBlockedBecause({
  required double held,
  required double amount,
  required Matter? to,
}) {
  if (to == null) return 'Choose the matter it moves to.';
  if (amount <= 0) return 'Enter an amount to move.';
  if (amount > held) {
    // Named, not "insufficient funds". The person doing this is looking
    // at two numbers and needs to know which one is the problem.
    return 'This matter holds only ${_money(held)}.';
  }
  return null;
}

/// What the sheet says about a transfer that will go through.
///
/// Deliberately says what does *not* happen. A solicitor reading
/// "transfer" reasonably wonders whether the bank has been told; it has
/// not, and the client account balance is unchanged. What moves is
/// which matter the firm holds the money against.
String transferBlurb(Matter from, Matter? to) => to == null
    ? 'Money held on ${from.matterNo} can be moved to another of this '
          'client’s matters.'
    : 'Nothing leaves the client account. ${from.matterNo} will hold '
          'that much less and ${to.matterNo} that much more.';

String _money(double v) => 'RM ${v.toStringAsFixed(2)}';
