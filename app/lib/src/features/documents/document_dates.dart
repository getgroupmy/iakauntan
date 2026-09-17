/// The two dates on a sales document, and which types carry them.
///
/// `sales_documents.valid_until` and `delivery_date` have been columns
/// since `0005` — the first even carries the comment `-- quotations` —
/// and until `0374` nothing wrote or read either. A quotation could be
/// turned into an invoice a year later at last year's prices, and a
/// delivery date promised on a quote was dropped at every transfer.
///
/// The rules are the database's; these are here so the fields appear on
/// the documents that have them and the form can say what a date means
/// before somebody presses Save.
library;

/// A validity belongs to an offer, and only to an offer.
///
/// A quotation and a proforma are both prices held open until a date. An
/// invoice has a due date instead — the day it must be paid, which is a
/// different fact — and an order is a commitment already made.
bool showsValidUntil(String docType) =>
    docType == 'quotation' || docType == 'proforma';

/// A promised delivery belongs to the documents about goods moving.
///
/// Not to an invoice: an invoice's delivery date would be a statement
/// about a delivery that already happened, and `0374` deliberately does
/// not carry a promise into one.
bool showsDeliveryDate(String docType) => const {
      'quotation',
      'sales_order',
      'delivery_order',
      'purchase_order',
      'goods_received',
    }.contains(docType);

/// Thirty days from the document date, the ordinary quotation validity.
///
/// A default rather than a rule: somebody quoting steel in a moving
/// market wants a week, and somebody quoting a service may want a
/// quarter. The point is that a new quotation arrives with a date on it
/// instead of arriving with none and never getting one.
DateTime defaultValidUntil(DateTime docDate) =>
    DateTime(docDate.year, docDate.month, docDate.day + 30);

/// Whether this offer has run out.
bool quoteExpired(DateTime? validUntil, {DateTime? today}) {
  if (validUntil == null) return false;
  final now = today ?? DateTime.now();
  return DateTime(validUntil.year, validUntil.month, validUntil.day)
      .isBefore(DateTime(now.year, now.month, now.day));
}

/// The sentence under the date, in the words the consequence deserves.
///
/// Null where there is nothing to say, so a document with a healthy date
/// carries no chatter.
String? validityNote(String docType, DateTime? validUntil,
    {DateTime? today}) {
  if (!showsValidUntil(docType)) return null;
  if (validUntil == null) {
    // Not an error. Every quotation raised before `0374` has none, and
    // the transfer treats a missing date as "no expiry" rather than as
    // expired — but somebody looking at the field should know that is
    // what they are choosing.
    return 'With no date the price is held open indefinitely.';
  }
  if (quoteExpired(validUntil, today: today)) {
    return 'This price has run out. It cannot be turned into an order or '
        'an invoice until the date is extended.';
  }
  final days = DateTime(validUntil.year, validUntil.month, validUntil.day)
      .difference(DateTime(
          (today ?? DateTime.now()).year,
          (today ?? DateTime.now()).month,
          (today ?? DateTime.now()).day))
      .inDays;
  if (days <= 7) {
    return 'Good for $days more day${days == 1 ? '' : 's'}.';
  }
  return null;
}
