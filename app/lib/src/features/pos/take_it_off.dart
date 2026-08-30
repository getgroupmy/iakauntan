/// Taking something back off a parked bill.
///
/// `remove_pos_sale_promotion` and `clear_pos_delivery` are both in the
/// schema and neither had a caller. A voucher typed in error stayed on
/// the bill until it was tendered; an address taken for the wrong order
/// could be corrected but never removed, so the ride stayed on the
/// total and the customer was charged for a run nobody was making.
library;

/// Whether anything can still be taken off this bill.
///
/// Both functions refuse a bill that is not parked, in the same words:
/// once it is tendered, "where it went is part of what was reported for
/// the day". A completed bill is corrected by voiding it, not by
/// quietly removing rows from underneath what was banked.
bool billIsStillOpen(String? saleStatus) => saleStatus == 'parked';

/// Whether the delivery can be taken back.
///
/// `clear_pos_delivery` refuses one a driver already has: "Once a
/// driver has it, the run happened. Whatever the shop wants to record
/// instead, it is not 'there was never a delivery'." Only a run still
/// waiting for a driver can be treated as never having existed.
bool deliveryCanBeCleared({
  required String? saleStatus,
  required String? deliveryStatus,
}) =>
    billIsStillOpen(saleStatus) &&
    (deliveryStatus == null || deliveryStatus == 'pending');

/// Why it cannot, said in the words the shop uses.
String? deliveryClearBlockedBecause({
  required String? saleStatus,
  required String? deliveryStatus,
}) {
  if (!billIsStillOpen(saleStatus)) {
    return 'This bill has been tendered. Where it went is part of what '
        'was reported for the day.';
  }
  if (deliveryStatus != null && deliveryStatus != 'pending') {
    return 'A driver already has it. Mark the run failed instead.';
  }
  return null;
}

/// Whether a promotion row can be taken off.
///
/// A blocked promotion — one that took nothing off because the basket
/// no longer qualifies — is still a row somebody typed in, and removing
/// it is how they take it back. The function does not distinguish, and
/// neither does this.
bool promotionCanBeRemoved(String? saleStatus) => billIsStillOpen(saleStatus);
