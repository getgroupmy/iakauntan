import '../../core/format.dart';
import '../../data/models.dart';

/// What the settings screen says about the bill.
///
/// 0488 let an owner switch a paid add-on on and told them "RM 39.00 a
/// month is added to this company from today". 0489 writes the invoice
/// that keeps that promise — on the first of the following month. Between
/// those two dates the company has agreed to a price and has nothing to
/// look at, which is the same gap moved a month later.
///
/// Kept apart from the card that draws it, as `module_offer.dart` is
/// and for the same reason: these are sentences about money, and a
/// sentence assembled inside a `build` method among the padding is a
/// sentence nobody can assert.

/// The heading figure. A company holding no paid add-ons is told so in
/// words rather than shown "RM 0.00", which reads like a fault.
String subscriptionRunningTotal(SubscriptionMonth s) =>
    s.lines.isEmpty ? 'Nothing this month' : Fmt.money(s.subtotal);

/// The line under it.
///
/// Two facts a person actually needs: which month is being counted, and
/// that the invoice has not been raised yet — because a figure with no
/// date beside it is read as a demand.
String subscriptionRunningLine(SubscriptionMonth s) {
  final month = Fmt.monthYear(s.month);
  if (s.lines.isEmpty) {
    return 'No paid add-ons are on this company, so $month costs nothing.';
  }
  return '$month so far. The invoice for it is raised on the first of '
      'next month, and anything added or taken off before then changes '
      'this figure.';
}

/// One row. The days are shown only where they explain the amount:
/// a module on for the whole month is simply its price.
String subscriptionChargeLine(ModuleCharge c) =>
    c.isPartial ? '${c.name} · ${c.days} of ${c.daysInMonth} days' : c.name;

/// Whether an invoice is still owed. `void` is neither paid nor owing —
/// it is withdrawn — so it counts towards nothing.
bool subscriptionInvoiceOwing(Map<String, dynamic> invoice) =>
    (invoice['status'] as String? ?? 'issued') == 'issued';

/// What the company owes across the invoices it has been shown.
double subscriptionOutstanding(List<Map<String, dynamic>> invoices) {
  var total = 0.0;
  for (final i in invoices) {
    if (subscriptionInvoiceOwing(i)) {
      total += (i['total_amount'] as num?)?.toDouble() ?? 0;
    }
  }
  return total;
}

/// The word beside an invoice.
String subscriptionInvoiceStatus(Map<String, dynamic> invoice) =>
    switch (invoice['status'] as String? ?? 'issued') {
      'paid' => 'Paid',
      'void' => 'Cancelled',
      _ => 'Due',
    };
