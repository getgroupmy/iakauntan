import '../../core/format.dart';
import '../../data/models.dart';

/// The currency decisions the document and settlement screens have to
/// make, kept out of the widgets so they can be asserted directly.
///
/// None of this is arithmetic the ledger relies on — the database
/// converts, and `app.exchange_rate_for` refuses to guess a rate. These
/// are the rules for what the *form* may submit, which exist so the user
/// is told what is wrong while they can still fix it, rather than by a
/// Postgres error code after they press Post.

/// Whether a rate is usable for a document in [currency].
///
/// A foreign document at rate 1 is the specific failure worth guarding:
/// it balances, it posts, every report foots, and a USD 10,000 invoice
/// has quietly become RM 10,000. Base currency is the one case where 1
/// is the right answer.
bool rateIsUsable({
  required String currency,
  required String baseCurrency,
  required double? rate,
}) {
  if (currency == baseCurrency) return true;
  return rate != null && rate > 0;
}

/// A typed rate, or null if it is not a number the database would accept.
///
/// `exchange_rates.rate` is `numeric(18, 8) check (rate > 0)`, so zero
/// and negatives are rejected here rather than at the insert.
double? parseRate(String text) {
  final value = double.tryParse(text.trim().replaceAll(',', ''));
  if (value == null || value <= 0 || !value.isFinite) return null;
  return value;
}

/// "1 USD = 4.70 MYR" — the sentence the rate field is claiming.
///
/// Shown because a bare number in a field labelled "Exchange rate" is
/// ambiguous in exactly the direction that matters: 4.70 and 0.2128 are
/// both plausible-looking rates for the same pair, and only one of them
/// posts the invoice at four times its value.
String rateCaption({
  required String currency,
  required String baseCurrency,
  required double rate,
}) =>
    '1 $currency = ${Fmt.rate(rate)} $baseCurrency';

/// The exchange gain (positive) or loss (negative) a settlement will
/// post, in base currency.
///
/// This mirrors `app.realised_fx_on_settlement` — same per-allocation
/// rounding, same sign convention — so the dialog can say what is about
/// to hit the profit and loss before it happens. The database remains
/// the authority; if the two ever disagree, the ledger is right and this
/// is the bug. `app/test/fx_test.dart` asserts it against the same
/// figures as `supabase/tests/multicurrency.sql`, which is what keeps
/// them from drifting apart.
///
/// A receivable is an asset: a rate that falls between invoice and
/// receipt means it was worth less than booked, a loss. A payable is a
/// liability: a rate that rises between bill and payment means settling
/// it cost more than booked, also a loss. Same movement, opposite
/// arithmetic.
double realisedFx({
  required bool isReceipt,
  required double settlementRate,
  required Iterable<({double amount, double documentRate})> allocations,
}) {
  var total = 0.0;
  for (final a in allocations) {
    final movement = isReceipt
        ? settlementRate - a.documentRate
        : a.documentRate - settlementRate;
    total += (a.amount * movement * 100).round() / 100;
  }
  return total;
}

/// What a settlement is being recorded in, read off the documents it is
/// applied to.
class SettlementCurrency {
  const SettlementCurrency(this.code, {this.conflict});

  /// The currency the receipt or payment must carry.
  final String code;

  /// Set when the chosen documents are not all in one currency, in which
  /// case the settlement cannot be recorded at all.
  final String? conflict;

  bool get isConflicting => conflict != null;
}

/// A receipt has one currency and one rate; the invoices it clears each
/// have their own. `app.realised_fx_on_settlement` refuses the mixture
/// with SQLSTATE 22023 rather than inventing a cross-rate, so the dialog
/// refuses it too — with the document numbers, which the error does not
/// give until it is too late to change the selection.
SettlementCurrency settlementCurrency(
  Iterable<BusinessDocument> allocated,
  String baseCurrency,
) {
  final byCurrency = <String, List<String>>{};
  for (final doc in allocated) {
    byCurrency.putIfAbsent(doc.currency, () => []).add(doc.docNo);
  }

  if (byCurrency.isEmpty) return SettlementCurrency(baseCurrency);
  if (byCurrency.length == 1) return SettlementCurrency(byCurrency.keys.first);

  final described = [
    for (final e in byCurrency.entries) '${e.value.join(', ')} in ${e.key}',
  ];
  return SettlementCurrency(
    byCurrency.keys.first,
    conflict: 'One payment cannot settle documents in different currencies: '
        '${described.join('; ')}. Record them separately.',
  );
}
