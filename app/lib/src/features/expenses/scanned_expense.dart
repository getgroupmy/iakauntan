import '../../core/format.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';

/// What a read receipt puts on the expense form.
///
/// Every field is null where the reading said nothing, and null means
/// "leave the form as it is" rather than "clear it" — the form opens
/// with a date of today and a payment mode of bank transfer, and a
/// receipt that does not say must not overwrite either with a blank.
class ScannedExpense {
  const ScannedExpense({
    this.description,
    this.reference,
    this.date,
    this.paymentModeCode,
    this.amount,
    this.taxCodeId,
    this.foreignCurrency,
  });

  final String? description;
  final String? reference;
  final DateTime? date;

  /// A `ref_payment_modes.code`, and only ever one the company actually
  /// offers. See [scannedExpense].
  final String? paymentModeCode;

  /// What goes in the Amount box, which is the figure BEFORE tax when a
  /// tax code was matched and the figure actually paid when one was
  /// not. The reason is in [scannedExpense] and it is the decision this
  /// whole file exists for.
  final double? amount;

  /// The tax code whose rate reproduces the printed tax exactly, or
  /// null. Never a guess: see [scannedExpense].
  final String? taxCodeId;

  /// The currency the document is in, when that is NOT the company's
  /// own. Null for an ordinary ringgit receipt.
  ///
  /// The form has nothing to put it in — `expenses.currency` defaults to
  /// `MYR`, `exchange_rate` to 1, and `recordExpense` sets neither — so
  /// this exists to be SAID rather than stored. A USD receipt posted as
  /// ringgit is a wrong number that looks like a right one, and the
  /// person holding the paper is the only one who can catch it.
  final String? foreignCurrency;

  bool get isEmpty =>
      description == null &&
      reference == null &&
      date == null &&
      paymentModeCode == null &&
      amount == null &&
      taxCodeId == null &&
      foreignCurrency == null;
}

/// What a reading fills in on the expense form.
///
/// Two sources, in the order `scanned_contact.dart` sets out:
/// [OcrExtraction.fields] is what the READER was asked for, keyed by
/// `expenses`' own column names — `0681` hands it that list — and the
/// typed properties are what the app made of the document afterwards
/// and are the fallback.
///
/// Four of the eight configured columns had no path into this form at
/// all before this: the reader's own `description` (the "being payment
/// of" line, in the words on the page), `payment_mode_code`,
/// `currency`, and `tax_amount`.
///
/// ---------------------------------------------------------------
/// THE TAX, which is the decision worth reading
///
/// The form does not take a tax figure. It takes a tax CODE and
/// computes the tax from its rate, and that figure is stored — so a
/// printed tax amount cannot simply be written somewhere.
///
/// What it can do is choose the code, and only when the choice is
/// certain: a code is picked only where `Fmt.taxOn(net, rate)` — the
/// exact arithmetic the form itself will apply — reproduces the printed
/// tax to the cent. Matching with the form's own function rather than
/// with `tax / net` is what makes the match mean something: what is
/// chosen recomputes to what is printed, by construction.
///
/// WHERE NOTHING MATCHES, THE AMOUNT BECOMES THE TOTAL. This is the
/// part that changes an existing behaviour, and it fixes a silent
/// under-recording: the form used to take `subtotal ?? total`, so a
/// receipt printing 100.00 + 6.00 = 106.00 with no matching tax code
/// posted an expense of 100.00 with no tax — six ringgit of a real
/// payment simply gone, in the ledger, with nothing on screen saying
/// so. A company that cannot match the code is a company not claiming
/// the input tax, and for it the whole 106.00 IS the cost.
ScannedExpense scannedExpense(
  OcrExtraction? read, {
  List<TaxCode> taxCodes = const [],
  Iterable<Map<String, dynamic>> paymentModes = const [],
  String homeCurrency = 'MYR',
}) {
  if (read == null) return const ScannedExpense();

  final fields = <String, String>{
    for (final e in read.fields.entries)
      if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
  };

  // The reader's own words for what the money was for. Only where it
  // did not answer is the old pairing used -- supplier and document
  // number joined -- which describes who was paid rather than what for.
  final described = fields['description'] ??
      [read.supplierName, read.documentNo].whereType<String>().join(' · ');

  final printed = _money(fields['amount']) ?? read.subtotal;
  final tax = _money(fields['tax_amount']) ?? read.taxAmount;
  final total = _money(fields['total_amount']) ?? read.totalAmount;
  final code = _taxCode(taxCodes, printed, tax);

  final currency = fields['currency']?.toUpperCase() ?? read.currency;

  return ScannedExpense(
    description: described.isEmpty ? null : described,
    reference: fields['reference'] ?? read.documentNo,
    date: _date(fields['expense_date']) ?? read.documentDate,
    paymentModeCode: _mode(paymentModes, fields['payment_mode_code']),
    amount: code != null ? printed : (total ?? printed),
    taxCodeId: code?.id,
    foreignCurrency:
        currency != null && currency != homeCurrency.toUpperCase()
            ? currency
            : null,
  );
}

