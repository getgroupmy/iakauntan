import '../../core/format.dart';

/// What the credit banner should say, decided apart from how it looks.
///
/// The banner had three separate reasons to stay silent — no limit set,
/// credit control off, and a balance not yet near the limit — and a
/// customer on credit hold hit all three at once. `enforce_credit_limit`
/// refuses a held customer above the mode and above the limit, so the
/// screen has to as well, and a rule that lives in a `build` method
/// among the padding is a rule nobody can assert.
///
/// So the decision lives here and the widget renders the answer.
enum CreditBannerKind {
  /// Say nothing. Not a fault: a warning shown every time is a warning
  /// nobody sees when it matters.
  none,

  /// On credit hold. Posting is refused whatever the limit or the mode.
  hold,

  /// Owes more than the limit allows.
  over,

  /// Close enough to the limit to be worth saying.
  near,
}

class CreditBannerState {
  const CreditBannerState(
    this.kind, {
    this.contactName,
    this.limit = 0,
    this.outstanding = 0,
    this.available = 0,
    this.blocked = false,
  });

  static const silent = CreditBannerState(CreditBannerKind.none);

  final CreditBannerKind kind;
  final String? contactName;
  final double limit;
  final double outstanding;
  final double available;

  /// Whether the arithmetic — not the hold — will refuse the post. A
  /// hold always refuses, so this says nothing about one.
  final bool blocked;

  bool get shows => kind != CreditBannerKind.none;
}

/// Read a `customer_credit_status` answer.
///
/// Null — nothing loaded yet — is silence rather than a guess.
CreditBannerState creditBannerFor(Map<String, dynamic>? status) {
  if (status == null) return CreditBannerState.silent;

  final control = status['control']?.toString() ?? 'warn';
  final limit = Fmt.toDouble(status['credit_limit']);

  // First, and gated on nothing. The refusal it warns about is gated on
  // nothing either.
  if (status['credit_hold'] == true) {
    return CreditBannerState(
      CreditBannerKind.hold,
      contactName: status['contact_name']?.toString(),
      limit: limit,
      outstanding: Fmt.toDouble(status['outstanding']),
    );
  }

  // A limit of zero is not a limit of nothing; it is no limit set. With
  // credit control off, the arithmetic refuses nothing, so there is
  // nothing to warn about.
  if (control == 'off' || limit <= 0) return CreditBannerState.silent;

  final over = status['over_limit'] == true;
  final available = Fmt.toDouble(status['available']);
  if (!over && available > limit * 0.1) return CreditBannerState.silent;

  return CreditBannerState(
    over ? CreditBannerKind.over : CreditBannerKind.near,
    contactName: status['contact_name']?.toString(),
    limit: limit,
    outstanding: Fmt.toDouble(status['outstanding']),
    available: available,
    blocked: control == 'block',
  );
}
