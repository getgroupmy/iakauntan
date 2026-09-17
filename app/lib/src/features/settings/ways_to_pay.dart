/// What a company may settle a platform invoice with.
///
/// `payment_gateways` has been readable by every signed-in user since
/// `0292`, and its own table comment says why: "so that a company can
/// be shown the ways it may pay". Nothing showed them. The screen had
/// one button, wired to Billplz, drawn for every outstanding invoice
/// whether or not Billplz was the gateway this platform had switched
/// on — so an operator who set up toyyibPay instead left every tenant
/// a Pay button that called an edge function with no credentials.
///
/// Everything here is pure and asserted in `ways_to_pay_test.dart`.
/// What it decides is what the screen may claim, and the two claims
/// worth being careful about are "there is a way to pay this online"
/// and "there is not" — the second is what somebody acts on by picking
/// up the phone.
library;

/// The rails a gateway may carry, in the order a person looks for them
/// rather than the order they sort in.
///
/// `payment_gateways.methods` is stored sorted, because `0352`
/// normalises it and a column that sorts is a column two rows can be
/// compared by. Sorted is the wrong order to *read*: it opens on
/// `bank_transfer` and `bnpl`, and in Malaysia the answer somebody is
/// looking for is FPX.
const List<String> kMethodOrder = [
  'fpx',
  'duitnow',
  'card',
  'ewallet',
  'qr',
  'bank_transfer',
  'direct_debit',
  'bnpl',
  'over_counter',
];

/// The gateway codes this app can actually start a payment with.
///
/// Not "which gateway is active" — that is the operator's decision and
/// the database's answer. This is the narrower and more awkward fact:
/// a hosted checkout needs an edge function that speaks one named
/// provider's API, and `billplz-checkout` is the only one written. A
/// Pay button drawn for anything else is a button that fails.
const Set<String> kHostedCheckoutCodes = {'billplz'};

/// One rail, in words.
///
/// Unknown codes are returned as they came rather than hidden. A method
/// added to the vocabulary by a later migration should look unpolished
/// on this screen, not invisible — invisible is how a shop finds out
/// from a customer.
String methodLabel(String code) {
  switch (code) {
    case 'fpx':
      return 'FPX';
    case 'duitnow':
      return 'DuitNow';
    case 'card':
      return 'Card';
    case 'ewallet':
      return 'E-wallet';
    case 'qr':
      return 'QR';
    case 'bank_transfer':
      return 'Bank transfer';
    case 'direct_debit':
      return 'Direct debit';
    case 'bnpl':
      return 'Buy now, pay later';
    case 'over_counter':
      return 'Over the counter';
    default:
      return code;
  }
}

/// The rails a gateway carries, in reading order.
List<String> methodsOf(Map<String, dynamic> row) {
  final raw = row['methods'];
  if (raw is! List) return const [];
  final have = {for (final m in raw) '$m'};
  final known = [
    for (final m in kMethodOrder)
      if (have.remove(m)) m,
  ];
  // Anything the vocabulary does not know goes last, in the order it
  // arrived, rather than being dropped.
  return [...known, ...have];
}

/// "FPX · Card · E-wallet", or nothing at all when a gateway has not
/// said. An empty string rather than a placeholder: a row that says
/// nothing about its rails should take up no line.
String methodsLine(Map<String, dynamic> row) =>
    methodsOf(row).map(methodLabel).join(' · ');

/// Where a gateway sells, for the console.
///
/// An empty coverage list is not missing information — `0352` makes it
/// mean "sells everywhere", and that is what it has to read as, because
/// the alternative reading sends an operator looking for a list that
/// was left empty on purpose.
String coverageLabel(Map<String, dynamic> row) {
  final raw = row['countries'];
  if (raw is! List || raw.isEmpty) return 'Everywhere';
  return raw.map((c) => '$c').join(' · ');
}

/// The gateway a Pay button can actually be wired to, or null.
///
/// Null is the interesting answer and the reason this is a function
/// rather than a `firstWhere`: it means the platform has switched on
/// ways to pay that this app cannot start, so the screen must say what
/// they are instead of offering a button that throws.
Map<String, dynamic>? hostedCheckout(Iterable<Map<String, dynamic>> gateways) {
  for (final g in gateways) {
    if (kHostedCheckoutCodes.contains('${g['code']}')) return g;
  }
  return null;
}

/// What to tell somebody holding an unpaid invoice and no button.
///
/// Three different situations, and they are different sentences,
/// because the action each one calls for is different: wait, read the
/// instructions, or ask.
String? payByHandBecause(List<Map<String, dynamic>> gateways) {
  if (hostedCheckout(gateways) != null) return null;
  if (gateways.isEmpty) {
    return 'No online payment is set up yet. Get in touch and we will '
        'send you the details.';
  }
  final named = gateways.map((g) => '${g['name']}').join(', ');
  return 'Paid outside the app for now, through $named. The details are '
      'below.';
}

/// The note an operator left on a gateway, trimmed to nothing when it
/// is blank — `instructions` is nullable and an empty string is what a
/// cleared text field sends.
String? instructionsOf(Map<String, dynamic> row) {
  final s = '${row['instructions'] ?? ''}'.trim();
  return s.isEmpty ? null : s;
}

/// A documentation link, only when it is one.
///
/// `0352` refuses anything but https on the way in, so this is a guard
/// against rows that predate it rather than a second opinion about the
/// rule.
String? docsUrlOf(Map<String, dynamic> row) {
  final s = '${row['docs_url'] ?? ''}'.trim();
  return s.toLowerCase().startsWith('https://') ? s : null;
}

/// A country list typed into a console field, as the RPC wants it.
///
/// Splitting is the screen's job and normalising is the database's, so
/// this deliberately does not upper-case or sort: `0352` does that, and
/// a second implementation here would be a second thing to keep in
/// step. What it does do is tell an empty field from a blank one —
/// null leaves the column alone, `[]` says the gateway sells
/// everywhere, and those are different saves.
List<String>? splitCodes(String? text) {
  if (text == null) return null;
  final parts = text
      .split(RegExp(r'[,\s]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return parts;
}
