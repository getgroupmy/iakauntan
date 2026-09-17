/// What is behind a statutory charge's paid date.
///
/// `paid_on` on `property_statutory_charges` was, until `0387`, a date
/// somebody typed. Typing it took the charge off
/// `property_statutory_due` — the one report anyone consults to see
/// what the company still owes the land office and the local authority
/// — with no bill, no supplier, no payment and nothing in the ledger.
///
/// The rule is in the database, where it is enforced. What is here is
/// the part the screen needs: which of the three states a charge is in,
/// and what to say about it before a round trip that would only be
/// refused.
library;

/// How a charge came to be settled, or that it has not been.
enum ChargeSettlement {
  /// Still owed.
  unpaid,

  /// Billed through the books. The bill decides the paid date, and the
  /// screen may not offer to type one.
  bill,

  /// Paid at the counter, or by an owner direct. Allowed, because it
  /// honestly happens — but it has to name the receipt.
  outsideTheBooks,
}

/// Which of the three a charge row is in.
///
/// The bill takes precedence over the date, deliberately: a charge with
/// a bill has its date derived from that bill, so the bill is the
/// record even on the tick where the date has not caught up.
ChargeSettlement settlementOf(Map<String, dynamic> charge) {
  if (charge['bill_document_id'] != null) return ChargeSettlement.bill;
  if (charge['paid_on'] != null) return ChargeSettlement.outsideTheBooks;
  return ChargeSettlement.unpaid;
}

/// A short phrase for the list.
String describeSettlement(Map<String, dynamic> charge) {
  switch (settlementOf(charge)) {
    case ChargeSettlement.bill:
      final no = charge['bill_no'] as String?;
      return charge['paid_on'] == null
          ? (no == null ? 'On a bill' : 'On bill $no')
          : (no == null ? 'Paid, on a bill' : 'Paid, on bill $no');
    case ChargeSettlement.outsideTheBooks:
      final ref = (charge['reference'] as String?)?.trim();
      return (ref == null || ref.isEmpty)
          ? 'Paid outside the books'
          : 'Paid outside the books — $ref';
    case ChargeSettlement.unpaid:
      return 'Owed';
  }
}

/// Why the paid date cannot be saved as it stands, or null if it can.
///
/// The database refuses this too, and its refusal is the one that
/// counts. This says the same thing without a round trip, and in the
/// place the person is typing.
String? paidDateBlockedBecause({
  required bool hasBill,
  required DateTime? paidOn,
  required String? reference,
}) {
  // A billed charge takes its date from the bill; whatever is typed is
  // overwritten rather than refused, so there is nothing to block.
  if (hasBill) return null;
  if (paidOn == null) return null;
  if ((reference ?? '').trim().isEmpty) {
    return 'Give the receipt number, or bill it to the authority. '
        'A date on its own takes the charge off the due list with '
        'nothing behind it.';
  }
  return null;
}

/// Whether a charge can be turned into a supplier bill.
///
/// Not one already billed, not one already marked paid by hand — the
/// two would each claim to be the record of the same payment — and not
/// a nil one.
bool canBill(Map<String, dynamic> charge) {
  if (charge['bill_document_id'] != null) return false;
  if (charge['paid_on'] != null) return false;
  final amount = charge['amount'];
  final value = amount is num
      ? amount.toDouble()
      : double.tryParse('${amount ?? ''}') ?? 0;
  return value > 0;
}

/// Why billing is not offered, for the tooltip on the disabled button.
String whyNotBillable(Map<String, dynamic> charge) {
  if (charge['bill_document_id'] != null) {
    final no = charge['bill_no'] as String?;
    return no == null
        ? 'Already on a bill.'
        : 'Already on bill $no.';
  }
  if (charge['paid_on'] != null) {
    return 'Already marked paid. Clear the paid date first, so there is '
        'one record of the payment and not two.';
  }
  return 'A bill is for something. This charge is nil.';
}