/// The code whose rate reproduces the printed tax, or null.
///
/// Null wherever there is any doubt: no tax printed, no net to compute
/// it on, the list not loaded, or nothing that matches — a Singapore
/// receipt at 9% against a chart that only knows 6%, say. The first
/// match wins where a chart carries two codes at one rate; they produce
/// the same figure, and picking by name would be a guess about which
/// one this purchase belongs to.
///
/// A zero-rated code needs no mention here: it produces nothing, and a
/// tax of nothing never gets this far. `isExempt` DOES, because it is a
/// claim about the purchase rather than a rate, and a chart can carry
/// one beside a rate that would match.
TaxCode? _taxCode(List<TaxCode> codes, double? net, double? tax) {
  if (net == null || tax == null || tax <= 0 || net <= 0) return null;
  for (final c in codes) {
    if (c.isExempt) continue;
    // Within half a sen rather than `==`. Both sides are figures held
    // to two decimals, so the comparison IS exact to the cent -- and
    // written as an equality between two doubles it would be one
    // representation change away from silently matching nothing.
    if ((Fmt.taxOn(net, c.rate) - tax).abs() < 0.005) return c;
  }
  return null;
}

/// A code the company actually offers, or null.
///
/// `payment_mode_code` is a foreign key into `ref_payment_modes`, so
/// the same rule as the contact form's state applies: an answer nothing
/// matches leaves the form's own default alone rather than being
/// written through to fail at save time. The reader is given the eight
/// codes in its instructions and still answers `cash` or `04 credit
/// card` often enough to be worth refusing rather than trusting.
String? _mode(Iterable<Map<String, dynamic>> modes, String? answer) {
  if (answer == null) return null;
  for (final m in modes) {
    if ('${m['code']}' == answer) return answer;
  }
  return null;
}

/// The day a document was dated, or null.
///
/// Read off the TEXT, and deliberately not through `DateTime.tryParse`.
/// `expenses.expense_date` is a `date`, and tryParse answers a moment
/// in time: a reader that returns `2026-03-04T18:00:00Z` parses to an
/// instant which is already the fifth in Malaysia, so anything that
/// then reads its local components files a document dated the fourth on
/// the fifth. Taking the three numbers as printed cannot do that on any
/// machine, which is the point — a defect that only appears east of UTC
/// is one no test run in CI would ever show.
///
/// Anything that does not begin with the `YYYY-MM-DD` the schema asks
/// for is refused, and refusing is the right answer: a bare `2026` or a
/// Malaysian `04/03/2026` turned into a date is a date that looks
/// entered, on an expense somebody files.
DateTime? _date(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(value);
  if (m == null) return null;
  return DateTime(
      int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// A figure as the schema asks for it: digits and one dot.
double? _money(String? value) {
  if (value == null) return null;
  final n = double.tryParse(value.replaceAll(',', ''));
  if (n == null || n.isNaN || n.isInfinite) return null;
  return n;
}
