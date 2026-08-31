/// What a customer saves by paying early, as the receipt screen has to
/// present it.
///
/// The terms and the arithmetic are the database's — `0385`'s
/// `settlement_discount_available` — and are asked for rather than
/// worked out again, because a screen that offered a discount the
/// ledger would refuse is worse than one that offered none.
///
/// What is decided here is how the offer reads and what the receipt
/// form does with it.
library;

/// A settlement discount as it stands on a given day.
class DiscountOffer {
  const DiscountOffer({
    required this.deadline,
    required this.discount,
    required this.payNow,
    required this.stillOpen,
  });

  /// The last day it can be taken. Null when the terms offer none.
  final DateTime? deadline;
  final double discount;

  /// What settles the document today: the balance, less the discount
  /// where it is still on offer.
  final double payNow;
  final bool stillOpen;

  /// Whether there is anything to say about it at all. Terms with no
  /// discount are the ordinary case and deserve no line on the screen.
  bool get isOffered => deadline != null;

  factory DiscountOffer.fromJson(Map<String, dynamic> j) => DiscountOffer(
        deadline: j['deadline'] == null
            ? null
            : DateTime.tryParse(j['deadline'].toString()),
        discount: (j['discount'] as num?)?.toDouble() ?? 0,
        payNow: (j['pay_now'] as num?)?.toDouble() ?? 0,
        stillOpen: j['still_open'] == true,
      );
}

/// How the offer reads on the receipt form.
///
/// Three states, and they are not the same sentence. An offer still
/// open is an invitation; one that has lapsed is a fact worth stating,
/// because otherwise somebody keys the discounted figure from an old
/// email and the allocation is refused with no explanation on screen.
String? describeOffer(DiscountOffer? offer, String Function(double) money) {
  if (offer == null || !offer.isOffered) return null;
  if (offer.stillOpen) {
    return 'Settlement discount of ${money(offer.discount)} if paid by '
        '${_day(offer.deadline!)} — ${money(offer.payNow)} settles it.';
  }
  return 'The settlement discount on this invoice ran out on '
      '${_day(offer.deadline!)}. The full ${money(offer.payNow)} is due.';
}

/// What the form will not send, in the words to show if so.
String? allocationBlockedBecause({
  required double amount,
  required double discount,
  required double balance,
  required DiscountOffer? offer,
}) {
  if (amount <= 0) return 'An allocation is of something.';
  if (discount < 0) return 'A discount is not a negative discount.';
  if (discount > 0) {
    if (offer == null || !offer.isOffered) {
      return 'These terms offer no settlement discount. Raise a credit '
          'note if the reduction is something else.';
    }
    if (!offer.stillOpen) {
      return 'That discount has run out. Taking it now would clear an '
          'invoice the customer has not paid.';
    }
    if (discount > offer.discount + 0.005) {
      return 'The terms allow ${discount.toStringAsFixed(2)} at most — '
          'they offer ${offer.discount.toStringAsFixed(2)}.';
    }
  }
  if (amount + discount > balance + 0.005) {
    return 'The cash and the discount come to more than is owed.';
  }
  return null;
}

String _day(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';
