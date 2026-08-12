import '../../data/models.dart';

/// What a customer owes, split by how overdue it is.
///
/// The arithmetic lives apart from the PDF because it is the part that
/// can be wrong in a way nobody notices: a statement whose buckets do not
/// add up to the total is a statement somebody will dispute, and by then
/// it has already been e-mailed.
class Ageing {
  const Ageing({
    required this.current,
    required this.upTo30,
    required this.upTo60,
    required this.upTo90,
    required this.over90,
  });

  /// Not yet due — including anything with no due date at all, which is
  /// the only defensible place to put it. Calling a document overdue
  /// when nobody ever agreed a date invites an argument the business
  /// will lose.
  final double current;
  final double upTo30;
  final double upTo60;
  final double upTo90;
  final double over90;

  double get total => current + upTo30 + upTo60 + upTo90 + over90;

  List<(String, double)> get buckets => [
        ('Not yet due', current),
        ('1–30 days', upTo30),
        ('31–60 days', upTo60),
        ('61–90 days', upTo90),
        ('Over 90 days', over90),
      ];
}

/// Buckets the outstanding balances by days past the due date.
///
/// The boundaries are inclusive at the top of each band — 30 days
/// overdue is in "1–30", not "31–60" — which is the convention every
/// Malaysian aged-receivables report uses, and the one a customer
/// checking your statement against theirs will assume.
///
/// Every balance is converted to base currency at the rate its own
/// document was raised at. Adding USD 10,000 to RM 5,000 and printing
/// 15,000 is the arithmetic this file exists to prevent, and it only
/// became reachable when the editor started letting anyone pick a
/// currency. Documents in base currency carry a rate of 1, so nothing
/// changes for books that never leave the ringgit.
Ageing ageing(List<BusinessDocument> documents, DateTime asAt) {
  var current = 0.0, upTo30 = 0.0, upTo60 = 0.0, upTo90 = 0.0, over90 = 0.0;

  // Compare whole days, not instants: a document due today is not one
  // hour overdue because the report ran in the afternoon.
  final today = DateTime(asAt.year, asAt.month, asAt.day);

  for (final doc in documents) {
    final balance = doc.balanceAmount * doc.exchangeRate;
    if (balance == 0) continue;

    final due = doc.dueDate;
    if (due == null) {
      current += balance;
      continue;
    }

    final days =
        today.difference(DateTime(due.year, due.month, due.day)).inDays;
    if (days <= 0) {
      current += balance;
    } else if (days <= 30) {
      upTo30 += balance;
    } else if (days <= 60) {
      upTo60 += balance;
    } else if (days <= 90) {
      upTo90 += balance;
    } else {
      over90 += balance;
    }
  }

  return Ageing(
    current: current,
    upTo30: upTo30,
    upTo60: upTo60,
    upTo90: upTo90,
    over90: over90,
  );
}
