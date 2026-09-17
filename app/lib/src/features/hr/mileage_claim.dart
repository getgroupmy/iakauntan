/// A claim measured rather than stated.
///
/// `claim_types.is_mileage`, `rate_per_unit` and `unit_label`, and the
/// line's `quantity` and `rate`, had all existed since 0027 and none had
/// ever been read. 0368 prices a mileage line as quantity times rate in
/// the database, which is where it has to be — but the person filing the
/// claim needs to be asked for a distance rather than an amount, and to
/// see what it comes to before they press Send.
library;

/// Whether this claim type is claimed by the unit rather than by the
/// ringgit.
bool isMileage(Map<String, dynamic>? claimType) =>
    claimType?['is_mileage'] == true;

/// What the amount box should be labelled for this type.
///
/// The unit the shop named, because "Quantity" does not tell somebody
/// they are being asked for kilometres — and a claim form that has to be
/// explained is a claim form people get wrong.
String claimQuantityLabel(Map<String, dynamic>? claimType) {
  final unit = (claimType?['unit_label'] as String?)?.trim();
  return unit == null || unit.isEmpty
      ? 'How many *'
      : 'How many ${unit}s *';
}

/// What the claim comes to, or null when it cannot be worked out yet.
///
/// Shown before Send rather than discovered afterwards. The database
/// computes the figure that is stored — two numbers that should agree
/// and are stored separately are two numbers that will not — and this is
/// the same arithmetic for the one purpose the screen has: telling
/// somebody what they are about to claim.
double? mileageAmount({
  required Map<String, dynamic>? claimType,
  required String quantity,
}) {
  if (!isMileage(claimType)) return null;
  final qty = double.tryParse(quantity.trim());
  final rate = (claimType?['rate_per_unit'] as num?)?.toDouble() ?? 0;
  if (qty == null || qty <= 0 || rate <= 0) return null;
  return double.parse((qty * rate).toStringAsFixed(2));
}

/// Why a mileage claim cannot be filed yet, or null when it can.
String? mileageBlockedBecause({
  required Map<String, dynamic>? claimType,
  required String quantity,
}) {
  if (!isMileage(claimType)) return null;
  final rate = (claimType?['rate_per_unit'] as num?)?.toDouble() ?? 0;
  // A type marked mileage with no rate is a setup somebody has not
  // finished. The database refuses it; saying so here saves the round
  // trip and names the thing to go and fix.
  if (rate <= 0) {
    return 'No rate is set for this category yet. Ask whoever looks '
        'after the claim types.';
  }
  final qty = double.tryParse(quantity.trim());
  if (qty == null || qty <= 0) return 'Say how many.';
  return null;
}
