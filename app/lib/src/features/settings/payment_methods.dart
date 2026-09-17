import '../../core/format.dart';
import '../../data/models.dart';

/// The lines a payment-method screen says, kept out of the widget so
/// they can be asserted without a Supabase client.
///
/// `0635`. The screen's whole job is to make one thing legible: what a
/// method costs, and where that cost lands in the ledger. Both are easy
/// to get subtly wrong on screen — "2.9%" and "2.9% + RM1.00" are
/// different products, and a blank charge account is not a gap but a
/// deliberate "use the company's".

/// LHDN's eight modes, by the code `ref_payment_modes` holds.
///
/// Hardcoded rather than read, because these are a statutory list and
/// not a company's data: they change when LHDN changes them, which is
/// a migration, not a row somebody edits.
const paymentModeNames = <String, String>{
  '01': 'Cash',
  '02': 'Cheque',
  '03': 'Bank transfer',
  '04': 'Credit card',
  '05': 'Debit card',
  '06': 'e-Wallet',
  '07': 'Digital bank',
  '08': 'Others',
};

/// What an e-Invoice will report this method as.
///
/// An unset mode says so rather than reading as "Others": a company
/// that has not chosen one has not chosen 08, and a screen that shows
/// 08 invites nobody to fix it.
String paymentModeLabel(String? code) {
  if (code == null || code.isEmpty) return 'Not set for e-Invoice';
  return paymentModeNames[code] ?? 'Mode $code';
}

/// What the provider keeps, in one line.
///
/// The three shapes are genuinely different and a screen that collapses
/// them misleads: a percentage alone, a flat fee alone, and the two
/// together.
String chargeSummary(PaymentMethod m) {
  final pct = m.chargePercent;
  final fixed = m.chargeFixed;
  if (pct <= 0 && fixed <= 0) return 'No charge';
  final parts = <String>[
    if (pct > 0) '${percentText(pct)}%',
    if (fixed > 0) Fmt.money(fixed),
  ];
  return parts.join(' + ');
}

/// A percentage with as many decimals as it has and no more.
///
/// The column is numeric(9, 4), so a rate can be 0.0125% — padding
/// everything to two decimals would round that to 0.01%, and padding
/// to four would print 2.9000% for the ordinary case. So: four
/// decimals, then strip the zeros nobody typed, keeping one so a whole
/// number still reads as a rate rather than a count.
String percentText(double pct) {
  var s = pct.toStringAsFixed(4);
  while (s.endsWith('0') && !s.endsWith('.0')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Where this method's bank charge lands, said in the order the
/// database resolves it.
///
/// A blank charge account is the ordinary case and must not read as a
/// warning. What it means is "the company's account", and saying so is
/// the difference between a setting somebody leaves alone on purpose
/// and one they fill in because the screen looked unfinished.
String chargeAccountLine(PaymentMethod m, {String? accountName}) {
  if (m.chargeAccountId == null) {
    return 'Bank charges go to the company account';
  }
  return 'Bank charges go to ${accountName ?? 'the chosen account'}';
}

/// Why this cannot be saved yet, or null.
String? paymentMethodProblem({
  required String name,
  required double chargePercent,
  required double chargeFixed,
}) {
  if (name.trim().isEmpty) return 'Give the method a name.';
  if (chargePercent < 0 || chargeFixed < 0) {
    return 'A charge cannot be negative.';
  }
  // The database's check constraint, said before the round trip. 100%
  // is allowed because it is a boundary, not a typo guard: what is
  // refused is a figure that cannot be a percentage at all.
  if (chargePercent > 100) return 'A percentage cannot be over 100.';
  return null;
}

/// What an empty list means.
///
/// Not "nothing yet" alone: the useful half is that the company is
/// already working without one, and what it gets by adding one.
const noPaymentMethodsLine =
    'No payment methods yet. Receipts and payments still work — bank '
    'charges go to account 6300. Add one to send a method\'s charges '
    'somewhere of their own.';

/// The one sentence the screen owes somebody about what this does NOT
/// do, placed where they set the rate.
///
/// Without it the natural reading of "Stripe keeps 2.9% + RM1" is that
/// receipts will be charged that automatically, and the first receipt
/// that is not would look like a bug.
const chargeRateNote =
    'Offered when you enter a receipt. What posts is always the figure '
    'on the document.';
