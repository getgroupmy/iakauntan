/// The customs tariff code on an item, and the one mistake worth
/// catching before the round trip.
///
/// `0636`. Malaysia's tariff codes live in the PDK — thousands of
/// lines, revised on a schedule of its own, and not published as
/// anything this repository can seed and keep current. So neither the
/// database nor this file validates MEMBERSHIP: refusing a code that
/// is correct is worse than accepting one that is wrong, because the
/// first stops an invoice that should go and the second is caught by
/// the customs officer who reads it.
///
/// What is checked is SHAPE, and it exists to catch one realistic
/// error: a description typed into the box under the one labelled
/// "e-Invoice classification", because the two fields sit together and
/// are constantly confused. Our own gap analysis confused them.
library;

/// The same rule as the database's `items_tariff_code_shape`, said
/// before the round trip so the message names the field rather than a
/// constraint.
final _shape = RegExp(r'^[0-9]{4}[0-9.]{0,10}$');

/// Why this cannot be saved, or null. Blank is a valid answer — a
/// service has no tariff code, and most items will never carry one.
String? tariffCodeProblem(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  if (_shape.hasMatch(v)) return null;
  // Naming the shape rather than saying "invalid": somebody who typed
  // "Natural rubber" needs to know a number is wanted, and somebody
  // who typed "400" needs to know how many digits.
  return 'A tariff code is four to fourteen digits, dots allowed — '
      '4001, 4001.10 or 4001.10.10.00.';
}
