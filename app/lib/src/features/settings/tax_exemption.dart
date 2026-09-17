/// Why a supply is exempt.
///
/// `ref_exemption_reasons` was seeded in `0011` with the Sales Tax and
/// Service Tax exemption orders — EX01 through EX99 — and nothing read
/// it. The tax code editor had a switch saying a code is exempt and no
/// way to say why, so `tax_codes.exemption_reason` stayed null on every
/// code any company created. That column is what
/// `0015_einvoice_prepare` carries onto the e-Invoice line as
/// `tax_exemption_reason`, which LHDN expects on an exempt line.
library;

/// Why an exempt tax code cannot be saved.
///
/// A code marked exempt with no reason is the shape that produces an
/// e-Invoice line claiming exemption and not saying under what. The
/// screen refuses it here, because nothing downstream does: the column
/// is nullable and the prepare step carries whatever is in it.
String? exemptionBlockedBecause({required bool isExempt, String? reason}) {
  if (!isExempt) return null;
  if (reason == null || reason.trim().isEmpty) {
    return 'An exempt code has to say what exempts it. LHDN puts the '
        'reason on the line.';
  }
  return null;
}

/// The reason a tax code carries, given what the switch says.
///
/// Null the moment it stops being exempt. A reason left behind on a
/// code that now charges tax would go out on a line that is not exempt
/// at all.
String? exemptionOf({required bool isExempt, String? reason}) {
  if (!isExempt) return null;
  final trimmed = reason?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// How one reads in the picker.
String exemptionLabel(Map<String, dynamic> row) =>
    '${row['code']} · ${row['description']}';

/// What the field shows for a reason already chosen.
///
/// The bare code where the list does not know it: an order withdrawn
/// since the code was set is still what the code was set under, and
/// blanking it would look like the code had no reason.
String exemptionSummary(Iterable<Map<String, dynamic>> all, String? code) {
  if (code == null || code.trim().isEmpty) return 'Not said';
  for (final r in all) {
    if ('${r['code']}' == code.trim()) return exemptionLabel(r);
  }
  return code.trim();
}
