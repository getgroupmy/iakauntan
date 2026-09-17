/// What a conversion actually turns one thing into.
///
/// `item_conversion_outputs_for` has been in `0265` since the day the
/// table was written, and nothing called it. The list could say a whole
/// chicken becomes "3 things" and could never say which three, in what
/// quantities, or how the bird's cost was split between them — and
/// `cost_share` is the only figure on the row that is a decision rather
/// than a fact. `supabase/tests/stock_transfers.sql` asserts the order
/// the shares come back in "because the screen edits them in place";
/// the screen did not exist.
library;

import '../../core/format.dart';

/// How many times, refused the way `run_item_conversion` refuses it.
///
/// The server's words are "How many times?" for anything not above
/// zero. The dialog used to read `num.tryParse(text) ?? 1`, so a typo
/// cut up one chicken rather than saying anything at all.
num? timesOf(String text) {
  final v = num.tryParse(text.trim().replaceAll(',', ''));
  if (v == null || v <= 0) return null;
  return v;
}

/// Six decimal places, because that is what the columns hold and what
/// `run_item_conversion` rounds its own arithmetic to.
num _six(num v) => num.parse(v.toStringAsFixed(6));

/// A figure off a row, or nothing.
///
/// One guard rather than the usual two: interpolating `x ?? 0` already
/// makes a string that parses, so a `?? 0` after it can never fire and
/// nothing could ever prove it right.
num _numOf(Object? v) => num.tryParse('$v') ?? 0;

/// How much of the input a run consumes.
num consumedQuantity({required num fromQuantity, required num times}) =>
    _six(fromQuantity * times);

/// How much of one output a run produces.
num producedQuantity(Map<String, dynamic> row, num times) =>
    _six(_numOf(row['quantity']) * times);

/// What the shares of a saved conversion come to.
///
/// A hundred, on anything `upsert_item_conversion` accepted. It is
/// shown anyway: a split that has drifted is worth seeing rather than
/// discovering when the costs come out wrong.
num declaredShare(Iterable<Map<String, dynamic>> rows) {
  num total = 0;
  for (final r in rows) {
    total += _numOf(r['cost_share']);
  }
  return total;
}

/// Why a conversion cannot be run, in the server's own terms.
///
/// `run_item_conversion` raises on a switched-off conversion and on a
/// count that is not above zero. Both are checked here so the button
/// is dark rather than the refusal arriving after the press.
String? conversionBlockedBecause({required bool isActive, required num? times}) {
  if (!isActive) return 'That conversion has been switched off.';
  if (times == null) return 'How many times?';
  return null;
}

/// Whether the store looks like it holds enough.
///
/// A warning, not a refusal. `run_item_conversion` counts what is in
/// one warehouse and skips the check entirely where the shop has
/// allowed negative stock; the figure on the list row is the item's
/// total across every store. So this can say nothing is wrong when the
/// server will still refuse, and it never stops the press. The
/// server's answer is the one that counts.
bool looksShortInTheStore({required num onHand, required num needed}) =>
    onHand < needed;

/// One output's line: how many come out, and what share of the input's
/// value each carries away with it.
String outputLine(Map<String, dynamic> row, num times) {
  final share = _numOf(row['cost_share']);
  return '${Fmt.qty(producedQuantity(row, times))} ${row['uom_code']} · '
      '${Fmt.qty(share)}% of what it was worth';
}
