import '../../core/format.dart';

/// A bill that is already on the books and looks like the one being
/// entered.
///
/// `0628`. Paying a supplier's invoice twice is the most expensive
/// routine mistake in accounts payable, and until this nothing in the
/// product looked for it.
///
/// The words are here rather than in the screen for the reason
/// `customer_portal_summary.dart` gives: a warning assembled inside a
/// `build` method among the padding is a warning nobody can assert, and
/// this one has to be exactly right or it gets dismissed by reflex.

class DuplicateBill {
  const DuplicateBill({
    required this.id,
    required this.docNo,
    required this.reason,
    required this.total,
    required this.currency,
    required this.status,
    this.docDate,
    this.supplierDocNo,
  });

  factory DuplicateBill.fromMap(Map<String, dynamic> m) => DuplicateBill(
    id: m['id']?.toString() ?? '',
    docNo: m['doc_no']?.toString() ?? '',
    reason: m['reason']?.toString() ?? '',
    total: Fmt.toDouble(m['total_amount']),
    currency: m['currency']?.toString() ?? 'MYR',
    status: m['status']?.toString() ?? '',
    docDate: Fmt.parseDate(m['doc_date']),
    supplierDocNo: m['supplier_doc_no']?.toString(),
  );

  final String id;
  final String docNo;
  final String reason;
  final double total;
  final String currency;
  final String status;
  final DateTime? docDate;
  final String? supplierDocNo;

  /// Matched on the supplier's own number, which is the reliable case.
  bool get onNumber => reason == 'same number';
}

/// True where at least one match is on the number.
///
/// The two reasons are not equally good and the screen must not pretend
/// they are: a number match is near enough proof, and an
/// amount-and-date match is a coincidence that happens.
bool duplicatesAreStrong(List<DuplicateBill> rows) =>
    rows.any((d) => d.onNumber);

/// The heading, which has to say which kind of match this is.
///
/// A single sentence for both would have to be the weaker one, and a
/// warning that always hedges is a warning people learn to click
/// through — including on the day it was the strong kind.
String duplicateHeadline(List<DuplicateBill> rows) {
  if (rows.isEmpty) return '';
  if (duplicatesAreStrong(rows)) {
    return rows.length == 1
        ? 'You already have this supplier’s invoice number'
        : 'You already have this supplier’s invoice number, more than once';
  }
  return 'This looks like something you have already entered';
}

/// What to do about it, in the words of the decision rather than of the
/// check.
String duplicateAdvice(List<DuplicateBill> rows) {
  if (duplicatesAreStrong(rows)) {
    return 'Entering it again would put the same charge on the books '
        'twice, and it can be paid twice. Open the one below before you '
        'go on.';
  }
  return 'Nothing carries this supplier’s number, but the amount and the '
      'date match. That does happen — two deliveries on one day — so '
      'check rather than assume.';
}

/// One match, as a line somebody can recognise the document from.
///
/// The supplier's own number is first where there is one, because that
/// is what is printed on the paper in their hand. Our own `doc_no` is
/// second and is what they would search for.
String duplicateLine(DuplicateBill d) {
  final parts = <String>[
    if ((d.supplierDocNo ?? '').trim().isNotEmpty)
      'No. ${d.supplierDocNo!.trim()}',
    d.docNo,
    if (d.docDate != null) Fmt.date(d.docDate),
    Fmt.money(d.total, currency: d.currency),
  ];
  // Said out loud, because a draft is not yet a charge and a posted one
  // is — and "you already have this" means something different in each
  // case.
  final state = switch (d.status) {
    'draft' => ' — still a draft',
    'pending' || 'approved' => ' — waiting to be posted',
    'partial' => ' — part paid',
    'completed' => ' — already paid',
    _ => '',
  };
  return '${parts.join(' · ')}$state';
}
